# Changelog

All notable changes to this GitHub Action are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The moving major-version tag (`v1`) is force-updated to the latest
backwards-compatible release on every cut. Immutable `vX.Y.Z` tags are
also published for reproducible pins; see the README "Pinning" section.

## [Unreleased]

## [1.1.5] - 2026-05-28

### Fixed

- Installer bootstrap: avoid silent fallback to ancient binaries when the
  GitHub releases API is unreachable from github-hosted runner pools.

  Two compounding root causes, fixed together:

  1. **Unauth rate limit / IP allow list on `api.github.com`.** The
     `Setup EDAMAME Posture` step used to read the latest release tag
     with an unauthenticated GitHub API call. On github-hosted runner
     pools, that call returned an empty body (or HTTP 403 once the
     `edamametechnologies` org enabled an IP allow list on the org-
     scoped `api.github.com` endpoint -- the allow list rejects github-
     hosted runner egress IPs even when the call is authenticated with
     `$GITHUB_TOKEN`, because the allow list is enforced at the org
     boundary, not at the auth layer). The resolver then fell back to
     the hardcoded `INSTALL_SCRIPT_REF=v1.0.0`, and the v1.0.0
     `install.sh` fell back to its own `FALLBACK_VERSION=0.9.75`,
     installing a 2024-era binary that lacks modern CLI subcommands
     (e.g. `vulnerability-findings`).

  2. **`install.sh` itself uses `api.github.com`.** Even after the
     action passed `$GITHUB_TOKEN` into `install.sh`, the installer's
     own `fetch_latest_release_tag` / `fetch_release_feed` calls hit
     the same blocked endpoint, fell back to the installer's hardcoded
     `FALLBACK_VERSION=1.2.0`, and installed a 6-month-old macOS binary
     that gets killed by Gatekeeper with `Killed: 9`.

  The action and the latest `install.sh` now:
  - resolve the latest release tag via the **`github.com/.../releases/
    latest` HTTP 302 redirect**, which is served by github.com itself
    (not the org-scoped `api.github.com`) and works without auth and
    without hitting the IP allow list, instead of calling
    `api.github.com/.../releases/latest`;
  - prefer `https://raw.githubusercontent.com/.../main/install.sh` as
    the **primary** installer source (release-pinned `install.sh` is
    frozen at release time and does not know how to install later
    releases), and only fall back to the release-asset installer when
    raw `main` is unreachable;
  - bump the hardcoded `INSTALL_SCRIPT_REF` default from `v1.0.0` to
    `v1.3.18` so the last-resort fallback uses an installer whose
    `FALLBACK_VERSION` and `LATEST_RELEASE_TAG_SECONDARY` retry logic
    are current and whose CLI surface includes the modern subcommand
    aliases (`vulnerability-findings`, etc.);
  - keep exporting `$GITHUB_TOKEN` into the `install.sh` invocation as
    a belt-and-suspenders fallback for installer code paths that still
    use `api.github.com` (the redirect path is now preferred, but the
    token is still useful for non-org repos or for the rare runner
    that can reach `api.github.com` but is being rate-limited).

  The companion change in `edamame_posture/install.sh` adds the same
  redirect-based resolver to `fetch_latest_version` and
  `fetch_latest_release_tag`, and bumps `FALLBACK_VERSION` from
  `1.2.0` to `1.3.18`. Released installers will keep the old fallback
  until the next `edamame_posture` release, which is why the action's
  `INSTALL_SCRIPT_REF=v1.3.18` default is the critical guard for the
  transition window.

### Changed

- Documented recommended `auto_whitelist_artifact_name` naming: key artifacts by
  `runs-on` runner pool (`edamame-auto-whitelist-${{ matrix.runs-on }}` or a
  literal runs-on suffix), not `runner.os` or the default single-repo bucket.
  Expanded README **Artifact naming (runner pools)** and the `action.yml` input
  description.

## [1.1.4] - 2026-05-22

### Added

- Preferred attack pattern detector inputs:
  `attack_pattern_detection`, `attack_pattern_detection_interval`,
  `dump_attack_pattern_findings`, and `exit_on_attack_pattern_findings`.
  Each new input takes precedence when explicitly set; the legacy
  `vulnerability_*` names remain accepted as wire-level aliases.
- Agent Security Attack Detection Demo workflow
  (`.github/workflows/agent_security_attacks.yml`) for end-to-end CVE
  scenario validation against a Lima-hosted posture daemon.

### Changed

- User-facing docs and input descriptions now refer to "attack pattern
  detection" while keeping legacy `vulnerability_*` input names for
  backward compatibility.
- `auto_whitelist_max_iterations` default raised from `15` to `25` so
  longer auto-whitelist learning cycles can converge before declaring
  stability.

## [1.1.3] - 2026-05-16

### Changed

- Live daemon cancellation now uses runtime vulnerability findings instead of
  anomalous-session enforcement. When `vulnerability_detection` and
  `exit_on_vulnerability_findings` are both enabled, setup passes
  `--fail-on-findings` to `edamame_posture`.
- Strict vulnerability gating now fails fast unless the setup invocation also
  enables LLM adjudication with `agentic_mode=analyze|auto`, a non-`none`
  `agentic_provider`, and the required provider credential environment variable.
- Disconnected startup now passes `--agentic-interval`, matching connected
  startup configuration.

### Removed

- Removed legacy posture-binary fallbacks from `dump_vulnerability_findings`.
  The action now requires `vulnerability-findings --active-only` and
  `vulnerability-status --fail-on-findings`.

## [1.1.2] - 2026-05-15

### Fixed

- Removed action-level vulnerability finding filtering from
  `dump_vulnerability_findings`. The action now dumps raw findings and delegates
  enforcement back to `edamame_posture vulnerability-status --fail-on-findings`;
  stale workflow state and detector false positives must be fixed in their
  owning workflow or detector layer.

## [1.1.1] - 2026-05-15

### Improved

- `stop: true` now bounds the foreground stop command to 30 seconds before
  continuing into the existing verification and force-kill path. This prevents
  Windows-hosted action tests from hanging indefinitely when the posture CLI
  blocks while the daemon is shutting down.

## [1.1.0] - 2026-05-14

### Fixed

- `display_logs: true` now correctly dumps the daemon's rolling log files
  from `/var/log/edamame/edamame_*_<pid>.YYYY-MM-DD` (Unix) and the
  binary's parent directory (Windows). Previously the step did
  `cd ~ && find .` which missed `/var/log/edamame/` entirely and had no
  `sudo`, so it could not read the daemon's root-owned rolling logs.
- Pre-create `/var/log/edamame` mode `1777` (sticky world-writable, like
  `/tmp`) on Unix so non-`sudo` CLI invocations no longer print
  `Failed to initialize rolling file appender in /var/log/edamame: Permission denied`.
  Both the root daemon and non-`sudo` CLI processes can now write their
  PID-suffixed log files in the same directory.

### Added

- `EDAMAME_DAEMON_LOGS_PATH` environment variable, exported when
  `display_logs: true`, points to `$RUNNER_TEMP/edamame-daemon-logs/`.
  Downstream `actions/upload-artifact` steps can hand the path through
  directly without recomputing daemon paths or trusting the daemon PID.
  See README "Daemon log collection".
- `dump_vulnerability_findings: true` now also runs
  `vulnerability-findings --active-only` and prints the full
  per-finding data (`finding_key`, `check`, `severity`, `description`,
  `process_*`, `destination_*`, `open_files`, `detection_basis`) so a CI
  operator can triage a finding from the job log alone without SSHing
  into the runner.
- README "Pinning" subsection explaining the difference between the
  moving `@v1` tag and immutable `@vX.Y.Z` tags.
- New release-time validation: the `release.yml` workflow now gates on
  semver-shape, version not already published, the presence of a
  CHANGELOG entry for the dispatched version, and `test.yml` being
  green on the same commit. All four checks hard-fail.

### Improved

- The vulnerability gate delegates to
  `edamame_posture vulnerability-status --fail-on-findings`, which consumes
  `active_alertable_findings` (HIGH/CRITICAL non-dismissed) so LOW-severity
  ambient findings stay visible without tripping the run gate.
- Self-test workflow `test_vulnerability_gate.yml` now clears runtime
  vulnerability state (`clear_vulnerability_history` +
  `reset_vulnerability_suppressions`) after the gate-firing scenario, so
  the deliberately-injected token-exfil finding cannot leak into a
  subsequent workflow run on the same self-hosted runner per the
  `vulnerability_detector` Finding Persistence invariant.

### Changed

- `release.yml` now publishes BOTH an immutable `vX.Y.Z` tag plus a
  GitHub Release AND force-updates the moving `v1` tag and its release
  pointer. The previous workflow only force-updated `v1`.
- `test.yml` `paths:` trigger now also fires on changes to
  `CHANGELOG.md`, `.github/workflows/test.yml`, and
  `.github/workflows/release.yml` so a release-relevant commit always
  produces a green test run on its own SHA before the release gate
  evaluates it.
- `release.yml` keeps `Setup EDAMAME Posture` (connected mode) as the
  first step of both the `validate` and `release` jobs. This is
  mandatory: the github-hosted runner pool's IPs are not in the
  `edamametechnologies` org IP allow list, so any direct
  `api.github.com` / `git push` call returns 403 from a hosted
  runner. Hub registration via Setup EDAMAME Posture dynamically
  whitelists the runner's egress IP for the duration of the job.
  The trailing `dump_vulnerability_findings: true` step enforces the
  gate (`exit_on_vulnerability_findings: true`) so the freshly-built
  binary is observed end-to-end.

## [1.0.0] - 2026-04-17

- Initial immutable-tag release (commit 479ee93).
- Composite action covering: setup, network scan, packet capture,
  policy checks, custom and auto-whitelist lifecycle, runtime
  vulnerability gate, eBPF support verification, and stop.
