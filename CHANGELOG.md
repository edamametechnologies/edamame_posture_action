# Changelog

All notable changes to this GitHub Action are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The moving major-version tag (`v1`) is force-updated to the latest
backwards-compatible release on every cut. Immutable `vX.Y.Z` tags are
also published for reproducible pins; see the README "Pinning" section.

## [Unreleased]

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
  `vulnerability-findings --active-only` (when the installed
  `edamame_posture` exposes the subcommand, > 1.2.2) and prints the full
  per-finding data (`finding_key`, `check`, `severity`, `description`,
  `process_*`, `destination_*`, `open_files`, `detection_basis`) so a CI
  operator can triage a finding from the job log alone without SSHing
  into the runner. Older posture binaries gracefully fall through with
  an `[INFO]` note; the summary-count gate path is unchanged.
- README "Pinning" subsection explaining the difference between the
  moving `@v1` tag and immutable `@vX.Y.Z` tags.
- New release-time validation: the `release.yml` workflow now gates on
  semver-shape, version not already published, the presence of a
  CHANGELOG entry for the dispatched version, and `test.yml` being
  green on the same commit. The "test.yml green" check soft-passes
  with a `::warning::` annotation when the github-hosted runner's
  IP is blocked by the `edamametechnologies` org IP allow list (the
  github-hosted runner pool is not whitelisted); the dispatcher is
  expected to visually verify `test.yml` is green on the dispatched
  SHA before invoking. The other three validate checks remain hard
  failures.

### Improved

- The vulnerability gate's Python fallback (used when the installed
  `edamame_posture` does not expose `--fail-on-findings`) now prefers
  `active_alertable_findings` (HIGH/CRITICAL non-dismissed) over the raw
  `active_findings` total, mirroring the native flag introduced in
  `edamame_posture` v1.3.1. LOW-severity ambient findings (CI
  bootstrappers like `rustup-init` from `/tmp/`, benign temp `.log`
  writes) stay visible in the dashboard but no longer trip the run gate.
  Older daemons that predate the alertable counter fall back to
  `active_findings` so the gate keeps working during a rolling upgrade.
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
- `release.yml` no longer dogfoods the action in-line (no more
  `Setup Posture` + `dump_vulnerability_findings` steps in the release
  workflow itself); the runner-protection gate is exercised by
  `test.yml` and `test_vulnerability_gate.yml`. This also removes the
  chicken-and-egg of `release.yml` consuming `@v1` while the release
  is mid-flight.

## [1.0.0] - 2026-04-17

- Initial immutable-tag release (commit 479ee93).
- Composite action covering: setup, network scan, packet capture,
  policy checks, custom and auto-whitelist lifecycle, runtime
  vulnerability gate, eBPF support verification, and stop.
