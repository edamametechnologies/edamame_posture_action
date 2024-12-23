# edamame_posture_action

## Overview
This GitHub Actions workflow sets up and configures EDAMAME Posture (https://github.com/edamametechnologies/edamame_posture_cli), a security posture management tool.

## Inputs
- `edamame_user`: EDAMAME Posture user (required to start the process in the background)
- `edamame_domain`: EDAMAME Posture domain (required to start the process in the background)
- `edamame_pin`: EDAMAME Posture PIN (required to start the process in the background)
- `edamame_id`: EDAMAME identifier suffix (required when starting the process in the background)
- `edamame_version`: EDAMAME Posture version to use (default: latest)
- `auto_remediate`: Automatically remediate posture issues (default: false)
- `skip_remediations`: Remediations to skip (comma-separated)
- `network_scan`: Scan network for critical devices and capture network traffic (default: false)
- `wait`: Wait for a while for access to be granted (default: false)
- `wait_for_https`: Wait for https access to the repo be granted (default: false)
- `checkout`: Checkout the repo through the git CLI (default: false)
- `checkout_submodules`: Checkout submodules (default: false)
- `token`: GitHub token to checkout the repo (default: ${{ github.token }})
- `display_logs`: Display posture logs (default: true)
- `dump_sessions_log`: Dump sessions log (default: false)
- `whitelist_conformance`: Exit with error when non-compliant endpoints are detected (default: false)

## Steps
1. Dependencies: Installs wget and curl on Windows runners if not already installed.
2. Download EDAMAME Posture binary: Downloads the EDAMAME Posture binary for the respective OS (Linux, macOS, or Windows) if not already present.
3. Show initial posture: Runs the score command to show the initial posture.
4. Auto remediate posture issues: Runs the remediate command to auto-remediate posture issues if auto_remediate is true.
5. Wait for a while: Waits for 180 seconds if wait is true.
6. Start EDAMAME Posture process: Starts the EDAMAME Posture process and waits for connection if all required arguments are provided.
7. Checkout repo: Checks out the repo through the git CLI if checkout is true.
8. Wait for https access: Waits for https access to the repository to be granted if wait_for_https is true.
9. Display posture logs: Displays the posture logs if display_logs is true.
10. Dump sessions log: Dumps the sessions log if dump_sessions_log is true and the EDAMAME Posture process is running with network_scan set to true.
11. Check whitelist conformance: Checks if the whitelist conformance is true and there are non-compliant endpoints detected. Exits with an error if there are non-compliant endpoints detected.

## Note
For public repos accessing private repos using a dedicated token, the token must be passed to posture_action in order to properly wait for access to be granted during the various wait_ or checkout steps.