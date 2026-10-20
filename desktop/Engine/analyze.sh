#!/bin/bash
# Explicit Analyze selections, reviewed and revalidated through Mole's funnel.
set -euo pipefail
[[ "$EUID" -ne 0 && $# -ge 5 ]] || exit 64
engine_root="$1"
action="$2"
category="$3"
target="$4"
shift 4
[[ "$category" == analyze || "$category" == analyze-project ]] || exit 64
binding="${!#}"
gate="${MOLE_DASHBOARD_ANALYZE_GATE:-}"
[[ -n "$gate" && -x "$gate" ]] || exit 64
source "$engine_root/bin/clean.sh" > /dev/null
export MOLE_CURRENT_COMMAND=analyze
export MOLE_DELETE_MODE=trash
SYSTEM_CLEAN=false
binding_gate=--check-binding
[[ "$category" != analyze-project ]] || binding_gate=--check-project-binding

analyze_refuse() {
    if [[ "$action" == trash ]]; then log_operation analyze SKIPPED "$target" "$1"; fi
    printf 'CLEAN_REASON:%s\n' "$1" >&2
    exit "${2:-65}"
}

analyze_check_selection() {
    local reason
    ANALYZE_REASON=''
    reason=$("$gate" "$binding_gate" "$target" "$binding" 2>&1) || {
        ANALYZE_REASON="${reason:-The item or protected contents could not be verified}"
        return 1
    }
    if should_protect_path "$target"; then
        ANALYZE_REASON='Protected by Mole; inspect it in Finder'
        return 1
    fi
    if is_path_whitelisted "$target"; then
        ANALYZE_REASON='Protected by your Mole whitelist'
        return 1
    fi
    if holds_compiled_model_cache "$target"; then
        ANALYZE_REASON='Compiled model state is kept'
        return 1
    fi
    if ! _user_cache_deno_delete_guard "$target"; then
        ANALYZE_REASON='Deno data is kept'
        return 1
    fi
    if ! validate_path_for_deletion "$target"; then
        ANALYZE_REASON="Kept by Mole: ${_MOLE_VALIDATION_REASON:-unverified item}"
        return 1
    fi

    if [[ "$category" == analyze-project ]]; then
        analyze_check_project_contents
        return $?
    fi

    # Only a completed physical walk may authorize a folder move. The Go gate
    # caps this tree at 10,000 entries and checks recognized credentials/state.
    local list member count=0 deadline=$((SECONDS + 8))
    list=$(mktemp "${TMPDIR:-/tmp}/mole-analyze-policy.XXXXXX") || return 1
    if ! run_with_timeout 6 "$FIND_BSD" "$target" -print0 > "$list" 2> /dev/null; then
        ANALYZE_REASON='Folder listing was incomplete; choose a smaller readable item'
        /bin/rm -f "$list" # SAFE: exact mktemp-created private policy listing.
        return 1
    fi
    local valid=true
    while IFS= read -r -d '' member; do
        count=$((count + 1))
        if [[ $count -gt 10000 ]]; then
            ANALYZE_REASON='Folder review supports at most 10,000 entries per item; review a smaller subfolder'
            valid=false
            break
        fi
        if [[ $SECONDS -ge $deadline ]]; then
            ANALYZE_REASON='Detailed safety checks reached their 8-second limit; review a smaller subfolder'
            valid=false
            break
        fi
        if should_protect_path "$member"; then
            ANALYZE_REASON="Contains a protected item: $member"
            valid=false
            break
        fi
        if is_path_whitelisted "$member"; then
            ANALYZE_REASON="Contains a whitelisted item: $member"
            valid=false
            break
        fi
        if ! validate_path_for_deletion "$member"; then
            ANALYZE_REASON="Contains an active, protected, or unverifiable item: $member"
            valid=false
            break
        fi
    done < "$list"
    /bin/rm -f "$list" # SAFE: exact mktemp-created private policy listing.
    [[ "$valid" == true ]]
}

analyze_check_project_contents() {
    # The Go gate has completed a no-follow metadata walk. User-owned whole
    # projects carry their Git history, local settings and internal links;
    # automatic-cleanup name heuristics do not classify their source/test data.
    # Keep whitelist matches and account-scoped SQLite probes, including sidecars.
    # This manual whole-project contract requires closing project tools; it does
    # not assert the administrator-wide visibility required by automated Clean.
    # BSD find's -path uses shell patterns without following symbolic links.
    local list member pattern valid=true deadline=$((SECONDS + 8))
    local -a predicates=(-false)
    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        predicates+=(-o -path "${pattern%/}")
    done
    list=$(mktemp "${TMPDIR:-/tmp}/mole-project-policy.XXXXXX") || return 1
    if ! run_with_timeout 6 "$FIND_BSD" "$target" \( "${predicates[@]}" -o -type f \( -iname '*.db*' -o -iname '*.sqlite*' \) \) -print0 > "$list" 2> /dev/null; then
        ANALYZE_REASON='Project listing was incomplete; check folder access or choose a smaller folder'
        /bin/rm -f "$list" # SAFE: exact mktemp-created private project policy listing.
        return 1
    fi
    while IFS= read -r -d '' member; do
        if [[ $SECONDS -ge $deadline ]]; then
            ANALYZE_REASON='Project whitelist/database checks reached their 8-second limit; choose a smaller folder'
            valid=false
            break
        fi
        if is_path_whitelisted "$member"; then
            ANALYZE_REASON="Contains a whitelisted item: $member"
            valid=false
            break
        fi
        # Links are carried as links; do not probe their destinations.
        if [[ ! -L "$member" ]] && _mole_is_sqlite_database_path "$member"; then
            local state=0
            analyze_project_database_state "$member" "$deadline" || state=$?
            if mole_rc_signal "$state"; then
                analyze_refuse 'Database check was interrupted; no move was attempted' 66
            fi
            if [[ $state -ne 1 ]]; then
                if [[ $state -eq 0 ]]; then
                    ANALYZE_REASON="A database is open in your account: $member; close its app or project tools and review again"
                else
                    ANALYZE_REASON="Could not check database use in your account: $member; close project tools and check folder access before reviewing again"
                fi
                valid=false
                break
            fi
        fi
    done < "$list"
    /bin/rm -f "$list" # SAFE: exact mktemp-created private project policy listing.
    [[ "$valid" == true ]]
}

# 0 = open in the invoking account, 1 = no matching account handle, 2 = unknown.
# The account scope is only for an explicitly acknowledged whole checkout under
# HOME, outside Library/hidden home roots. It is never used by automatic Clean.
analyze_project_database_state() {
    local base candidate output errors_file probe_timeout rc=0
    local -a family=()
    base=$(_mole_sqlite_family_base_path "${1%-journal}")
    for candidate in "$base" "${base}-wal" "${base}-shm" "${base}-journal"; do
        [[ ! -e "$candidate" ]] || family+=("$candidate")
    done
    [[ ${#family[@]} -gt 0 ]] || return 2
    probe_timeout=$(_mole_timeout_with_deadline 3 "$2") || return 2
    errors_file=$(mktemp "${TMPDIR:-/tmp}/mole-project-handles.XXXXXX") || return 2
    output=$(run_with_timeout "$probe_timeout" lsof -nP -a -u "$UID" -F fn -- "${family[@]}" < /dev/null 2> "$errors_file") || rc=$?
    local known=true
    [[ ! -s "$errors_file" ]] || known=false
    /bin/rm -f "$errors_file" # SAFE: exact mktemp-created private probe diagnostics.
    if mole_rc_signal "$rc"; then return "$rc"; fi
    [[ "$known" == true ]] || return 2
    [[ $rc -ne 0 || -z "$output" ]] || return 0
    [[ $rc -ne 1 || -n "$output" ]] || return 1
    return 2
}

analyze_check_selection || analyze_refuse "$ANALYZE_REASON"
_mole_snapshot_path_identity "$target" || analyze_refuse 'Cannot verify item identity'
parent="$_MOLE_PATH_SNAPSHOT_PARENT"
parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
identity=$(mole_deletion_identity "$target") || analyze_refuse 'Cannot verify item version'

case "$action" in
    inspect)
        [[ $# -eq 1 ]] || exit 64
        size=$(get_path_size_kb "$target") || analyze_refuse 'Size is incomplete; choose a readable item'
        [[ "$size" =~ ^[0-9]+$ ]] || analyze_refuse 'Size is unavailable'
        reason=$("$gate" "$binding_gate" "$target" "$binding" 2>&1) || analyze_refuse "${reason:-Item changed while sizing; scan again}"
        printf '%s\0' "$size" "$identity" "$parent" "$parent_id" "$target_id"
        ;;
    trash)
        [[ $# -eq 5 ]] || exit 64
        [[ "$identity" == "$1" && "$parent" == "$2" && "$parent_id" == "$3" && "$target_id" == "$4" ]] ||
            analyze_refuse 'Item changed since review; scan and review again'
        original=$(declare -f _mole_trash_target_still_safe)
        [[ "$original" == '_mole_trash_target_still_safe ()'* ]] || analyze_refuse 'Unsupported engine guard'
        eval "${original/#_mole_trash_target_still_safe /_analyze_original_trash_guard }"
        _mole_trash_target_still_safe() {
            _analyze_original_trash_guard "$@" || return $?
            analyze_check_selection || return 1
            [[ "$(mole_deletion_identity "$target")" == "$identity" ]] || return 1
            _mole_path_matches_identity "$target" "$parent" "$parent_id" "$target_id"
        }
        # Keep the funnel and logging. Native failure never triggers Finder
        # authorization or another move attempt. Original transport is test-only.
        original_transport=$(declare -f _mole_move_to_trash)
        [[ "$original_transport" == '_mole_move_to_trash ()'* ]] || analyze_refuse 'Unsupported Trash transport'
        eval "${original_transport/#_mole_move_to_trash /_analyze_fixture_trash_transport }"
        _mole_move_to_trash() {
            if [[ "${MOLE_TEST_NO_AUTH:-0}" == 1 && -n "${MOLE_TEST_TRASH_DIR:-}" ]]; then
                _analyze_fixture_trash_transport "$@"
                return $?
            fi
            [[ "${MOLE_TEST_NO_AUTH:-0}" != 1 && "$2" == false ]] || return 1
            _mole_trash_target_still_safe "$1" "$3" "$4" "$5" "${6:-}" || return $?
            _mole_owned_path_still_valid "$1" "${6:-}" "${7:-}" "$3" "$4" "$5" || return $?
            run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" trash "$1" > /dev/null 2>&1
        }
        export MOLE_DRY_RUN=0
        DRY_RUN=false
        mole_delete "$target" false "$identity" || analyze_refuse 'Trash move was not confirmed; check the item and history' 66
        [[ ! -e "$target" && ! -L "$target" ]] || analyze_refuse 'The item is still present; check it before retrying' 66
        ;;
    *) exit 64 ;;
esac
