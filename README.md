# edamame_posture_action

## Overview
This GitHub Actions workflow sets up and configures EDAMAME Posture (https://github.com/edamametechnologies/edamame_posture_cli), a security posture management tool.  
It supports Windows, Linux, and macOS runners, checking for and installing any missing dependencies such as wget, curl, jq, Node.js, etc.

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
   Checks for and installs required dependencies for your runner's OS: wget, curl, jq, Node.js, and other environment-specific packages. This includes:  
   - Windows: uses Chocolatey to install missing packages and checks for Packet.dll/wpcap.dll.  
   - Linux (Ubuntu/Debian): installs packages via apt-get.  
   - macOS: installs packages using Homebrew if missing.  

2. **Download EDAMAME Posture binary**  
   - Downloads the latest EDAMAME Posture binary (or a fallback version) for the appropriate OS if not already present.  
   - Uses GitHub's public API for searching release versions, and implements exponential backoff on rate-limit errors.

3. **Show initial posture**  
   - Calls "score" to display the current posture prior to any remediation.

4. **Auto remediate posture issues**  
   - If the input "auto_remediate" is true, invokes the EDAMAME posture "remediate" command.  
   - Respects the "skip_remediations" input to skip specified remediation IDs.

5. **Report email**  
   - If "report_email" is set, obtains a signature and requests a compliance report to be delivered to that email address.

6. **Wait for a while**  
   - If "wait" is true, waits 180 seconds.  
   - Used to allow time for access or for other processes to complete.

7. **Start EDAMAME Posture process**  
   - If all required arguments (edamame_user, edamame_domain, edamame_pin, edamame_id) are present, starts the EDAMAME Posture background process.  
   - Automatically stops any existing EDAMAME session if it's mismatched, then restarts with a unique suffix for edamame_id.  
   - Waits for the connection to be established.

8. **Checkout the repo through the git CLI**  
   - If "checkout" is true, attempts to fetch and checkout (up to 10 times) the repository using the specified token.  
   - Optionally checks out submodules if "checkout_submodules" is true.

9. **Wait for API access**  
   - If "wait_for_api" is true, runs "gh release list" a limited number of times, waiting between attempts to see if GitHub API access is granted.

10. **Wait for https access**  
   - If "wait_for_https" is true, queries the repository URL (https://github.com/…) multiple times to confirm that https access is operational.  
   - Exits if not granted within the allotted attempts.

11. **Display posture logs**  
   - If "display_logs" is true, prints the EDAMAME Posture CLI logs.

12. **Dump sessions log**  
   - If "dump_sessions_log" is true (and running on a supported OS), dumps the sessions log using "get-sessions" if the EDAMAME Posture background process is active.  
   - Exits with error if "whitelist_conformance" is true and the CLI output indicates non-compliant endpoints.

## Note
For public repos that need access to private repos (or other restricted endpoints), the "token" input must be passed to this action in order to properly wait for permission to be granted during the "wait_for_https," "wait_for_api," or "checkout" steps.