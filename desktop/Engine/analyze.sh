#!/bin/bash
# Explicit Analyze selections, reviewed and revalidated through Mole's funnel.
set -euo pipefail
[[ "$EUID" -ne 0 && $# -ge 5 ]] || exit 64
engine_root="$1"
action="$2"
category="$3"
target="$4"
shift 4
[[ "$category" == analyze ]] || exit 64
binding="${!#}"
gate="${MOLE_DASHBOARD_ANALYZE_GATE:-}"
[[ -n "$gate" && -x "$gate" ]] || exit 64
source "$engine_root/bin/clean.sh" > /dev/null
export MOLE_CURRENT_COMMAND=analyze
export MOLE_DELETE_MODE=trash
SYSTEM_CLEAN=false

analyze_refuse() {
    if [[ "$action" == trash ]]; then log_operation analyze SKIPPED "$target" "$1"; fi
    printf 'CLEAN_REASON:%s\n' "$1" >&2
    exit "${2:-65}"
}

analyze_check_selection() {
    local reason
    ANALYZE_REASON=''
    reason=$("$gate" --check-binding "$target" "$binding" 2>&1) || {
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
        "$gate" --check-binding "$target" "$binding" > /dev/null 2>&1 || analyze_refuse 'Item changed while sizing; scan again'
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
