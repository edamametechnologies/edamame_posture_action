# Changelog

All notable changes to this GitHub Action are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The moving major-version tag (`v1`) follows the latest backwards-compatible
release once an organization admin moves it (only admins may update `v*`
tags). Immutable `vX.Y.Z` tags are published for reproducible pins; see the
README "Pinning" section.

## [Unreleased]

Requires edamame_posture 2.0.3 or later.

### Added

- Windows self-hosted runners: the first setup of a job stops the processes
  an earlier, interrupted job left running (its posture daemon, build or test
  processes). Only processes started by the runner's earlier jobs are
  stopped, each one is logged, and no file or service is touched.
- `adjudication_mode` input: how the attack pattern detector publishes
  without an LLM adjudicator: `llm` (default), `advisory` (publish the
  deterministic result when the LLM fails or is not configured) or
  `deterministic` (never consult the LLM; the strict gate then needs no LLM
  provider or key).
- The `whitelist` input is applied to the daemon at setup, also when a
  persistent runner reuses a running daemon. An unknown name fails the setup
  and lists the names that exist.

### Changed

- Auto-whitelist:
  - A run's mode, learning or enforcing, is decided at setup from the
    whitelist's saved state. Once the whitelist has settled, a job that
    contacts an endpoint outside it fails, and the endpoint is not added.
  - A learning run counts toward stability when it saw nothing outside the
    whitelist; with `auto_whitelist_stability_threshold` above 0, also when
    its additions stay at or under that percentage of the whitelist's
    entries. After `auto_whitelist_max_iterations` learning runs, the
    whitelist is enforced as it stands, with a warning.
  - Each job is checked, and learns, against the whitelist file it
    downloaded, from the traffic seen since its setup.
  - One artifact per runner pool, OS and architecture: the action appends
    the runner OS and architecture to `auto_whitelist_artifact_name`
    (`edamame-auto-whitelist-ubuntu-latest` is stored as
    `edamame-auto-whitelist-ubuntu-latest-linux-x64`). Artifacts are read
    from earlier runs of the same workflow, on the same branch of the same
    repository, started by `push`, `workflow_dispatch`, `schedule`,
    `merge_group`, `release` or `repository_dispatch`.
  - The job fails when the whitelist artifact cannot be listed or
    downloaded; a new whitelist starts only when no eligible artifact
    exists. In an organization with an IP allow list, use connected mode
    with `wait_for_api: true`.
  - `promote_exceptions: true` adds the endpoints outside an enforced
    whitelist instead of failing the job, lists them, and keeps them in
    `auto_whitelist_added.json` in the artifact.
  - Each run records its result in `auto_whitelist_verdict.json` (in the
    artifact, and during the job in `EDAMAME_AUTO_WHITELIST_DIR`) and in the
    job summary.
  - Migration: every runner pool learns its whitelist again under the new
    artifact name; artifacts from earlier versions are not read. Delete them
    once the new ones exist (README, "Artifact naming").
  - Deprecated: `auto_whitelist_state_artifact_name` is ignored; the state
    travels in the whitelist artifact.
- Whitelist matching (edamame_posture 2.0.3): a destination with a name
  (DNS answer or TLS SNI) is matched by its name. An entry's addresses cover
  destinations without a name and, in an entry without a domain, named
  destinations outside shared hosting and CDN networks. A custom whitelist
  that allows a service on a CDN or cloud front end only by its address
  needs a `domain` entry for it.
- `exit_on_whitelist_exceptions` checks the whitelist the job set up. A job
  that set none has nothing to check; a whitelist that cannot be checked
  (capture not running) fails the job.
- `set_custom_whitelists` loads an empty whitelist as it is (it allows
  nothing) and fails the step when the daemon refuses the file.
- `augment_custom_whitelists` learns on top of the file at
  `custom_whitelists_path`, from the traffic seen since the job's setup.
- `debug: true` on macOS installs the debug PKG with an edamame_posture 2.0.3
  or later installer; with an older installer it installs the release PKG
  and keeps debug logging on.
- The attack pattern gate (`exit_on_attack_pattern_findings`, legacy
  `exit_on_vulnerability_findings`) fails only on findings first seen after
  the job's setup. On a persistent self-hosted runner, findings earlier jobs
  left active are printed as warnings with their first-seen time and stay in
  the history. The setup time is exported as `EDAMAME_POSTURE_SETUP_TIME`.
  The detector's liveness checks still fail the gate.
- The installer is the `install.sh` asset of the latest edamame_posture
  release, published with the binaries it installs. When neither that
  installer nor a release can be resolved or downloaded, the setup fails;
  no older installer or version is used instead.
- The action calls the `attack-pattern-*` posture subcommands
  (edamame_posture 1.3.18 or later); inputs are unchanged and the legacy
  `vulnerability_*` inputs are still accepted.
- Release workflow (maintainers): releases only from `main`, requires
  `test.yml` and `test_vulnerability_gate.yml` green on the commit, and
  publishes `vX.Y.Z` without moving `v1`; an organization admin moves `v1`
  once the release is validated.

### Fixed

- Setup waits for the daemon to answer before starting the attack pattern
  detector and the file monitor.

### Documentation

- `wait_repository`: in a public repository, set it to a private repository
  the job needs so `wait_for_api` / `wait_for_https` wait for that access.
  `token` is also the token these waits use.
- README: the pinning example reads `@v1.2.0`, and moving `v1` is described
  as an admin step taken once a release is validated.

## [1.1.10] - 2026-09-29

### Security

- Security improvements. Updating is recommended.

### Added

- `agentic_mode: off` turns agentic protection off (the Assistant, attack
  pattern detection, divergence detection; edamame_posture 2.0.2 or later).
  The strict vulnerability gate treats it like `disabled`.

## [1.1.9] - 2026-09-26

### Fixed

- Linux: a package installed or upgraded later in the job no longer
  restarts the posture daemon. The action installs
  `/etc/needrestart/conf.d/50-edamame-posture.conf`, so needrestart lists
  the daemon instead of restarting it.

## [1.1.8] - 2026-09-25

### Added

- `wait_repository` input: the repository `wait_for_api` and
  `wait_for_https` probe (default: the workflow's repository). In a public
  repository, set it to a private repository the job needs.

### Changed

- `wait_for_api` and `wait_for_https` try 20 times (about 19 minutes)
  instead of 10.

## [1.1.7] - 2026-09-25

### Removed

- The "Sync system clock" setup step, which could hold up the setup on
  self-hosted Windows runners.

### Fixed

- Setup retries transient Hub errors while waiting for the connection
  instead of failing.
- Linux: package installs recover from transient package index errors.

## [1.1.6] - 2026-07-20

### Fixed

- Setup waits longer for a newly registered device to become visible in
  EDAMAME Hub before failing.

## [1.1.5] - 2026-05-28

### Fixed

- The installer finds the latest edamame_posture release reliably on
  GitHub-hosted runners, instead of sometimes installing an old version.

### Documentation

- Recommended `auto_whitelist_artifact_name` naming: one artifact per
  runner pool (`edamame-auto-whitelist-${{ matrix.runs-on }}` or a literal
  runs-on suffix). See README "Artifact naming (runner pools)".

## [1.1.4] - 2026-05-22

### Added

- Preferred attack pattern detector inputs: `attack_pattern_detection`,
  `attack_pattern_detection_interval`, `dump_attack_pattern_findings` and
  `exit_on_attack_pattern_findings`. Each takes precedence when set; the
  legacy `vulnerability_*` names remain accepted.
- Agent security attack detection demo workflow
  (`.github/workflows/agent_security_attacks.yml`).

### Changed

- Documentation and input descriptions refer to "attack pattern
  detection"; the legacy `vulnerability_*` input names are kept.
- `auto_whitelist_max_iterations` defaults to `25` (was `15`).

## [1.1.3] - 2026-05-16

### Changed

- Live cancellation (`cancel_on_violation`) uses attack pattern findings
  when `vulnerability_detection` and `exit_on_vulnerability_findings` are
  both enabled.
- The strict vulnerability gate requires LLM adjudication at setup:
  `agentic_mode: analyze` or `auto`, an `agentic_provider`, and the
  provider's credential in the environment.
- Disconnected mode passes `agentic_interval` to the daemon, like connected
  mode.

### Removed

- Support for posture binaries without `vulnerability-findings
  --active-only` and `vulnerability-status --fail-on-findings`.

## [1.1.2] - 2026-05-15

### Changed

- `dump_vulnerability_findings` prints the daemon's findings as they are,
  and the gate is edamame_posture's own
  (`vulnerability-status --fail-on-findings`).

## [1.1.1] - 2026-05-15

### Fixed

- `stop: true` gives the stop command 30 seconds before verifying and, if
  needed, forcing the daemon to stop, so a stop can no longer hang the job.

## [1.1.0] - 2026-05-14

### Added

- `EDAMAME_DAEMON_LOGS_PATH`, exported with `display_logs: true`: the
  directory holding a copy of the daemon's logs, ready for
  `actions/upload-artifact`. See README "Daemon log collection".
- `dump_vulnerability_findings: true` prints each active finding's details
  (key, check, severity, description, process, destination, open files,
  detection basis).
- README "Pinning": the moving `@v1` tag and immutable `@vX.Y.Z` tags.

### Fixed

- `display_logs: true` collects the daemon's rolling logs
  (`/var/log/edamame/edamame_*_<pid>.YYYY-MM-DD` on Unix, beside the binary
  on Windows).
- Unix: `/var/log/edamame` is created writable for both the daemon and the
  CLI, so CLI commands no longer print log permission errors.

### Changed

- The vulnerability gate fails on active HIGH/CRITICAL findings; LOW
  findings stay visible without failing it.
- Release workflow (maintainers): publishes an immutable `vX.Y.Z` tag and
  release, and validates the version, the CHANGELOG entry and a green
  `test.yml` on the commit first.

## [1.0.0] - 2026-04-17

- Initial immutable-tag release.
- Composite action covering: setup, network scan, packet capture, policy
  checks, custom and auto-whitelist lifecycle, runtime vulnerability gate,
  eBPF support verification, and stop.
