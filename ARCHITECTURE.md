# EDAMAME Posture Action Architecture

## Daemon-Based State Management

The EDAMAME Posture action uses a **daemon-based architecture** where state is maintained by a background process, not by local files.

### Correct Workflow Pattern

```yaml
jobs:
  security:
    steps:
      # 1. Start daemon (downloads artifact, applies whitelist, starts capture)
      - name: Start EDAMAME Posture
        uses: edamametechnologies/edamame_posture_action@main
        with:
          disconnected_mode: true
          network_scan: true
          packet_capture: true
          auto_whitelist: true
          auto_whitelist_artifact_name: my-whitelist
      
      # 2. Generate traffic (daemon captures in background)
      - name: Build and Test
        run: |
          npm install
          npm test
      
      # 3. Talk to daemon via CLI commands (NOT another action invocation)
      - name: Augment Whitelist
        run: |
          cd ~
          # Daemon command: augment whitelist with new traffic
          $EDAMAME_POSTURE_CMD augment-custom-whitelists > auto_whitelist_new.json
          mv auto_whitelist_new.json auto_whitelist.json
      
      # 4. Display sessions from daemon
      - name: Check Sessions
        run: |
          $EDAMAME_POSTURE_CMD get-sessions
      
      # 5. Upload artifacts for next run
      - name: Upload Whitelist
        uses: actions/upload-artifact@v4
        with:
          name: my-whitelist
          path: ~/auto_whitelist*.json
      
      # 6. Stop daemon
      - name: Stop
        uses: edamametechnologies/edamame_posture_action@main
        with:
          stop: true
```

### Key CLI Commands That Talk to Daemon

These commands communicate with the running daemon via gRPC:

- **`create-custom-whitelists`**: Creates whitelist from daemon's captured sessions
- **`augment-custom-whitelists`**: Adds new endpoints to daemon's active whitelist
- **`get-sessions`**: Retrieves sessions from daemon's capture
- **`get-whitelist-name`**: Gets active whitelist name from daemon
- **`set-custom-whitelists-from-file`**: Loads whitelist into daemon
- **`compare-custom-whitelists-from-files`**: Compares whitelists (local operation)

## Why Second Action Invocation Was Wrong

### ❌ Incorrect Pattern (What Was Happening)

```yaml
# Invocation 1: Start daemon
- uses: ./
  with:
    auto_whitelist: true

# Traffic generation
- run: curl https://api.github.com/...

# Invocation 2: Try to augment (WRONG!)
- uses: ./  # ❌ Second action invocation
  with:
    auto_whitelist: true
    dump_sessions_log: true
```

**Problem**: The second action invocation:
1. Downloads artifact from previous **workflow run** (not from Invocation 1!)
2. Can't find it → resets state → creates fresh whitelist
3. Loses all traffic captured by Invocation 1's daemon
4. Result: Endpoint counts fluctuate (30→37→35→33)

### ✅ Correct Pattern (Daemon Commands)

```yaml
# Invocation 1: Start daemon  
- uses: ./
  with:
    auto_whitelist: true

# Traffic generation
- run: curl https://api.github.com/...

# Talk to daemon via CLI (CORRECT!)
- run: |
    cd ~
    $EDAMAME_POSTURE_CMD augment-custom-whitelists > new_whitelist.json
```

**Why it works**:
1. CLI command talks to daemon started by Invocation 1
2. Daemon has all captured traffic in memory
3. `augment-custom-whitelists` adds new exceptions to existing whitelist
4. Result: Monotonically increasing endpoints (30→37→41→45)

## Action's Auto-Whitelist Mode

The `auto_whitelist: true` mode in the action handles:

1. **Downloading previous artifact** from prior workflow runs
2. **Applying whitelist to daemon** before it starts
3. **Uploading artifacts** after workflow completes

But it does **NOT** handle augmentation - that's done via CLI commands talking to the daemon.

## State Flow Across Workflow Runs

```
Workflow Run N:
  [Action] Download artifact N-1 → Apply to daemon → Start capture
  [Traffic] Generate traffic (captured by daemon)
  [CLI] Talk to daemon: augment-custom-whitelists → Save to file
  [Action] Upload artifact N

Workflow Run N+1:
  [Action] Download artifact N → Apply to daemon → Start capture
  [Traffic] Generate traffic (captured by daemon)
  [CLI] Talk to daemon: augment-custom-whitelists → Save to file
  [Action] Upload artifact N+1
```

The daemon is the **single source of truth** during a workflow run. Artifacts are only for **persisting state between workflow runs**.

## Why This Architecture?

**Daemon advantages**:
- Real-time packet capture in background
- In-memory session tracking
- gRPC interface for fast queries
- Stateful whitelist enforcement

**Not file-based because**:
- Files can't capture live traffic
- Files don't maintain session state
- Files require constant read/write
- Files don't support real-time enforcement

## Reference: README Examples

From the README (lines 1700-1828), the recommended pattern for building baselines:

```bash
# Start daemon with whitelist
sudo edamame_posture background-start-disconnected --network-scan --packet-capture --whitelist github_ubuntu

# Run your build
npm install && npm run build

# Talk to daemon: create baseline
edamame_posture create-custom-whitelists > baseline_v1.json

# Next build: Talk to daemon: augment
sudo edamame_posture set-custom-whitelists-from-file baseline_v1.json
npm install && npm run build
edamame_posture augment-custom-whitelists > additional_v2.json

# Merge results (local operation, not daemon)
edamame_posture merge-custom-whitelists-from-files baseline_v1.json additional_v2.json > baseline_v2.json
```

Notice: All whitelist operations either:
1. Talk to the daemon (create/augment/set)
2. Are local file operations (merge/compare)

Never two separate daemon processes trying to share state via files.

