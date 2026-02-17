#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="edamame-posture-action"
MODE="enforcement"
SCENARIOS="all"
MAX_RETRIES=2

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Transport-resilient Lima suite runner.

Runs scenarios one-by-one using short-lived 'limactl shell' invocations, with retries
on transport failures. Artifacts are written to /tmp inside the VM, and a summary is
written locally under tests/artifacts/ (gitignored).

Options:
  --vm <name>                Lima instance name (default: edamame-posture-action)
  --mode <learning|enforcement>
                             Forwarded to run_adversarial_lima.sh (default: enforcement)
  --scenarios <all|csv>      Scenario ids to run (default: all)
  --max-retries <n>          Retries per scenario on transport error (default: 2)
  --help                     Show this help

Example:
  ./tests/run_adversarial_suite_lima.sh --scenarios dns_over_https,cdn_piggyback --max-retries 1
EOF
}

log() { echo "[suite-lima] $*"; }
fail() { echo "[suite-lima][error] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM_NAME="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --scenarios) SCENARIOS="${2:-}"; shift 2 ;;
    --max-retries) MAX_RETRIES="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

command -v limactl >/dev/null 2>&1 || fail "Missing limactl"
command -v jq >/dev/null 2>&1 || fail "Missing jq"

CONFIG_JSON="$ROOT_DIR/tests/adversarial_scenarios.json"
[[ -f "$CONFIG_JSON" ]] || fail "Missing scenario config: $CONFIG_JSON"

declare -a scenario_list=()
if [[ "$SCENARIOS" == "all" ]]; then
  while IFS= read -r s; do scenario_list+=("$s"); done < <(jq -r '.scenarios[].id' "$CONFIG_JSON")
else
  IFS=',' read -r -a scenario_list <<< "$SCENARIOS"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$ROOT_DIR/tests/artifacts/adversarial_suite_lima/$RUN_ID"
mkdir -p "$OUT_DIR"

total=0
passed=0
failed=0

for scenario in "${scenario_list[@]}"; do
  scenario="$(echo "$scenario" | xargs)"
  [[ -n "$scenario" ]] || continue

  log "Running scenario=$scenario"
  total=$((total + 1))

  attempt=0
  success=false
  while [[ "$attempt" -le "$MAX_RETRIES" ]]; do
    attempt=$((attempt + 1))
    log "Attempt $attempt/$((MAX_RETRIES + 1))"

    set +e
    limactl shell "$VM_NAME" sudo -n /bin/bash -lc \
      "cd '/Users/flyonnet/Programming/edamame_posture_action' && ./tests/run_adversarial_lima.sh --scenario '$scenario' --mode '$MODE' --output-dir /tmp/adversarial_local" \
      >"$OUT_DIR/${scenario}.stdout.log" 2>&1
    rc=$?
    set -e

    # Transport errors commonly manifest as 255; treat those as retryable.
    if [[ "$rc" -eq 255 ]]; then
      log "Transport error (rc=255), retrying..."
      sleep 2
      continue
    fi

    # Non-zero can mean test failure; still fetch result_summary if present.
    vm_latest="$(limactl shell "$VM_NAME" /bin/bash -lc "ls -1t /tmp/adversarial_local 2>/dev/null | head -1" 2>/dev/null || true)"
    if [[ -n "$vm_latest" ]]; then
      vm_summary="/tmp/adversarial_local/${vm_latest}/${scenario}/result_summary.json"
      limactl shell "$VM_NAME" /bin/bash -lc "cat '$vm_summary' 2>/dev/null" \
        >"$OUT_DIR/${scenario}.result_summary.json" 2>/dev/null || true
    fi

    if [[ -f "$OUT_DIR/${scenario}.result_summary.json" ]] && jq -e '.pass == true' "$OUT_DIR/${scenario}.result_summary.json" >/dev/null 2>&1; then
      success=true
      break
    fi

    # If the script failed (rc != 0) and we have no result_summary, no point retrying unless transport.
    if [[ "$rc" -ne 0 && ! -f "$OUT_DIR/${scenario}.result_summary.json" ]]; then
      break
    fi

    break
  done

  if [[ "$success" == "true" ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

pass_rate="$(python3 - <<PY
total=$total
passed=$passed
print(round((passed*100.0)/total, 2) if total else 0.0)
PY
)"

cat > "$OUT_DIR/summary.json" <<EOF
{
  "run_id": "$RUN_ID",
  "vm": "$VM_NAME",
  "mode": "$MODE",
  "total": $total,
  "pass": $passed,
  "fail": $failed,
  "pass_rate_percent": $pass_rate,
  "max_retries": $MAX_RETRIES,
  "scenarios": $(jq -n --arg s "$(IFS=,; echo "${scenario_list[*]}")" '$s|split(",")')
}
EOF

log "Summary: $OUT_DIR/summary.json (pass_rate=${pass_rate}%)"
[[ "$failed" -eq 0 ]] || exit 1
