#!/usr/bin/env bash
#
# scripts/e2e_destructive_equivalents.sh
#
# Shared end-to-end test harness for the EPIC tracked at
# git_safety_guard-nqhi: "Block all destructive command families equivalent
# to recursive force-delete".
#
# Each child bead (nqhi.1 .. nqhi.N) implements a focused regex pattern in
# `src/packs/core/filesystem.rs` (or sibling packs) and ADDS a scenario
# function to this script. The scenarios share the same logging contract,
# helpers, and exit conventions documented below.
#
# # Logging contract
#
# - Plain text, ISO-8601 UTC timestamps to millisecond.
# - Each line:  YYYY-MM-DDTHH:MM:SS.mmmZ [LEVEL] [SCENARIO] message key=val
# - Levels: DEBUG, INFO, WARN, ERROR, FATAL.
# - Default log file is ./e2e_destructive_equivalents.log; override with
#   `DCG_E2E_LOG=/path/to/file`.
# - Every assertion logs INFO (pass) or ERROR (fail) with the full command
#   under test and the matched rule id.
# - On failure, the full FAIL_DETAILS list is logged at ERROR before exit 1.
#
# # Exit codes
#
#   0  All assertions passed.
#   1  At least one assertion failed.
#   2  Pre-flight failure (missing binary, missing jq, etc.).
#
# # Required environment
#
#   DCG_BIN  Path to the dcg binary under test. Defaults to
#            ./target/release/dcg. CI MUST set this explicitly.
#
# # Optional environment
#
#   DCG_E2E_LOG       Log file path (default ./e2e_destructive_equivalents.log).
#   DCG_E2E_FILTER    Substring filter on scenario names (e.g. "find" runs
#                     only scenario_find_*). Empty = run all.
#   DCG_E2E_KEEP_LOG  If set, do not truncate the log on start.
#

set -euo pipefail
shopt -s lastpipe nullglob

# ---------------------------------------------------------------------------
# Counters and state
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
declare -a FAIL_DETAILS=()
SCENARIO_ID="init"

DCG_BIN="${DCG_BIN:-./target/release/dcg}"
DCG_E2E_LOG="${DCG_E2E_LOG:-./e2e_destructive_equivalents.log}"
DCG_E2E_FILTER="${DCG_E2E_FILTER:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    printf '%s [%s] [%s] %s\n' "$ts" "$level" "$SCENARIO_ID" "$*" \
        | tee -a "$DCG_E2E_LOG" >&2
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
preflight() {
    SCENARIO_ID="preflight"
    if [[ -z "${DCG_E2E_KEEP_LOG:-}" ]]; then
        : > "$DCG_E2E_LOG"
    fi
    log INFO "starting harness dcg_bin=$DCG_BIN log=$DCG_E2E_LOG filter='${DCG_E2E_FILTER}'"

    if [[ ! -x "$DCG_BIN" ]]; then
        log FATAL "dcg binary not found or not executable: $DCG_BIN"
        log FATAL "hint: run \`cargo build --release\` first, or set DCG_BIN to the binary path"
        exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log FATAL "jq not found in PATH (required for JSON parsing)"
        exit 2
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log FATAL "python3 not found in PATH (required for safe JSON encoding)"
        exit 2
    fi

    local version
    version="$("$DCG_BIN" --version 2>&1 | head -1 || true)"
    log INFO "dcg version: $version"
}

# ---------------------------------------------------------------------------
# JSON-safe payload encoding (python avoids quoting issues)
# ---------------------------------------------------------------------------
encode_payload() {
    local cmd="$1"
    printf '%s' "$cmd" | python3 -c \
'import json, sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))'
}

# ---------------------------------------------------------------------------
# Run dcg against a single command. Echoes the JSON denial to stdout (empty
# string means allowed). Captures stderr to a temp file for triage on
# unexpected behavior.
# ---------------------------------------------------------------------------
run_dcg() {
    local cmd="$1"
    local payload
    payload="$(encode_payload "$cmd")"
    local stderr_file
    stderr_file="$(mktemp)"
    local stdout
    stdout="$(printf '%s' "$payload" | "$DCG_BIN" 2>"$stderr_file" || true)"
    if [[ -n "${DCG_E2E_DEBUG:-}" ]]; then
        log DEBUG "stderr=$(cat "$stderr_file")"
    fi
    rm -f "$stderr_file"
    printf '%s' "$stdout"
}

extract_rule_id() {
    local result="$1"
    [[ -z "$result" ]] && { printf ''; return 0; }
    printf '%s' "$result" | jq -r '.hookSpecificOutput.ruleId // ""' 2>/dev/null || true
}

extract_severity() {
    local result="$1"
    [[ -z "$result" ]] && { printf ''; return 0; }
    printf '%s' "$result" | jq -r '.hookSpecificOutput.severity // ""' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
assert_blocked() {
    local cmd="$1"
    local expected_rule="${2:-}"
    local expected_severity="${3:-}"
    local result rule severity
    result="$(run_dcg "$cmd")"
    if [[ -z "$result" ]]; then
        FAIL=$((FAIL + 1))
        FAIL_DETAILS+=("[$SCENARIO_ID] EXPECTED_BLOCK_GOT_ALLOW cmd=$(printf '%q' "$cmd")")
        log ERROR "expected_block_got_allow cmd=$(printf '%q' "$cmd")"
        return 0
    fi
    rule="$(extract_rule_id "$result")"
    if [[ -n "$expected_rule" ]] && [[ "$rule" != "$expected_rule" ]]; then
        FAIL=$((FAIL + 1))
        FAIL_DETAILS+=("[$SCENARIO_ID] WRONG_RULE cmd=$(printf '%q' "$cmd") expected=$expected_rule got=$rule")
        log ERROR "wrong_rule cmd=$(printf '%q' "$cmd") expected=$expected_rule got=$rule"
        return 0
    fi
    if [[ -n "$expected_severity" ]]; then
        severity="$(extract_severity "$result")"
        if [[ "$severity" != "$expected_severity" ]]; then
            FAIL=$((FAIL + 1))
            FAIL_DETAILS+=("[$SCENARIO_ID] WRONG_SEVERITY cmd=$(printf '%q' "$cmd") rule=$rule expected=$expected_severity got=$severity")
            log ERROR "wrong_severity cmd=$(printf '%q' "$cmd") rule=$rule expected=$expected_severity got=$severity"
            return 0
        fi
    fi
    PASS=$((PASS + 1))
    log INFO "blocked cmd=$(printf '%q' "$cmd") rule=$rule"
}

assert_allowed() {
    local cmd="$1"
    local result rule
    result="$(run_dcg "$cmd")"
    if [[ -n "$result" ]]; then
        rule="$(extract_rule_id "$result")"
        FAIL=$((FAIL + 1))
        FAIL_DETAILS+=("[$SCENARIO_ID] EXPECTED_ALLOW_GOT_BLOCK cmd=$(printf '%q' "$cmd") rule=$rule")
        log ERROR "expected_allow_got_block cmd=$(printf '%q' "$cmd") rule=$rule"
        return 0
    fi
    PASS=$((PASS + 1))
    log INFO "allowed cmd=$(printf '%q' "$cmd")"
}

# DCG_BYPASS contract verifier (commit 0c356c2 hardening).
#
# By design, DCG_BYPASS=1 (or any truthy value) DISABLES dcg entirely —
# this is the documented escape hatch and applies to ALL severity tiers.
# What the hardening guarantees is that FALSY values do NOT bypass:
# DCG_BYPASS= (empty), DCG_BYPASS=0, DCG_BYPASS=false, DCG_BYPASS=no,
# and DCG_BYPASS=off must all leave protection in effect.
#
# This helper asserts that contract: with each falsy value, the command
# must still block. Use it on Critical-tier commands so a regression in
# the truthy-only check (e.g. accidentally treating "" as truthy) is
# caught immediately.
assert_blocked_under_falsy_bypass() {
    local cmd="$1"
    local expected_rule="${2:-}"
    local falsy_value
    for falsy_value in "" "0" "false" "no" "off" "FALSE"; do
        local result rule
        result="$(DCG_BYPASS="$falsy_value" run_dcg "$cmd")"
        if [[ -z "$result" ]]; then
            FAIL=$((FAIL + 1))
            FAIL_DETAILS+=("[$SCENARIO_ID] FALSY_BYPASS_LEAK cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$falsy_value") (falsy value should NOT bypass but did)")
            log ERROR "falsy_bypass_leak cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$falsy_value")"
            continue
        fi
        rule="$(extract_rule_id "$result")"
        if [[ -n "$expected_rule" ]] && [[ "$rule" != "$expected_rule" ]]; then
            FAIL=$((FAIL + 1))
            FAIL_DETAILS+=("[$SCENARIO_ID] FALSY_BYPASS_WRONG_RULE cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$falsy_value") expected=$expected_rule got=$rule")
            log ERROR "falsy_bypass_wrong_rule cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$falsy_value") expected=$expected_rule got=$rule"
            continue
        fi
        PASS=$((PASS + 1))
        log INFO "falsy_bypass_blocked cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$falsy_value") rule=$rule"
    done
}

# Verify that DCG_BYPASS=1 (truthy) DOES allow the command, as documented.
# This pins the documented escape-hatch contract — if dcg ever stops
# honoring DCG_BYPASS=1, this fails so we can update docs accordingly.
assert_allowed_under_truthy_bypass() {
    local cmd="$1"
    local truthy_value
    for truthy_value in "1" "true" "yes" "on" "TRUE"; do
        local result
        result="$(DCG_BYPASS="$truthy_value" run_dcg "$cmd")"
        if [[ -n "$result" ]]; then
            local rule
            rule="$(extract_rule_id "$result")"
            FAIL=$((FAIL + 1))
            FAIL_DETAILS+=("[$SCENARIO_ID] TRUTHY_BYPASS_BLOCKED cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$truthy_value") rule=$rule (truthy bypass should disable dcg)")
            log ERROR "truthy_bypass_blocked cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$truthy_value") rule=$rule"
            continue
        fi
        PASS=$((PASS + 1))
        log INFO "truthy_bypass_allowed cmd=$(printf '%q' "$cmd") DCG_BYPASS=$(printf '%q' "$truthy_value")"
    done
}

# ---------------------------------------------------------------------------
# Scenario registry & runner
# ---------------------------------------------------------------------------
should_run_scenario() {
    local name="$1"
    [[ -z "$DCG_E2E_FILTER" ]] && return 0
    [[ "$name" == *"$DCG_E2E_FILTER"* ]]
}

run_scenario() {
    local name="$1"
    if ! should_run_scenario "$name"; then
        log INFO "skipped (filter) scenario=$name"
        return 0
    fi
    SCENARIO_ID="$name"
    log INFO "begin scenario=$name"
    "$name"
    log INFO "end scenario=$name"
}

# ---------------------------------------------------------------------------
# Existing scenarios — find -delete (already shipped, this proves the
# harness contract by exercising the closed bypass family)
# ---------------------------------------------------------------------------
scenario_find_delete_root_home() {
    assert_blocked 'find / -delete'                               'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'find /home -delete'                            'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'find /etc -delete'                             'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'find ~ -delete'                                'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'find $HOME -delete'                            'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'find / -type f -delete'                        'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'find /etc -name *.conf -delete'                'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked '/usr/bin/find / -delete'                       'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'sudo find /etc -delete'                        'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'env FOO=bar find /etc -delete'                 'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked 'echo done; find /etc -delete'                  'core.filesystem:find-delete-root-home' 'critical'
    assert_blocked '(find /etc -delete)'                           'core.filesystem:find-delete-root-home' 'critical'
}

scenario_find_delete_general() {
    assert_blocked 'find . -delete'                'core.filesystem:find-delete-general' 'high'
    assert_blocked 'find ./node_modules -delete'   'core.filesystem:find-delete-general' 'high'
    assert_blocked 'find /data -delete'            'core.filesystem:find-delete-general' 'high'
    assert_blocked 'find /workspace/build -delete' 'core.filesystem:find-delete-general' 'high'
}

scenario_find_delete_temp_safe() {
    assert_allowed 'find /tmp -delete'
    assert_allowed 'find /tmp/foo -delete'
    assert_allowed 'find /tmp -name *.log -delete'
    assert_allowed 'find /var/tmp -delete'
    assert_allowed 'find $TMPDIR -delete'
}

scenario_find_no_false_positive() {
    assert_allowed 'find . -name *.rs'
    assert_allowed 'find / -type f'
    assert_allowed 'find /etc -ls'
    assert_allowed 'find . -name -delete-this-not-a-flag'
    assert_allowed 'find . -exec cat {} +'
}

scenario_find_delete_bypass_var() {
    # Falsy DCG_BYPASS values must NOT bypass — the hardening contract
    # from commit 0c356c2.
    assert_blocked_under_falsy_bypass 'find /etc -delete'   'core.filesystem:find-delete-root-home'
    assert_blocked_under_falsy_bypass 'find $HOME -delete'  'core.filesystem:find-delete-root-home'
    # Truthy DCG_BYPASS values DO bypass — the documented escape hatch
    # (README.md "DCG_BYPASS=1 disables all protection").
    assert_allowed_under_truthy_bypass 'find /etc -delete'
}

# ---------------------------------------------------------------------------
# Per-child scenarios are added below as each bead is implemented. Every new
# scenario function MUST follow the naming convention `scenario_<binary>_*`
# and be listed in the run_all() block at the bottom of the file.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# unlink (git_safety_guard-nqhi.3)
# ---------------------------------------------------------------------------
scenario_unlink_root_home() {
    assert_blocked 'unlink /etc/passwd'                 'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink /etc/shadow'                 'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink /etc/sudoers'                'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink /usr/bin/sudo'               'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink /boot/vmlinuz'               'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink ~/.bashrc'                   'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink ~/.ssh/id_ed25519'           'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink $HOME/.aws/credentials'      'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink ${HOME}/.gnupg/secring.gpg'  'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'unlink "/etc/passwd"'               'core.filesystem:unlink-root-home' 'critical'
    assert_blocked "unlink '/etc/shadow'"               'core.filesystem:unlink-root-home' 'critical'
    # Compound forms (\bunlink\b matches at any boundary)
    assert_blocked 'echo done; unlink /etc/passwd'      'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'true && unlink /etc/passwd'         'core.filesystem:unlink-root-home' 'critical'
    assert_blocked '(unlink /etc/passwd)'               'core.filesystem:unlink-root-home' 'critical'
    # Wrappers
    assert_blocked 'sudo unlink /etc/passwd'            'core.filesystem:unlink-root-home' 'critical'
    assert_blocked 'env FOO=bar unlink /etc/passwd'     'core.filesystem:unlink-root-home' 'critical'
    # Path-prefixed (PATH_NORMALIZER strips it)
    assert_blocked '/usr/bin/unlink /etc/passwd'        'core.filesystem:unlink-root-home' 'critical'
    assert_blocked '/bin/unlink /etc/shadow'            'core.filesystem:unlink-root-home' 'critical'
}

scenario_unlink_general() {
    assert_blocked 'unlink ./important.db'              'core.filesystem:unlink-general' 'high'
    assert_blocked 'unlink ./build/output.bin'          'core.filesystem:unlink-general' 'high'
    assert_blocked 'unlink secrets.txt'                 'core.filesystem:unlink-general' 'high'
    assert_blocked 'unlink /data/important'             'core.filesystem:unlink-general' 'high'
    assert_blocked 'unlink /workspace/build/critical.bin' 'core.filesystem:unlink-general' 'high'
}

scenario_unlink_temp_safe() {
    assert_allowed 'unlink /tmp/scratch'
    assert_allowed 'unlink /tmp/foo/bar'
    assert_allowed 'unlink /var/tmp/cache'
    assert_allowed 'unlink $TMPDIR/file'
    assert_allowed 'unlink ${TMPDIR}/file'
    assert_allowed 'unlink --help'
    assert_allowed 'unlink --version'
}

scenario_unlink_no_false_positive() {
    # Substring traps — `unlink` inside other paths/strings must not trip.
    assert_allowed 'cat /etc/unlink-script.sh'
    assert_allowed 'ls unlink-foo.txt'
    assert_allowed 'echo unlink'
    # Path traversal under /tmp must NOT short-circuit the safe pattern.
    # The regex is lexical (matches text, not resolved paths), so the
    # block lands on `unlink-general` rather than `unlink-root-home`
    # — but the important property is "blocked SOMEHOW", which is what
    # the parent epic's contract requires (no bypass).
    assert_blocked 'unlink /tmp/../etc/passwd' 'core.filesystem:unlink-general' 'high'
}

scenario_unlink_bypass_var() {
    assert_blocked_under_falsy_bypass  'unlink /etc/passwd'  'core.filesystem:unlink-root-home'
    assert_blocked_under_falsy_bypass  'unlink ~/.ssh/id_ed25519'  'core.filesystem:unlink-root-home'
    assert_allowed_under_truthy_bypass 'unlink /etc/passwd'
}

# ---------------------------------------------------------------------------
# truncate (git_safety_guard-nqhi.1)
# ---------------------------------------------------------------------------
scenario_truncate_root_home() {
    assert_blocked 'truncate -s 0 /etc/passwd'              'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate -s 0 /etc/shadow'              'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate --size=0 /etc/sudoers'         'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate -s -100 /etc/passwd'           'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate -s -1024 /etc/hosts'           'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate --size=-100 /etc/passwd'       'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate -s 0 ~/.bashrc'                'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate -s 0 $HOME/.aws/credentials'   'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'truncate -s 0 /usr/bin/sudo'            'core.filesystem:truncate-zero-root-home' 'critical'
    # compound forms
    assert_blocked 'echo done; truncate -s 0 /etc/passwd'   'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'true && truncate -s 0 /etc/passwd'      'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked '(truncate -s 0 /etc/passwd)'            'core.filesystem:truncate-zero-root-home' 'critical'
    # wrappers
    assert_blocked 'sudo truncate -s 0 /etc/passwd'         'core.filesystem:truncate-zero-root-home' 'critical'
    assert_blocked 'env FOO=bar truncate -s 0 /etc/passwd'  'core.filesystem:truncate-zero-root-home' 'critical'
    # path-prefixed (PATH_NORMALIZER)
    assert_blocked '/usr/bin/truncate -s 0 /etc/passwd'     'core.filesystem:truncate-zero-root-home' 'critical'
}

scenario_truncate_general() {
    assert_blocked 'truncate -s 0 ./important.db'           'core.filesystem:truncate-zero-general' 'high'
    assert_blocked 'truncate -s 0 build/output.bin'         'core.filesystem:truncate-zero-general' 'high'
    assert_blocked 'truncate --size=0 secrets.txt'          'core.filesystem:truncate-zero-general' 'high'
    assert_blocked 'truncate -s -100 ./large.log'           'core.filesystem:truncate-zero-general' 'high'
    assert_blocked 'truncate -s 0 /data/important'          'core.filesystem:truncate-zero-general' 'high'
}

scenario_truncate_temp_safe() {
    assert_allowed 'truncate -s 0 /tmp/scratch.bin'
    assert_allowed 'truncate -s 1G /tmp/sparse-file.bin'
    assert_allowed 'truncate -s 0 /var/tmp/cache.bin'
    assert_allowed 'truncate -s 100M /var/tmp/test.img'
    assert_allowed 'truncate -s 0 $TMPDIR/cache.bin'
    assert_allowed 'truncate --size=0 ${TMPDIR}/scratch'
    assert_allowed 'truncate -s -100 /tmp/log.txt'
    # Pure-growth allowed everywhere (non-destructive).
    assert_allowed 'truncate -s +1024 ./output.bin'
    assert_allowed 'truncate -s +1G /var/log/sparse'
    assert_allowed 'truncate --size=+100M ./preallocated'
    # --help / --version
    assert_allowed 'truncate --help'
    assert_allowed 'truncate --version'
}

scenario_truncate_no_false_positive() {
    assert_allowed 'cat /etc/truncate-readme.txt'
    assert_allowed 'ls truncate-script.sh'
    assert_allowed 'echo truncate'
    # truncate without destructive size operand → falls through
    assert_allowed 'truncate -r ref.bin out.bin'
    assert_allowed 'truncate --reference=ref.bin out.bin'
}

scenario_truncate_bypass_var() {
    assert_blocked_under_falsy_bypass  'truncate -s 0 /etc/passwd'   'core.filesystem:truncate-zero-root-home'
    assert_blocked_under_falsy_bypass  'truncate --size=0 /etc/shadow' 'core.filesystem:truncate-zero-root-home'
    assert_allowed_under_truthy_bypass 'truncate -s 0 /etc/passwd'
}

# ---------------------------------------------------------------------------
# shred (git_safety_guard-nqhi.2)
# ---------------------------------------------------------------------------
scenario_shred_root_home() {
    assert_blocked 'shred /etc/passwd'                  'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred -u /etc/passwd'               'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred -fzu /etc/shadow'             'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred --remove /etc/hosts'          'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred -n 3 -u /etc/passwd'          'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred -u ~/.ssh/id_ed25519'         'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred -u $HOME/.aws/credentials'    'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred -fzu /usr/bin/sudo'           'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'shred -u /boot/vmlinuz'             'core.filesystem:shred-root-home' 'critical'
    # compound forms
    assert_blocked 'echo done; shred -u /etc/passwd'    'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'true && shred -u /etc/passwd'       'core.filesystem:shred-root-home' 'critical'
    assert_blocked '(shred -u /etc/passwd)'             'core.filesystem:shred-root-home' 'critical'
    # wrappers
    assert_blocked 'sudo shred -u /etc/passwd'          'core.filesystem:shred-root-home' 'critical'
    assert_blocked 'env FOO=bar shred -u /etc/passwd'   'core.filesystem:shred-root-home' 'critical'
    # path-prefixed
    assert_blocked '/usr/bin/shred -fzu /etc/passwd'    'core.filesystem:shred-root-home' 'critical'
}

scenario_shred_general() {
    assert_blocked 'shred ./important.db'               'core.filesystem:shred-general' 'high'
    assert_blocked 'shred -u ./secrets.txt'             'core.filesystem:shred-general' 'high'
    assert_blocked 'shred -fzu build/output.bin'        'core.filesystem:shred-general' 'high'
    assert_blocked 'shred -u /data/private'             'core.filesystem:shred-general' 'high'
}

scenario_shred_temp_safe() {
    assert_allowed 'shred -u /tmp/scratch.bin'
    assert_allowed 'shred -fzu /tmp/foo/cache'
    assert_allowed 'shred -u /var/tmp/cache.bin'
    assert_allowed 'shred -u $TMPDIR/file'
    assert_allowed 'shred -u ${TMPDIR}/file'
    assert_allowed 'shred -n 1 -u /tmp/scratch'
    assert_allowed 'shred /tmp/foo/output'
    assert_allowed 'shred --help'
    assert_allowed 'shred --version'
}

scenario_shred_no_false_positive() {
    assert_allowed 'cat /etc/shred-readme.txt'
    assert_allowed 'ls shred-script.sh'
    assert_allowed 'echo shred'
}

scenario_shred_bypass_var() {
    assert_blocked_under_falsy_bypass  'shred -u /etc/passwd'   'core.filesystem:shred-root-home'
    assert_blocked_under_falsy_bypass  'shred -fzu ~/.ssh/id_ed25519'  'core.filesystem:shred-root-home'
    assert_allowed_under_truthy_bypass 'shred -u /etc/passwd'
}

# ---------------------------------------------------------------------------
# tar --remove-files (git_safety_guard-nqhi.6)
# ---------------------------------------------------------------------------
scenario_tar_remove_files_root_home() {
    # Flag-then-source.
    assert_blocked 'tar --remove-files -cf out.tar /etc'              'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked 'tar --remove-files -czf out.tar.gz /home/user'    'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked 'tar --remove-files -cf out.tar /usr/local'        'core.filesystem:tar-remove-files-root-home' 'critical'
    # Source-then-flag (order-agnostic).
    assert_blocked 'tar -cf out.tar --remove-files /etc'              'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked 'tar -cf out.tar /etc --remove-files'              'core.filesystem:tar-remove-files-root-home' 'critical'
    # Delete-only (archive discarded to /dev/null).
    assert_blocked 'tar --remove-files -cf /dev/null /etc'            'core.filesystem:tar-remove-files-root-home' 'critical'
    # Quoted sensitive paths.
    assert_blocked 'tar --remove-files -cf out.tar "/etc"'            'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked "tar --remove-files -cf out.tar '/etc'"            'core.filesystem:tar-remove-files-root-home' 'critical'
    # Home variants.
    assert_blocked 'tar --remove-files -cf out.tar ~/.ssh'            'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked 'tar --remove-files -cf out.tar $HOME/.aws'        'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked 'tar --remove-files -cf out.tar ${HOME}/.gnupg'    'core.filesystem:tar-remove-files-root-home' 'critical'
    # Compound forms (\btar\b matches at any boundary).
    assert_blocked 'echo done; tar --remove-files -cf out.tar /etc'   'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked 'true && tar --remove-files -cf out.tar /etc'      'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked '(tar --remove-files -cf out.tar /etc)'            'core.filesystem:tar-remove-files-root-home' 'critical'
    # Wrappers (sudo/env stripped).
    assert_blocked 'sudo tar --remove-files -cf out.tar /etc'         'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked 'env FOO=bar tar --remove-files -cf out.tar /etc'  'core.filesystem:tar-remove-files-root-home' 'critical'
    # Path-prefixed (PATH_NORMALIZER).
    assert_blocked '/usr/bin/tar --remove-files -cf out.tar /etc'     'core.filesystem:tar-remove-files-root-home' 'critical'
    assert_blocked '/bin/tar --remove-files -cf out.tar /etc'         'core.filesystem:tar-remove-files-root-home' 'critical'
    # Mixed-source: a /tmp source does NOT rescue when an /etc co-source
    # is also present — root-home must still fire.
    assert_blocked 'tar --remove-files -cf out.tar /tmp/foo /etc/bar' 'core.filesystem:tar-remove-files-root-home' 'critical'
}

scenario_tar_remove_files_general() {
    assert_blocked 'tar --remove-files -cf out.tar ./build'           'core.filesystem:tar-remove-files-general' 'high'
    assert_blocked 'tar --remove-files -cf out.tar important.db'      'core.filesystem:tar-remove-files-general' 'high'
    assert_blocked 'tar -cf out.tar --remove-files data.json'         'core.filesystem:tar-remove-files-general' 'high'
    assert_blocked 'tar --remove-files -cf out.tar /data/important'   'core.filesystem:tar-remove-files-general' 'high'
}

scenario_tar_remove_files_temp_safe() {
    assert_allowed 'tar --remove-files -cf out.tar /tmp/scratch'
    assert_allowed 'tar -cf out.tar --remove-files /tmp/foo'
    assert_allowed 'tar --remove-files -czf out.tar.gz /var/tmp/cache'
    assert_allowed 'tar --remove-files -cf out.tar $TMPDIR/scratch'
    assert_allowed 'tar --remove-files -cf out.tar ${TMPDIR}/scratch'
}

scenario_tar_no_false_positive() {
    # No --remove-files means no destruction trigger.
    assert_allowed 'tar -cf out.tar /etc'
    assert_allowed 'tar -czf out.tar.gz /home/user'
    assert_allowed 'tar -xf in.tar'
    assert_allowed 'tar -xzf in.tar.gz -C /tmp'
    assert_allowed 'tar -tf in.tar'
    assert_allowed 'tar --help'
    assert_allowed 'tar --version'
    # Substring traps.
    assert_allowed 'cat tar-readme.md'
    assert_allowed 'ls /etc/tar-config'
    # `--remove-files` mentioned but not as a tar flag (no `tar` invocation).
    assert_allowed 'echo --remove-files'
}

scenario_tar_remove_files_bypass_var() {
    assert_blocked_under_falsy_bypass  'tar --remove-files -cf out.tar /etc'      'core.filesystem:tar-remove-files-root-home'
    assert_blocked_under_falsy_bypass  'tar --remove-files -cf /dev/null /etc'    'core.filesystem:tar-remove-files-root-home'
    assert_allowed_under_truthy_bypass 'tar --remove-files -cf out.tar /etc'
}

# ---------------------------------------------------------------------------
# dd of= (git_safety_guard-nqhi.5)
# ---------------------------------------------------------------------------
scenario_dd_root_home() {
    # Canonical zero/urandom into sensitive files.
    assert_blocked 'dd if=/dev/zero of=/etc/passwd'                  'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'dd if=/dev/urandom of=/etc/shadow'               'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'dd if=/dev/zero of=/etc/sudoers'                 'core.filesystem:dd-overwrite-root-home' 'critical'
    # With bs/count operands.
    assert_blocked 'dd if=/dev/zero of=/etc/passwd bs=1M count=10'   'core.filesystem:dd-overwrite-root-home' 'critical'
    # Operand order swapped (of= first).
    assert_blocked 'dd of=/etc/passwd if=/dev/zero'                  'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'dd of=/etc/passwd if=/dev/zero bs=1M'            'core.filesystem:dd-overwrite-root-home' 'critical'
    # No if= (dd reads from stdin — still destroys content).
    assert_blocked 'dd of=/etc/passwd'                               'core.filesystem:dd-overwrite-root-home' 'critical'
    # Quoted paths.
    assert_blocked 'dd if=/dev/zero of="/etc/passwd"'                'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked "dd if=/dev/zero of='/etc/shadow'"                'core.filesystem:dd-overwrite-root-home' 'critical'
    # Home variants.
    assert_blocked 'dd if=/dev/zero of=~/.ssh/id_ed25519'            'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'dd if=/dev/zero of=$HOME/.aws/credentials'       'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'dd if=/dev/zero of=${HOME}/.gnupg/secring.gpg'   'core.filesystem:dd-overwrite-root-home' 'critical'
    # Other system roots.
    assert_blocked 'dd if=/dev/zero of=/usr/bin/sudo'                'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'dd if=/dev/zero of=/boot/vmlinuz'                'core.filesystem:dd-overwrite-root-home' 'critical'
    # Compound forms.
    assert_blocked 'echo done; dd if=/dev/zero of=/etc/passwd'       'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'true && dd if=/dev/zero of=/etc/passwd'          'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked '(dd if=/dev/zero of=/etc/passwd)'                'core.filesystem:dd-overwrite-root-home' 'critical'
    # Wrappers.
    assert_blocked 'sudo dd if=/dev/zero of=/etc/passwd'             'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked 'env FOO=bar dd if=/dev/zero of=/etc/passwd'      'core.filesystem:dd-overwrite-root-home' 'critical'
    # Path-prefixed (PATH_NORMALIZER).
    assert_blocked '/usr/bin/dd if=/dev/zero of=/etc/passwd'         'core.filesystem:dd-overwrite-root-home' 'critical'
    assert_blocked '/bin/dd if=/dev/urandom of=/etc/shadow'          'core.filesystem:dd-overwrite-root-home' 'critical'
}

scenario_dd_general() {
    assert_blocked 'dd if=/dev/zero of=./important.db'               'core.filesystem:dd-overwrite-general' 'high'
    assert_blocked 'dd if=/dev/urandom of=secrets.txt'               'core.filesystem:dd-overwrite-general' 'high'
    assert_blocked 'dd if=/dev/zero of=build/output.bin bs=1M count=10' 'core.filesystem:dd-overwrite-general' 'high'
    assert_blocked 'dd of=workspace/critical.bin'                    'core.filesystem:dd-overwrite-general' 'high'
    assert_blocked 'dd if=/dev/zero of=/data/important'              'core.filesystem:dd-overwrite-general' 'high'
}

scenario_dd_temp_safe() {
    assert_allowed 'dd if=/dev/zero of=/tmp/scratch.bin bs=1M count=10'
    assert_allowed 'dd if=/dev/urandom of=/tmp/random.bin bs=4096 count=1'
    assert_allowed 'dd if=/dev/zero of=/var/tmp/cache.bin'
    assert_allowed 'dd if=/dev/zero of=$TMPDIR/cache.bin'
    assert_allowed 'dd if=/dev/zero of=${TMPDIR}/scratch'
    assert_allowed 'dd of=/tmp/out.bin'
    assert_allowed 'dd of=/tmp/out.bin if=/dev/zero'
    # Backup TO tmp from sensitive source — NOT destruction (of= is to tmp).
    assert_allowed 'dd if=/etc/passwd of=/tmp/passwd.bak'
    assert_allowed 'dd if=/etc/shadow of=/tmp/shadow.backup'
    assert_allowed 'dd if=/home/user/.ssh/id_ed25519 of=/tmp/keybackup'
    # Read-only dd (output discarded — common for read-speed test).
    assert_allowed 'dd if=/etc/passwd of=/dev/null'
    assert_allowed 'dd if=/etc/shadow of=/dev/null bs=1M'
    assert_allowed 'dd if=/dev/sda of=/dev/null count=1024'
    # --help / --version.
    assert_allowed 'dd --help'
    assert_allowed 'dd --version'
}

scenario_dd_no_false_positive() {
    # dd is a 2-char common substring — \bdd\b must reject these.
    assert_allowed 'echo address'
    assert_allowed 'ls add-ons.txt'
    assert_allowed 'cat odd.log'
    assert_allowed 'echo dd-script'
    assert_allowed 'ls dd-readme.md'
    # dd alone (no of=).
    assert_allowed 'dd if=/dev/zero'
    assert_allowed 'dd if=/etc/passwd'
    # Device-level dd (out of scope: system.disk's territory).
    assert_allowed 'dd if=/dev/zero of=/dev/sda'
    assert_allowed 'dd if=/dev/urandom of=/dev/sdb1'
}

scenario_dd_bypass_var() {
    assert_blocked_under_falsy_bypass  'dd if=/dev/zero of=/etc/passwd'    'core.filesystem:dd-overwrite-root-home'
    assert_blocked_under_falsy_bypass  'dd if=/dev/urandom of=/etc/shadow' 'core.filesystem:dd-overwrite-root-home'
    assert_allowed_under_truthy_bypass 'dd if=/dev/zero of=/etc/passwd'
}

# ---------------------------------------------------------------------------
# (placeholders — implementers replace with concrete assertions)
# scenario_redirect_*() { :; }
# scenario_mv_sensitive_*() { :; }
# scenario_system_disk_default() { :; }

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
run_all() {
    # find -delete (already shipped)
    run_scenario scenario_find_delete_root_home
    run_scenario scenario_find_delete_general
    run_scenario scenario_find_delete_temp_safe
    run_scenario scenario_find_no_false_positive
    run_scenario scenario_find_delete_bypass_var

    # truncate / shred / unlink / dd / tar / redirect / mv / system.disk
    # (added by their respective child beads)
    for scenario in \
        scenario_truncate_root_home \
        scenario_truncate_general \
        scenario_truncate_temp_safe \
        scenario_truncate_no_false_positive \
        scenario_truncate_bypass_var \
        scenario_shred_root_home \
        scenario_shred_general \
        scenario_shred_temp_safe \
        scenario_shred_no_false_positive \
        scenario_shred_bypass_var \
        scenario_unlink_root_home \
        scenario_unlink_general \
        scenario_unlink_temp_safe \
        scenario_unlink_no_false_positive \
        scenario_unlink_bypass_var \
        scenario_dd_root_home \
        scenario_dd_general \
        scenario_dd_temp_safe \
        scenario_dd_no_false_positive \
        scenario_dd_bypass_var \
        scenario_tar_remove_files_root_home \
        scenario_tar_remove_files_general \
        scenario_tar_remove_files_temp_safe \
        scenario_tar_no_false_positive \
        scenario_tar_remove_files_bypass_var \
        scenario_redirect_root_home \
        scenario_redirect_append_safe \
        scenario_redirect_temp_safe \
        scenario_redirect_bypass_var \
        scenario_mv_sensitive_root_home \
        scenario_mv_no_false_positive \
        scenario_mv_sensitive_bypass_var \
        scenario_system_disk_default; do
        if declare -F "$scenario" >/dev/null 2>&1; then
            run_scenario "$scenario"
        else
            log INFO "not implemented yet, skipped scenario=$scenario"
        fi
    done
}

main() {
    preflight
    run_all

    SCENARIO_ID="summary"
    log INFO "summary pass=$PASS fail=$FAIL"
    if (( FAIL > 0 )); then
        log ERROR "FAIL details:"
        for d in "${FAIL_DETAILS[@]}"; do
            log ERROR "  - $d"
        done
        exit 1
    fi
    log INFO "ALL TESTS PASSED"
    exit 0
}

main "$@"
