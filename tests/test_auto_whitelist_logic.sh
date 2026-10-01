#!/usr/bin/env bash
# Deterministic tests of scripts/auto_whitelist.sh: the artifact selection,
# the mode decision, enforcement, promotion, learning and every failure path,
# with `gh` and the posture CLI replaced by stubs. Runs wherever bash and jq
# run (Linux, macOS, Windows Git Bash, containers without unzip).
#
# A fake `sort` and `unzip` sit first on PATH and record any call: the script
# must use neither (on Windows `sort` can resolve to sort.exe; some containers
# have no unzip).
#
# Usage: tests/test_auto_whitelist_logic.sh [scenario ...]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/auto_whitelist.sh"
BASE_TMP="$(mktemp -d)"
trap 'rm -rf "$BASE_TMP"' EXIT

# jq.exe on Windows ends lines with CR LF: strip the CR so values compare
# equal on every OS. pipefail keeps jq's exit status (jq -e).
jq() { command jq "$@" | tr -d '\r'; }

PASSED=0
FAILED=0
FAILURES=()

REPO="acme/widgets"
BRANCH="main"
WORKFLOW=".github/workflows/release.yml"
RUN_ID="9000"
POOL="edamame-auto-whitelist-ubuntu-latest"
ARTIFACT="$POOL-linux-x64"

make_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
d="$STUB_DIR"
echo "gh $*" >> "$d/calls.log"
case "$1" in
  api)
    shift
    [[ "${1:-}" == "--paginate" ]] && shift
    url="$1"
    case "$url" in
      *"/actions/artifacts?"*)
        # refuse_list_times N: the next N calls are refused with refuse_list.
        if [[ -f "$d/refuse_list_times" ]]; then
          n=$(cat "$d/refuse_list_times")
          if ((n > 0)); then
            echo $((n - 1)) > "$d/refuse_list_times"
            cat "$d/refuse_list" >&2
            exit 1
          fi
        fi
        if [[ -f "$d/fail_list" ]]; then cat "$d/fail_list" >&2; exit 1; fi
        cat "$d/artifacts.json"
        exit 0
        ;;
      *"/actions/runs/"*)
        id="${url##*/}"
        if [[ -f "$d/fail_run" ]]; then cat "$d/fail_run" >&2; exit 1; fi
        if [[ -f "$d/runs/$id.json" ]]; then cat "$d/runs/$id.json"; exit 0; fi
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
    esac
    echo "unexpected gh api $url" >&2
    exit 2
    ;;
  run)
    [[ "$2" == "download" ]] || exit 2
    id="$3"
    shift 3
    name=""
    dir=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --dir) dir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -f "$d/fail_download" ]]; then cat "$d/fail_download" >&2; exit 1; fi
    src="$d/downloads/$id/$name"
    if [[ ! -d "$src" ]]; then echo "no artifact named $name in run $id" >&2; exit 1; fi
    mkdir -p "$dir"
    cp "$src"/* "$dir"/
    ;;
  *)
    exit 2
    ;;
esac
STUB
  cat > "$bin/edamame_posture" <<'STUB'
#!/usr/bin/env bash
d="$STUB_DIR"
echo "posture $*" >> "$d/calls.log"
case "$1" in
  set-custom-whitelists-from-file)
    if [[ -f "$d/refuse_load" ]]; then echo "Error setting custom whitelists: refused" >&2; exit 3; fi
    cp "$2" "$d/loaded.json"
    echo "custom_whitelist" > "$d/active"
    ;;
  get-whitelist-name)
    cat "$d/active" 2>/dev/null || echo ""
    ;;
  evaluate-custom-whitelists-from-file)
    cp "$2" "$d/evaluated_whitelist.json"
    cat "$d/evaluate.json"
    exit "$(cat "$d/evaluate_rc" 2>/dev/null || echo 0)"
    ;;
  augment-custom-whitelists-from-file)
    echo called >> "$d/augment_called"
    added="$(cat "$d/augment_added.json" 2>/dev/null || echo '[]')"
    jq -c --argjson added "$added" '{success: true,
      whitelist: (.whitelists |= map(if .name == "custom_whitelist" then .endpoints += $added else . end)),
      added: $added, evaluated: 3, non_conforming: ($added | length)}' "$2"
    ;;
  *)
    echo "unexpected posture command $1" >&2
    exit 2
    ;;
esac
STUB
  # Stand-ins for Windows' sort.exe and a container without unzip: the
  # script must call neither.
  cat > "$bin/sort" <<'STUB'
#!/usr/bin/env bash
echo "sort $*" >> "$STUB_DIR/forbidden.log"
echo "Input file specified two times." >&2
exit 1
STUB
  cat > "$bin/unzip" <<'STUB'
#!/usr/bin/env bash
echo "unzip $*" >> "$STUB_DIR/forbidden.log"
echo "unzip: command not found" >&2
exit 127
STUB
  chmod +x "$bin"/*
}

# Fresh scenario directories and environment.
new_case() {
  CASE_DIR="$BASE_TMP/$1"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/stub/runs" "$CASE_DIR/stub/downloads" "$CASE_DIR/runner_temp" "$CASE_DIR/home"
  STUB_DIR="$CASE_DIR/stub"
  export STUB_DIR
  make_stubs "$CASE_DIR/bin"
  : > "$STUB_DIR/calls.log"
  echo '{"total_count":0,"artifacts":[]}' > "$STUB_DIR/artifacts.json"
  echo '{"success": true, "evaluated": 3, "conforming": 3, "non_conforming": []}' > "$STUB_DIR/evaluate.json"
  CASE_ENV=(
    "PATH=$CASE_DIR/bin:$PATH"
    "STUB_DIR=$STUB_DIR"
    "RUNNER_TEMP=$CASE_DIR/runner_temp"
    "HOME=$CASE_DIR/home"
    "GITHUB_ENV=$CASE_DIR/github_env"
    "GITHUB_STEP_SUMMARY=$CASE_DIR/summary.md"
    "GITHUB_REPOSITORY=$REPO"
    "GITHUB_RUN_ID=$RUN_ID"
    "GITHUB_RUN_ATTEMPT=1"
    "GITHUB_JOB=build"
    "GITHUB_REF_NAME=$BRANCH"
    "GITHUB_HEAD_REF="
    "GITHUB_EVENT_NAME=workflow_dispatch"
    "GITHUB_WORKFLOW=Release"
    "GITHUB_WORKFLOW_REF=$REPO/$WORKFLOW@refs/heads/$BRANCH"
    "RUNNER_OS=Linux"
    "RUNNER_ARCH=X64"
    "EDAMAME_POSTURE_SETUP_TIME=2026-09-29T10:00:00Z"
    "EDAMAME_POSTURE_CMD=$CASE_DIR/bin/edamame_posture"
    "AW_ARTIFACT_NAME=$POOL"
    "AW_THRESHOLD=0"
    "AW_CONSECUTIVE=3"
    "AW_MAX_ITERATIONS=25"
    "AW_DISCONNECTED=false"
    "AW_PROMOTE=false"
    "GH_TOKEN=test"
  )
  : > "$CASE_DIR/github_env"
}

run_step() {
  local step="$1"
  shift
  env "${CASE_ENV[@]}" "$@" bash "$SCRIPT" "$step" > "$CASE_DIR/$step.out" 2>&1
}

WORKDIR_REL="runner_temp/edamame-auto-whitelist"

whitelist_json() {
  # whitelist_json DOMAIN... -> a custom whitelist with one entry per domain
  local entries="[]" d
  for d in "$@"; do
    entries=$(jq -c --arg d "$d" '. + [{domain: $d, port: 443, protocol: "TCP"}]' <<< "$entries")
  done
  jq -n --argjson e "$entries" '{date: "d", signature: null, whitelists: [{name: "custom_whitelist", extends: null, endpoints: $e}]}'
}

# add_artifact ID RUN_ID CREATED BRANCH FORK(true|false) [NAME]
add_artifact() {
  local id="$1" run="$2" created="$3" branch="$4" fork="$5" name="${6:-$ARTIFACT}"
  local head_repo=1
  [[ "$fork" == "true" ]] && head_repo=2
  jq --argjson id "$id" --argjson run "$run" --arg created "$created" --arg branch "$branch" \
    --arg name "$name" --argjson head "$head_repo" \
    '.total_count += 1 | .artifacts += [{id: $id, name: $name, expired: false, created_at: $created,
      workflow_run: {id: $run, repository_id: 1, head_repository_id: $head, head_branch: $branch}}]' \
    "$STUB_DIR/artifacts.json" > "$STUB_DIR/artifacts.tmp" && mv "$STUB_DIR/artifacts.tmp" "$STUB_DIR/artifacts.json"
}

# add_run RUN_ID EVENT PATH BRANCH [FORK]
add_run() {
  local run="$1" event="$2" path="$3" branch="$4" fork="${5:-false}"
  local head_repo=1
  [[ "$fork" == "true" ]] && head_repo=2
  jq -n --argjson id "$run" --arg event "$event" --arg path "$path" --arg branch "$branch" --argjson head "$head_repo" \
    '{id: $id, event: $event, path: $path, name: "Release", head_branch: $branch, head_sha: "abc",
      repository: {id: 1}, head_repository: {id: $head}}' > "$STUB_DIR/runs/$run.json"
}

# add_download RUN_ID ITERATION STABLE_COUNT [FORMAT] [DOMAINS...]
add_download() {
  local run="$1" iteration="$2" stable="$3" format="${4:-2}"
  shift 4 2>/dev/null || shift $#
  local dir="$STUB_DIR/downloads/$run/$ARTIFACT"
  mkdir -p "$dir"
  if (($# > 0)); then
    whitelist_json "$@" > "$dir/auto_whitelist.json"
  else
    whitelist_json api.github.com raw.githubusercontent.com > "$dir/auto_whitelist.json"
  fi
  jq -n --argjson f "$format" --argjson i "$iteration" --argjson s "$stable" \
    '{format: $f, iteration: $i, stable_count: $s, mode: "learning"}' > "$dir/auto_whitelist_state.json"
}

one_eligible() {
  # One trusted artifact from an earlier dispatch of the same workflow on main.
  local iteration="$1" stable="$2"
  add_artifact 501 8001 "2026-09-28T10:00:00Z" "$BRANCH" false
  add_run 8001 workflow_dispatch "$WORKFLOW" "$BRANCH"
  add_download 8001 "$iteration" "$stable" 2
}

gist_exception() {
  cat > "$STUB_DIR/evaluate.json" <<'JSON'
{"success": true, "evaluated": 4, "conforming": 3, "non_conforming": [
 {"protocol": "TCP", "src_ip": "10.1.0.4", "src_port": 50123, "dst_ip": "185.199.110.133", "dst_port": 443,
  "dst_domain": "gist.githubusercontent.com", "as_number": 54113, "as_owner": "FASTLY", "process": "python3",
  "last_activity": "2026-09-29T10:05:00Z", "reason": "Domain mismatch"}]}
JSON
  echo 1 > "$STUB_DIR/evaluate_rc"
  echo '[{"domain": "gist.githubusercontent.com", "port": 443, "protocol": "TCP"}]' > "$STUB_DIR/augment_added.json"
}

wd() { printf '%s/%s' "$CASE_DIR" "$WORKDIR_REL"; }
jqf() { jq -r "$1" "$(wd)/$2"; }

check() {
  # check DESCRIPTION CONDITION...
  local what="$1"
  shift
  if "$@"; then
    return 0
  fi
  CASE_OK=false
  CASE_WHY+=("$what")
  return 0
}

eq() { [[ "$1" == "$2" ]]; }
file_has() { grep -q -- "$2" "$1" 2>/dev/null; }
no_file() { [[ ! -e "$1" ]]; }

no_forbidden_tools() { no_file "$STUB_DIR/forbidden.log"; }

finish_case() {
  local name="$1"
  check "the script must not call sort or unzip" no_forbidden_tools
  if [[ "$CASE_OK" == "true" ]]; then
    PASSED=$((PASSED + 1))
    echo "PASS  $name"
  else
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
    echo "FAIL  $name"
    local why
    for why in "${CASE_WHY[@]}"; do echo "      - $why"; done
    for f in setup teardown finalize; do
      [[ -f "$CASE_DIR/$f.out" ]] && { echo "      --- $f output"; sed 's/^/      | /' "$CASE_DIR/$f.out"; }
    done
  fi
}

begin() {
  CASE_OK=true
  CASE_WHY=()
  new_case "$1"
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario_first_run_learns() {
  begin first_run_learns
  run_step setup
  check "setup succeeds" eq "$?" 0
  check "mode learning/first_run" eq "$(jqf '.start_mode + "/" + .start_reason' auto_whitelist_config.json)" "learning/first_run"
  check "an empty whitelist is loaded" eq "$(jq '.whitelists[0].endpoints | length' "$STUB_DIR/loaded.json")" 0
  check "EDAMAME_AUTO_WHITELIST_MODE exported" file_has "$CASE_DIR/github_env" "EDAMAME_AUTO_WHITELIST_MODE=learning"
  gist_exception
  run_step teardown
  check "teardown succeeds" eq "$?" 0
  check "learning verdict" eq "$(jqf '.verdict' auto_whitelist_verdict.json)" learning
  check "gist learned on the first run" eq "$(jqf '[.whitelists[0].endpoints[].domain] | index("gist.githubusercontent.com") != null' auto_whitelist.json)" true
  check "iteration 1, stable 0, next learning" eq "$(jqf '"\(.iteration)/\(.stable_count)/\(.mode)"' auto_whitelist_state.json)" "1/0/learning"
  check "the check is scoped to the job's setup time" file_has "$STUB_DIR/calls.log" "--since 2026-09-29T10:00:00Z"
  check "upload requested" file_has "$CASE_DIR/github_env" "AUTO_WHITELIST_UPLOAD=true"
  run_step finalize
  check "finalize passes" eq "$?" 0
  finish_case first_run_learns
}

scenario_stable_start_fails_on_new_endpoint() {
  begin stable_start_fails_on_new_endpoint
  one_eligible 7 3
  run_step setup
  check "setup succeeds" eq "$?" 0
  check "mode enforcing/stable" eq "$(jqf '.start_mode + "/" + .start_reason' auto_whitelist_config.json)" "enforcing/stable"
  local before
  before=$(jqf '.whitelist_sha256' auto_whitelist_config.json)
  gist_exception
  run_step teardown
  check "teardown records the violation" eq "$?" 0
  check "violation verdict" eq "$(jqf '.verdict' auto_whitelist_verdict.json)" violation
  check "nothing learned (augment not called)" no_file "$STUB_DIR/augment_called"
  check "whitelist unchanged" eq "$(jqf '[.whitelists[0].endpoints[].domain] | index("gist.githubusercontent.com")' auto_whitelist.json)" null
  check "stable count kept, next run enforces" eq "$(jqf '"\(.stable_count)/\(.mode)"' auto_whitelist_state.json)" "3/enforcing"
  run_step finalize
  check "finalize fails the job" eq "$?" 1
  check "finalize names the endpoint" file_has "$CASE_DIR/teardown.out" "gist.githubusercontent.com"
  check "finalize reports the violation" file_has "$CASE_DIR/finalize.out" "not in the enforced whitelist"
  [[ -n "$before" ]]
  finish_case stable_start_fails_on_new_endpoint
}

scenario_stable_start_promote() {
  begin stable_start_promote
  one_eligible 7 3
  run_step setup
  gist_exception
  run_step teardown AW_PROMOTE=true
  check "teardown succeeds" eq "$?" 0
  check "promoted verdict" eq "$(jqf '.verdict' auto_whitelist_verdict.json)" promoted
  check "gist added" eq "$(jqf '[.whitelists[0].endpoints[].domain] | index("gist.githubusercontent.com") != null' auto_whitelist.json)" true
  check "added report lists gist" eq "$(jqf '.[0].domain' auto_whitelist_added.json)" "gist.githubusercontent.com"
  check "promotion is flagged as unreviewed" file_has "$CASE_DIR/teardown.out" "PROMOTED"
  check "still enforcing" eq "$(jqf '"\(.stable_count)/\(.mode)"' auto_whitelist_state.json)" "3/enforcing"
  run_step finalize
  check "finalize passes" eq "$?" 0
  finish_case stable_start_promote
}

scenario_stable_start_conforming() {
  begin stable_start_conforming
  one_eligible 7 3
  run_step setup
  run_step teardown
  check "conforming verdict" eq "$(jqf '.verdict' auto_whitelist_verdict.json)" conforming
  check "nothing learned" no_file "$STUB_DIR/augment_called"
  check "iteration advances" eq "$(jqf '.iteration' auto_whitelist_state.json)" 8
  run_step finalize
  check "finalize passes" eq "$?" 0
  finish_case stable_start_conforming
}

scenario_learning_settles() {
  begin learning_settles
  one_eligible 4 2
  run_step setup
  check "mode learning" eq "$(jqf '.start_mode' auto_whitelist_config.json)" learning
  run_step teardown
  check "learning verdict" eq "$(jqf '.verdict' auto_whitelist_verdict.json)" learning
  check "a run with nothing new is stable" eq "$(jqf '.run_stable' auto_whitelist_verdict.json)" true
  check "third stable run: next run enforces" eq "$(jqf '"\(.stable_count)/\(.mode)/\(.mode_reason)"' auto_whitelist_state.json)" "3/enforcing/stable"
  check "announced" file_has "$CASE_DIR/teardown.out" "the next run ENFORCES it"
  finish_case learning_settles
}

scenario_learning_new_endpoint_resets() {
  begin learning_new_endpoint_resets
  one_eligible 4 2
  run_step setup
  gist_exception
  run_step teardown
  check "stable count reset" eq "$(jqf '"\(.stable_count)/\(.mode)"' auto_whitelist_state.json)" "0/learning"
  check "gist learned while learning" eq "$(jqf '[.whitelists[0].endpoints[].domain] | index("gist.githubusercontent.com") != null' auto_whitelist.json)" true
  run_step finalize
  check "finalize passes while learning" eq "$?" 0
  finish_case learning_new_endpoint_resets
}

scenario_max_iterations() {
  begin max_iterations
  one_eligible 24 0
  run_step setup
  check "still learning at 24/25" eq "$(jqf '.start_mode' auto_whitelist_config.json)" learning
  gist_exception
  run_step teardown
  check "next run enforces by max_iterations" eq "$(jqf '"\(.iteration)/\(.mode)/\(.mode_reason)"' auto_whitelist_state.json)" "25/enforcing/max_iterations"
  check "warned" file_has "$CASE_DIR/teardown.out" "without settling"
  # The next run starts enforcing.
  finish_case max_iterations
}

scenario_selects_only_trusted_artifact() {
  begin selects_only_trusted_artifact
  # Newest first: a fork, another branch, another workflow, a
  # pull_request_target run, then the trusted one.
  add_artifact 505 8005 "2026-09-28T15:00:00Z" "$BRANCH" true
  add_run 8005 pull_request "$WORKFLOW" "$BRANCH" true
  add_artifact 504 8004 "2026-09-28T14:00:00Z" "feature-x" false
  add_run 8004 push "$WORKFLOW" "feature-x"
  add_artifact 503 8003 "2026-09-28T13:00:00Z" "$BRANCH" false
  add_run 8003 workflow_dispatch ".github/workflows/other.yml" "$BRANCH"
  add_artifact 502 8002 "2026-09-28T12:00:00Z" "$BRANCH" false
  add_run 8002 pull_request_target "$WORKFLOW" "$BRANCH"
  add_artifact 501 8001 "2026-09-28T10:00:00Z" "$BRANCH" false
  add_run 8001 workflow_dispatch "$WORKFLOW" "$BRANCH"
  add_download 8001 3 1 2
  # This run's own artifact is never used.
  add_artifact 506 "$RUN_ID" "2026-09-29T11:00:00Z" "$BRANCH" false
  run_step setup
  check "setup succeeds" eq "$?" 0
  check "the trusted artifact is chosen" eq "$(jqf '.source.run.id' auto_whitelist_config.json)" 8001
  check "fork skipped" file_has "$CASE_DIR/setup.out" "produced by a fork"
  check "other branch skipped" file_has "$CASE_DIR/setup.out" "produced on branch feature-x"
  check "other workflow skipped" file_has "$CASE_DIR/setup.out" "produced by workflow .github/workflows/other.yml"
  check "pull_request_target skipped" file_has "$CASE_DIR/setup.out" "produced by a pull_request_target run"
  check "only the artifacts of this pool, OS and architecture are listed" file_has "$STUB_DIR/calls.log" "artifacts?name=$ARTIFACT&"
  finish_case selects_only_trusted_artifact
}

scenario_no_trusted_artifact_starts_new() {
  begin no_trusted_artifact_starts_new
  add_artifact 505 8005 "2026-09-28T15:00:00Z" "feature-x" false
  add_run 8005 push "$WORKFLOW" "feature-x"
  run_step setup
  check "setup succeeds" eq "$?" 0
  check "first run" eq "$(jqf '.start_reason' auto_whitelist_config.json)" first_run
  finish_case no_trusted_artifact_starts_new
}

scenario_pool_name_carries_os_and_arch() {
  begin pool_name_carries_os_and_arch
  run_step setup RUNNER_OS=Windows RUNNER_ARCH=ARM64
  check "effective artifact name" eq "$(jqf '.artifact_name' auto_whitelist_config.json)" "$POOL-windows-arm64"
  finish_case pool_name_carries_os_and_arch
}

expect_setup_failure() {
  # expect_setup_failure NAME TEXT
  run_step setup
  check "setup fails" eq "$?" 1
  check "setup explains: $2" file_has "$CASE_DIR/setup.out" "$2"
  check "no whitelist is loaded" no_file "$STUB_DIR/loaded.json"
}

scenario_list_refused_by_allow_list() {
  begin list_refused_by_allow_list
  echo "gh: Although you appear to have the correct authorization credentials, the \`acme\` organization has an IP allow list enabled, and your IP address is not permitted to access this resource. (HTTP 403)" > "$STUB_DIR/fail_list"
  expect_setup_failure list_refused_by_allow_list "Set wait_for_api: true"
  check "no wait without wait_for_api" eq "$(artifact_calls)" 1
  finish_case list_refused_by_allow_list
}

ALLOW_LIST_REFUSAL="gh: Although you appear to have the correct authorization credentials, the \`acme\` organization has an IP allow list enabled, and your IP address is not permitted to access this resource. (HTTP 403)"

artifact_calls() { grep -c "/actions/artifacts?" "$STUB_DIR/calls.log"; }

scenario_allow_list_wait_then_listed() {
  begin allow_list_wait_then_listed
  echo "$ALLOW_LIST_REFUSAL" > "$STUB_DIR/refuse_list"
  echo 2 > "$STUB_DIR/refuse_list_times"
  run_step setup AW_WAIT_FOR_API=true AW_ALLOW_LIST_INTERVAL=0
  check "setup succeeds once the runner is allowed" eq "$?" 0
  check "mode learning/first_run" eq "$(jqf '.start_mode + "/" + .start_reason' auto_whitelist_config.json)" "learning/first_run"
  check "the wait is logged" file_has "$CASE_DIR/setup.out" "does not list this runner yet (attempt 1 of 20)"
  check "the wait ends on attempt 3" file_has "$CASE_DIR/setup.out" "answers this runner (attempt 3)"
  check "three probes, then the listing" eq "$(artifact_calls)" 4
  finish_case allow_list_wait_then_listed
}

scenario_allow_list_wait_exhausted() {
  begin allow_list_wait_exhausted
  echo "$ALLOW_LIST_REFUSAL" > "$STUB_DIR/fail_list"
  run_step setup AW_WAIT_FOR_API=true AW_ALLOW_LIST_ATTEMPTS=3 AW_ALLOW_LIST_INTERVAL=0
  check "setup fails" eq "$?" 1
  check "says it waited" file_has "$CASE_DIR/setup.out" "after waiting for EDAMAME Hub to allow this runner"
  check "three probes, then the listing" eq "$(artifact_calls)" 4
  check "no whitelist is loaded" no_file "$STUB_DIR/loaded.json"
  finish_case allow_list_wait_exhausted
}

scenario_allow_list_wait_only_for_the_allow_list() {
  begin allow_list_wait_only_for_the_allow_list
  echo "gh: Server Error (HTTP 502)" > "$STUB_DIR/fail_list"
  run_step setup AW_WAIT_FOR_API=true AW_ALLOW_LIST_INTERVAL=0
  check "setup fails" eq "$?" 1
  check "the server error is reported" file_has "$CASE_DIR/setup.out" "not starting a new one in its place"
  check "one probe, then the listing" eq "$(artifact_calls)" 2
  finish_case allow_list_wait_only_for_the_allow_list
}

scenario_list_refused_disconnected() {
  begin list_refused_disconnected
  echo "gh: ... has an IP allow list enabled ... (HTTP 403)" > "$STUB_DIR/fail_list"
  run_step setup AW_DISCONNECTED=true AW_WAIT_FOR_API=true
  check "setup fails" eq "$?" 1
  check "explains disconnected mode" file_has "$CASE_DIR/setup.out" "disconnected daemon cannot"
  check "a disconnected daemon does not wait" eq "$(artifact_calls)" 1
  finish_case list_refused_disconnected
}

scenario_list_server_error() {
  begin list_server_error
  echo "gh: Server Error (HTTP 502)" > "$STUB_DIR/fail_list"
  expect_setup_failure list_server_error "not starting a new one in its place"
  finish_case list_server_error
}

scenario_run_lookup_error() {
  begin run_lookup_error
  add_artifact 501 8001 "2026-09-28T10:00:00Z" "$BRANCH" false
  echo "gh: Server Error (HTTP 500)" > "$STUB_DIR/fail_run"
  expect_setup_failure run_lookup_error "looking up run 8001"
  finish_case run_lookup_error
}

scenario_download_error() {
  begin download_error
  one_eligible 3 1
  echo "error downloading: HTTP 503" > "$STUB_DIR/fail_download"
  expect_setup_failure download_error "downloading artifact"
  finish_case download_error
}

scenario_corrupt_artifact() {
  begin corrupt_artifact
  add_artifact 501 8001 "2026-09-28T10:00:00Z" "$BRANCH" false
  add_run 8001 workflow_dispatch "$WORKFLOW" "$BRANCH"
  add_download 8001 3 1 1
  expect_setup_failure corrupt_artifact "state format"
  finish_case corrupt_artifact
}

scenario_daemon_refuses_load() {
  begin daemon_refuses_load
  touch "$STUB_DIR/refuse_load"
  run_step setup
  check "setup fails" eq "$?" 1
  check "explains" file_has "$CASE_DIR/setup.out" "the daemon refused the whitelist"
  finish_case daemon_refuses_load
}

scenario_check_refused() {
  begin check_refused
  one_eligible 7 3
  run_step setup
  echo '{"success": false, "error": "capture is not running: no traffic was observed to check against the whitelist"}' > "$STUB_DIR/evaluate.json"
  echo 2 > "$STUB_DIR/evaluate_rc"
  run_step teardown
  check "teardown records the refusal" eq "$?" 0
  check "refused verdict" eq "$(jqf '.verdict' auto_whitelist_verdict.json)" refused
  check "iteration unchanged" eq "$(jqf '.iteration' auto_whitelist_state.json)" 7
  run_step finalize
  check "finalize fails the job" eq "$?" 1
  check "finalize says nothing is certified" file_has "$CASE_DIR/finalize.out" "Nothing is certified"
  finish_case check_refused
}

scenario_first_run_refused_uploads_nothing() {
  begin first_run_refused_uploads_nothing
  run_step setup
  echo '{"success": false, "error": "capture is not running"}' > "$STUB_DIR/evaluate.json"
  run_step teardown
  check "no upload of an empty state" file_has "$CASE_DIR/github_env" "AUTO_WHITELIST_UPLOAD=false"
  run_step finalize
  check "finalize fails" eq "$?" 1
  finish_case first_run_refused_uploads_nothing
}

scenario_tampered_file() {
  begin tampered_file
  one_eligible 7 3
  run_step setup
  jq '.whitelists[0].endpoints += [{"domain": "tampered.example", "port": 443}]' "$(wd)/auto_whitelist.json" > "$(wd)/x.json"
  mv "$(wd)/x.json" "$(wd)/auto_whitelist.json"
  run_step teardown
  check "teardown fails" eq "$?" 1
  check "explains" file_has "$CASE_DIR/teardown.out" "changed during the job"
  finish_case tampered_file
}

scenario_old_posture_cli() {
  begin old_posture_cli
  one_eligible 7 3
  run_step setup
  echo "error: unrecognized subcommand 'evaluate-custom-whitelists-from-file'" > "$STUB_DIR/evaluate.json"
  echo 2 > "$STUB_DIR/evaluate_rc"
  run_step teardown
  check "teardown fails" eq "$?" 1
  check "names the required version" file_has "$CASE_DIR/teardown.out" "2.0.3"
  finish_case old_posture_cli
}

scenario_no_setup_no_check() {
  begin no_setup_no_check
  run_step teardown
  check "teardown is a no-op" eq "$?" 0
  check "disabled" file_has "$CASE_DIR/github_env" "AUTO_WHITELIST_ENABLED=false"
  run_step finalize
  check "finalize passes" eq "$?" 0
  finish_case no_setup_no_check
}

scenario_legacy_home_files_removed() {
  begin legacy_home_files_removed
  echo '{}' > "$CASE_DIR/home/auto_whitelist.json"
  echo 7 > "$CASE_DIR/home/auto_whitelist_stable_count.txt"
  run_step setup
  check "legacy whitelist removed" no_file "$CASE_DIR/home/auto_whitelist.json"
  check "legacy state removed" no_file "$CASE_DIR/home/auto_whitelist_stable_count.txt"
  check "first run: nothing is inherited from the home directory" eq "$(jqf '.start_reason' auto_whitelist_config.json)" first_run
  finish_case legacy_home_files_removed
}

ALL_SCENARIOS=(
  first_run_learns
  stable_start_fails_on_new_endpoint
  stable_start_promote
  stable_start_conforming
  learning_settles
  learning_new_endpoint_resets
  max_iterations
  selects_only_trusted_artifact
  no_trusted_artifact_starts_new
  pool_name_carries_os_and_arch
  list_refused_by_allow_list
  allow_list_wait_then_listed
  allow_list_wait_exhausted
  allow_list_wait_only_for_the_allow_list
  list_refused_disconnected
  list_server_error
  run_lookup_error
  download_error
  corrupt_artifact
  daemon_refuses_load
  check_refused
  first_run_refused_uploads_nothing
  tampered_file
  old_posture_cli
  no_setup_no_check
  legacy_home_files_removed
)

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 2; }

if (($# > 0)); then
  SELECTED=("$@")
else
  SELECTED=("${ALL_SCENARIOS[@]}")
fi
for scenario in "${SELECTED[@]}"; do
  "scenario_$scenario"
done

echo ""
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
  printf '  failed: %s\n' "${FAILURES[@]}"
  exit 1
fi
