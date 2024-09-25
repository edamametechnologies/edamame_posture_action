# edamame_posture_action

## Overview
This GitHub Actions workflow sets up and configures EDAMAME Posture (https://github.com/edamametechnologies/edamame_posture_cli), a security posture management tool.

## Inputs
- edamame_user: EDAMAME Posture user (required to start the process in the background)
- edamame_domain: EDAMAME Posture domain (required to start the process in the background)
- edamame_pin: EDAMAME Posture PIN (required to start the process in the background)
- edamame_id: EDAMAME identifier suffix (required to start the process in the background)
- auto_remediate: Automatically remediate posture issues (default: false)
- skip_remediations: Remediations to skip (comma-separated)
- network_scan: Scan network for critical devices (default: false)
- dump_sessions_log: Dump sessions log (default: false)
- wait: Wait for a while for access to be granted (default: false)
- wait_for_https: Wait for https access to the repo be granted (default: false)
- wait_for_api: Wait for API access to be granted (default: true)
- wait_for_repo: Wait for access to the repo through the git CLI to be granted (default: false)
- token: GitHub token to check access to the repo through the git CLI (default: ${{ github.token }})

## Steps
- Dependencies: Installs wget on Windows runners if not already installed.
- Download EDAMAME Posture binary: Downloads the EDAMAME Posture binary for the respective OS (Linux, macOS, or Windows) if not already present.
- Show initial posture: Runs the score command to show the initial posture.
- Auto remediate posture issues: Runs the remediate command to auto-remediate posture issues if auto_remediate is true.
- Start EDAMAME Posture process: Starts the EDAMAME Posture process and waits for connection if all required arguments are provided.
- Wait:
  - for a while: Waits for 180 seconds if wait is true. 
  - for https access: Waits for https access to the repository to be granted if wait_for_https is true.
  - for repo access: Waits for access to the repository to be granted through the git CLI if wait_for_repo is true. 
  - for API access: Waits for API access to be granted if wait_for_api is true.
- Dump sessions log: Dumps the sessions log if dump_sessions_log is true and the EDAMAME Posture process is running with network_scan set to true.