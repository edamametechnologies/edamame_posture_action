#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO_CONFIG_DEFAULT="$ROOT_DIR/tests/adversarial_scenarios.json"
OUTPUT_ROOT_DEFAULT="$ROOT_DIR/tests/artifacts/adversarial_local"

SCENARIO_ID="all"
MODE="enforcement"
SCENARIO_CONFIG="$SCENARIO_CONFIG_DEFAULT"
OUTPUT_ROOT="$OUTPUT_ROOT_DEFAULT"
KEEP_DAEMON="false"

EDAMAME_POSTURE_CMD="${EDAMAME_POSTURE_CMD:-edamame_posture}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Runs local adversarial CVE-like scenarios for Ubuntu Lima.

Options:
  --scenario <id|all>       Scenario id from config (default: all)
  --mode <learning|enforcement>
                            Assertion mode for expected signals (default: enforcement)
  --config <path>           Path to scenario config JSON
  --output-dir <path>       Directory for evidence artifacts
  --keep-daemon             Do not stop daemon at script exit
  --help                    Show this help

Examples:
  ./tests/run_adversarial_lima.sh --scenario dns_over_https --mode enforcement
  ./tests/run_adversarial_lima.sh --scenario all --mode learning
EOF
}

log() { echo "[adversarial] $*"; }
warn() { echo "[adversarial][warn] $*" >&2; }
fail() { echo "[adversarial][error] $*" >&2; exit 1; }

to_int() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -cd '0-9')"
  [[ -n "$raw" ]] || raw="0"
  printf '%s' "$raw"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
  if [[ "$KEEP_DAEMON" == "true" ]]; then
    log "Leaving daemon running (--keep-daemon set)"
    return
  fi
  set +e
  $EDAMAME_POSTURE_CMD stop >/dev/null 2>&1 || true
  set -e
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      SCENARIO_ID="${2:-}"; shift 2 ;;
    --mode)
      MODE="${2:-}"; shift 2 ;;
    --config)
      SCENARIO_CONFIG="${2:-}"; shift 2 ;;
    --output-dir)
      OUTPUT_ROOT="${2:-}"; shift 2 ;;
    --keep-daemon)
      KEEP_DAEMON="true"; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      fail "Unknown argument: $1" ;;
  esac
done

[[ "$MODE" == "learning" || "$MODE" == "enforcement" ]] || fail "Invalid --mode: $MODE"
[[ -f "$SCENARIO_CONFIG" ]] || fail "Config file not found: $SCENARIO_CONFIG"

require_cmd jq
require_cmd python3
require_cmd curl
require_cmd "$EDAMAME_POSTURE_CMD"

if ! python3 - <<'PY'
import importlib.util, sys
if importlib.util.find_spec("requests") is None:
    sys.exit(1)
PY
then
  log "Installing python requests dependency"
  python3 -m pip install --quiet requests
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

log "Mode=$MODE Scenario=$SCENARIO_ID Config=$SCENARIO_CONFIG"
log "Evidence directory: $RUN_DIR"

WARMUP_SECONDS="$(jq -r '.baseline.warmup_seconds // 20' "$SCENARIO_CONFIG")"
POST_ATTACK_WAIT_SECONDS="$(jq -r '.baseline.post_attack_wait_seconds // 15' "$SCENARIO_CONFIG")"
DEFAULT_WHITELIST="$(jq -r '.baseline.whitelist_name // "github_ubuntu"' "$SCENARIO_CONFIG")"

start_disconnected_daemon() {
  local whitelist_name="$1"
  local i
  local start_output
  log "Starting daemon in disconnected mode"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop edamame_posture.service >/dev/null 2>&1 || true
  fi
  $EDAMAME_POSTURE_CMD stop >/dev/null 2>&1 || true
  pkill -f edamame_posture >/dev/null 2>&1 || true
  sleep 2
  start_output="$($EDAMAME_POSTURE_CMD background-start-disconnected \
    --network-scan \
    --packet-capture \
    --whitelist "$whitelist_name" 2>&1 || true)"
  printf '%s\n' "$start_output"
  if echo "$start_output" | grep -qi "unable to lock pid file"; then
    log "Detected stale pid lock; forcing cleanup and retrying startup once"
    $EDAMAME_POSTURE_CMD stop >/dev/null 2>&1 || true
    pkill -f edamame_posture >/dev/null 2>&1 || true
    sleep 2
    $EDAMAME_POSTURE_CMD background-start-disconnected \
      --network-scan \
      --packet-capture \
      --whitelist "$whitelist_name"
  fi
  sleep 2
  for i in {1..20}; do
    if $EDAMAME_POSTURE_CMD status >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  $EDAMAME_POSTURE_CMD status >/dev/null 2>&1 || fail "Daemon did not become ready"
  sleep "$WARMUP_SECONDS"
}

generate_baseline_traffic() {
  log "Generating baseline traffic"
  curl -s --max-time 15 https://github.com/robots.txt >/dev/null || true
  curl -s --max-time 15 https://api.github.com/zen >/dev/null || true
  curl -s --max-time 15 https://pypi.org/pypi/requests/json >/dev/null || true
  sleep 5
  # Force daemon to flush current sessions into cache used by whitelist builders.
  $EDAMAME_POSTURE_CMD get-sessions >/dev/null 2>&1 || true
}

create_and_load_whitelist() {
  local scenario="$1"
  local scenario_dir="$2"
  local include_process
  local wl_file="$scenario_dir/custom_whitelist.json"
  local attempt=1
  local max_attempts=5
  local endpoint_count=0
  include_process="$(jq -r --arg s "$scenario" '.scenarios[] | select(.id == $s) | .requires_include_process // false' "$SCENARIO_CONFIG")"

  while [[ "$attempt" -le "$max_attempts" ]]; do
    if [[ "$include_process" == "true" ]]; then
      log "Creating process-aware whitelist (--include-process), attempt $attempt/$max_attempts"
      $EDAMAME_POSTURE_CMD create-custom-whitelists --include-process > "$wl_file"
    else
      log "Creating whitelist, attempt $attempt/$max_attempts"
      $EDAMAME_POSTURE_CMD create-custom-whitelists > "$wl_file"
    fi

    endpoint_count="$(jq '[.whitelists[]? | select(.name == "custom_whitelist") | .endpoints? // [] | length] | add // 0' "$wl_file" 2>/dev/null || echo 0)"
    log "Whitelist endpoint count: $endpoint_count"
    if [[ "$endpoint_count" -gt 0 ]]; then
      break
    fi

    attempt=$((attempt + 1))
    if [[ "$attempt" -le "$max_attempts" ]]; then
      log "No endpoints yet; generating extra baseline traffic and retrying"
      generate_baseline_traffic
      sleep 5
    fi
  done

  [[ "$endpoint_count" -gt 0 ]] || fail "Baseline whitelist is empty after retries for scenario=$scenario"

  $EDAMAME_POSTURE_CMD set-custom-whitelists-from-file "$wl_file"
}

run_scenario_payload() {
  local scenario="$1"
  local scenario_dir="$2"
  local payload
  payload="$(jq -r --arg s "$scenario" '.scenarios[] | select(.id == $s) | .command' "$SCENARIO_CONFIG")"
  [[ -n "$payload" && "$payload" != "null" ]] || fail "Missing command in config for scenario=$scenario"

  printf '%s\n' "$payload" > "$scenario_dir/payload.sh"
  chmod +x "$scenario_dir/payload.sh"

  log "Running scenario payload: $scenario"
  bash "$scenario_dir/payload.sh" > "$scenario_dir/payload.log" 2>&1 || true
  sleep "$POST_ATTACK_WAIT_SECONDS"
}

collect_and_assert() {
  local scenario="$1"
  local scenario_dir="$2"
  local require_failure
  local min_nonconforming
  local min_anomalous
  local min_recorded_sessions

  require_failure="$(jq -r --arg s "$scenario" --arg mode "$MODE" '.scenarios[] | select(.id == $s) | if $mode == "enforcement" then .enforcement_expected.require_failure // false else .learning_expected.require_failure // false end' "$SCENARIO_CONFIG")"
  min_nonconforming="$(jq -r --arg s "$scenario" --arg mode "$MODE" '.scenarios[] | select(.id == $s) | if $mode == "enforcement" then .enforcement_expected.min_nonconforming // 0 else .learning_expected.min_nonconforming // 0 end' "$SCENARIO_CONFIG")"
  min_anomalous="$(jq -r --arg s "$scenario" --arg mode "$MODE" '.scenarios[] | select(.id == $s) | if $mode == "enforcement" then .enforcement_expected.min_anomalous // 0 else .learning_expected.min_anomalous // 0 end' "$SCENARIO_CONFIG")"
  min_recorded_sessions="$(jq -r --arg s "$scenario" --arg mode "$MODE" '.scenarios[] | select(.id == $s) | if $mode == "enforcement" then .enforcement_expected.min_recorded_sessions // 1 else .learning_expected.min_recorded_sessions // 1 end' "$SCENARIO_CONFIG")"

  local sessions_file="$scenario_dir/sessions.log"
  local exceptions_file="$scenario_dir/exceptions.log"
  local summary_file="$scenario_dir/result_summary.json"
  local sessions_exit=0

  set +e
  if [[ "$MODE" == "enforcement" ]]; then
    $EDAMAME_POSTURE_CMD get-sessions --fail-on-whitelist --fail-on-anomalous > "$sessions_file" 2>&1
  else
    $EDAMAME_POSTURE_CMD get-sessions > "$sessions_file" 2>&1
  fi
  sessions_exit=$?
  set -e

  $EDAMAME_POSTURE_CMD get-exceptions > "$exceptions_file" 2>&1 || true

  local nonconforming_count anomalous_count unknown_count recorded_sessions
  nonconforming_count="$(to_int "$(grep -ci 'whitelisted:[[:space:]]*nonconforming' "$sessions_file" 2>/dev/null || true)")"
  anomalous_count="$(to_int "$(grep -ci 'anomalous' "$exceptions_file" 2>/dev/null || true)")"
  unknown_count="$(to_int "$(grep -ci 'whitelisted:[[:space:]]*unknown' "$sessions_file" 2>/dev/null || true)")"
  recorded_sessions="$(to_int "$(grep -cve '^[[:space:]]*$' "$sessions_file" 2>/dev/null || true)")"

  local pass="true"
  local reason=()

  if [[ "$require_failure" == "true" && "$sessions_exit" -eq 0 ]]; then
    pass="false"
    reason+=("expected_nonzero_exit")
  fi
  if [[ "$nonconforming_count" -lt "$min_nonconforming" ]]; then
    pass="false"
    reason+=("nonconforming_lt_${min_nonconforming}")
  fi
  if [[ "$anomalous_count" -lt "$min_anomalous" ]]; then
    pass="false"
    reason+=("anomalous_lt_${min_anomalous}")
  fi
  if [[ "$recorded_sessions" -lt "$min_recorded_sessions" ]]; then
    pass="false"
    reason+=("sessions_lt_${min_recorded_sessions}")
  fi

  jq -n \
    --arg scenario "$scenario" \
    --arg mode "$MODE" \
    --arg pass "$pass" \
    --arg reason "$(IFS=,; echo "${reason[*]:-ok}")" \
    --argjson sessions_exit "$sessions_exit" \
    --argjson nonconforming "$nonconforming_count" \
    --argjson anomalous "$anomalous_count" \
    --argjson unknown "$unknown_count" \
    --argjson recorded_sessions "$recorded_sessions" \
    --argjson min_nonconforming "$min_nonconforming" \
    --argjson min_anomalous "$min_anomalous" \
    --argjson min_recorded_sessions "$min_recorded_sessions" \
    '{
      scenario: $scenario,
      mode: $mode,
      pass: ($pass == "true"),
      reason: $reason,
      observed: {
        sessions_exit: $sessions_exit,
        nonconforming: $nonconforming,
        anomalous: $anomalous,
        unknown: $unknown,
        recorded_sessions: $recorded_sessions
      },
      expected: {
        min_nonconforming: $min_nonconforming,
        min_anomalous: $min_anomalous,
        min_recorded_sessions: $min_recorded_sessions
      }
    }' > "$summary_file"

  if [[ "$pass" == "true" ]]; then
    log "Scenario passed: $scenario"
    return 0
  fi

  warn "Scenario failed: $scenario (reason=$(IFS=,; echo "${reason[*]}"))"
  return 1
}

declare -a scenarios=()
if [[ "$SCENARIO_ID" == "all" ]]; then
  while IFS= read -r line; do scenarios+=("$line"); done < <(jq -r '.scenarios[].id' "$SCENARIO_CONFIG")
else
  if ! jq -e --arg s "$SCENARIO_ID" '.scenarios[] | select(.id == $s)' "$SCENARIO_CONFIG" >/dev/null; then
    fail "Unknown scenario id: $SCENARIO_ID"
  fi
  scenarios+=("$SCENARIO_ID")
fi

pass_count=0
fail_count=0

for scenario in "${scenarios[@]}"; do
  scenario_dir="$RUN_DIR/$scenario"
  mkdir -p "$scenario_dir"
  log "===== Scenario: $scenario ====="

  start_disconnected_daemon "$DEFAULT_WHITELIST"
  generate_baseline_traffic
  create_and_load_whitelist "$scenario" "$scenario_dir"
  run_scenario_payload "$scenario" "$scenario_dir"

  if collect_and_assert "$scenario" "$scenario_dir"; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi
done

jq -n \
  --arg mode "$MODE" \
  --arg run_dir "$RUN_DIR" \
  --argjson pass_count "$pass_count" \
  --argjson fail_count "$fail_count" \
  --argjson total "$((pass_count + fail_count))" \
  '{
    mode: $mode,
    run_dir: $run_dir,
    total: $total,
    pass_count: $pass_count,
    fail_count: $fail_count
  }' > "$RUN_DIR/summary.json"

log "Completed. pass=$pass_count fail=$fail_count artifacts=$RUN_DIR"
[[ "$fail_count" -eq 0 ]] || exit 1
