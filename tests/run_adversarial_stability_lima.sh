#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="edamame-posture-action"
SCENARIOS="dns_over_https,cdn_piggyback,process_masquerade"
MODE="enforcement"
ITERATIONS=5
MIN_PASS_RATE=95
MAX_UNKNOWN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Host-side stability runner that drives a dedicated Lima VM.
This avoids long-lived SSH sessions by running one limactl command per scenario.

Options:
  --vm <name>                Lima instance name (default: edamame-posture-action)
  --scenarios <csv>          Scenario ids (default: dns_over_https,cdn_piggyback,process_masquerade)
  --mode <learning|enforcement>
                             Mode forwarded to run_adversarial_lima.sh (default: enforcement)
  --iterations <n>           Number of iterations (default: 5)
  --min-pass-rate <percent>  Minimum pass rate (default: 95)
  --max-unknown <n>          Max unknown sessions allowed (default: 0)
  --help                     Show this help

Example:
  ./tests/run_adversarial_stability_lima.sh --iterations 3 --min-pass-rate 90
EOF
}

log() { echo "[stability-lima] $*"; }
fail() { echo "[stability-lima][error] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM_NAME="${2:-}"; shift 2 ;;
    --scenarios) SCENARIOS="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --iterations) ITERATIONS="${2:-}"; shift 2 ;;
    --min-pass-rate) MIN_PASS_RATE="${2:-}"; shift 2 ;;
    --max-unknown) MAX_UNKNOWN="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

command -v limactl >/dev/null 2>&1 || fail "Missing limactl"
command -v jq >/dev/null 2>&1 || fail "Missing jq"

IFS=',' read -r -a scenario_list <<< "$SCENARIOS"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
HOST_OUT_DIR="$ROOT_DIR/tests/artifacts/adversarial_stability_lima/$RUN_ID"
mkdir -p "$HOST_OUT_DIR"

total=0
pass=0
fail_count=0
unknown_total=0

for iter in $(seq 1 "$ITERATIONS"); do
  log "Iteration $iter/$ITERATIONS"
  for scenario in "${scenario_list[@]}"; do
    scenario="$(echo "$scenario" | xargs)"
    log "Running scenario=$scenario"

    # Run scenario in VM; write artifacts to /tmp inside VM to avoid read-only mounts.
    if limactl shell "$VM_NAME" sudo -n /bin/bash -lc \
      "cd '/Users/flyonnet/Programming/edamame_posture_action' && ./tests/run_adversarial_lima.sh --scenario '$scenario' --mode '$MODE' --output-dir /tmp/adversarial_local" \
      >"$HOST_OUT_DIR/${iter}_${scenario}.stdout.log" 2>&1; then
      :
    fi

    # Find most recent run directory in VM.
    vm_latest="$(limactl shell "$VM_NAME" /bin/bash -lc "ls -1t /tmp/adversarial_local 2>/dev/null | head -1" 2>/dev/null || true)"
    [[ -n "$vm_latest" ]] || fail "Could not find /tmp/adversarial_local runs in VM"

    # Fetch result summary to host for aggregation.
    vm_summary_path="/tmp/adversarial_local/${vm_latest}/${scenario}/result_summary.json"
    summary_json="$(limactl shell "$VM_NAME" /bin/bash -lc "cat '$vm_summary_path' 2>/dev/null" 2>/dev/null || true)"
    if [[ -z "$summary_json" ]]; then
      # If the scenario failed before writing result_summary, record as fail.
      total=$((total + 1))
      fail_count=$((fail_count + 1))
      continue
    fi

    echo "$summary_json" > "$HOST_OUT_DIR/${iter}_${scenario}.result_summary.json"

    total=$((total + 1))
    if jq -e '.pass == true' "$HOST_OUT_DIR/${iter}_${scenario}.result_summary.json" >/dev/null; then
      pass=$((pass + 1))
    else
      fail_count=$((fail_count + 1))
    fi

    unknown_total=$((unknown_total + $(jq -r '.observed.unknown // 0' "$HOST_OUT_DIR/${iter}_${scenario}.result_summary.json" 2>/dev/null || echo 0)))
  done
done

pass_rate="0"
if [[ "$total" -gt 0 ]]; then
  pass_rate="$(python3 - <<PY
total=$total
passed=$pass
print(round((passed*100.0)/total, 2))
PY
)"
fi

cat > "$HOST_OUT_DIR/summary.json" <<EOF
{
  "run_id": "$RUN_ID",
  "vm": "$VM_NAME",
  "mode": "$MODE",
  "iterations": $ITERATIONS,
  "scenarios": "$(echo "$SCENARIOS")",
  "total": $total,
  "pass": $pass,
  "fail": $fail_count,
  "pass_rate_percent": $pass_rate,
  "unknown_total": $unknown_total,
  "thresholds": {
    "min_pass_rate_percent": $MIN_PASS_RATE,
    "max_unknown": $MAX_UNKNOWN
  }
}
EOF

log "Summary written: $HOST_OUT_DIR/summary.json"

python3 - <<PY
import json, sys
data=json.load(open("$HOST_OUT_DIR/summary.json"))
ok = (data["pass_rate_percent"] >= data["thresholds"]["min_pass_rate_percent"]) and (data["unknown_total"] <= data["thresholds"]["max_unknown"])
print(f'pass_rate={data["pass_rate_percent"]}% unknown_total={data["unknown_total"]} ok={ok}')
sys.exit(0 if ok else 1)
PY
