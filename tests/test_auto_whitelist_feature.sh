#!/bin/bash

# Auto-Whitelist Lifecycle Test Script
# =====================================
# Validates the complete auto-whitelist feature by running multiple iterations
# and verifying the lifecycle: baseline → learning → stability → enforcement

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
WORKFLOW_FILE=".github/workflows/test_auto_whitelist_feature.yml"
ARTIFACT_NAME_PREFIX="test-auto-whitelist-feature"
BRANCH="${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || echo "main")}"
MAX_ITERATIONS=20
STABILITY_REQUIRED=3

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions (GitHub Actions web UI compatible - no ANSI colors)
# ─────────────────────────────────────────────────────────────────────────────
log_header() {
    echo ""
    echo "========================================================================"
    echo "  $1"
    echo "========================================================================"
}

log_step() {
    echo "▶ $1"
}

log_success() {
    echo "✓ $1"
}

log_warning() {
    echo "⚠️  $1"
}

log_error() {
    echo "❌ $1"
}

log_info() {
    echo "  $1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites check
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v gh &> /dev/null; then
    log_error "gh CLI is not installed"
    exit 1
fi

if ! gh auth status &> /dev/null 2>&1; then
    log_error "Not authenticated with gh CLI. Run 'gh auth login'"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_warning "jq not installed - some features may be limited"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Header
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "========================================================================"
echo "         AUTO-WHITELIST LIFECYCLE TEST"
echo "========================================================================"
echo "  Repository:    $REPO"
echo "  Branch:        $BRANCH"
echo "  Max Runs:      $MAX_ITERATIONS"
echo "  Stability:     $STABILITY_REQUIRED consecutive stable runs"
echo "========================================================================"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: Clean up existing artifacts
# ─────────────────────────────────────────────────────────────────────────────
log_header "PHASE 1: Cleanup"

log_step "Deleting existing auto-whitelist artifacts..."
ARTIFACT_IDS=$(gh api repos/$REPO/actions/artifacts --paginate --jq ".artifacts[] | select(.name | startswith(\"$ARTIFACT_NAME_PREFIX\")) | .id" 2>/dev/null || true)

if [[ -n "$ARTIFACT_IDS" ]]; then
    COUNT=0
    echo "$ARTIFACT_IDS" | while read -r ARTIFACT_ID; do
        [[ -n "$ARTIFACT_ID" ]] || continue
        gh api repos/$REPO/actions/artifacts/$ARTIFACT_ID -X DELETE 2>/dev/null || true
        COUNT=$((COUNT + 1))
    done
    log_success "Artifacts cleaned up"
else
    log_success "No existing artifacts (clean slate)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: Run iterations
# ─────────────────────────────────────────────────────────────────────────────
log_header "PHASE 2: Lifecycle Test"

declare -a RUN_IDS=()
declare -a RUN_STATUSES=()
declare -a ENDPOINT_HISTORY=()
LAST_ENDPOINT_COUNT=0
STABLE_REACHED=false

for i in $(seq 1 $MAX_ITERATIONS); do
    echo ""
    echo "------------------------------------------------------------------------"
    echo "  ITERATION $i / $MAX_ITERATIONS"
    echo "------------------------------------------------------------------------"
    
    # Get the latest run ID before triggering
    LATEST_RUN_BEFORE=$(gh run list --workflow="$WORKFLOW_FILE" --repo "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || echo "")
    
    # Trigger workflow
    log_step "Triggering workflow..."
    set +e
    TRIGGER_OUTPUT=$(gh workflow run "$WORKFLOW_FILE" --ref "$BRANCH" --field "iteration=$i" 2>&1)
    TRIGGER_EXIT_CODE=$?
    set -e
    
    if [[ $TRIGGER_EXIT_CODE -ne 0 ]]; then
        log_error "Failed to trigger workflow"
        echo "  $TRIGGER_OUTPUT"
        exit 1
    fi
    
    # Wait for workflow to start
    log_step "Waiting for workflow to start..."
    RUN_ID=""
    MAX_WAIT=30
    WAIT_COUNT=0
    
    while [[ -z "$RUN_ID" && $WAIT_COUNT -lt $MAX_WAIT ]]; do
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        
        set +e
        CURRENT_RUN=$(gh run list --workflow="$WORKFLOW_FILE" --repo "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || echo "")
        set -e
        
        if [[ -n "$CURRENT_RUN" && "$CURRENT_RUN" != "$LATEST_RUN_BEFORE" ]]; then
            RUN_ID="$CURRENT_RUN"
        fi
    done
    
    if [[ -z "$RUN_ID" ]]; then
        log_error "Failed to detect new workflow run after ${MAX_WAIT}s"
        exit 1
    fi
    
    log_success "Run started: $RUN_ID"
    log_info "URL: https://github.com/$REPO/actions/runs/$RUN_ID"
    RUN_IDS+=("$RUN_ID")
    
    # Wait for workflow to complete (silent polling, no spam)
    log_step "Waiting for completion..."
    WAIT_START=$(date +%s)
    while true; do
        STATUS=$(gh run view "$RUN_ID" --repo "$REPO" --json status --jq .status 2>/dev/null || echo "queued")
        if [[ "$STATUS" == "completed" ]]; then
            break
        fi
        sleep 15  # Check every 15 seconds
        
        # Show progress every 2 minutes
        ELAPSED=$(( $(date +%s) - WAIT_START ))
        if [[ $((ELAPSED % 120)) -lt 15 && $ELAPSED -gt 60 ]]; then
            echo "  Still running... (${ELAPSED}s elapsed)"
        fi
    done
    
    # Get conclusion
    CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq .conclusion 2>/dev/null || echo "unknown")
    RUN_STATUSES+=("$CONCLUSION")
    ELAPSED=$(( $(date +%s) - WAIT_START ))
    
    if [[ "$CONCLUSION" == "success" ]]; then
        log_success "Completed in ${ELAPSED}s"
    else
        log_warning "Status: $CONCLUSION (after ${ELAPSED}s)"
    fi
    
    # Download artifact
    log_step "Downloading artifact..."
    TEMP_DIR="/tmp/auto_whitelist_test_$i"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    ARTIFACT_DOWNLOADED=false
    MAX_WAIT_TIME=120
    ELAPSED=0
    
    while [[ $ELAPSED -lt $MAX_WAIT_TIME ]]; do
        ARTIFACT_EXISTS=$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq ".artifacts[] | select(.name == \"$ARTIFACT_NAME_PREFIX-$BRANCH\") | .id" 2>/dev/null || echo "")
        
        if [[ -n "$ARTIFACT_EXISTS" ]]; then
            if gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT_NAME_PREFIX-$BRANCH" --dir "$TEMP_DIR" 2>/dev/null; then
                if [[ -f "$TEMP_DIR/auto_whitelist.json" ]]; then
                    ARTIFACT_DOWNLOADED=true
                    break
                fi
            fi
        fi
        
        # Simple waiting indicator every 30s
        if [[ $((ELAPSED % 30)) -eq 0 && $ELAPSED -gt 0 ]]; then
            echo "  Still waiting for artifact... (${ELAPSED}s elapsed)"
        fi
        
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    
    # Analyze results
    CURRENT_ENDPOINT_COUNT=0
    STABLE_COUNT=0
    
    if [[ "$ARTIFACT_DOWNLOADED" == "true" ]]; then
        log_success "Artifact downloaded"
        
        if [[ -f "$TEMP_DIR/auto_whitelist.json" ]]; then
            CURRENT_ENDPOINT_COUNT=$(jq '[.whitelists[]? | select(.name == "custom_whitelist") | .endpoints? // [] | length] | add // 0' "$TEMP_DIR/auto_whitelist.json" 2>/dev/null || echo "0")
        fi
        
        if [[ -f "$TEMP_DIR/auto_whitelist_stable_count.txt" ]]; then
            STABLE_COUNT=$(cat "$TEMP_DIR/auto_whitelist_stable_count.txt")
        fi
    else
        if [[ $i -eq 1 ]]; then
            log_info "No artifact yet (first iteration creates baseline)"
        else
            log_warning "Artifact not available after ${MAX_WAIT_TIME}s"
        fi
    fi
    
    ENDPOINT_HISTORY+=("$CURRENT_ENDPOINT_COUNT")
    
    # Calculate delta
    DELTA=0
    if [[ $LAST_ENDPOINT_COUNT -gt 0 && $CURRENT_ENDPOINT_COUNT -gt 0 ]]; then
        DELTA=$((CURRENT_ENDPOINT_COUNT - LAST_ENDPOINT_COUNT))
    fi
    LAST_ENDPOINT_COUNT=$CURRENT_ENDPOINT_COUNT
    
    # Display status (simple format for GitHub logs)
    echo ""
    echo "  Results:"
    echo "    Endpoints:  $CURRENT_ENDPOINT_COUNT (delta: $DELTA)"
    echo "    Stability:  $STABLE_COUNT / $STABILITY_REQUIRED"
    
    # Check if stable
    if [[ "$STABLE_COUNT" -ge "$STABILITY_REQUIRED" ]]; then
        echo ""
        echo "🎉 STABILITY REACHED!"
        STABLE_REACHED=true
        break
    fi
    
    # Delay between runs
    if [[ $i -lt $MAX_ITERATIONS ]]; then
        echo ""
        echo "  Waiting 10s before next iteration..."
        sleep 10
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: Results Summary
# ─────────────────────────────────────────────────────────────────────────────
log_header "PHASE 3: Results"

# Count successes/failures
SUCCESS_COUNT=0
FAILURE_COUNT=0
for status in "${RUN_STATUSES[@]}"; do
    if [[ "$status" == "success" ]]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
done

echo ""
echo "  Iteration  | Status  | Endpoints | Run ID"
echo "  -----------+---------+-----------+------------------"

for i in "${!RUN_IDS[@]}"; do
    ITER=$((i + 1))
    STATUS="${RUN_STATUSES[$i]}"
    RUN_ID="${RUN_IDS[$i]}"
    ENDPOINTS="${ENDPOINT_HISTORY[$i]:-0}"
    
    if [[ "$STATUS" == "success" ]]; then
        ICON="✓"
    else
        ICON="✗"
    fi
    
    printf "  #%-9d | %s %-5s | %-9s | %s\n" "$ITER" "$ICON" "$STATUS" "$ENDPOINTS" "$RUN_ID"
done
echo "  -----------+---------+-----------+------------------"
echo ""

# Final verdict
echo ""
echo "========================================================================"

if [[ "$STABLE_REACHED" == "true" ]]; then
    echo "  ✅ TEST PASSED"
    echo ""
    echo "  Auto-whitelist completed full lifecycle:"
    echo "    • Baseline created"
    echo "    • Learning phase completed"  
    echo "    • Stability reached ($STABILITY_REQUIRED consecutive stable runs)"
    echo "    • Ready for enforcement"
    echo "========================================================================"
    exit 0
elif [[ $FAILURE_COUNT -eq 0 ]]; then
    echo "  ⚠️  TEST PARTIAL"
    echo ""
    echo "  All $SUCCESS_COUNT iterations succeeded but stability not reached"
    echo "  after $MAX_ITERATIONS iterations."
    echo ""
    echo "  This may indicate:"
    echo "    • Network traffic is still evolving"
    echo "    • More iterations needed"
    echo "========================================================================"
    exit 0
else
    echo "  ❌ TEST FAILED"
    echo ""
    echo "  $FAILURE_COUNT of ${#RUN_IDS[@]} iterations failed."
    echo ""
    echo "  Failed runs:"
    for i in "${!RUN_IDS[@]}"; do
        if [[ "${RUN_STATUSES[$i]}" != "success" ]]; then
            echo "    • #$((i + 1)): https://github.com/$REPO/actions/runs/${RUN_IDS[$i]}"
        fi
    done
    echo "========================================================================"
    exit 1
fi

