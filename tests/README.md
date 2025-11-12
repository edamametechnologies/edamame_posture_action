# Test Scripts

This directory contains test scripts for validating EDAMAME Posture Action features.

## test_auto_whitelist_feature.sh

Tests the actual `auto_whitelist: true` feature by sequentially triggering workflow runs and verifying the complete lifecycle.

### What it tests:

1. **Artifact Cleanup**: Ensures a clean state by deleting existing artifacts
2. **Sequential Workflow Runs**: Triggers multiple workflow runs one after another
3. **Lifecycle Verification**: 
   - First run creates initial whitelist
   - Subsequent runs augment the whitelist
   - Checks for stability (no changes for N consecutive runs)
4. **Status Validation**: Verifies each run completes successfully
5. **Stability Detection**: Confirms when auto-whitelist reaches stable state

### Prerequisites:

- `gh` CLI installed (`brew install gh` or see [GitHub CLI docs](https://cli.github.com/))
- Authenticated with GitHub (`gh auth login`)
- Repository access to trigger workflows
- `jq` installed for JSON parsing (usually pre-installed on macOS/Linux)

### Usage:

```bash
# From the repository root
./tests/test_auto_whitelist_feature.sh
```

Or with explicit token:

```bash
GITHUB_TOKEN=your_token ./tests/test_auto_whitelist_feature.sh
```

### Configuration:

Edit the script to customize:

- `MAX_ITERATIONS`: Maximum number of workflow runs (default: 5)
- `STABILITY_REQUIRED`: Number of consecutive stable runs needed (default: 3)
- `ARTIFACT_NAME_PREFIX`: Artifact name prefix (default: "test-auto-whitelist-feature")

### Expected Behavior:

1. **Iteration 1**: Creates initial whitelist from captured traffic
2. **Iteration 2**: Augments whitelist with new endpoints (if any)
3. **Iterations 3-5**: Continues until stability is reached (no changes for 3 consecutive runs)

### Output:

The script provides:
- Color-coded status for each iteration
- Artifact download and validation
- Stability count tracking
- Final test verdict (PASS/FAIL)

### Troubleshooting:

- **Workflow not triggering**: Check `gh auth status` and repository permissions
- **Artifacts not found**: Ensure workflow completed successfully and artifacts were uploaded
- **Stability not reached**: May need more iterations - increase `MAX_ITERATIONS`

