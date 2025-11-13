# Core Augmentation Issue

## Problem

The `augment-custom-whitelists` CLI command is creating **fresh whitelists** instead of **merging exceptions** with the existing whitelist.

### Evidence from Test Results

Endpoint counts fluctuate wildly across iterations instead of monotonically increasing:

```
Iteration 4:  43 endpoints
Iteration 5:  49 endpoints (+6)  ✅ Good
Iteration 6:  47 endpoints (-2)  ❌ Should never decrease!
Iteration 7:  60 endpoints (+13)
Iteration 8:  64 endpoints (+4)
Iteration 9:  46 endpoints (-18) ❌ Lost 18 endpoints!
Iteration 10: 57 endpoints (+11)
Iteration 11: 43 endpoints (-14) ❌ Lost 14 endpoints!
Iteration 12: 39 endpoints (-4)  ❌ Lowest count yet!
Iteration 13: 47 endpoints (+8)
Iteration 14: 49 endpoints (+2)
Iteration 15: 58 endpoints (+9)
Iteration 16: 43 endpoints (-15) ❌ Lost 15 endpoints!
Iteration 17: 44 endpoints (+1)
Iteration 18: 59 endpoints (+15)
Iteration 19: 40 endpoints (-19) ❌ Lost 19 endpoints!
Iteration 20: 52 endpoints (+12)
```

**This is wrong.** Whitelists should only grow or stay stable, never shrink.

## Expected vs Actual Behavior

### Expected (Correct Augmentation):

```
Iteration 1: Create from sessions    → 30 endpoints
Iteration 2: Merge exceptions + old  → 37 endpoints (30 + 7 new)
Iteration 3: Merge exceptions + old  → 41 endpoints (37 + 4 new)
Iteration 4: Merge exceptions + old  → 41 endpoints (no new)
Iteration 5: Merge exceptions + old  → 41 endpoints (no new)
Iteration 6: Merge exceptions + old  → 41 endpoints (no new) → STABLE
```

Endpoint count: **monotonically increasing or stable**

### Actual (Current Broken Behavior):

```
Iteration 1: Create from sessions    → 38 endpoints
Iteration 2: Create from sessions    → 51 endpoints (REPLACED, not merged!)
Iteration 3: Create from sessions    → 44 endpoints (REPLACED again!)
Iteration 4: Create from sessions    → 43 endpoints
...
```

Endpoint count: **random fluctuations based on what traffic was captured in current run**

## Root Cause

The `augment-custom-whitelists` command (via `rpc_augment_custom_whitelists_info`) is:

1. ❌ **Creating a fresh whitelist from current sessions**
2. ❌ **NOT merging with the whitelist loaded in the daemon**

It should be:

1. ✅ **Getting whitelist exceptions from daemon** (sessions that don't match loaded whitelist)
2. ✅ **Merging exceptions with the loaded whitelist**
3. ✅ **Returning the merged result**

## What the Action Is Doing Correctly

The action workflow is working as designed:

1. ✅ **First invocation**: Downloads artifact → Applies whitelist to daemon → Starts daemon
2. ✅ **Traffic generation**: Daemon captures traffic
3. ✅ **Second invocation**: Calls `augment-custom-whitelists` → Uploads result

The daemon correctly:
- ✅ Has the whitelist loaded (verified via `get-whitelist-name`)
- ✅ Marks exceptions (sessions not matching whitelist)
- ✅ Captures all network traffic

## What Needs to be Fixed in Core

Location: `edamame_core` or `edamame_posture`

The `augment-custom-whitelists` implementation needs to:

```rust
// CURRENT (WRONG):
pub fn augment_custom_whitelists() -> WhitelistsJSON {
    // Get current sessions
    let sessions = get_current_sessions();
    // Create whitelist from current sessions
    Whitelists::new_from_sessions(&sessions) // ❌ Creates fresh whitelist!
}

// CORRECT:
pub fn augment_custom_whitelists() -> WhitelistsJSON {
    // Get the LOADED whitelist from daemon
    let loaded_whitelist = get_loaded_whitelist();
    
    // Get EXCEPTIONS (sessions that don't match loaded whitelist)
    let exceptions = get_whitelist_exceptions();
    
    // Create whitelist from exceptions only
    let exceptions_whitelist = Whitelists::new_from_sessions(&exceptions);
    
    // MERGE loaded + exceptions
    merge_whitelists(loaded_whitelist, exceptions_whitelist)  // ✅ Merges!
}
```

## Verification

After fixing the core, the test should show:
- ✅ Monotonically increasing endpoint counts: 38 → 51 → 55 → 58 → 58 → 58 → 58
- ✅ Stability reached after 3 consecutive runs with 0 new endpoints
- ✅ No fluctuations or decreases

## Workaround Applied in Action

The action now includes automatic detection and recovery:

1. **Verification**: Before augmentation, checks if daemon has `custom_whitelist` loaded
2. **Auto-Reload**: If not loaded, automatically reloads from `auto_whitelist.json`
3. **Verification**: Confirms reload succeeded
4. **Logging**: Shows daemon state and any recovery actions taken

This ensures augmentation always has a baseline to merge with, preventing fresh whitelist creation.

## Status

✅ **Action workaround implemented** (commit 56a7e1d)
- Auto-detects missing whitelist in daemon
- Auto-reloads before augmentation
- Should resolve endpoint fluctuations

Test after this fix should show monotonically increasing counts.

## Files Involved

- **edamame_posture/src/background.rs**: `background_augment_custom_whitelists()`
- **edamame_core** (likely): RPC implementation of `rpc_augment_custom_whitelists_info()`
- **flodbadd/src/whitelists.rs**: Merge logic exists but might not be used by augment

The merge logic already exists (see `Whitelists::merge_custom_whitelists`), it just needs to be called by augment instead of creating fresh whitelists.

