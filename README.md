# edamame_posture_action

## Overview
This GitHub Actions workflow sets up and configures [EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture_cli), a security posture management tool.  
It supports Windows, Linux, and macOS runners, checking for and installing any missing dependencies such as wget, curl, jq, Node.js, etc.

## Behavior in Self-Hosted vs. GitHub-Hosted Runners

- **Self-Hosted Runners (Posture Already Installed)**  
  If your self-hosted runner already has the EDAMAME Posture CLI installed (e.g., in `/usr/bin` or a pre-configured location), this action will detect the existing binary and skip the download. It then checks the posture service status:
  - If you are **already connected** (matching `edamame_user` and `edamame_domain`), the action will **skip** starting the service again.  
  - If the runner has the EDAMAME Posture binary installed but is **not connected**, the action will attempt to use the provided inputs to connect the posture service. If critical connection inputs (`edamame_user`, `edamame_domain`, `edamame_pin`, `edamame_id`) are missing or incorrect, the step fails.

- **GitHub-Hosted Runners (Posture Not Installed)**  
  On a typical GitHub-hosted runner, EDAMAME Posture is not installed by default. The action will:
  1. Download the appropriate EDAMAME Posture binary for the runner's operating system.  
  2. Attempt to remediate or start the posture service using the provided inputs.  
     - If the required arguments (`edamame_user`, `edamame_domain`, `edamame_pin`, `edamame_id`) are present, it starts EDAMAME Posture in the background and waits for a successful connection.  
     - If inputs are missing or invalid, the step is skipped or fails with an error message.

## Inputs

- `edamame_user`: EDAMAME Posture user (required to start the process in the background)  
- `edamame_domain`: EDAMAME Posture domain (required to start the process in the background)  
- `edamame_pin`: EDAMAME Posture PIN (required to start the process in the background)  
- `edamame_id`: EDAMAME identifier suffix (required when starting the process in the background)  
- `edamame_version`: EDAMAME Posture version to use (default: latest)  
- `auto_remediate`: Automatically remediate posture issues (default: false)  
- `skip_remediations`: Remediations to skip (comma-separated)  
- `network_scan`: Scan network for critical devices and capture network traffic (default: false)  
- `dump_sessions_log`: Dump sessions log (default: false)  
- `checkout`: Checkout the repo through the git CLI (default: false)  
- `checkout_submodules`: Checkout git submodules (default: false)  
- `wait_for_https`: Wait for https access to the repo to be granted (default: false)  
- `wait`: Wait for a while (180 seconds) (default: false)  
- `wait_for_api`: Wait for API access via the GitHub CLI (default: false)  
- `token`: GitHub token to checkout the repo (default: ${{ github.token }})  
- `display_logs`: Display posture logs (default: true)  
- `whitelist`: Whitelist to use for the network scan (default: github)  
- `whitelist_conformance`: Exit with error when non-compliant endpoints are detected (default: false)  
- `report_email`: Send a compliance report to this email address (default: "")

## Steps

1. **Dependencies**  
   Checks for and installs required dependencies for your runner's OS—wget, curl, jq, Node.js, etc.—using either Chocolatey (Windows), apt-get (Linux), or Homebrew (macOS).

2. **Download EDAMAME Posture binary**  
   - Looks for an existing binary. If found, skips download. Otherwise, downloads the latest (or fallback) version.  
   - Implements exponential backoff if rate-limited by GitHub's public API.

3. **Show initial posture**  
   - Calls `score` to display the current posture prior to any remediation.

4. **Auto remediate posture issues**  
   - If `auto_remediate` is true, invokes `remediate`.  
   - Respects `skip_remediations` if specified.

5. **Report email**  
   - If `report_email` is set, requests a compliance report for that email address by fetching a signature and using `request-report`.

6. **Wait for a while**  
   - If `wait` is true, sleeps for 180 seconds. Useful if you need more lead time for certain environments.

7. **Start EDAMAME Posture process**  
   - If `edamame_user`, `edamame_domain`, `edamame_pin`, and `edamame_id` are all set, attempts to start in the background.  
   - Adds a unique suffix to `edamame_id` when running on ephemeral (matrix or short-lived) runners.

8. **Checkout the repo through the git CLI**  
   - If `checkout` is true, tries up to 10 times to fetch and check out the specified branch (using `token`).

9. **Wait for API access**  
   - If `wait_for_api` is true, periodically invokes `gh release list`, allowing time for an IP/runner to be whitelisted in private repos.

10. **Wait for https access**  
   - If `wait_for_https` is true, repeatedly checks the repo over https until it is accessible or time runs out.

11. **Display posture logs**  
   - If `display_logs` is true, prints the EDAMAME CLI's logs.

12. **Dump sessions log**  
   - If `dump_sessions_log` is true on a supported OS, runs `get-sessions`.  
   - If `whitelist_conformance` is true and the CLI reports non-compliant endpoints, the step exits with an error status.

## Note
For public repos that need access to private repos (or other restricted endpoints), pass the `token` input to this action. This allows the action to handle partial or delayed permissions during checkout, API access, or HTTPS waiting steps.