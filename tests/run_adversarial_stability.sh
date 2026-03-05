#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_SCRIPT="$ROOT_DIR/tests/run_adversarial_lima.sh"
OUTPUT_ROOT_DEFAULT="$ROOT_DIR/tests/artifacts/adversarial_stability"

ITERATIONS=10
MIN_PASS_RATE=95
MAX_UNKNOWN_EXCEPTIONS=0
SCENARIOS="dns_over_https,cdn_piggyback,process_masquerade"
MODE="enforcement"
OUTPUT_ROOT="$OUTPUT_ROOT_DEFAULT"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Runs repeated adversarial scenarios and computes stability metrics.

Options:
  --iterations <n>           Number of runs (default: 10)
  --min-pass-rate <percent>  Minimum pass rate (default: 95)
  --max-unknown <n>          Max unknown exceptions allowed (default: 0)
  --scenarios <csv>          Scenario ids (default: dns_over_https,cdn_piggyback,process_masquerade)
  --mode <learning|enforcement>
                             Mode forwarded to run_adversarial_lima.sh (default: enforcement)
  --output-dir <path>        Output directory for stability report
  --help                     Show this help
EOF
}

log() { echo "[stability] $*"; }
fail() { echo "[stability][error] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations) ITERATIONS="${2:-}"; shift 2 ;;
    --min-pass-rate) MIN_PASS_RATE="${2:-}"; shift 2 ;;
    --max-unknown) MAX_UNKNOWN_EXCEPTIONS="${2:-}"; shift 2 ;;
    --scenarios) SCENARIOS="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_ROOT="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -x "$RUNNER_SCRIPT" ]] || fail "Runner script not executable: $RUNNER_SCRIPT"
command -v jq >/dev/null 2>&1 || fail "Missing required command: jq"
command -v bc >/dev/null 2>&1 || fail "Missing required command: bc"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

IFS=',' read -r -a scenario_list <<< "$SCENARIOS"

total_runs=0
total_pass=0
total_fail=0
total_unknown=0
total_nonconforming=0
total_anomalous=0

for i in $(seq 1 "$ITERATIONS"); do
  log "Iteration $i/$ITERATIONS"
  iter_dir="$RUN_DIR/iteration_$i"
  mkdir -p "$iter_dir"

  iter_pass=0
  iter_fail=0

  for scenario in "${scenario_list[@]}"; do
    scenario_trimmed="$(echo "$scenario" | xargs)"
    if "$RUNNER_SCRIPT" --scenario "$scenario_trimmed" --mode "$MODE" --output-dir "$iter_dir" > "$iter_dir/${scenario_trimmed}.stdout.log" 2>&1; then
      iter_pass=$((iter_pass + 1))
    else
      iter_fail=$((iter_fail + 1))
    fi

    latest_summary="$(find "$iter_dir" -name result_summary.json | sort | tail -1)"
    if [[ -n "${latest_summary:-}" && -f "$latest_summary" ]]; then
      total_unknown=$((total_unknown + $(jq -r '.observed.unknown // 0' "$latest_summary" 2>/dev/null || echo 0)))
      total_nonconforming=$((total_nonconforming + $(jq -r '.observed.nonconforming // 0' "$latest_summary" 2>/dev/null || echo 0)))
      total_anomalous=$((total_anomalous + $(jq -r '.observed.anomalous // 0' "$latest_summary" 2>/dev/null || echo 0)))
    fi
  done

  total_runs=$((total_runs + ${#scenario_list[@]}))
  total_pass=$((total_pass + iter_pass))
  total_fail=$((total_fail + iter_fail))
done

if [[ "$total_runs" -eq 0 ]]; then
  fail "No scenarios executed"
fi

pass_rate="$(echo "scale=2; ($total_pass * 100) / $total_runs" | bc -l)"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg mode "$MODE" \
  --arg scenarios "$SCENARIOS" \
  --argjson iterations "$ITERATIONS" \
  --argjson total_runs "$total_runs" \
  --argjson total_pass "$total_pass" \
  --argjson total_fail "$total_fail" \
  --arg pass_rate "$pass_rate" \
  --argjson min_pass_rate "$MIN_PASS_RATE" \
  --argjson max_unknown "$MAX_UNKNOWN_EXCEPTIONS" \
  --argjson observed_unknown "$total_unknown" \
  --argjson observed_nonconforming "$total_nonconforming" \
  --argjson observed_anomalous "$total_anomalous" \
  '{
    run_id: $run_id,
    mode: $mode,
    scenarios: ($scenarios | split(",")),
    iterations: $iterations,
    totals: {
      runs: $total_runs,
      pass: $total_pass,
      fail: $total_fail,
      pass_rate_percent: ($pass_rate | tonumber)
    },
    thresholds: {
      min_pass_rate_percent: $min_pass_rate,
      max_unknown_exceptions: $max_unknown
    },
    observed: {
      unknown_exceptions: $observed_unknown,
      nonconforming_exceptions: $observed_nonconforming,
      anomalous_exceptions: $observed_anomalous
    }
  }' > "$RUN_DIR/stability_summary.json"

log "Stability summary: $RUN_DIR/stability_summary.json"

pass_rate_ok="$(echo "$pass_rate >= $MIN_PASS_RATE" | bc -l)"
unknown_ok="1"
if [[ "$total_unknown" -gt "$MAX_UNKNOWN_EXCEPTIONS" ]]; then
  unknown_ok="0"
fi

if [[ "$pass_rate_ok" != "1" || "$unknown_ok" != "1" ]]; then
  log "FAILED thresholds: pass_rate=${pass_rate}% min=${MIN_PASS_RATE}% unknown=${total_unknown} max=${MAX_UNKNOWN_EXCEPTIONS}"
  exit 1
fi

log "PASS thresholds: pass_rate=${pass_rate}% unknown=${total_unknown}"
