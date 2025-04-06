# edamame_posture_action

## Overview
This GitHub Actions workflow sets up and configures [EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture_cli), a security posture management tool.  
It supports Windows, Linux, and macOS runners, checking for and installing any missing dependencies such as wget, curl, jq, Node.js, etc.

## Behavior in Self-Hosted vs. GitHub-Hosted Runners

- **Self-Hosted Runners (Posture Already Installed)**  
  If your self-hosted runner already has the EDAMAME Posture CLI installed (e.g., in `/usr/bin` or a pre-configured location), this action will detect the existing binary and skip the download. It then checks the posture service status:
  - If you are **already connected** (matching `edamame_user` and `edamame_domain`), the action will **skip** starting the service again.

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
- `edamame_policy`: EDAMAME policy name that the device must comply with (the action will fail if the device does not comply)  
- `edamame_minimum_score`: Minimum score that the device must achieve (the action will fail if the device does not achieve the minimum score)  
- `edamame_mandatory_threats`: Comma-separated list of mandatory threats that the device must not exhibit (the action will fail if the device detects these threats)  
- `edamame_mandatory_prefixes`: Comma-separated list of mandatory tag prefixes covering threats that the device must not exhibit (the action will fail if the device does not have the prefixes)  
- `auto_remediate`: Automatically remediate posture issues (default: false)  
- `skip_remediations`: Remediations to skip (comma-separated)  
- `network_scan`: Scan network for critical devices and capture network traffic (default: false)  
- `disconnected_mode`: Start EDAMAME Posture in disconnected mode without requiring domain authentication (default: false)
- `dump_sessions_log`: Dump sessions log (default: false)  
- `checkout`: Checkout the repo through the git CLI (default: false)  
- `checkout_submodules`: Checkout git submodules (default: false)  
- `wait_for_https`: Wait for https access to the repo to be granted (default: false)  
- `wait`: Wait for a while (180 seconds) (default: false)  
- `wait_for_api`: Wait for API access via the GitHub CLI (default: false)  
- `token`: GitHub token to checkout the repo (default: ${{ github.token }})  
- `display_logs`: Display posture logs (default: true)  
- `whitelist`: Whitelist to use for the network scan (default: github). A platform-dependent suffix (`_windows`, `_macos`, or `_linux`) is automatically appended to this value based on the runner's operating system.
- `exit_on_whitelist_exceptions`: Exit with error when whitelist exceptions are detected (default: true)
- `exit_on_blacklisted_sessions`: Exit with error when blacklisted sessions are detected (default: false)
- `exit_on_anomalous_sessions`: Exit with error when anomalous sessions are detected (default: false)
- `report_email`: Send a compliance report to this email address (default: "")
- `create_custom_whitelists`: Create custom whitelists from captured network sessions (default: false)
- `custom_whitelists_path`: Path to save or load custom whitelists JSON (default: "")
- `set_custom_whitelists`: Apply custom whitelists from a file specified in custom_whitelists_path (default: false)
- `stop`: Stop the background process  (default: false)

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

6. **Check local policy compliance**  
   - If `edamame_minimum_score` and optionnaly `edamame_mandatory_threats` are set, verifies device compliance.
   - Uses `check-policy` to check against the specified minimum score and mandatory threats.
   - Validates mandatory prefixes if provided.
   - Exits with an error if the device fails to comply.

7. **Check domain policy compliance**  
   - If both `edamame_domain` and `edamame_policy` are set, verifies device compliance.
   - Uses `check-policy-for-domain` to evaluate compliance with the specified domain policy.
   - Exits with an error if the device fails to comply.

8. **Wait for a while**  
   - If `wait` is true, sleeps for 180 seconds. Useful if you need more lead time for certain environments.

9. **Start EDAMAME Posture process**  
   - If `edamame_user`, `edamame_domain`, `edamame_pin`, and `edamame_id` are all set, attempts to start in the background.  
   - Adds a unique suffix to `edamame_id` when running on ephemeral (matrix or short-lived) runners.

10. **Checkout the repo through the git CLI**  
   - If `checkout` is true, tries up to 10 times to fetch and check out the specified branch (using `token`).

11. **Wait for API access**  
   - If `wait_for_api` is true, periodically invokes `gh release list`, allowing time for an IP/runner to be whitelisted in private repos.

12. **Wait for https access**  
   - If `wait_for_https` is true, repeatedly checks the repo over https until it is accessible or time runs out.

13. **Display posture logs**  
   - If `display_logs` is true, prints the EDAMAME CLI's logs.

14. **Dump sessions log**  
   - If `dump_sessions_log` is true on a supported OS, runs `get-sessions`.  
   - If `exit_on_whitelist_exceptions` is true and the CLI reports whitelist exceptions, the step exits with an error status.

15. **Create custom whitelist**  
   - If `create_custom_whitelists` is true, generates a whitelist from the current network sessions.
   - If `custom_whitelists_path` is provided, saves the whitelist to this file.
   - Otherwise, outputs the whitelist JSON to the action log.
   - Limited functionality on Windows due to licensing constraints.

16. **Apply custom whitelist**  
   - If `custom_whitelists_path` is provided and `create_custom_whitelists` is not true, loads and applies the whitelist.
   - Reads the whitelist JSON from the specified file and applies it using `set-custom-whitelists`.
   - Exits with an error if the specified file is not found.

17. **Stop EDAMAME Posture process**  
   - If `stop` is true, stops the EDAMAME Posture background process.
   - Uses the `stop` command to gracefully terminate the posture service.
   - Useful for cleaning up resources at the end of a workflow or before starting a new posture service instance.

## Usage Pattern

For optimal security monitoring in your CI/CD workflows, follow this recommended pattern:

1. **Setup at Workflow Beginning**  
   Place the main EDAMAME Posture setup step at the very beginning of your workflow, before any build, test, or deployment steps. This ensures complete capture of all network activity and security posture evaluation throughout the entire workflow execution.

   ```yaml
   - name: Setup EDAMAME Posture
     uses: edamametechnologies/edamame_posture_action@v0
     with:
       edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
       edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
       edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
       edamame_id: ${{ github.run_id }}
       network_scan: true  # Required for network traffic capture and whitelist application
       # Other configuration parameters
   ```

   > **Important:** The `network_scan` parameter must be set to `true` for network traffic capture to occur and for the default whitelist to apply. Without this setting, the session dump will not contain network traffic information.

2. **Dump Sessions at Workflow End**  
   Add a second EDAMAME Posture action step at the very end of your workflow to dump and analyze the captured session logs. This provides a comprehensive view of all network activity that occurred during workflow execution and a detection of communications outside of the default or custom whitelist.

   ```yaml
   - name: Dump EDAMAME Posture sessions
     uses: edamametechnologies/edamame_posture_action@v0
     with:
       dump_sessions_log: true
   ```

3. **Using Custom Whitelists with Conformance Checking**  
   For stricter security controls, you can use custom whitelists and enforce conformance. This pattern will cause the workflow to exit with a non-zero exit code if any non-conforming communications are detected during the session dump.

   ```yaml
   # At the beginning of the workflow
   - name: Setup EDAMAME Posture with Custom Whitelist
     uses: edamametechnologies/edamame_posture_action@v0
     with:
       edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
       edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
       edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
       edamame_id: ${{ github.run_id }}
       network_scan: true
       custom_whitelists_path: ./whitelists.json  # Path to your predefined whitelist
       set_custom_whitelists: true  # Required to apply the custom whitelist
       
   # ... your workflow steps ...
   
   # At the end of the workflow
   - name: Dump EDAMAME Posture sessions with conformance check
     uses: edamametechnologies/edamame_posture_action@v0
     with:
       dump_sessions_log: true
       exit_on_whitelist_exceptions: true  # Will exit with non-zero code if whitelist exceptions are detected
       exit_on_blacklisted_sessions: false # Will not exit with error if blacklisted sessions are detected (default)
       exit_on_anomalous_sessions: false   # Will not exit with error if anomalous sessions are detected (default)
   ```

4. **Disconnected Mode for Air-Gapped or Restricted Environments**
   For environments where you want all the security monitoring capabilities without requiring domain authentication or external connectivity:

   ```yaml
   # At the beginning of the workflow
   - name: Setup EDAMAME Posture in Disconnected Mode
     uses: edamametechnologies/edamame_posture_action@v0
     with:
       disconnected_mode: true
       network_scan: true
       whitelist: github # Platform-dependent suffix (_windows, _macos, or _linux) is automatically added based on the runner's OS
       
   # ... your workflow steps ...
   
   # At the end of the workflow
   - name: Verify Network Activity
     uses: edamametechnologies/edamame_posture_action@v0
     with:
       dump_sessions_log: true
       exit_on_whitelist_exceptions: true  # Will exit with non-zero code if whitelist exceptions are detected
   ```

   > **Important:** Disconnected mode provides all the network monitoring and local security policy checking capabilities without requiring EDAMAME Hub registration.

This pattern is demonstrated in the example workflows included in the EDAMAME repositories, such as the `release_deploy_debs.yml` workflow, where the initial setup is performed at the beginning and session logs are dumped at the very end of the workflow execution.

## Note
For public repos that need access to private repos (or other restricted endpoints), pass the `token` input to this action. This allows the action to handle partial or delayed permissions during checkout, API access, or HTTPS waiting steps.

## Examples

### Basic Security Check
```yaml
- name: EDAMAME Posture Check
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    auto_remediate: true
```

### Creating a Custom Whitelist
```yaml
- name: EDAMAME Posture with Custom Whitelist Creation
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    network_scan: true                      # Enable network scanning
    create_custom_whitelists: true           # Generate a whitelist from observed traffic
    custom_whitelists_path: ./whitelists.json # Save to this file
```

### Applying a Custom Whitelist
```yaml
- name: EDAMAME Posture with Custom Whitelist
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    network_scan: true                      # Enable network scanning
    custom_whitelists_path: ./whitelists.json # Load and apply this whitelist
    set_custom_whitelists: true             # Required to apply the custom whitelist
    exit_on_whitelist_exceptions: true      # Fail if whitelist exceptions are detected
```

### Full CI/CD Integration with Custom Whitelist
```yaml
- name: EDAMAME Posture Setup with Continuous Monitoring
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    edamame_user: ${{ secrets.EDAMAME_USER }}
    edamame_domain: ${{ secrets.EDAMAME_DOMAIN }}
    edamame_pin: ${{ secrets.EDAMAME_PIN }}
    edamame_id: "cicd-runner"
    network_scan: true
    custom_whitelists_path: ./whitelists.json
    set_custom_whitelists: true             # Required to apply the custom whitelist
    exit_on_whitelist_exceptions: true      # Fail if whitelist exceptions are detected
    auto_remediate: true
```

### Using Disconnected Mode with Local Policy Checking
```yaml
- name: EDAMAME Posture in Disconnected Mode
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    disconnected_mode: true                  # Run without domain authentication
    network_scan: true                       # Monitor network traffic
    whitelist: github_linux                  # Apply appropriate whitelist
    auto_remediate: true                     # Fix security issues automatically
    edamame_minimum_score: 2.0               # Enforce minimum security score
    edamame_mandatory_threats: "encrypted disk disabled,critical vulnerability"
```

## EDAMAME Ecosystem

This GitHub Action is part of the broader EDAMAME security ecosystem:

- **EDAMAME Core**: The core implementation used by all EDAMAME components (closed source)
- **[EDAMAME Security](https://github.com/edamametechnologies)**: Desktop/mobile security application with full UI and enhanced capabilities (closed source)
- **[EDAMAME Foundation](https://github.com/edamametechnologies/edamame_foundation)**: Foundation library providing security assessment functionality
- **[EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture_cli)**: CLI tool for security posture assessment and remediation
- **[EDAMAME Helper](https://github.com/edamametechnologies/edamame_helper)**: Helper application for executing privileged security checks
- **[EDAMAME CLI](https://github.com/edamametechnologies/edamame_cli)**: Interface to EDAMAME core services
- **[GitHub Integration](https://github.com/edamametechnologies/edamame_posture_action)**: GitHub Action for integrating posture checks in CI/CD
- **[GitLab Integration](https://gitlab.com/edamametechnologies/edamame_posture_action)**: Similar integration for GitLab CI/CD workflows
- **[Threat Models](https://github.com/edamametechnologies/threatmodels)**: Threat model definitions used throughout the system
- **[EDAMAME Hub](https://hub.edamame.tech)**: Web portal for centralized management when using these components in team environments
