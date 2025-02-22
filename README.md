# edamame_posture_action

## Overview
This GitHub Actions (and GitLab CI) workflow sets up and configures [EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture_cli), a security posture management tool.  
It supports Windows, Linux, and macOS runners, checking for and installing any missing dependencies such as Git, wget, curl, jq, Node.js, etc.

> **Note for GitLab users**: While this README focuses on GitHub Actions usage, the [`setup_edamame_posture.yaml`](../edamame_posture_action_gitlab/setup_edamame_posture.yaml) file includes equivalent stages for GitLab CI. Some environment variable names differ in case (e.g., `AUTO_REMEDIATE` vs. `auto_remediate`), but the same functionality applies.

## Behavior in Self-Hosted vs. GitHub-Hosted Runners

- **Self-Hosted Runners (Posture Already Installed)**  
  If your self-hosted runner already has the EDAMAME Posture CLI installed (e.g., in `/usr/bin` or a pre-configured location), this workflow will detect the existing binary and skip downloading. It then checks the posture service status:
  - If you are **already connected** (matching `edamame_user` and `edamame_domain`), the workflow will **skip** starting the service again.  
  - If the runner has the EDAMAME Posture binary installed but is **not connected**, the workflow will attempt to use the provided inputs to connect the service. If critical connection inputs (`edamame_user`, `edamame_domain`, `edamame_pin`, `edamame_id`) are missing or incorrect, the step fails.

- **GitHub-Hosted (or Other Hosted) Runners (Posture Not Installed)**  
  On a typical hosted runner without EDAMAME Posture pre-installed, this workflow will:
  1. Detect the operating system (Ubuntu, Alpine, RHEL/CentOS, macOS, Windows, etc.).  
  2. Download the appropriate EDAMAME Posture binary for the runner's OS and architecture (x86_64, armhf, aarch64, etc.).  
  3. Attempt to remediate or start the posture service using the provided inputs.  
     - If the required arguments (`edamame_user`, `edamame_domain`, `edamame_pin`, `edamame_id`) are present, it starts EDAMAME Posture in the background and waits for a successful connection.  
     - If inputs are missing or invalid, the step is skipped or fails with an error message.

## Inputs

| Input               | Description                                                                                           | Default                        |
|---------------------|-------------------------------------------------------------------------------------------------------|--------------------------------|
| `edamame_user`      | EDAMAME Posture user (required to start the process in the background).                               | *(none)*                       |
| `edamame_domain`    | EDAMAME Posture domain (required to start the process in the background).                             | *(none)*                       |
| `edamame_pin`       | EDAMAME Posture PIN (required to start the process in the background).                                | *(none)*                       |
| `edamame_id`        | EDAMAME Posture identifier suffix (required to start the process in the background).                 | *(none)*                       |
| `edamame_version`   | EDAMAME Posture version to use. If not specified, uses the latest or a fallback version.             | `latest`                       |
| `auto_remediate`    | Automatically remediate posture issues.                                                              | `false`                        |
| `skip_remediations` | Remediations to skip (comma-separated).                                                              | *(none)*                       |
| `network_scan`      | Scan network for critical devices and capture network traffic.                                       | `false`                        |
| `dump_sessions_log` | Dump sessions log (if supported by the OS).                                                          | `false`                        |
| `checkout`          | Checkout the repo through the git CLI.                                                               | `false`                        |
| `checkout_submodules` | Checkout git submodules (if `checkout` is true).                                                   | `false`                        |
| `display_logs`      | Display posture logs.                                                                                | `true`                         |
| `wait_for_https`    | Wait for HTTPS access to the repo (some hosts whitelist dynamically).                                | `false`                        |
| `wait_for_api`      | Wait for API access using the GitHub CLI (if needed).                                                | `false`                        |
| `wait`              | Wait 180 seconds at a certain step for environment readiness.                                        | `false`                        |
| `token`             | GitHub token to checkout the repo.                                                                   | `${{ github.token }}`          |
| `whitelist`         | Whitelist to use for the network scan.                                                               | `github`                       |
| `whitelist_conformance` | Exit with error if non-compliant endpoints are detected.                                         | `false`                        |
| `report_email`      | Send a compliance report to this email address (if supported).                                       | *(none)*                       |

## Steps

1. **Dependencies**  
   - Detect the runner's OS:
     - **Linux**: Tries `apt-get`, `yum`, or `apk` to install required packages (`git`, `libpcap`, `wget`, etc.).  
     - **macOS**: Optionally install via `brew` if needed.  
     - **Windows**: Installs Git (including Git Bash) via Chocolatey or a direct `.exe` installer if not already present.
   - Ensures essential utilities are in `PATH` (e.g., `sudo`, `git`, `wget`, etc.).

2. **Download EDAMAME Posture binary**  
   - Checks if the binary is already present in a known location (`/usr/bin/edamame_posture`, local directory, etc.).  
   - If not found, downloads by matching:
     - OS type (Linux, macOS, Windows).  
     - CPU architecture (x86_64, aarch64, armhf, etc.).  
   - Marks the binary as executable.

3. **Show initial posture**  
   Runs:
   \[
     \texttt{edamame_posture score}
   \]
   to display the current posture before any remediation.

4. **Auto-remediate posture issues**  
   - If `auto_remediate` is true, invokes:
   \[
     \texttt{edamame_posture remediate}
   \]
   - Respects `skip_remediations` if specified.

5. **Report email**  
   - (Optional) If `report_email` is set, the action **could** request a compliance report for that email address (not currently in the GitLab script, but available in some GitHub workflows).

6. **Wait for a while**  
   - If `wait` is true, sleeps for 180 seconds to allow the environment to stabilize.

7. **Start EDAMAME Posture process**  
   - If `edamame_user`, `edamame_domain`, `edamame_pin`, and `edamame_id` are all provided, starts EDAMAME Posture in the background, optionally including a `whitelist` and `network_scan`.
   - Waits for a successful connection:
   \[
     \texttt{edamame_posture wait-for-connection}
   \]
   - If partial or missing arguments exist, the step fails with an error.

8. **Checkout the repo through the git CLI**  
   - If `checkout` is true, the workflow tries up to **20** times (in the current GitLab script) or 10 times (GitHub-Action default) to fetch and check out the specified branch. Each attempt waits 60 seconds if failed.  
   - If `checkout_submodules` is also true, updates submodules recursively after checkout.

9. **Wait for API access**  
   - If `wait_for_api` is true, periodically invokes `gh release list` or similar calls, allowing more time if the runner's IP or environment must be whitelisted.

10. **Wait for HTTPS access**  
   - If `wait_for_https` is true, repeatedly checks for a valid HTTPS response from the repo (or any required domain).

11. **Display posture logs**  
   - If `display_logs` is true, prints logs:
   \[
     \texttt{edamame_posture logs}
   \]
   - Useful for auditing posture events.

12. **Dump sessions log**  
   - If `dump_sessions_log` is true (and supported on the OS), runs:
   \[
     \texttt{edamame_posture get-sessions}
   \]
   - On Windows, this feature is currently skipped or limited.
   - If `whitelist_conformance` is true and the CLI detects non-compliant endpoints, the step exits with an error.

## Note
- In GitHub Actions, pass a personal or repo-scoped `token` if you need to checkout private repos or use the GitHub CLI.  
- For GitLab CI usage, this workflow tries to fetch the repo using `$CI_JOB_TOKEN`. You can raise or lower the retry limits in your `.gitlab-ci.yml` with environment variables.  
- The `setup_edamame_posture.yaml` script includes OS-specific logic for additional distributions (Alpine, CentOS, RHEL, etc.).  
- On Windows runners, `dump_sessions_log` is currently skipped due to CLI limitations.  
- If the posture CLI is installed but not connected, and you omit the necessary environment variables (`edamame_user`, `edamame_domain`, `edamame_pin`, `edamame_id`), the step fails with a reminder to provide them.