#!/usr/bin/env bash
# Print the edamame_posture ref whose attack scenario corpus
# (tests/security: run_cve_detection.sh and its triggers) the test workflows
# run: $POSTURE_REF when it is set (a workflow_dispatch override, for instance
# `main` before a release), otherwise the latest edamame_posture release tag.
# That is the version this action installs, so the triggers always match the
# detector under test and there is no pinned tag to forget.
set -euo pipefail

if [[ -n "${POSTURE_REF:-}" ]]; then
  printf '%s\n' "$POSTURE_REF"
  exit 0
fi

# The public releases/latest redirect needs no token, so the organization's
# IP allow list does not apply on GitHub-hosted runners.
url="https://github.com/edamametechnologies/edamame_posture_cli/releases/latest"
location=$(curl -sSI --retry 3 --retry-delay 5 --max-time 30 "$url" |
  tr -d '\r' | sed -n 's/^[Ll]ocation: *//p' | tail -n 1)
tag=$(printf '%s' "$location" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' || true)
if [[ -z "$tag" ]]; then
  echo "::error::Could not resolve the latest edamame_posture release (redirect: ${location:-none})" >&2
  exit 1
fi
printf '%s\n' "$tag"
