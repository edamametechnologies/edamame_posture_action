#!/usr/bin/env bash
# Auto-whitelist lifecycle of the EDAMAME Posture action.
#
#   setup     find this runner pool's whitelist artifact from a trusted earlier
#             run, download it, decide this run's mode from the state it was
#             saved with (learning or enforcing), and load it into the daemon
#   teardown  enforcing: check this job's egress traffic against the
#             whitelist, and learn nothing unless promote_exceptions asks for
#             it; learning: learn from this job's traffic and count the runs
#             that saw nothing new. Writes the next state.
#   finalize  fail the job on a whitelist violation, or when the check could
#             not certify anything (capture not running, daemon refusal)
#
# The run's mode is decided from the state BEFORE the run: a stable whitelist
# is enforced first, and a new endpoint fails the job instead of being
# learned. The whitelist and its state travel in one artifact per runner pool,
# OS and architecture, taken only from runs of the same workflow, branch and
# repository (never a fork) with a trusted trigger. Any failure to list or
# download artifacts fails the job: only a listing that answered and holds no
# eligible artifact starts a new whitelist. The checks run against the
# whitelist file this job downloaded, not against whatever the daemon holds,
# and only on sessions active since this job's setup (a daemon on a
# persistent runner outlives jobs).
#
# Tools: bash, jq, gh, and the posture CLI in EDAMAME_POSTURE_CMD. No sort,
# unzip or bc: on Windows `sort` can resolve to sort.exe, and containers may
# lack unzip.

set -euo pipefail

# jq.exe on Windows ends lines with CR LF: strip the CR so values compare
# equal on every OS. pipefail keeps jq's exit status (jq -e).
jq() { command jq "$@" | tr -d '\r'; }

FORMAT=2
readonly FORMAT

WORK="${RUNNER_TEMP:?RUNNER_TEMP is not set}/edamame-auto-whitelist"
CONFIG="$WORK/auto_whitelist_config.json"
WHITELIST="$WORK/auto_whitelist.json"
STATE="$WORK/auto_whitelist_state.json"
VERDICT="$WORK/auto_whitelist_verdict.json"
ADDED="$WORK/auto_whitelist_added.json"
NON_CONFORMING="$WORK/auto_whitelist_non_conforming.json"

log() { printf '%s\n' "$*"; }
notice() { printf '::notice::%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
fail() {
  printf '::error::%s\n' "$*"
  exit 1
}

# Append KEY=VALUE to GITHUB_ENV (when running under Actions).
set_env() {
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
  fi
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

posture() {
  # EDAMAME_POSTURE_CMD may carry a prefix ("sudo -E /usr/bin/edamame_posture").
  # shellcheck disable=SC2086
  ${EDAMAME_POSTURE_CMD:?EDAMAME_POSTURE_CMD is not set} "$@"
}

# The artifact name for this runner pool, OS and architecture. The caller
# names the pool (its runs-on label); the OS and architecture are added so a
# pool label shared across operating systems can never mix their whitelists.
effective_artifact_name() {
  printf '%s-%s-%s' "${AW_ARTIFACT_NAME:?AW_ARTIFACT_NAME is not set}" \
    "$(lower "${RUNNER_OS:-unknown}")" "$(lower "${RUNNER_ARCH:-unknown}")"
}

current_branch() {
  if [[ -n "${GITHUB_HEAD_REF:-}" ]]; then
    printf '%s' "$GITHUB_HEAD_REF"
  else
    printf '%s' "${GITHUB_REF_NAME:-}"
  fi
}

# The workflow file of this run (".github/workflows/x.yml"), from
# GITHUB_WORKFLOW_REF ("owner/repo/.github/workflows/x.yml@refs/heads/main").
current_workflow_path() {
  local ref="${GITHUB_WORKFLOW_REF:-}"
  ref="${ref#"${GITHUB_REPOSITORY:-}"/}"
  printf '%s' "${ref%%@*}"
}

# Explain a failed gh call and stop. A failure to list or download is never
# read as "no previous whitelist": a whitelist that cannot be read is not
# replaced by a new one.
gh_failure() {
  local what="$1" errfile="$2"
  local detail
  detail=$(tr '\n' ' ' < "$errfile" | cut -c1-600)
  if grep -qi "IP allow list" "$errfile"; then
    if [[ "${AW_DISCONNECTED:-false}" == "true" ]]; then
      fail "auto_whitelist: $what was refused by the organization's IP allow list, and a disconnected daemon cannot get this runner allowed. Use connected mode (edamame_user, edamame_domain, edamame_pin) with wait_for_api: true, or run where the artifacts API is reachable. ($detail)"
    fi
    if [[ "${AW_WAIT_FOR_API:-false}" == "true" ]]; then
      fail "auto_whitelist: $what was refused by the organization's IP allow list, after waiting for EDAMAME Hub to allow this runner. ($detail)"
    fi
    fail "auto_whitelist: $what was refused by the organization's IP allow list. Set wait_for_api: true so the job waits until EDAMAME Hub has allowed this runner. ($detail)"
  fi
  fail "auto_whitelist: $what failed, so the previous whitelist cannot be read; not starting a new one in its place. ($detail)"
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------

# Events whose runs may feed a whitelist: they run the repository's own code.
# pull_request runs (the PR's code) feed only other pull_request runs of the
# same branch; pull_request_target, workflow_run, issue_comment and the like
# never feed one.
trusted_event() {
  local event="$1" current="$2"
  case "$event" in
    push | workflow_dispatch | schedule | merge_group | release | repository_dispatch) return 0 ;;
    pull_request) [[ "$current" == "pull_request" ]] ;;
    *) return 1 ;;
  esac
}

# With wait_for_api and a connected daemon, wait until the artifacts API
# answers this runner. The organization's IP allow list guards it even in a
# public repository, where wait_for_api's probe of the repository answers at
# once, and EDAMAME Hub allows a newly connected runner a minute or two later.
# Same budget as wait_for_api: 20 attempts, a minute apart. Any other answer
# ends the wait; select_artifact then reports it.
wait_for_artifacts_api() {
  local errfile="$WORK/gh_wait_error.txt" attempt
  local attempts="${AW_ALLOW_LIST_ATTEMPTS:-20}" interval="${AW_ALLOW_LIST_INTERVAL:-60}"
  if [[ "${AW_WAIT_FOR_API:-false}" != "true" || "${AW_DISCONNECTED:-false}" == "true" ]]; then
    return 0
  fi
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts?per_page=1" > /dev/null 2> "$errfile"; then
      if ((attempt > 1)); then
        log "The artifacts API answers this runner (attempt $attempt)."
      fi
      return 0
    fi
    grep -qi "IP allow list" "$errfile" || return 0
    if ((attempt < attempts)); then
      log "The organization's IP allow list does not list this runner yet (attempt $attempt of $attempts); waiting ${interval}s for EDAMAME Hub to allow it."
      sleep "$interval"
    fi
  done
}

# Write the chosen artifact as JSON ({artifact, run}) to OUT, or leave OUT
# empty when no eligible artifact exists. Fails (exits the script) on any API
# error: it runs in the main shell, never in a command substitution, so a
# failure cannot be mistaken for "nothing found".
select_artifact() {
  local name="$1" branch="$2" workflow_path="$3" current_event="$4" out="$5"
  local encoded listing candidates count i candidate run_id run_json errfile reason
  errfile="$WORK/gh_error.txt"
  : > "$out"
  encoded=$(jq -rn --arg v "$name" '$v|@uri')

  if ! listing=$(gh api --paginate \
    "repos/${GITHUB_REPOSITORY}/actions/artifacts?name=${encoded}&per_page=100" 2>"$errfile"); then
    gh_failure "listing the artifacts named $name" "$errfile"
  fi
  if ! candidates=$(printf '%s' "$listing" | jq -s \
    --arg run "${GITHUB_RUN_ID:-}" --arg branch "$branch" '
      [ .[] | .artifacts[]?
        | select(.expired == false)
        | select(((.workflow_run.id // 0) | tostring) != $run) ]
      | sort_by(.created_at) | reverse
      | map(. + {reject: (
          if (.workflow_run.head_repository_id // -1) != (.workflow_run.repository_id // -2)
          then "produced by a fork"
          elif (.workflow_run.head_branch // "") != $branch
          then "produced on branch \(.workflow_run.head_branch // "?")"
          else null end)})' 2>"$errfile"); then
    gh_failure "reading the artifact listing" "$errfile"
  fi

  count=$(printf '%s' "$candidates" | jq 'length')
  for ((i = 0; i < count; i++)); do
    candidate=$(printf '%s' "$candidates" | jq -c ".[$i]")
    reason=$(printf '%s' "$candidate" | jq -r '.reject // empty')
    run_id=$(printf '%s' "$candidate" | jq -r '.workflow_run.id')
    if [[ -n "$reason" ]]; then
      log "  skipped artifact $(printf '%s' "$candidate" | jq -r '.id') of run $run_id: $reason"
      continue
    fi
    if ! run_json=$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}" 2>"$errfile"); then
      if grep -q "HTTP 404" "$errfile"; then
        log "  skipped artifact of run $run_id: the run no longer exists"
        continue
      fi
      gh_failure "looking up run $run_id (to check where its whitelist comes from)" "$errfile"
    fi
    local event path head_repo repo
    event=$(printf '%s' "$run_json" | jq -r '.event // ""')
    path=$(printf '%s' "$run_json" | jq -r '.path // ""')
    head_repo=$(printf '%s' "$run_json" | jq -r '.head_repository.id // -1')
    repo=$(printf '%s' "$run_json" | jq -r '.repository.id // -2')
    if [[ "$head_repo" != "$repo" ]]; then
      log "  skipped artifact of run $run_id: produced by a fork"
      continue
    fi
    if [[ -n "$workflow_path" && "$path" != "$workflow_path" ]]; then
      log "  skipped artifact of run $run_id: produced by workflow ${path:-?}, not $workflow_path"
      continue
    fi
    if [[ -z "$workflow_path" && "$(printf '%s' "$run_json" | jq -r '.name // ""')" != "${GITHUB_WORKFLOW:-}" ]]; then
      log "  skipped artifact of run $run_id: produced by another workflow"
      continue
    fi
    if ! trusted_event "$event" "$current_event"; then
      log "  skipped artifact of run $run_id: produced by a $event run"
      continue
    fi
    printf '%s' "$candidate" | jq -c --argjson run "$run_json" '{artifact: (. | del(.reject)), run: {id: $run.id, event: $run.event, path: $run.path, head_branch: $run.head_branch, head_sha: $run.head_sha}}' > "$out"
    return 0
  done
  return 0
}

write_empty_whitelist() {
  jq -n '{date: "Initial empty whitelist", signature: null,
    whitelists: [{name: "custom_whitelist", extends: null, endpoints: []}]}' > "$1"
}

validate_whitelist_file() {
  jq -e '(.whitelists | map(select(.name == "custom_whitelist")) | length) == 1' "$1" >/dev/null 2>&1
}

setup() {
  local name branch workflow_path event selection tmp errfile
  local iteration=0 stable_count=0 first_run=true start_mode=learning start_reason=first_run
  local consecutive="${AW_CONSECUTIVE:-3}" max_iterations="${AW_MAX_ITERATIONS:-25}" threshold="${AW_THRESHOLD:-0}"
  if ! is_integer "$consecutive" || ((consecutive == 0)); then
    fail "auto_whitelist_stability_consecutive_runs must be a positive integer (got '$consecutive')"
  fi
  if ! is_integer "$max_iterations" || ((max_iterations == 0)); then
    fail "auto_whitelist_max_iterations must be a positive integer (got '$max_iterations')"
  fi
  is_number "$threshold" || fail "auto_whitelist_stability_threshold must be a number (got '$threshold')"
  threshold=$(jq -n --arg t "$threshold" '$t | tonumber')

  rm -rf "$WORK"
  mkdir -p "$WORK"
  errfile="$WORK/gh_error.txt"

  # Files earlier versions of the action kept in the home directory: on a
  # persistent runner they belong to whatever job ran last.
  local legacy
  for legacy in "$HOME"/auto_whitelist.json "$HOME"/auto_whitelist_*.json "$HOME"/auto_whitelist_*.txt; do
    if [[ -f "$legacy" ]]; then
      log "Removing $legacy, left by an earlier job (the whitelist now lives in \$RUNNER_TEMP)"
      rm -f "$legacy"
    fi
  done

  if [[ -n "${AW_STATE_ARTIFACT_NAME:-}" && "${AW_STATE_ARTIFACT_NAME}" != "auto-whitelist-state" ]]; then
    notice "auto_whitelist_state_artifact_name is no longer used: the state travels in the whitelist artifact."
  fi

  name=$(effective_artifact_name)
  branch=$(current_branch)
  workflow_path=$(current_workflow_path)
  event="${GITHUB_EVENT_NAME:-}"
  log "Auto-whitelist artifact: $name (repository ${GITHUB_REPOSITORY}, workflow ${workflow_path:-${GITHUB_WORKFLOW:-?}}, branch ${branch:-?}, event ${event:-?})"

  wait_for_artifacts_api
  select_artifact "$name" "$branch" "$workflow_path" "$event" "$WORK/selection.json"
  selection=$(cat "$WORK/selection.json")
  if [[ -z "$selection" ]]; then
    log "No whitelist from an earlier run of this workflow on this branch: this run starts a new whitelist (learning)."
    write_empty_whitelist "$WHITELIST"
  else
    local run_id artifact_id created
    run_id=$(printf '%s' "$selection" | jq -r '.run.id')
    artifact_id=$(printf '%s' "$selection" | jq -r '.artifact.id')
    created=$(printf '%s' "$selection" | jq -r '.artifact.created_at')
    log "Using artifact $artifact_id from run $run_id (${created}, $(printf '%s' "$selection" | jq -r '.run.event') on $(printf '%s' "$selection" | jq -r '.run.head_branch'))"
    tmp="$WORK/download"
    mkdir -p "$tmp"
    if ! gh run download "$run_id" --repo "$GITHUB_REPOSITORY" --name "$name" --dir "$tmp" 2>"$errfile"; then
      gh_failure "downloading artifact $name from run $run_id" "$errfile"
    fi
    [[ -f "$tmp/auto_whitelist.json" && -f "$tmp/auto_whitelist_state.json" ]] ||
      fail "auto_whitelist: artifact $name from run $run_id lacks auto_whitelist.json or auto_whitelist_state.json; not starting a new whitelist in its place. Delete the artifact to start over."
    validate_whitelist_file "$tmp/auto_whitelist.json" ||
      fail "auto_whitelist: artifact $name from run $run_id holds no valid custom_whitelist; delete the artifact to start over."
    [[ "$(jq -r '.format // 0' "$tmp/auto_whitelist_state.json" 2>/dev/null)" == "$FORMAT" ]] ||
      fail "auto_whitelist: artifact $name from run $run_id has state format $(jq -r '.format // "?"' "$tmp/auto_whitelist_state.json" 2>/dev/null || printf '?') (expected $FORMAT); delete the artifact to start over."
    cp "$tmp/auto_whitelist.json" "$WHITELIST"
    cp "$tmp/auto_whitelist_state.json" "$STATE"
    iteration=$(jq -r '.iteration // 0' "$STATE")
    stable_count=$(jq -r '.stable_count // 0' "$STATE")
    is_integer "$iteration" || fail "auto_whitelist: corrupt state in $name (iteration '$iteration')"
    is_integer "$stable_count" || fail "auto_whitelist: corrupt state in $name (stable_count '$stable_count')"
    first_run=false
    if ((stable_count >= consecutive)); then
      start_mode=enforcing
      start_reason=stable
    elif ((iteration >= max_iterations)); then
      start_mode=enforcing
      start_reason=max_iterations
    else
      start_mode=learning
      start_reason=learning
    fi
  fi

  local endpoints
  endpoints=$(jq '[.whitelists[] | select(.name == "custom_whitelist") | .endpoints | length] | add // 0' "$WHITELIST")

  jq -n \
    --argjson format "$FORMAT" \
    --arg artifact_name "$name" \
    --arg input_artifact_name "$AW_ARTIFACT_NAME" \
    --argjson threshold "$threshold" \
    --argjson consecutive "$consecutive" \
    --argjson max_iterations "$max_iterations" \
    --arg start_mode "$start_mode" \
    --arg start_reason "$start_reason" \
    --argjson first_run "$first_run" \
    --argjson iteration "$iteration" \
    --argjson stable_count "$stable_count" \
    --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg job "${GITHUB_JOB:-}" \
    --arg setup_time "${EDAMAME_POSTURE_SETUP_TIME:-$(now_utc)}" \
    --arg branch "$branch" \
    --arg workflow "${workflow_path:-${GITHUB_WORKFLOW:-}}" \
    --arg sha "$(sha256_of "$WHITELIST")" \
    --argjson source "${selection:-null}" \
    '{format: $format, artifact_name: $artifact_name, input_artifact_name: $input_artifact_name,
      stability_threshold: $threshold, stability_consecutive_runs: $consecutive,
      max_iterations: $max_iterations, start_mode: $start_mode, start_reason: $start_reason,
      first_run: $first_run, iteration: $iteration, stable_count: $stable_count,
      run_id: $run_id, run_attempt: $run_attempt, job: $job, setup_time: $setup_time,
      branch: $branch, workflow: $workflow, whitelist_sha256: $sha, source: $source}' > "$CONFIG"

  set_env EDAMAME_AUTO_WHITELIST_DIR "$WORK"
  set_env EDAMAME_AUTO_WHITELIST_MODE "$start_mode"
  set_env EDAMAME_AUTO_WHITELIST_ARTIFACT "$name"

  # Load it so the daemon's live view (get-sessions, cancel_on_violation)
  # reflects it. The teardown checks against the file, not the daemon.
  local out
  if ! out=$(posture set-custom-whitelists-from-file "$WHITELIST" 2>&1); then
    printf '%s\n' "$out"
    fail "auto_whitelist: the daemon refused the whitelist ($name). Nothing would be checked; stopping."
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out"
  local active
  active=$(posture get-whitelist-name 2>/dev/null | tr -d '\r' | tail -1 || true)
  [[ "$active" == "custom_whitelist" ]] ||
    fail "auto_whitelist: after loading, the daemon enforces '${active:-nothing}' instead of custom_whitelist."

  case "$start_mode:$start_reason" in
    learning:first_run)
      log "Mode: LEARNING (first run). This job's traffic becomes the whitelist; nothing fails on it."
      ;;
    learning:*)
      log "Mode: LEARNING (iteration $((iteration + 1)), $stable_count/$consecutive consecutive runs without a new endpoint, $endpoints endpoints). Nothing fails on new endpoints yet."
      ;;
    enforcing:stable)
      log "Mode: ENFORCING ($stable_count consecutive runs saw nothing new; $endpoints endpoints). A new endpoint fails this job and is not learned."
      ;;
    enforcing:max_iterations)
      warn "auto_whitelist: the whitelist did not settle within $max_iterations learning runs; it is enforced as it stands ($endpoints endpoints). A new endpoint fails this job."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------

teardown() {
  if [[ ! -f "$CONFIG" ]]; then
    log "No auto-whitelist setup ran in this job; nothing to check."
    set_env AUTO_WHITELIST_ENABLED false
    return 0
  fi
  set_env AUTO_WHITELIST_ENABLED true
  [[ "$(jq -r '.run_id' "$CONFIG")" == "${GITHUB_RUN_ID:-}" ]] ||
    fail "auto_whitelist: $CONFIG belongs to run $(jq -r '.run_id' "$CONFIG"), not this one."
  [[ "$(sha256_of "$WHITELIST")" == "$(jq -r '.whitelist_sha256' "$CONFIG")" ]] ||
    fail "auto_whitelist: $WHITELIST changed during the job; refusing to check against or learn from it."

  local name start_mode start_reason iteration stable_count consecutive max_iterations threshold since first_run
  name=$(jq -r '.artifact_name' "$CONFIG")
  start_mode=$(jq -r '.start_mode' "$CONFIG")
  start_reason=$(jq -r '.start_reason' "$CONFIG")
  iteration=$(jq -r '.iteration' "$CONFIG")
  stable_count=$(jq -r '.stable_count' "$CONFIG")
  consecutive=$(jq -r '.stability_consecutive_runs' "$CONFIG")
  max_iterations=$(jq -r '.max_iterations' "$CONFIG")
  threshold=$(jq -r '.stability_threshold' "$CONFIG")
  since=$(jq -r '.setup_time' "$CONFIG")
  first_run=$(jq -r '.first_run' "$CONFIG")
  local promote="${AW_PROMOTE:-false}"

  # 1. Check this job's traffic against the whitelist it started from.
  local check rc=0
  check=$(posture evaluate-custom-whitelists-from-file "$WHITELIST" --since "$since" --json 2>"$WORK/check_error.txt") || rc=$?
  if ! printf '%s' "$check" | jq -e 'type == "object" and has("success")' >/dev/null 2>&1; then
    cat "$WORK/check_error.txt" >&2 || true
    fail "auto_whitelist: the posture CLI did not check the traffic (exit $rc). This action needs edamame_posture >= 2.0.3 (evaluate-custom-whitelists-from-file)."
  fi

  local verdict evaluated=0 non_conforming='[]' error=""
  if [[ "$(printf '%s' "$check" | jq -r '.success')" != "true" ]]; then
    error=$(printf '%s' "$check" | jq -r '.error // "unknown error"')
    verdict=refused
  else
    evaluated=$(printf '%s' "$check" | jq -r '.evaluated // 0')
    non_conforming=$(printf '%s' "$check" | jq -c '.non_conforming // []')
  fi
  local exceptions
  exceptions=$(printf '%s' "$non_conforming" | jq 'length')

  # 2. Decide from the mode the run started in.
  local learn=false
  if [[ "${verdict:-}" != "refused" ]]; then
    if [[ "$start_mode" == "enforcing" ]]; then
      if ((exceptions == 0)); then
        verdict=conforming
      elif [[ "$promote" == "true" ]]; then
        verdict=promoted
        learn=true
      else
        verdict=violation
      fi
    else
      verdict=learning
      learn=true
    fi
  fi

  local added='[]' added_count=0 total_after
  if [[ "$learn" == "true" ]]; then
    local augment
    rc=0
    augment=$(posture augment-custom-whitelists-from-file "$WHITELIST" --since "$since" 2>"$WORK/augment_error.txt") || rc=$?
    if ! printf '%s' "$augment" | jq -e '.success == true and (.whitelist | type == "object")' >/dev/null 2>&1; then
      cat "$WORK/augment_error.txt" >&2 || true
      fail "auto_whitelist: learning from this job's traffic failed (exit $rc): $(printf '%s' "$augment" | jq -r '.error // empty' 2>/dev/null)"
    fi
    printf '%s' "$augment" | jq '.whitelist' > "$WHITELIST.new"
    validate_whitelist_file "$WHITELIST.new" || fail "auto_whitelist: the learned whitelist has no custom_whitelist"
    mv "$WHITELIST.new" "$WHITELIST"
    added=$(printf '%s' "$augment" | jq -c '.added // []')
    added_count=$(printf '%s' "$added" | jq 'length')
  fi
  printf '%s\n' "$added" | jq '.' > "$ADDED"
  printf '%s\n' "$non_conforming" | jq '.' > "$NON_CONFORMING"
  total_after=$(jq '[.whitelists[] | select(.name == "custom_whitelist") | .endpoints | length] | add // 0' "$WHITELIST")

  # 3. Counters. A refused check counts nothing. A learning run is stable when
  #    it saw nothing the whitelist did not already allow (or, with a
  #    threshold, when what it added stays under it); enforcing runs keep
  #    their count.
  local run_stable=false next_mode next_reason
  if [[ "$verdict" != "refused" ]]; then
    iteration=$((iteration + 1))
    if [[ "$verdict" == "learning" ]]; then
      if [[ "$first_run" != "true" ]]; then
        if ((exceptions == 0)); then
          run_stable=true
        elif ((total_after > 0)) && jq -en --argjson added "$added_count" --argjson total "$total_after" --argjson threshold "$threshold" \
          '$threshold > 0 and ($added * 100 / $total) <= $threshold' >/dev/null; then
          run_stable=true
        fi
      fi
      if [[ "$run_stable" == "true" ]]; then
        stable_count=$((stable_count + 1))
      else
        stable_count=0
      fi
    fi
  fi
  if ((stable_count >= consecutive)); then
    next_mode=enforcing
    next_reason=stable
  elif ((iteration >= max_iterations)); then
    next_mode=enforcing
    next_reason=max_iterations
  else
    next_mode=learning
    next_reason=learning
  fi

  # 4. State for the next run, and a record of this one.
  jq -n \
    --argjson format "$FORMAT" \
    --arg artifact_name "$name" \
    --argjson iteration "$iteration" \
    --argjson stable_count "$stable_count" \
    --arg mode "$next_mode" \
    --arg mode_reason "$next_reason" \
    --arg last_verdict "$verdict" \
    --arg updated_at "$(now_utc)" \
    --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg workflow "$(jq -r '.workflow' "$CONFIG")" \
    --arg branch "$(jq -r '.branch' "$CONFIG")" \
    --arg runner_os "${RUNNER_OS:-}" \
    --arg runner_arch "${RUNNER_ARCH:-}" \
    '{format: $format, artifact_name: $artifact_name, iteration: $iteration,
      stable_count: $stable_count, mode: $mode, mode_reason: $mode_reason,
      last_verdict: $last_verdict, updated_at: $updated_at, run_id: $run_id,
      run_attempt: $run_attempt, workflow: $workflow, branch: $branch,
      runner_os: $runner_os, runner_arch: $runner_arch}' > "$STATE"

  # The two lists go through files: on a busy runner either one passes the
  # 128 KiB a single argument may hold on Linux, and jq never starts
  # ("Argument list too long", posture release_debs 2026-10-02).
  jq -n \
    --arg start_mode "$start_mode" \
    --arg start_reason "$start_reason" \
    --arg verdict "$verdict" \
    --arg error "$error" \
    --argjson evaluated "$evaluated" \
    --slurpfile non_conforming "$NON_CONFORMING" \
    --slurpfile added "$ADDED" \
    --argjson iteration "$iteration" \
    --argjson stable_count "$stable_count" \
    --argjson run_stable "$run_stable" \
    --arg next_mode "$next_mode" \
    --arg next_reason "$next_reason" \
    --argjson endpoints "$total_after" \
    '{start_mode: $start_mode, start_reason: $start_reason, verdict: $verdict,
      error: (if $error == "" then null else $error end), evaluated: $evaluated,
      non_conforming: $non_conforming[0], added: $added[0], iteration: $iteration,
      stable_count: $stable_count, run_stable: $run_stable,
      next_mode: $next_mode, next_reason: $next_reason, endpoints: $endpoints}' > "$VERDICT"

  set_env AUTO_WHITELIST_VERDICT "$verdict"
  set_env AUTO_WHITELIST_ITERATION "$iteration"
  set_env AUTO_WHITELIST_STABLE_COUNT "$stable_count"
  set_env AUTO_WHITELIST_NEXT_MODE "$next_mode"
  # A refused check changes nothing; upload only when there is a state to
  # carry (a refused first run has none).
  if [[ "$verdict" == "refused" && "$first_run" == "true" ]]; then
    set_env AUTO_WHITELIST_UPLOAD false
  else
    set_env AUTO_WHITELIST_UPLOAD true
  fi

  report "$name"
}

report() {
  local name="$1"
  local verdict start_mode evaluated exceptions added_count next_mode next_reason stable_count iteration endpoints
  verdict=$(jq -r '.verdict' "$VERDICT")
  start_mode=$(jq -r '.start_mode' "$VERDICT")
  evaluated=$(jq -r '.evaluated' "$VERDICT")
  exceptions=$(jq '.non_conforming | length' "$VERDICT")
  added_count=$(jq '.added | length' "$VERDICT")
  next_mode=$(jq -r '.next_mode' "$VERDICT")
  next_reason=$(jq -r '.next_reason' "$VERDICT")
  stable_count=$(jq -r '.stable_count' "$VERDICT")
  iteration=$(jq -r '.iteration' "$VERDICT")
  endpoints=$(jq -r '.endpoints' "$VERDICT")

  log ""
  log "=== Auto-whitelist ($name) ==="
  log "Started: $start_mode. Egress sessions checked: $evaluated. Not in the whitelist: $exceptions."
  if ((exceptions > 0)); then
    jq -r '.non_conforming[] | "  \(.protocol) \(.dst_domain // "(no name)") \(.dst_ip):\(.dst_port) process=\(.process // "?") AS\(.as_number // "?") \(.as_owner // "")"' "$VERDICT"
  fi
  case "$verdict" in
    conforming) log "Result: conforming. Nothing learned." ;;
    violation) log "Result: VIOLATION. The endpoints above are not learned; the job fails at the end of this step list." ;;
    promoted)
      warn "auto_whitelist: $added_count endpoint(s) PROMOTED into the enforced whitelist without review (promote_exceptions=true). Review them in auto_whitelist_added.json of artifact $name."
      ;;
    learning) log "Result: learning. Added $added_count endpoint(s); the whitelist now holds $endpoints." ;;
    refused) log "Result: NOT CERTIFIED: $(jq -r '.error' "$VERDICT")" ;;
  esac
  if ((added_count > 0)); then
    log "Added:"
    jq -r '.added[] | "  \(.protocol // "?") \(.domain // (.domains // [] | join(",")) // "") \(.ip // ((.ips // []) | join(","))) ports=\(.port // ((.ports // []) | tostring)) \(if .unresolved_only then "AS\(.as_number) (unnamed traffic only)" else "" end)"' "$VERDICT"
  fi
  if [[ "$verdict" != "refused" ]]; then
    if [[ "$next_mode" == "enforcing" && "$start_mode" == "learning" ]]; then
      if [[ "$next_reason" == "stable" ]]; then
        log "The whitelist is settled ($stable_count consecutive runs without a new endpoint): the next run ENFORCES it."
      else
        warn "auto_whitelist: $iteration learning runs without settling; the next run enforces the whitelist as it stands."
      fi
    elif [[ "$next_mode" == "learning" ]]; then
      log "Next run: learning ($stable_count/$(jq -r '.stability_consecutive_runs' "$CONFIG") consecutive runs without a new endpoint)."
    fi
  fi

  summary "### EDAMAME auto-whitelist: $verdict"
  summary ""
  summary "Artifact \`$name\`, started **$start_mode**, iteration $iteration, $stable_count consecutive runs without a new endpoint, $endpoints endpoints. Next run: **$next_mode**."
  summary ""
  if ((exceptions > 0)); then
    summary "| Protocol | Destination | Address | Process | Network |"
    summary "|---|---|---|---|---|"
    jq -r '.non_conforming[] | "| \(.protocol) | \(.dst_domain // "(no name)") | \(.dst_ip):\(.dst_port) | \(.process // "?") | AS\(.as_number // "?") \(.as_owner // "") |"' "$VERDICT" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    summary ""
  fi
  if ((added_count > 0)); then
    summary "$added_count endpoint(s) added to the whitelist (\`auto_whitelist_added.json\` in the artifact)."
  fi
}

# ---------------------------------------------------------------------------
# finalize
# ---------------------------------------------------------------------------

finalize() {
  [[ -f "$VERDICT" ]] || return 0
  local verdict name
  verdict=$(jq -r '.verdict' "$VERDICT")
  name=$(jq -r '.artifact_name' "$CONFIG" 2>/dev/null || printf '?')
  case "$verdict" in
    violation)
      printf '::error::auto_whitelist: %s endpoint(s) this job contacted are not in the enforced whitelist (%s).\n' "$(jq '.non_conforming | length' "$VERDICT")" "$name"
      log ""
      log "This can be a supply chain compromise (a dependency or build step calling out) or a legitimate new endpoint."
      log "Review the endpoints listed above. To accept them:"
      log "  - rerun with promote_exceptions: true (they are added without review; the list is kept in the artifact), or"
      log "  - delete the artifact $name to learn this pool's whitelist again:"
      log "      gh api repos/${GITHUB_REPOSITORY:-OWNER/REPO}/actions/artifacts?name=$name --jq '.artifacts[].id' | xargs -I {} gh api -X DELETE repos/${GITHUB_REPOSITORY:-OWNER/REPO}/actions/artifacts/{}"
      exit 1
      ;;
    refused)
      fail "auto_whitelist: this job's traffic could not be checked against the whitelist: $(jq -r '.error' "$VERDICT"). Nothing is certified."
      ;;
    *) return 0 ;;
  esac
}

case "${1:-}" in
  setup) setup ;;
  teardown) teardown ;;
  finalize) finalize ;;
  *)
    printf 'usage: %s setup|teardown|finalize\n' "$0" >&2
    exit 2
    ;;
esac
