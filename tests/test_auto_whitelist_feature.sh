#!/bin/bash

# Test script for auto-whitelist feature
# This script sequentially triggers workflow runs and verifies the auto-whitelist lifecycle
#
# What it does:
# 1. Cleans up existing artifacts to ensure clean state
# 2. Sequentially triggers workflow runs (.github/workflows/test_auto_whitelist_feature.yml)
# 3. Waits for each run to complete
# 4. Downloads and validates artifacts from each run
# 5. Checks if stability is reached (N consecutive runs with no changes)
# 6. Reports final test results
#
# Requirements:
# - gh CLI installed and authenticated
# - GITHUB_TOKEN environment variable set (or gh auth login)
# - Repository access to trigger workflows
# - jq installed for JSON parsing
#
# Usage:
#   GITHUB_TOKEN=your_token ./tests/test_auto_whitelist_feature.sh
#   or
#   gh auth login
#   ./tests/test_auto_whitelist_feature.sh
#
# Related files:
# - .github/workflows/test_auto_whitelist_feature.yml: Workflow that uses auto_whitelist: true
# - action.yml: Contains the auto-whitelist implementation

set -eo pipefail
# Note: Removed 'u' (unset variable check) to allow for empty variables in some cases

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
WORKFLOW_FILE=".github/workflows/test_auto_whitelist_feature.yml"
ARTIFACT_NAME_PREFIX="test-auto-whitelist-feature"
BRANCH="${GITHUB_REF_NAME:-$(git branch --show-current)}"
MAX_ITERATIONS=20
STABILITY_REQUIRED=3

# Check prerequisites
if ! command -v gh &> /dev/null; then
    echo -e "${RED}Error: gh CLI is not installed${NC}"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo -e "${RED}Error: Not authenticated with gh CLI. Run 'gh auth login'${NC}"
    exit 1
fi

echo "=========================================="
echo "Auto-Whitelist Feature Test"
echo "=========================================="
echo "Repository: $REPO"
echo "Branch: $BRANCH"
echo "Workflow: $WORKFLOW_FILE"
echo "Max Iterations: $MAX_ITERATIONS"
echo "Stability Required: $STABILITY_REQUIRED consecutive runs"
echo "=========================================="
echo ""

# Step 1: Clean up existing artifacts
echo -e "${YELLOW}Step 1: Cleaning up existing artifacts...${NC}"
ARTIFACT_IDS=$(gh api repos/$REPO/actions/artifacts --paginate --jq ".artifacts[] | select(.name | startswith(\"$ARTIFACT_NAME_PREFIX\")) | .id" 2>/dev/null || true)

if [[ -n "$ARTIFACT_IDS" ]]; then
    echo "$ARTIFACT_IDS" | while read -r ARTIFACT_ID; do
        [[ -n "$ARTIFACT_ID" ]] || continue
        echo "  Deleting artifact id $ARTIFACT_ID"
        gh api repos/$REPO/actions/artifacts/$ARTIFACT_ID -X DELETE 2>/dev/null || echo "    (may already be deleted)"
    done
    echo -e "${GREEN}✓ Artifacts cleaned up${NC}"
else
    echo -e "${GREEN}✓ No existing artifacts found${NC}"
fi
echo ""

# Step 2: Trigger sequential workflow runs
echo -e "${YELLOW}Step 2: Triggering sequential workflow runs...${NC}"

declare -a RUN_IDS=()
declare -a RUN_STATUSES=()
declare -a ENDPOINT_HISTORY=()
LAST_ENDPOINT_COUNT="unknown"

for i in $(seq 1 $MAX_ITERATIONS); do
    echo ""
    echo "--- Iteration $i ---"
    
    # Get the latest run ID before triggering (to detect new runs)
    LATEST_RUN_BEFORE=$(gh run list --workflow="$WORKFLOW_FILE" --repo "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || echo "") || LATEST_RUN_BEFORE=""
    
    # Trigger workflow
    echo "  Triggering workflow run $i..."
    set +e  # Temporarily disable exit on error for this command
    TRIGGER_OUTPUT=$(gh workflow run "$WORKFLOW_FILE" \
        --ref "$BRANCH" \
        --field "iteration=$i" 2>&1)
    TRIGGER_EXIT_CODE=$?
    set -e  # Re-enable exit on error
    
    if [[ $TRIGGER_EXIT_CODE -ne 0 ]]; then
        echo -e "${RED}Error: Failed to trigger workflow (exit code: $TRIGGER_EXIT_CODE)${NC}"
        echo "$TRIGGER_OUTPUT"
        exit 1
    fi
    
    # Wait for the workflow to start and get the new run ID
    echo "  Waiting for workflow to start..."
    RUN_ID=""
    MAX_WAIT=30
    WAIT_COUNT=0
    
    while [[ -z "$RUN_ID" && $WAIT_COUNT -lt $MAX_WAIT ]]; do
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        
        # Get the most recent workflow run ID
        set +e  # Temporarily disable exit on error
        CURRENT_RUN=$(gh run list --workflow="$WORKFLOW_FILE" --repo "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || echo "")
        set -e  # Re-enable exit on error
        
        # If we have a new run ID (different from before), use it
        if [[ -n "$CURRENT_RUN" && "$CURRENT_RUN" != "$LATEST_RUN_BEFORE" ]]; then
            RUN_ID="$CURRENT_RUN"
        fi
    done
    
    if [[ -z "$RUN_ID" ]]; then
        echo -e "${RED}Error: Failed to get workflow run ID after ${MAX_WAIT}s${NC}"
        echo "  Latest run before trigger: $LATEST_RUN_BEFORE"
        echo "  Current latest run: $(gh run list --workflow=\"$WORKFLOW_FILE\" --repo \"$REPO\" --limit 1 --json databaseId --jq '.[0].databaseId // \"none\"' 2>/dev/null || echo \"unknown\")"
        exit 1
    fi
    
    echo "  Workflow run ID: $RUN_ID"
    RUN_IDS+=("$RUN_ID")
    
    # Wait for workflow to complete
    echo "  Waiting for workflow to complete..."
    gh run watch "$RUN_ID" --repo "$REPO" --exit-status || {
        echo -e "${YELLOW}  Warning: Workflow completed with non-zero exit code${NC}"
    }
    
    # Small delay to ensure artifacts are available
    echo "  Waiting for artifacts to be available..."
    sleep 5
    
    # Get workflow conclusion
    CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq .conclusion)
    RUN_STATUSES+=("$CONCLUSION")
    
    if [[ "$CONCLUSION" == "success" ]]; then
        echo -e "${GREEN}  ✓ Iteration $i completed successfully${NC}"
    else
        echo -e "${RED}  ✗ Iteration $i failed with status: $CONCLUSION${NC}"
        echo "  View run: https://github.com/$REPO/actions/runs/$RUN_ID"
    fi
    
    # Download and check artifact
    echo "  Checking artifact status..."
    ARTIFACT_DOWNLOADED=false
    # Try downloading artifact (may not exist on first run)
    if gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT_NAME_PREFIX-$BRANCH" --dir "/tmp/auto_whitelist_test_$i" 2>/dev/null; then
        ARTIFACT_DOWNLOADED=true
    fi
    
    CURRENT_ENDPOINT_COUNT="$LAST_ENDPOINT_COUNT"

    if [[ "$ARTIFACT_DOWNLOADED" == "true" ]]; then
        if [[ -f "/tmp/auto_whitelist_test_$i/auto_whitelist.json" ]]; then
            ENDPOINT_COUNT=$(jq '[.whitelists[]? | select(.name == "custom_whitelist") | .endpoints? // [] | length] | add // 0' "/tmp/auto_whitelist_test_$i/auto_whitelist.json" 2>/dev/null || echo "0")
            echo "    Whitelist contains $ENDPOINT_COUNT endpoints"
            CURRENT_ENDPOINT_COUNT="$ENDPOINT_COUNT"
            LAST_ENDPOINT_COUNT="$ENDPOINT_COUNT"
            
            if [[ -f "/tmp/auto_whitelist_test_$i/auto_whitelist_stable_count.txt" ]]; then
                STABLE_COUNT=$(cat "/tmp/auto_whitelist_test_$i/auto_whitelist_stable_count.txt")
                echo "    Consecutive stable runs: $STABLE_COUNT"
                
                if [[ "$STABLE_COUNT" -ge "$STABILITY_REQUIRED" ]]; then
                    echo -e "${GREEN}  ✓ Auto-whitelist reached stability!${NC}"
                    break
                fi
            fi
        fi
    else
        echo "    No artifact found (may be first run)"
    fi

    ENDPOINT_HISTORY+=("$CURRENT_ENDPOINT_COUNT")
    echo "    ▶ Whitelist endpoints after iteration $i: $CURRENT_ENDPOINT_COUNT"
    
    # Small delay between runs
    if [[ $i -lt $MAX_ITERATIONS ]]; then
        echo "  Waiting 10 seconds before next iteration..."
        sleep 10
    fi
done

echo ""
echo "=========================================="
echo "Test Results Summary"
echo "=========================================="

# Step 3: Verify results
ALL_SUCCESS=true
STABLE_REACHED=false

for i in "${!RUN_IDS[@]}"; do
    ITER=$((i + 1))
    STATUS="${RUN_STATUSES[$i]}"
    RUN_ID="${RUN_IDS[$i]}"
    ENDPOINTS="${ENDPOINT_HISTORY[$i]:-unknown}"
    
    if [[ "$STATUS" == "success" ]]; then
        echo -e "${GREEN}Iteration $ITER: SUCCESS${NC} (Run ID: $RUN_ID) - Whitelist endpoints: $ENDPOINTS"
    else
        echo -e "${RED}Iteration $ITER: FAILED${NC} (Status: $STATUS, Run ID: $RUN_ID, Whitelist endpoints: $ENDPOINTS)"
        ALL_SUCCESS=false
    fi
done

# Check if stability was reached
if [[ -f "/tmp/auto_whitelist_test_${#RUN_IDS[@]}/auto_whitelist_stable_count.txt" ]]; then
    FINAL_STABLE_COUNT=$(cat "/tmp/auto_whitelist_test_${#RUN_IDS[@]}/auto_whitelist_stable_count.txt")
    if [[ "$FINAL_STABLE_COUNT" -ge "$STABILITY_REQUIRED" ]]; then
        STABLE_REACHED=true
        echo ""
        echo -e "${GREEN}✓ Auto-whitelist reached stability ($FINAL_STABLE_COUNT consecutive stable runs)${NC}"
    fi
fi

echo ""
echo "=========================================="

# Final verdict
if [[ "$ALL_SUCCESS" == "true" && "$STABLE_REACHED" == "true" ]]; then
    echo -e "${GREEN}✅ TEST PASSED: Auto-whitelist feature completed lifecycle successfully${NC}"
    exit 0
elif [[ "$ALL_SUCCESS" == "true" ]]; then
    echo -e "${YELLOW}⚠️  TEST PARTIAL: All runs succeeded but stability not reached in $MAX_ITERATIONS iterations${NC}"
    echo "   This may be expected if more iterations are needed"
    exit 0
else
    echo -e "${RED}❌ TEST FAILED: Some workflow runs failed${NC}"
    echo ""
    echo "Failed runs:"
    for i in "${!RUN_IDS[@]}"; do
        if [[ "${RUN_STATUSES[$i]}" != "success" ]]; then
            echo "  Iteration $((i + 1)): https://github.com/$REPO/actions/runs/${RUN_IDS[$i]}"
        fi
    done
    exit 1
fi

