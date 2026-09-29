#!/bin/bash

# Auto-Whitelist Lifecycle Test
# =============================
# Dispatches .github/workflows/test_auto_whitelist_feature.yml once per
# iteration, on real GitHub-hosted runners with a real posture daemon, and
# follows the state the action saves in the artifact between runs:
#
#   - every iteration must succeed (each one asserts its own outcome: a
#     learning run passes, an enforcing run fails on the gist fetch, reports it
#     and does not learn it);
#   - each iteration must start in the mode the previous one saved and carry
#     its iteration counter forward (the artifact round trip works and nothing
#     else feeds it);
#   - the test passes only once an enforcing iteration has run and succeeded.
#
# It reads the action's own record (auto_whitelist_verdict.json in the
# artifact) with jq; nothing is inferred from log lines.

set -eo pipefail

REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
WORKFLOW_FILE=".github/workflows/test_auto_whitelist_feature.yml"
BRANCH="${GITHUB_REF_NAME:-$(git branch --show-current 2>/dev/null || echo "main")}"
# The workflow names the pool test-auto-whitelist-feature-<branch>; the action
# appends the runner OS and architecture (ubuntu-latest: linux-x64).
ARTIFACT_NAME="test-auto-whitelist-feature-$BRANCH-linux-x64"
LEGACY_ARTIFACT_NAMES=("test-auto-whitelist-feature-$BRANCH" "test-auto-whitelist-feature-state-$BRANCH")
# The workflow enforces after 2 consecutive clean runs or 6 learning runs, so
# the 7th iteration enforces at the latest.
MAX_ITERATIONS=9

log_header() {
    echo ""
    echo "========================================================================"
    echo "  $1"
    echo "========================================================================"
}

fail() {
    echo "❌ $1"
    exit 1
}

command -v gh >/dev/null 2>&1 || fail "gh CLI is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"
gh auth status >/dev/null 2>&1 || fail "Not authenticated with gh CLI"

log_header "AUTO-WHITELIST LIFECYCLE TEST"
echo "  Repository: $REPO"
echo "  Branch:     $BRANCH"
echo "  Artifact:   $ARTIFACT_NAME"
echo "  Max runs:   $MAX_ITERATIONS"

# ---------------------------------------------------------------------------
# PHASE 1: clean slate
# ---------------------------------------------------------------------------
log_header "PHASE 1: Cleanup"
for name in "$ARTIFACT_NAME" "${LEGACY_ARTIFACT_NAMES[@]}"; do
    ids=$(gh api --paginate "repos/$REPO/actions/artifacts?name=$name&per_page=100" --jq '.artifacts[].id') ||
        fail "Could not list artifacts named $name"
    for id in $ids; do
        gh api -X DELETE "repos/$REPO/actions/artifacts/$id" >/dev/null || fail "Could not delete artifact $id ($name)"
        echo "  deleted artifact $id ($name)"
    done
done

# ---------------------------------------------------------------------------
# PHASE 2: iterations
# ---------------------------------------------------------------------------
log_header "PHASE 2: Lifecycle"

RESULTS_DIR="/tmp/auto_whitelist_test_results"
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
SUMMARY=()
PREVIOUS_NEXT_MODE="learning"
ENFORCEMENT_VERIFIED=false
ENFORCEMENT_REASON=""

for i in $(seq 1 "$MAX_ITERATIONS"); do
    echo ""
    echo "------------------------------------------------------------------------"
    echo "  ITERATION $i / $MAX_ITERATIONS"
    echo "------------------------------------------------------------------------"

    LATEST_RUN_BEFORE=$(gh run list --workflow="$WORKFLOW_FILE" --repo "$REPO" --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId // ""')
    gh workflow run "$WORKFLOW_FILE" --repo "$REPO" --ref "$BRANCH" --field "iteration=$i" >/dev/null ||
        fail "Failed to dispatch iteration $i"

    RUN_ID=""
    for _ in $(seq 1 30); do
        sleep 4
        CURRENT_RUN=$(gh run list --workflow="$WORKFLOW_FILE" --repo "$REPO" --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId // ""' || true)
        if [[ -n "$CURRENT_RUN" && "$CURRENT_RUN" != "$LATEST_RUN_BEFORE" ]]; then
            RUN_ID="$CURRENT_RUN"
            break
        fi
    done
    [[ -n "$RUN_ID" ]] || fail "Iteration $i: the dispatched run did not appear"
    echo "  run: https://github.com/$REPO/actions/runs/$RUN_ID"

    while true; do
        STATUS=$(gh run view "$RUN_ID" --repo "$REPO" --json status --jq .status || echo "unknown")
        [[ "$STATUS" == "completed" ]] && break
        sleep 20
    done
    CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq .conclusion)
    echo "  conclusion: $CONCLUSION"

    DIR="$RESULTS_DIR/iteration_$i"
    mkdir -p "$DIR"
    if ! gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT_NAME" --dir "$DIR"; then
        fail "Iteration $i: run $RUN_ID uploaded no $ARTIFACT_NAME artifact"
    fi
    VERDICT="$DIR/auto_whitelist_verdict.json"
    [[ -f "$VERDICT" ]] || fail "Iteration $i: the artifact has no auto_whitelist_verdict.json"
    jq '{start_mode, start_reason, verdict, evaluated, non_conforming: (.non_conforming | length), added: (.added | length), iteration, stable_count, next_mode, next_reason, endpoints}' "$VERDICT"

    START_MODE=$(jq -r '.start_mode' "$VERDICT")
    ITERATION=$(jq -r '.iteration' "$VERDICT")
    SUMMARY+=("#$i run $RUN_ID: $CONCLUSION, started $START_MODE ($(jq -r '.start_reason' "$VERDICT")), verdict $(jq -r '.verdict' "$VERDICT"), $(jq '.non_conforming | length' "$VERDICT") outside, +$(jq '.added | length' "$VERDICT") learned, $(jq -r '.endpoints' "$VERDICT") endpoints")

    [[ "$CONCLUSION" == "success" ]] || fail "Iteration $i failed its own assertions (run $RUN_ID)"
    [[ "$ITERATION" == "$i" ]] ||
        fail "Iteration $i: the saved state says iteration $ITERATION; the state chain was broken or fed from elsewhere"
    [[ "$START_MODE" == "$PREVIOUS_NEXT_MODE" ]] ||
        fail "Iteration $i started $START_MODE, but iteration $((i - 1)) saved $PREVIOUS_NEXT_MODE for it"

    if [[ "$START_MODE" == "enforcing" ]]; then
        ENFORCEMENT_VERIFIED=true
        ENFORCEMENT_REASON=$(jq -r '.start_reason' "$VERDICT")
        break
    fi
    PREVIOUS_NEXT_MODE=$(jq -r '.next_mode' "$VERDICT")
    sleep 10
done

# ---------------------------------------------------------------------------
# PHASE 3: results
# ---------------------------------------------------------------------------
log_header "PHASE 3: Results"
printf '  %s\n' "${SUMMARY[@]}"
echo ""

if [[ "$ENFORCEMENT_VERIFIED" == "true" ]]; then
    echo "✅ TEST PASSED: learning, then an enforcing run (${ENFORCEMENT_REASON}) that failed on the gist fetch, reported it and did not learn it."
    if [[ "$ENFORCEMENT_REASON" == "max_iterations" ]]; then
        echo "   Note: the whitelist was enforced because the learning budget ran out, not because runs came out clean: hosted-runner traffic kept adding endpoints."
    fi
    exit 0
fi
fail "No enforcing iteration within $MAX_ITERATIONS runs"
