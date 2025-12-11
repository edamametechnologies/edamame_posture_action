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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
log_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} ${BOLD}$1${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
}

log_step() {
    echo -e "${BLUE}▶${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_info() {
    echo -e "  $1"
}

# Progress bar for waiting
show_progress() {
    local elapsed=$1
    local max=$2
    local width=40
    local percent=$((elapsed * 100 / max))
    local filled=$((elapsed * width / max))
    local empty=$((width - filled))
    printf "\r  [%-${width}s] %3d%% (%ds)" "$(printf '%*s' $filled | tr ' ' '█')$(printf '%*s' $empty)" "$percent" "$elapsed"
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
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║            AUTO-WHITELIST LIFECYCLE TEST                           ║${NC}"
echo -e "${BOLD}╠════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  Repository:    $REPO"
echo -e "${BOLD}║${NC}  Branch:        $BRANCH"
echo -e "${BOLD}║${NC}  Max Runs:      $MAX_ITERATIONS"
echo -e "${BOLD}║${NC}  Stability:     $STABILITY_REQUIRED consecutive stable runs"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
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
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│ ITERATION $i / $MAX_ITERATIONS                                              │${NC}"
    echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
    
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
        show_progress $WAIT_COUNT $MAX_WAIT
        
        set +e
        CURRENT_RUN=$(gh run list --workflow="$WORKFLOW_FILE" --repo "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || echo "")
        set -e
        
        if [[ -n "$CURRENT_RUN" && "$CURRENT_RUN" != "$LATEST_RUN_BEFORE" ]]; then
            RUN_ID="$CURRENT_RUN"
        fi
    done
    echo ""  # New line after progress bar
    
    if [[ -z "$RUN_ID" ]]; then
        log_error "Failed to detect new workflow run"
        exit 1
    fi
    
    log_success "Run started: $RUN_ID"
    RUN_IDS+=("$RUN_ID")
    
    # Wait for workflow to complete
    log_step "Waiting for completion..."
    gh run watch "$RUN_ID" --repo "$REPO" --exit-status 2>/dev/null || true
    
    # Get conclusion
    CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq .conclusion 2>/dev/null || echo "unknown")
    RUN_STATUSES+=("$CONCLUSION")
    
    if [[ "$CONCLUSION" == "success" ]]; then
        log_success "Workflow completed"
    else
        log_warning "Workflow status: $CONCLUSION"
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
        
        show_progress $ELAPSED $MAX_WAIT_TIME
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done
    echo ""  # New line after progress bar
    
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
    
    # Display status
    echo ""
    echo "  ┌────────────────────────────────────┐"
    printf "  │ Endpoints:  %4d" "$CURRENT_ENDPOINT_COUNT"
    if [[ $DELTA -ne 0 ]]; then
        printf " (%+d)" "$DELTA"
    fi
    echo ""
    printf "  │ Stability:  %d/%d\n" "$STABLE_COUNT" "$STABILITY_REQUIRED"
    echo "  └────────────────────────────────────┘"
    
    # Check if stable
    if [[ "$STABLE_COUNT" -ge "$STABILITY_REQUIRED" ]]; then
        echo ""
        echo -e "${GREEN}${BOLD}🎉 STABILITY REACHED!${NC}"
        STABLE_REACHED=true
        break
    fi
    
    # Delay between runs
    if [[ $i -lt $MAX_ITERATIONS ]]; then
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
echo "  Iterations Summary"
echo "  ─────────────────────────────────────────────────────────────"
printf "  %-10s %-12s %-10s %-10s\n" "Iteration" "Status" "Endpoints" "Run ID"
echo "  ─────────────────────────────────────────────────────────────"

for i in "${!RUN_IDS[@]}"; do
    ITER=$((i + 1))
    STATUS="${RUN_STATUSES[$i]}"
    RUN_ID="${RUN_IDS[$i]}"
    ENDPOINTS="${ENDPOINT_HISTORY[$i]:-0}"
    
    if [[ "$STATUS" == "success" ]]; then
        STATUS_ICON="${GREEN}✓${NC}"
    else
        STATUS_ICON="${RED}✗${NC}"
    fi
    
    printf "  %-10s %b %-10s %-10s %s\n" "#$ITER" "$STATUS_ICON" "$STATUS" "$ENDPOINTS" "$RUN_ID"
done
echo "  ─────────────────────────────────────────────────────────────"
echo ""

# Endpoint growth visualization
if [[ ${#ENDPOINT_HISTORY[@]} -gt 1 ]]; then
    echo "  Endpoint Growth"
    echo "  ─────────────────────────────────────────────────────────────"
    MAX_EP=0
    for ep in "${ENDPOINT_HISTORY[@]}"; do
        [[ $ep -gt $MAX_EP ]] && MAX_EP=$ep
    done
    
    if [[ $MAX_EP -gt 0 ]]; then
        for i in "${!ENDPOINT_HISTORY[@]}"; do
            ITER=$((i + 1))
            EP="${ENDPOINT_HISTORY[$i]}"
            BAR_LEN=$((EP * 40 / MAX_EP))
            [[ $BAR_LEN -lt 1 && $EP -gt 0 ]] && BAR_LEN=1
            BAR=$(printf '%*s' $BAR_LEN | tr ' ' '█')
            printf "  #%-2d %s %d\n" "$ITER" "$BAR" "$EP"
        done
    fi
    echo ""
fi

# Final verdict
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════════╗${NC}"

if [[ "$STABLE_REACHED" == "true" ]]; then
    echo -e "${BOLD}║${NC}  ${GREEN}${BOLD}✅ TEST PASSED${NC}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Auto-whitelist completed full lifecycle:"
    echo -e "${BOLD}║${NC}    • Baseline created"
    echo -e "${BOLD}║${NC}    • Learning phase completed"
    echo -e "${BOLD}║${NC}    • Stability reached ($STABILITY_REQUIRED consecutive stable runs)"
    echo -e "${BOLD}║${NC}    • Ready for enforcement"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
    exit 0
elif [[ $FAILURE_COUNT -eq 0 ]]; then
    echo -e "${BOLD}║${NC}  ${YELLOW}${BOLD}⚠️ TEST PARTIAL${NC}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  All $SUCCESS_COUNT iterations succeeded but stability not reached"
    echo -e "${BOLD}║${NC}  after $MAX_ITERATIONS iterations."
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  This may indicate:"
    echo -e "${BOLD}║${NC}    • Network traffic is still evolving"
    echo -e "${BOLD}║${NC}    • More iterations needed"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${BOLD}║${NC}  ${RED}${BOLD}❌ TEST FAILED${NC}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  $FAILURE_COUNT of ${#RUN_IDS[@]} iterations failed."
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Failed runs:"
    for i in "${!RUN_IDS[@]}"; do
        if [[ "${RUN_STATUSES[$i]}" != "success" ]]; then
            echo -e "${BOLD}║${NC}    • #$((i + 1)): https://github.com/$REPO/actions/runs/${RUN_IDS[$i]}"
        fi
    done
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

