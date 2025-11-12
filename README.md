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
- `network_scan`: Scan the local network for critical devices (default: false)  
- `packet_capture`: Capture network traffic (`auto` mirrors `network_scan`; set to `true`/`false` to override)  
- `check_whitelist`: When `true`, enforce whitelist conformance during network capture (requires `whitelist` to be set) (default: false)  
- `check_blacklist`: When `true`, fail if blacklisted sessions are observed during capture (default: true)  
- `check_anomalous`: When `true`, fail if anomalous sessions are detected during capture (default: true)  
- `cancel_on_violation`: When `true`, attempt to cancel the current CI pipeline if violations are detected during capture (default: false)  
- `disconnected_mode`: Start EDAMAME Posture in disconnected mode without requiring domain authentication (default: false)
- `dump_sessions_log`: Dump sessions log (default: false)  
- `checkout`: Checkout the repo through the git CLI (default: false)  
- `checkout_submodules`: Checkout git submodules (default: false)  
- `wait_for_https`: Wait for https access to the repo to be granted (default: false)  
- `wait`: Wait for a while (180 seconds) (default: false)  
- `wait_for_api`: Wait for API access via the GitHub CLI (default: false)  
- `token`: GitHub token to checkout the repo (default: ${{ github.token }})  
- `display_logs`: Display posture logs (default: false)  
- `debug`: Enable debug mode - downloads debug version of binary and sets log level to debug (default: false)  
- `whitelist`: Whitelist to use for the network scan (default: github). A platform-dependent suffix (`_windows`, `_macos`, or `_linux`) is automatically appended to this value based on the runner's operating system.
- `exit_on_whitelist_exceptions`: Exit with error when whitelist exceptions are detected (default: true)
- `exit_on_blacklisted_sessions`: Exit with error when blacklisted sessions are detected (default: false)
- `exit_on_anomalous_sessions`: Exit with error when anomalous sessions are detected (default: false)
- `report_email`: Send a compliance report to this email address (default: "")
- `create_custom_whitelists`: Create custom whitelists from captured network sessions (default: false)
- `custom_whitelists_path`: Path to save or load custom whitelists JSON (default: "")
- `set_custom_whitelists`: Apply custom whitelists from a file specified in custom_whitelists_path (default: false)
- `augment_custom_whitelists`: When `true`, runs `augment-custom-whitelists` and writes the result to the file specified by `custom_whitelists_path` (overwriting it). Requires `network_scan: true` with packet capture enabled.
- `include_local_traffic`: Include local traffic in network capture and session logs (default: false)
- `agentic_mode`: AI assistant mode for automated security todo processing: `auto` (execute actions), `analyze` (recommendations only), or `disabled` (default: disabled)
- `agentic_provider`: LLM provider for AI assistant: `claude`, `openai`, `ollama`, or none. Requires `EDAMAME_LLM_API_KEY` environment variable (default: "")
- `agentic_interval`: Interval in seconds for automated AI assistant todo processing (default: 3600)
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

## Automation Options

This GitHub Action provides multiple automation capabilities that can be combined to create comprehensive, hands-off security workflows. These options work together to provide defense-in-depth for your CI/CD pipelines.

### Overview of Automation Capabilities

| Capability | Input | Type | Scope | Use Case |
|-----------|-------|------|-------|----------|
| **Auto-Remediation** | `auto_remediate` | One-shot | Security posture | Fix security issues before build |
| **AI Assistant (Agentic)** | `agentic_mode` | Continuous | Security todos | Automated "Do It For Me" security management |
| **Network Violation Detection** | `exit_on_*` | One-shot | Network traffic | Detect supply chain attacks, unauthorized connections |
| **Pipeline Cancellation** | `cancel_on_violation` | Real-time | CI/CD pipeline | Stop builds immediately on security violations |

### 1. Auto-Remediation (One-Shot)

**Purpose**: Automatically fix common security issues before your build starts.

**How to enable**:
```yaml
- uses: edamametechnologies/edamame_posture_action@v0
  with:
    auto_remediate: true
    skip_remediations: "remote_login,firewall"  # Optional: skip specific fixes
```

**Best for**:
- Hardening CI runners before build
- Quick security posture improvement
- Automated compliance enforcement

**Limitations**:
- One-time action only (doesn't monitor for new issues during build)
- Some fixes skipped by default to avoid disrupting CI environment

### 2. AI Assistant (Continuous Remediation)

**Purpose**: Continuous "Do It For Me" security management using LLM intelligence throughout workflow execution.

**How to enable**:
```yaml
- uses: edamametechnologies/edamame_posture_action@v0
  with:
    edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
    edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
    edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
    edamame_id: ${{ github.run_id }}
    agentic_mode: auto              # or 'analyze' for recommendations only
    agentic_provider: claude        # or 'openai', 'ollama'
    agentic_interval: 600           # Check every 10 minutes
  env:
    EDAMAME_LLM_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    EDAMAME_AGENTIC_SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}  # Optional
    EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL: "C01234567"  # Optional
```

**Modes**:
- **`auto`**: Automatically resolves safe/low-risk items; escalates high-risk items
- **`analyze`**: Provides recommendations without executing actions
- **`disabled`**: No AI processing (default)

**Best for**:
- Long-running workflows that need adaptive security
- Reducing manual security work
- Teams wanting AI-powered security automation

**Cost**: ~$1-3/day for 24/7 operation with cloud LLMs; $0 with Ollama (local)

### 3. Network Violation Detection & Exit Codes

**Purpose**: Detect unauthorized network connections and fail workflows when violations occur.

**How to enable**:
```yaml
# At workflow start
- name: Setup EDAMAME Posture
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    network_scan: true
    packet_capture: true
    whitelist: github_ubuntu

# At workflow end
- name: Verify Network Activity
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    dump_sessions_log: true
    exit_on_whitelist_exceptions: true   # Fail if traffic violates whitelist
    exit_on_blacklisted_sessions: true   # Fail if blacklisted IPs contacted
    exit_on_anomalous_sessions: true     # Fail if ML detects anomalies
```

**Exit Behavior**:
- Workflow succeeds (exit 0) if no violations detected
- Workflow fails (exit 1) if any enabled check detects violations
- Detailed session logs show exactly what was detected

**Best for**:
- Supply chain attack prevention (like CVE-2025-30066)
- Zero-trust CI/CD networking
- Detecting malicious dependencies or compromised build steps

### 4. Pipeline Cancellation (Real-Time)

**Purpose**: Immediately stop workflows when security violations are detected during execution (not just at end).

**How to enable**:
```yaml
- uses: edamametechnologies/edamame_posture_action@v0
  with:
    edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
    edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
    edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
    edamame_id: ${{ github.run_id }}
    network_scan: true
    packet_capture: true
    whitelist: github_ubuntu
    check_whitelist: true           # Enable real-time whitelist checking
    check_blacklist: true           # Enable real-time blacklist checking
    check_anomalous: true           # Enable real-time anomaly detection
    cancel_on_violation: true       # Cancel pipeline on violation
```

**How it works**:
- EDAMAME monitors network traffic in real-time during workflow execution
- If a violation is detected, attempts to cancel the entire workflow immediately
- Provides defense-in-depth beyond just exit code checking at workflow end

**Best for**:
- High-security environments where violations must stop immediately
- Preventing data exfiltration in progress
- Reducing wasted compute time on compromised builds

### Combining Automation Options

You can combine all these capabilities for comprehensive automation:

```yaml
name: Comprehensive Security Automation

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # 1. Setup with all automation enabled
      - name: Setup EDAMAME Posture with Full Automation
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          # Authentication
          edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
          edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
          edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
          edamame_id: ${{ github.run_id }}
          
          # One-shot remediation
          auto_remediate: true
          
          # Network monitoring with real-time cancellation
          network_scan: true
          packet_capture: true
          whitelist: github_ubuntu
          check_whitelist: true
          check_blacklist: true
          check_anomalous: true
          cancel_on_violation: true
          
          # AI Assistant for continuous remediation
          agentic_mode: auto
          agentic_provider: claude
          agentic_interval: 600
        env:
          EDAMAME_LLM_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          EDAMAME_AGENTIC_SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
          EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL: "C01234567"
      
      # 2. Your build/test steps
      - name: Build
        run: |
          npm install
          npm run build
          npm test
      
      # 3. Final verification with exit on violations
      - name: Verify Network Activity
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          dump_sessions_log: true
          exit_on_whitelist_exceptions: true
          exit_on_blacklisted_sessions: true
          exit_on_anomalous_sessions: true
```

### Recommended Patterns by Environment

| Environment | Auto-Remediate | AI Assistant | Network Detection | Cancellation |
|------------|----------------|--------------|-------------------|--------------|
| **Public Repos** | ✅ Yes | ❌ No | `exit_on_whitelist_exceptions: true` | ❌ No |
| **Private Repos (Dev)** | ✅ Yes | `analyze` mode | `exit_on_whitelist_exceptions: true` | ❌ No |
| **Private Repos (Prod)** | ✅ Yes | `disabled` | All exit flags | ✅ Yes |
| **Air-Gapped CI** | ✅ Yes | `auto` (Ollama) | `exit_on_whitelist_exceptions: true` | ✅ Yes |

### Disconnected Mode (No Hub Required)

All automation features work in disconnected mode without requiring EDAMAME Hub authentication:

```yaml
- uses: edamametechnologies/edamame_posture_action@v0
  with:
    disconnected_mode: true        # No Hub authentication needed
    auto_remediate: true           # Still works
    network_scan: true
    packet_capture: true
    whitelist: github_ubuntu
    check_whitelist: true          # Still works
    cancel_on_violation: true      # Still works
    # Note: AI Assistant requires Hub connection or local Ollama
```

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
      network_scan: true   # Discover LAN-connected peers
      packet_capture: true # Capture network traffic (optional: defaults to auto)
       # Other configuration parameters
   ```

> **Important:** Network traffic capture requires `packet_capture` to be enabled. With the default `auto` value, capture automatically turns on whenever `network_scan` is `true`.

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
      packet_capture: true
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
      packet_capture: true
       whitelist: github_ubuntu
       
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

## Custom Whitelist Management

Custom whitelists are a powerful feature for implementing zero-trust network security in your CI/CD pipelines. They enable you to define and enforce exactly which network endpoints your workflows are permitted to access, providing defense against supply chain attacks, data exfiltration, and unauthorized communications.

### What Are Custom Whitelists?

A **whitelist** is a list of approved network endpoints (domains, IPs, ports) that your CI/CD workflow is allowed to communicate with. EDAMAME Posture provides two types of whitelists:

1. **Default Whitelists** (e.g., `github`, `github_ubuntu`, `github_macos`, `github_windows`)
   - Pre-configured lists of common CI/CD infrastructure endpoints (GitHub Actions, package managers, build tools)
   - Platform-specific to account for OS differences
   - Suitable for standard workflows with typical dependencies
   - Automatically applied based on your runner OS

2. **Custom Whitelists**
   - User-defined lists tailored to your specific workflow requirements
   - Created from observed network traffic during "learning" runs
   - Incrementally refined as your pipeline evolves
   - Enforced to fail builds when unauthorized endpoints are contacted
   - Stored as JSON files that can be version-controlled

### Why Use Custom Whitelists?

Custom whitelists provide critical security benefits:

- **Supply Chain Attack Prevention**: Detect when compromised dependencies attempt to contact malicious endpoints (e.g., CVE-2025-30066)
- **Data Exfiltration Detection**: Identify when build processes try to send sensitive data to unauthorized servers
- **Compliance Enforcement**: Ensure workflows only access approved services and APIs
- **Zero-Trust Networking**: Implement "deny by default, allow by exception" security model
- **Change Detection**: Alert when new network dependencies are introduced (intentionally or maliciously)

### Custom Whitelist Lifecycle

The custom whitelist feature follows a three-phase lifecycle:

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│  Learning   │ ───> │ Augmentation │ ───> │ Enforcement │
│   Phase     │      │    Phase     │      │    Phase    │
└─────────────┘      └──────────────┘      └─────────────┘
  Generate           Add new endpoints     Fail on violations
  baseline           incrementally         
```

#### Phase 1: Learning (Generate Baseline)

In the learning phase, you run your workflow with network capture enabled to observe all network communications and automatically generate a baseline whitelist.

**Purpose**: Capture all legitimate network traffic from a known-good workflow execution.

**Configuration**:

```yaml
- name: Setup EDAMAME Posture (Learning Mode)
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    network_scan: true                      # Enable network monitoring
    packet_capture: true                    # Capture all traffic
    create_custom_whitelists: true          # Generate whitelist from traffic
    custom_whitelists_path: ./whitelists.json  # Save to this file

# ... your build/test steps ...

- name: Save Generated Whitelist
  uses: actions/upload-artifact@v4
  with:
    name: custom-whitelist
    path: ./whitelists.json
```

**What happens**:
1. EDAMAME monitors all network traffic during your workflow execution
2. At the end, it generates a JSON file containing all observed endpoints
3. The file includes domains, IPs, ports, and protocols for each connection
4. You save this file for use in subsequent runs

**Best Practices**:
- Run learning mode on a clean, trusted environment
- Include all typical workflow scenarios (different branches, test suites, etc.)
- Review the generated whitelist manually to understand your workflow's network footprint
- Store the whitelist in version control or as a workflow artifact

#### Phase 2: Augmentation (Incremental Refinement)

As your workflow evolves and legitimately needs to access new endpoints, you can incrementally add them to your whitelist rather than regenerating it from scratch.

**Purpose**: Merge new legitimate endpoints into an existing whitelist without losing previously approved entries.

**Configuration**:

```yaml
- name: Download Existing Whitelist
  uses: actions/download-artifact@v4
  with:
    name: custom-whitelist
    path: .

- name: Setup EDAMAME Posture (Augmentation Mode)
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    network_scan: true
    packet_capture: true
    augment_custom_whitelists: true         # Merge new + existing entries
    custom_whitelists_path: ./whitelists.json  # Read from and write to this file

# ... your build/test steps that may access new endpoints ...

- name: Save Updated Whitelist
  uses: actions/upload-artifact@v4
  with:
    name: custom-whitelist
    path: ./whitelists.json
```

**What happens**:
1. EDAMAME loads the existing whitelist from `whitelists.json`
2. Monitors network traffic during workflow execution
3. Identifies any new endpoints not in the existing whitelist
4. Merges the new endpoints with existing entries (preserves all previous entries)
5. Overwrites `whitelists.json` with the augmented version

**When to use**:
- Adding new dependencies or services to your workflow
- Updating package versions that contact new CDN endpoints
- Expanding test coverage that accesses new APIs
- Rolling out changes incrementally across multiple runs

**Best Practices**:
- Use augmentation mode temporarily when introducing known changes
- Review the augmented whitelist to verify only expected endpoints were added
- Switch back to enforcement mode once changes are validated
- Document why new endpoints were added (in commit messages or PR descriptions)

#### Phase 3: Enforcement (Lock Down)

Once your whitelist is complete and validated, switch to enforcement mode where any communication to non-whitelisted endpoints will cause your workflow to fail.

**Purpose**: Detect and prevent unauthorized network communications.

**Configuration**:

```yaml
- name: Download Whitelist
  uses: actions/download-artifact@v4
  with:
    name: custom-whitelist
    path: .

- name: Setup EDAMAME Posture (Enforcement Mode)
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
    edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
    edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
    edamame_id: ${{ github.run_id }}
    network_scan: true
    packet_capture: true
    custom_whitelists_path: ./whitelists.json
    set_custom_whitelists: true             # Apply the whitelist
    check_whitelist: true                   # Enable real-time checking
    cancel_on_violation: true               # Cancel workflow on violation

# ... your build/test steps ...

- name: Verify Network Compliance
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    dump_sessions_log: true
    exit_on_whitelist_exceptions: true      # Fail if violations detected
```

**What happens**:
1. EDAMAME loads your custom whitelist at workflow start
2. Monitors all network traffic in real-time during execution
3. Compares each connection against the whitelist
4. If `check_whitelist: true` and `cancel_on_violation: true`:
   - Immediately attempts to cancel the workflow when a violation is detected
5. If `exit_on_whitelist_exceptions: true`:
   - Fails the workflow at the end if any violations occurred
6. Detailed logs show exactly which endpoints violated the whitelist

**Best Practices**:
- Use enforcement mode as your default for production workflows
- Enable `cancel_on_violation` for high-security environments
- Monitor logs regularly for legitimate endpoints that need to be added
- Test whitelist changes in non-production environments first
- Keep whitelists in version control to track changes over time

### Complete Lifecycle Example

Here's a complete workflow showing all three phases:

```yaml
name: Whitelist Lifecycle Demo

on:
  workflow_dispatch:
    inputs:
      mode:
        description: 'Whitelist mode'
        required: true
        type: choice
        options:
          - learning
          - augmentation
          - enforcement

jobs:
  security-scan:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # Download existing whitelist (except in learning mode)
      - name: Download Existing Whitelist
        if: inputs.mode != 'learning'
        uses: actions/download-artifact@v4
        with:
          name: custom-whitelist
          path: .
        continue-on-error: true

      # LEARNING MODE
      - name: Setup EDAMAME (Learning)
        if: inputs.mode == 'learning'
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          network_scan: true
          packet_capture: true
          create_custom_whitelists: true
          custom_whitelists_path: ./whitelists.json

      # AUGMENTATION MODE
      - name: Setup EDAMAME (Augmentation)
        if: inputs.mode == 'augmentation'
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          network_scan: true
          packet_capture: true
          augment_custom_whitelists: true
          custom_whitelists_path: ./whitelists.json

      # ENFORCEMENT MODE
      - name: Setup EDAMAME (Enforcement)
        if: inputs.mode == 'enforcement'
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
          edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
          edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
          edamame_id: ${{ github.run_id }}
          network_scan: true
          packet_capture: true
          custom_whitelists_path: ./whitelists.json
          set_custom_whitelists: true
          check_whitelist: true
          cancel_on_violation: true

      # Your actual workflow steps
      - name: Build and Test
        run: |
          npm install
          npm run build
          npm test

      # Final verification (enforcement mode)
      - name: Verify Compliance
        if: inputs.mode == 'enforcement'
        uses: edamametechnologies/edamame_posture_action@v0
        with:
          dump_sessions_log: true
          exit_on_whitelist_exceptions: true

      # Save/update whitelist (learning and augmentation modes)
      - name: Save Whitelist
        if: inputs.mode != 'enforcement'
        uses: actions/upload-artifact@v4
        with:
          name: custom-whitelist
          path: ./whitelists.json
```

### Whitelist Management Strategies

#### Strategy 1: Per-Environment Whitelists

Maintain separate whitelists for different environments:

```yaml
- name: Setup EDAMAME with Environment-Specific Whitelist
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    custom_whitelists_path: ./whitelists-${{ github.ref_name }}.json
    set_custom_whitelists: true
```

**Use case**: Development, staging, and production may access different APIs and services.

#### Strategy 2: Repository Artifact Storage

Store whitelists as GitHub Actions artifacts:

```yaml
# Save
- uses: actions/upload-artifact@v4
  with:
    name: whitelist-${{ runner.os }}
    path: ./whitelists.json
    retention-days: 90

# Load
- uses: actions/download-artifact@v4
  with:
    name: whitelist-${{ runner.os }}
    path: .
```

**Use case**: Ephemeral runners that don't persist files between runs.

#### Strategy 3: Version Control

Commit whitelists to your repository:

```yaml
# After learning/augmentation
- name: Commit Updated Whitelist
  run: |
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add whitelists.json
    git commit -m "Update custom whitelist [skip ci]"
    git push
```

**Use case**: Transparent change tracking and team collaboration.

#### Strategy 4: Platform-Specific Whitelists

Create separate whitelists for each runner OS:

```yaml
- name: Setup EDAMAME with Platform Whitelist
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    custom_whitelists_path: ./whitelists-${{ runner.os }}.json
    set_custom_whitelists: true
```

**Use case**: Cross-platform builds with different package managers and dependencies.

### Whitelist JSON Format

Custom whitelists are stored as JSON files with the following structure:

```json
{
  "version": "1.0",
  "generated_at": "2025-11-12T10:30:00Z",
  "platform": "linux",
  "entries": [
    {
      "domain": "github.com",
      "ip": "140.82.112.3",
      "port": 443,
      "protocol": "https",
      "first_seen": "2025-11-12T10:30:00Z"
    },
    {
      "domain": "registry.npmjs.org",
      "ip": "104.16.16.35",
      "port": 443,
      "protocol": "https",
      "first_seen": "2025-11-12T10:31:15Z"
    }
  ]
}
```

You can manually edit these files to:
- Remove entries you want to exclude
- Add comments explaining why specific endpoints are needed
- Merge whitelists from different sources

### Troubleshooting

**Problem**: Workflow fails with "Whitelist exception detected"

**Solutions**:
1. Check the session logs to identify the blocked endpoint
2. Verify if the endpoint is legitimate for your workflow
3. If legitimate, run in augmentation mode to add it
4. If unexpected, investigate potential supply chain compromise

**Problem**: Whitelist becomes too permissive over time

**Solutions**:
1. Periodically regenerate the baseline in learning mode
2. Review and prune unused entries manually
3. Use separate whitelists for different workflow types
4. Document each endpoint's purpose in comments

**Problem**: Real-time checking misses violations

**Solutions**:
1. Ensure `packet_capture: true` is set
2. Enable both `check_whitelist: true` (real-time) and `exit_on_whitelist_exceptions: true` (end-of-run)
3. Check that EDAMAME Posture has network capture permissions
4. On Windows, note that packet capture has licensing limitations

### Advanced Features

#### Combining with Default Whitelists

You can use custom whitelists alongside default whitelists:

```yaml
- name: Setup with Hybrid Whitelist
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    whitelist: github_ubuntu              # Default whitelist as base
    custom_whitelists_path: ./custom.json # Additional custom rules
    set_custom_whitelists: true
```

The CLI will merge both lists for enforcement.

#### Blacklist Integration

Custom whitelists work in conjunction with EDAMAME's built-in blacklist:

```yaml
- name: Setup with Whitelist and Blacklist
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    custom_whitelists_path: ./whitelists.json
    set_custom_whitelists: true
    exit_on_whitelist_exceptions: true    # Fail if not on whitelist
    exit_on_blacklisted_sessions: true    # Fail if on blacklist
```

**Behavior**: An endpoint must be on the whitelist AND NOT on the blacklist to be permitted.

#### Anomaly Detection

Machine learning-based anomaly detection complements whitelist enforcement:

```yaml
- name: Setup with Multi-Layer Detection
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    custom_whitelists_path: ./whitelists.json
    set_custom_whitelists: true
    exit_on_whitelist_exceptions: true    # Explicit whitelist check
    exit_on_anomalous_sessions: true      # ML-based anomaly detection
```

**Use case**: Detect unusual communication patterns even among whitelisted endpoints (e.g., data exfiltration to a normally-trusted API).

### Related Inputs Summary

| Input | Type | Default | Purpose |
|-------|------|---------|---------|
| `create_custom_whitelists` | boolean | false | Generate whitelist from observed traffic |
| `custom_whitelists_path` | string | "" | Path to whitelist JSON file |
| `set_custom_whitelists` | boolean | false | Apply whitelist from file |
| `augment_custom_whitelists` | boolean | false | Merge new entries into existing whitelist |
| `exit_on_whitelist_exceptions` | boolean | true | Fail workflow on violations (end-of-run) |
| `check_whitelist` | boolean | false | Enable real-time whitelist checking |
| `cancel_on_violation` | boolean | false | Cancel workflow immediately on violation |
| `whitelist` | string | "github" | Default whitelist name (platform suffix auto-added) |

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
    packet_capture: true                    # Capture network traffic
    create_custom_whitelists: true           # Generate a whitelist from observed traffic
    custom_whitelists_path: ./whitelists.json # Save to this file
```

### Applying a Custom Whitelist
```yaml
- name: EDAMAME Posture with Custom Whitelist
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    network_scan: true                      # Enable network scanning
    packet_capture: true                    # Capture network traffic
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
    packet_capture: true
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
    whitelist: github_ubuntu                 # Apply appropriate whitelist
    auto_remediate: true                     # Fix security issues automatically
    edamame_minimum_score: 2.0               # Enforce minimum security score
    edamame_mandatory_threats: "encrypted disk disabled,critical vulnerability"
```

### Using AI Assistant for Automated Security Todo Processing
```yaml
- name: EDAMAME Posture with AI Assistant
  uses: edamametechnologies/edamame_posture_action@v0
  with:
    edamame_user: ${{ vars.EDAMAME_POSTURE_USER }}
    edamame_domain: ${{ vars.EDAMAME_POSTURE_DOMAIN }}
    edamame_pin: ${{ secrets.EDAMAME_POSTURE_PIN }}
    edamame_id: ${{ github.run_id }}
    network_scan: true
    agentic_mode: analyze                     # AI provides recommendations without executing
    agentic_provider: claude                  # Use Claude as the LLM provider
    agentic_interval: 3600                    # Check for new todos every hour
  env:
    EDAMAME_LLM_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}  # Required for AI features
```

**AI Assistant Modes:**
- `disabled`: No AI assistance (default)
- `analyze`: AI analyzes security todos and provides recommendations without executing actions
- `auto`: AI automatically executes low-risk security actions and escalates high-risk items

**Note:** AI assistant features require setting `EDAMAME_LLM_API_KEY` environment variable with your LLM provider's API key. Additional environment variables for Slack notifications:
- `EDAMAME_AGENTIC_SLACK_BOT_TOKEN`: Slack bot token for notifications
- `EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL`: Channel for action notifications
- `EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL`: Channel for escalations

## EDAMAME Ecosystem

This GitHub Action is part of the broader EDAMAME security ecosystem:

- **EDAMAME Core**: The core implementation used by all EDAMAME components (closed source)
- **[EDAMAME Security](https://github.com/edamametechnologies/edamame_security)**: Desktop/mobile security application with full UI and enhanced capabilities (closed source)
- **[EDAMAME Foundation](https://github.com/edamametechnologies/edamame_foundation)**: Foundation library providing security assessment functionality
- **[EDAMAME Posture](https://github.com/edamametechnologies/edamame_posture_cli)**: CLI tool for security posture assessment and remediation
- **[EDAMAME Helper](https://github.com/edamametechnologies/edamame_helper)**: Helper application for executing privileged security checks
- **[EDAMAME CLI](https://github.com/edamametechnologies/edamame_cli)**: Interface to EDAMAME core services
- **[GitHub Action](https://github.com/edamametechnologies/edamame_posture_action)**: CI/CD integration to enforce posture and network controls
- **[GitLab Action](https://gitlab.com/edamametechnologies/edamame_posture_action)**: CI/CD integration to enforce posture and network controls
- **[Threat Models](https://github.com/edamametechnologies/threatmodels)**: Threat model definitions used throughout the system
- **[EDAMAME Hub](https://hub.edamame.tech)**: Web portal for centralized management when using these components in team environments

## Incremental Whitelist Augmentation

In situations where your pipeline progressively accesses new domains or endpoints over time, you can **iteratively build up a custom whitelist** in a series of "learning" runs and then lock it down for enforcement.

1. **First run – generate baseline**
   ```yaml
   - name: Setup EDAMAME Posture (Learning Mode)
     uses: edamametechnologies/edamame_posture_action@v0
     with:
      network_scan: true                  # Discover LAN peers
      packet_capture: true                # Capture traffic
       create_custom_whitelists: true      # Auto-generate whitelist JSON
       custom_whitelists_path: whitelists.json
   ```
   This step records all endpoints observed during the run and saves them to `whitelists.json`.

2. **Subsequent runs – augment**
   As new endpoints appear in later executions you can merge them into the existing file instead of replacing it:
   ```yaml
   - name: EDAMAME Posture – Augment Whitelist
     uses: edamametechnologies/edamame_posture_action@v0
     with:
      network_scan: true
      packet_capture: true
       augment_custom_whitelists: true      # NEW INPUT
       custom_whitelists_path: whitelists.json
   ```
   The action will:
   1. Generate an **augmented** whitelist (`augment-custom-whitelists`).
   2. Overwrite the existing `whitelists.json` so the list steadily grows (the `augment-custom-whitelists` command already preserves existing entries).

3. **Enforcement mode – lock it**
   Once your whitelist is mature, switch to **enforcement** by simply applying it and failing on exceptions:
   ```yaml
   - name: EDAMAME Posture – Enforce Whitelist
     uses: edamametechnologies/edamame_posture_action@v0
     with:
      network_scan: true
      packet_capture: true
       custom_whitelists_path: whitelists.json
       set_custom_whitelists: true          # Apply the list
       exit_on_whitelist_exceptions: true   # Fail if any new endpoint appears
   ```

### New Inputs
| Name | Default | Description |
|------|---------|-------------|
| `augment_custom_whitelists` | `false` | When `true`, runs `augment-custom-whitelists` and writes the result to the file specified by `custom_whitelists_path` (overwriting it). Requires `network_scan: true` and packet capture to be enabled. |

> **Tip:** Store `whitelists.json` as a version-controlled artifact (e.g., in your repo or an S3 bucket) to share it across pipeline runs and agents.

## CLI to GitHub Action Parameter Mapping

This section shows how GitHub Action inputs map to CLI flags.

### background-start / start Command

| Action Input | CLI Flag | Type | Default | Notes |
|--------------|----------|------|---------|-------|
| `edamame_user` | `--user` | string | - | Required for connected mode |
| `edamame_domain` | `--domain` | string | - | Required for connected mode |
| `edamame_pin` | `--pin` | string | - | Required for connected mode |
| `edamame_id` | `--device-id` | string | - | Optional suffix for device ID |
| `network_scan` | `--network-scan` | flag | false | Enable LAN scanning |
| `packet_capture` | `--packet-capture` | flag | auto | Enable packet capture |
| `whitelist` | `--whitelist` | string | "github" | Whitelist name |
| `check_whitelist` | `--fail-on-whitelist` | flag | false | Fail on whitelist violations |
| `check_blacklist` | `--fail-on-blacklist` | flag | true | Fail on blacklist matches |
| `check_anomalous` | `--fail-on-anomalous` | flag | true | Fail on anomalous sessions |
| `cancel_on_violation` | `--cancel-on-violation` | flag | false | Cancel CI on violations |
| `include_local_traffic` | `--include-local-traffic` | flag | false | Include local traffic |
| `agentic_mode` | `--agentic-mode` | string | "disabled" | AI assistant mode |
| `agentic_provider` | `--agentic-provider` | string | "" | LLM provider |
| `agentic_interval` | `--agentic-interval` | number | 3600 | Processing interval (seconds) |

### background-start-disconnected Command

| Action Input | CLI Flag | Type | Default | Notes |
|--------------|----------|------|---------|-------|
| `disconnected_mode` | (command selection) | boolean | false | Triggers disconnected mode |
| `network_scan` | `--network-scan` | flag | false | Enable LAN scanning |
| `packet_capture` | `--packet-capture` | flag | auto | Enable packet capture |
| `whitelist` | `--whitelist` | string | "" | Whitelist name |
| `check_whitelist` | `--fail-on-whitelist` | flag | false | Fail on whitelist violations |
| `check_blacklist` | `--fail-on-blacklist` | flag | true | Fail on blacklist matches |
| `check_anomalous` | `--fail-on-anomalous` | flag | true | Fail on anomalous sessions |
| `cancel_on_violation` | `--cancel-on-violation` | flag | false | Cancel CI on violations |
| `include_local_traffic` | `--include-local-traffic` | flag | false | Include local traffic |
| `agentic_mode` | `--agentic-mode` | string | "disabled" | AI assistant mode |

**Note:** `agentic_provider` and `agentic_interval` are not supported in disconnected mode.

### get-sessions Command

| Action Input | CLI Flag | Type | Default | Notes |
|--------------|----------|------|---------|-------|
| `dump_sessions_log` | (triggers command) | boolean | false | Run get-sessions |
| `exit_on_whitelist_exceptions` | `--fail-on-whitelist` | flag | true | Fail on whitelist violations |
| `exit_on_blacklisted_sessions` | `--fail-on-blacklist` | flag | false | Fail on blacklist matches |
| `exit_on_anomalous_sessions` | `--fail-on-anomalous` | flag | false | Fail on anomalous sessions |

### Other Commands

| Action Input | CLI Command | Notes |
|--------------|-------------|-------|
| `auto_remediate` | `remediate` | Auto-remediate posture issues |
| `skip_remediations` | (passed as argument) | Comma-separated remediations to skip |
| `edamame_minimum_score` | `check-policy` | Local policy check - minimum score |
| `edamame_mandatory_threats` | `check-policy` | Local policy check - threat IDs |
| `edamame_mandatory_prefixes` | `check-policy` | Local policy check - tag prefixes |
| `edamame_policy` | `check-policy-for-domain` | Domain policy name |
| `create_custom_whitelists` | `create-custom-whitelists` | Generate whitelist from sessions |
| `set_custom_whitelists` | `set-custom-whitelists-from-file` | Apply whitelist from file |
| `augment_custom_whitelists` | `augment-custom-whitelists` | Augment existing whitelist |
| `stop` | `stop` | Stop background process |

### Environment Variables for Advanced Features

These environment variables can be set in the workflow to configure advanced features:

| Variable | Purpose | Required For |
|----------|---------|--------------|
| `EDAMAME_LLM_API_KEY` | LLM API key | Agentic features |
| `EDAMAME_LLM_MODEL` | Override default model | Agentic features (optional) |
| `EDAMAME_LLM_BASE_URL` | Custom LLM endpoint | Agentic features (optional) |
| `EDAMAME_AGENTIC_SLACK_BOT_TOKEN` | Slack bot token | Slack notifications (optional) |
| `EDAMAME_AGENTIC_SLACK_ACTIONS_CHANNEL` | Slack channel for actions | Slack notifications (optional) |
| `EDAMAME_AGENTIC_SLACK_ESCALATIONS_CHANNEL` | Slack channel for escalations | Slack notifications (optional) |
| `EDAMAME_LOG_LEVEL` | Log verbosity (info/debug/trace) | Debugging (optional) |

### CLI Arguments Not Exposed

The following CLI arguments are intentionally not exposed in the GitHub Action:

- `--zeek-format` - Not relevant for GitHub Actions output
- Verbose flags (`-v`, `-vv`, `-vvv`) - Use debug mode instead
- MCP server commands - Not needed in CI/CD
- Direct device/session management commands - Not relevant for CI/CD

### Special Handling

#### packet_capture

The action input supports three values:
- `"true"` - Always enable packet capture
- `"false"` - Never enable packet capture  
- `"auto"` (default) - Enable if `network_scan` is true

This is translated to `--packet-capture` flag when enabled.

#### whitelist

The action automatically appends OS-specific suffixes (`_windows`, `_macos`, `_linux`) to the whitelist name based on the runner OS, unless the input is empty.

#### device_id

The action automatically appends a timestamp suffix to avoid conflicts in matrix jobs: `${device_id}_${timestamp}`
