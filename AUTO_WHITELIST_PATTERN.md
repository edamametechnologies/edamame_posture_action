# Auto-Whitelist Two-Invocation Pattern

## Overview

The auto-whitelist feature uses a **two-invocation pattern** that mirrors real-world production workflows. This pattern ensures the daemon maintains state while allowing proper augmentation of the whitelist.

## Real-World Usage Pattern

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # ============================================================
      # INVOCATION 1: Setup
      # ============================================================
      - name: Setup EDAMAME Posture
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          disconnected_mode: true
          network_scan: true
          packet_capture: true
          auto_whitelist: true
          auto_whitelist_artifact_name: my-project-whitelist
          # Optional: stability thresholds and limits

      # ============================================================
      # Do Your Work (daemon captures traffic in background)
      # ============================================================
      - name: Build and Test
        run: |
          npm install
          npm run build
          npm test

      # ============================================================
      # INVOCATION 2: Teardown
      # ============================================================
      - name: Dump EDAMAME Posture sessions
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          dump_sessions_log: true
```

## How It Works

### Invocation 1: Setup Phase

**What it does:**
1. Downloads artifact from **previous workflow run** (if exists)
2. Applies whitelist to daemon
3. Starts daemon with packet capture
4. Saves whitelist files to `~/auto_whitelist*.json`

**What gets skipped:**
- Nothing (full setup)

**State after:**
- Daemon running in background
- Whitelist applied to daemon (if iteration > 1)
- Files in `~/`: `auto_whitelist.json`, `auto_whitelist_iteration.txt`, `auto_whitelist_stable_count.txt`

### Traffic Generation Phase

**What happens:**
- Your build, test, deployment steps run
- Daemon captures all network traffic
- Daemon marks whitelist violations as "exceptions"

**No action invocation** - just normal workflow steps

### Invocation 2: Teardown Phase

**What it does:**
1. Loads state from files created by Invocation 1
2. Talks to daemon: `augment-custom-whitelists` (adds new endpoints)
3. Compares old vs new whitelist for stability
4. Updates iteration counters
5. Saves updated whitelist files
6. Uploads artifact for next workflow run

**What gets skipped:**
- Binary download (already done)
- Daemon start (already running)
- Artifact download (using files from Invocation 1)
- Whitelist application (daemon already has it)

**State after:**
- Updated `~/auto_whitelist.json` with augmented endpoints
- Artifact uploaded to GitHub for next workflow run
- Daemon still running (stopped by separate step)

## Action Intelligence

The action automatically detects which phase based on inputs:

| Phase | `auto_whitelist` | `dump_sessions_log` | Behavior |
|-------|------------------|---------------------|----------|
| Setup | `true` | `false` | Download, apply, start daemon |
| Teardown | `true` | `true` | Load state, augment, upload |
| Stop | n/a | n/a | `stop: true` |

## State Flow Across Workflow Runs

```
Workflow Run 1:
  [Invocation 1] No artifact exists → First run → No whitelist applied
  [Traffic] Daemon captures: github.com, npmjs.org (2 endpoints)
  [Invocation 2] create-custom-whitelists → 2 endpoints
  [Upload] Artifact v1: 2 endpoints

Workflow Run 2:
  [Invocation 1] Download artifact v1 → Apply 2 endpoints → Start daemon
  [Traffic] Daemon captures: github.com, npmjs.org, cdn.jsdelivr.net (NEW!)
  [Invocation 2] augment-custom-whitelists → 3 endpoints (2 + 1 new)
  [Upload] Artifact v2: 3 endpoints

Workflow Run 3:
  [Invocation 1] Download artifact v2 → Apply 3 endpoints → Start daemon
  [Traffic] Daemon captures: same 3 endpoints (no new)
  [Invocation 2] augment-custom-whitelists → 3 endpoints (0% change)
  [Stability] Count: 1/3 required
  [Upload] Artifact v3: 3 endpoints

Workflow Run 4:
  [Invocation 1] Download artifact v3 → Apply 3 endpoints → Start daemon
  [Traffic] Same 3 endpoints (no new)
  [Invocation 2] augment-custom-whitelists → 3 endpoints (0% change)
  [Stability] Count: 2/3 required
  [Upload] Artifact v4: 3 endpoints

Workflow Run 5:
  [Invocation 1] Download artifact v4 → Apply 3 endpoints → Start daemon
  [Traffic] Same 3 endpoints (no new)
  [Invocation 2] augment-custom-whitelists → 3 endpoints (0% change)
  [Stability] ✅ STABLE! (3/3 consecutive runs with 0% change)
  [Enforcement] Future runs will now FAIL on violations
```

## Daemon Communication

The augmentation happens via CLI commands that talk to the daemon over gRPC:

```bash
# These commands communicate with the running daemon:
edamame_posture create-custom-whitelists     # First run: create from sessions
edamame_posture augment-custom-whitelists    # Subsequent: add new endpoints
edamame_posture get-sessions                 # Retrieve captured sessions
edamame_posture compare-custom-whitelists-from-files file1.json file2.json  # Local comparison
```

The daemon maintains:
- All captured network sessions in memory
- Active whitelist for real-time checking
- Exception list (sessions that don't match whitelist)

## Why Two Invocations?

**Why not one invocation?**
- Daemon needs to capture traffic DURING your build/test steps
- Can't capture traffic before your build starts
- Can't augment whitelist before traffic is generated

**Why not shell commands only?**
- Action encapsulates artifact management
- Action handles state transitions automatically
- Action provides stability detection
- Simpler for users (no manual artifact handling)

**Why not keep daemon running between workflow runs?**
- Workflow runs are ephemeral
- Each run needs fresh daemon with previous whitelist
- Artifacts persist state between runs

## Configuration Options

```yaml
auto_whitelist: true                             # Enable feature
auto_whitelist_artifact_name: "my-whitelist"    # Artifact name
auto_whitelist_stability_threshold: "0"          # 0% = no new endpoints
auto_whitelist_stability_consecutive_runs: "3"   # 3 runs required
auto_whitelist_max_iterations: "10"              # Max iterations
```

## Testing

The `test_auto_whitelist_feature.yml` workflow demonstrates the pattern:

```bash
# Run test script to trigger multiple iterations
./tests/test_auto_whitelist_feature.sh

# The script:
# 1. Cleans up old artifacts
# 2. Triggers workflow runs sequentially
# 3. Verifies endpoint counts increase/stabilize
# 4. Confirms stability reached after N runs
```

## Troubleshooting

**Problem:** Endpoints not augmenting (count stays same)

**Possible causes:**
1. Second invocation not talking to daemon (daemon stopped?)
2. No new traffic generated between invocations
3. Whitelist not applied in first invocation

**Solution:** Check logs for "augment-custom-whitelists" output

---

**Problem:** Endpoint counts fluctuating (30→37→35)

**Possible causes:**
1. Second invocation creating fresh whitelist instead of augmenting
2. Daemon not running during second invocation
3. State not loaded from first invocation

**Solution:** Verify second invocation sees "Loading state from first invocation"

---

**Problem:** Stability never reached

**Possible causes:**
1. Traffic patterns not consistent (different endpoints each run)
2. External services changing IPs
3. Threshold too strict (try 5% instead of 0%)

**Solution:** Review whitelist diff percentages in logs

## Production Example

From `release_macos_standalone.yml`:

```yaml
# Setup at start of workflow
- name: Setup EDAMAME Posture
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
    edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
    edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
    edamame_id: ${{ github.run_id }}
    auto_remediate: true
    network_scan: true
    # auto_whitelist: true  # Could be added here

# ... 200 lines of build steps ...

# Teardown at end of workflow
- name: Dump EDAMAME Posture sessions
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    dump_sessions_log: true
```

This pattern works for any workflow - just add auto-whitelist to the setup step!

