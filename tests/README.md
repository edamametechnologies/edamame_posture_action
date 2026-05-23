# Tests

## Auto-whitelist lifecycle

- `test_auto_whitelist_feature.sh`: drives `.github/workflows/test_auto_whitelist_feature.yml` across multiple runs and checks artifact/state progression.
- `test_auto_whitelist_runner.yml`: long-running runner-pool validation (see README **Artifact naming (runner pools)** for the recommended `auto_whitelist_artifact_name` convention in production workflows).

Production workflows should set `auto_whitelist_artifact_name` from the job's `runs-on` label (for example `edamame-auto-whitelist-${{ matrix.runs-on }}`), not the default single-repo bucket or `runner.os` alone. Details: [README — Automated Whitelist Lifecycle](../README.md#artifact-naming-runner-pools).

## Adversarial scenarios (CVE-style)

Source of truth:
- `adversarial_scenarios.json`: scenario definitions and expected outcomes (`learning` vs `enforcement`).

Local runner:
- `run_adversarial_lima.sh`: executes one scenario (or `all`) and writes evidence to the chosen output directory.

Stability runners:
- `run_adversarial_stability.sh`: repeated local runs (single machine) and a JSON summary.
- `run_adversarial_stability_lima.sh`: host-driven stability runner for a Lima VM.

Suite runner:
- `run_adversarial_suite_lima.sh`: runs a full scenario set against a Lima VM and writes a local summary.

Examples:

```bash
./tests/run_adversarial_lima.sh --scenario dns_over_https --mode enforcement

./tests/run_adversarial_stability_lima.sh \
  --vm edamame-posture-action \
  --iterations 3 \
  --min-pass-rate 95 \
  --max-unknown 0 \
  --scenarios dns_over_https,cdn_piggyback,process_masquerade
```

Evidence:
- `tests/artifacts/` is gitignored; scripts write structured summaries and per-scenario logs there by default.

