#!/bin/bash
# Reviewed, exact app bundles and optional bundle-ID data. No teardown or sudo.
set -euo pipefail
[[ "$EUID" -ne 0 && $# -ge 8 ]] || exit 64
engine_root="$1" action="$2" category="$3" target="$4"
shift 4
case "$action" in policy | inspect) [[ $# -eq 4 ]] ;; trash) [[ $# -eq 8 ]] ;; *) exit 64 ;; esac || exit 64
if [[ "$action" == trash ]]; then
    expected_identity="$1" expected_parent="$2" expected_parent_id="$3" expected_target_id="$4"
    shift 4
fi
app_path="$1" bundle_id="$2" owner="$3" binding="$4"
gate="${MOLE_DASHBOARD_UNINSTALL_GATE:-}"
[[ -x "$gate" ]] || exit 64
source "$engine_root/lib/core/common.sh" > /dev/null
source "$engine_root/lib/uninstall/batch.sh" > /dev/null
export MOLE_UNINSTALL_MODE=1 MOLE_CURRENT_COMMAND=uninstall MOLE_DELETE_MODE=trash
load_mole_whitelist "$HOME" || exit 65

uninstall_refuse() {
    if [[ "$action" == trash ]]; then log_operation uninstall SKIPPED "$target" "$1"; fi
    printf 'CLEAN_REASON:%s\n' "$1" >&2
    exit "${2:-65}"
}

# Inventory and every review/final guard share the pinned upstream Apple list.
# Namespace detection is case-insensitive; allowlist patterns stay case-sensitive.
uninstall_app_policy_safe() {
    local lower_id pattern allowed=false
    if [[ "$bundle_id" == local.hui.mole-dashboard ]]; then
        printf 'CLEAN_REASON:This dashboard cannot uninstall itself. Quit it and remove it in Finder.\n' >&2
        return 1
    fi
    mole_ascii_lowercase lower_id "$bundle_id"
    if [[ "$lower_id" == com.apple.* ]]; then
        for pattern in "${APPLE_UNINSTALLABLE_APPS[@]}"; do
            if bundle_matches_pattern "$bundle_id" "$pattern"; then
                allowed=true
                break
            fi
        done
        if [[ "$allowed" != true ]]; then
            printf "CLEAN_REASON:Protected Apple app. It is not on Mole's removable-app list; check Apple's removal instructions.\n" >&2
            return 1
        fi
    fi
    if should_protect_from_uninstall "$bundle_id" || should_protect_path "$target"; then
        printf 'CLEAN_REASON:Protected by Mole; use the app vendor or macOS removal instructions\n' >&2
        return 1
    fi
}

if [[ "$action" == policy ]]; then
    uninstall_app_policy_safe || uninstall_refuse 'App protection policy could not be verified'
    exit 0
fi

uninstall_contents_safe() {
    local list member pattern count=0 deadline=$((SECONDS + 8)) valid=true
    local -a predicates=(-false)
    for pattern in "${WHITELIST_PATTERNS[@]}"; do predicates+=(-o -path "${pattern%/}"); done
    list=$(mktemp "${TMPDIR:-/tmp}/mole-uninstall-policy.XXXXXX") || return 1
    if ! run_with_timeout 6 "$FIND_BSD" "$target" \( "${predicates[@]}" -o -type f \( -iname '*.db*' -o -iname '*.sqlite*' \) \) -print0 > "$list" 2> /dev/null; then
        /bin/rm -f "$list" # SAFE: Exact mktemp-created private policy listing.
        printf 'CLEAN_REASON:Contents could not be completely checked; inspect access in Finder\n' >&2
        return 1
    fi
    while IFS= read -r -d '' member; do
        count=$((count + 1))
        if [[ $SECONDS -ge $deadline || $count -gt 10000 ]]; then
            printf 'CLEAN_REASON:Content checks exceeded their time or entry budget; inspect this item in Finder\n' >&2
            valid=false
            break
        fi
        if is_path_whitelisted "$member"; then
            printf 'CLEAN_REASON:Contains a whitelisted item: %s\n' "$member" >&2
            valid=false
            break
        fi
        if [[ ! -L "$member" ]] && ! validate_path_for_deletion "$member"; then
            printf 'CLEAN_REASON:Contains an active, protected, or unverified database: %s\n' "$member" >&2
            valid=false
            break
        fi
    done < "$list"
    /bin/rm -f "$list" # SAFE: Exact mktemp-created private policy listing.
    if [[ "$valid" == true && $SECONDS -ge $deadline ]]; then
        printf 'CLEAN_REASON:Content checks reached their time limit; inspect this item in Finder\n' >&2
        return 1
    fi
    [[ "$valid" == true ]]
}

# Only the unit harness supplies these variables; the packaged helper drops them.
if [[ "${MOLE_TEST_NO_AUTH:-0}" == 1 && -n "${MOLE_DASHBOARD_FIXTURE_APPS:-}" ]]; then
    _MOLE_UNINSTALL_LIVE_APP_ROOTS=("$MOLE_DASHBOARD_FIXTURE_APPS")
    _MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="$HOME/fixture-volumes"
fi

uninstall_selection_safe() {
    local reason vendor sibling_rc=0
    uninstall_app_policy_safe || return 1
    reason=$("$gate" --uninstall-check "$owner" "$binding" "$action" 2>&1) || {
        printf 'CLEAN_REASON:%s\n' "${reason:-App identity or running state is unknown; review again}" >&2
        return 1
    }
    case "$category" in
        uninstall-bundle) [[ "$target" == "$app_path" ]] || return 1 ;;
        uninstall-data) [[ "$target" != "$app_path" ]] || return 1 ;;
        *) return 1 ;;
    esac
    vendor=$(official_uninstaller_vendor "$bundle_id" "${app_path##*/}" "$app_path") || vendor=''
    if [[ -n "$vendor" ]]; then
        printf 'CLEAN_REASON:Use the official %s uninstaller for this app\n' "$vendor" >&2
        return 1
    fi
    if is_path_whitelisted "$target"; then
        printf 'CLEAN_REASON:Protected by your Mole whitelist; inspect it before changing the whitelist\n' >&2
        return 1
    fi
    if [[ "$category" == uninstall-data ]]; then
        uninstall_live_bundle_has_other_install "$bundle_id" "$app_path" > /dev/null 2>&1 || sibling_rc=$?
        if [[ $sibling_rc -ne 1 ]]; then
            printf 'CLEAN_REASON:App data is shared with another install or ownership is unknown; data is kept\n' >&2
            return 1
        fi
    fi
    if ! validate_path_for_deletion "$target"; then
        printf 'CLEAN_REASON:Mole retained this item (%s); close its apps and check Finder access before reviewing again\n' "${_MOLE_VALIDATION_REASON:-protected or inaccessible path}" >&2
        return 1
    fi
    uninstall_contents_safe
}

uninstall_selection_safe || uninstall_refuse 'App protection, ownership, or running-state checks refused this item'
_mole_snapshot_path_identity "$target" || uninstall_refuse 'Cannot bind the item and physical parent'
bound_parent="$_MOLE_PATH_SNAPSHOT_PARENT" bound_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID" bound_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
identity=$(mole_deletion_identity "$target") || uninstall_refuse 'Cannot read item identity'

case "$action" in
    inspect)
        size=$(get_path_size_kb "$target") || uninstall_refuse 'Size is incomplete; inspect the app in Finder'
        [[ "$size" =~ ^[0-9]+$ ]] || uninstall_refuse 'Size is unavailable'
        uninstall_selection_safe || uninstall_refuse 'App changed during review; review again'
        [[ "$(mole_deletion_identity "$target")" == "$identity" ]] || uninstall_refuse 'Item changed during review'
        _mole_path_matches_identity "$target" "$bound_parent" "$bound_parent_id" "$bound_target_id" || uninstall_refuse 'Physical parent changed during review'
        printf '%s\0' "$size" "$identity" "$bound_parent" "$bound_parent_id" "$bound_target_id"
        ;;
    trash)
        [[ "$identity" == "$expected_identity" && "$bound_parent" == "$expected_parent" && "$bound_parent_id" == "$expected_parent_id" && "$bound_target_id" == "$expected_target_id" ]] || uninstall_refuse 'Item changed since review; review again'
        original=$(declare -f _mole_trash_target_still_safe)
        [[ "$original" == '_mole_trash_target_still_safe ()'* ]] || uninstall_refuse 'Unsupported engine guard'
        eval "${original/#_mole_trash_target_still_safe /_uninstall_original_trash_guard }"
        _mole_trash_target_still_safe() {
            _uninstall_original_trash_guard "$@" || return $?
            uninstall_selection_safe || return $?
            [[ "$(mole_deletion_identity "$target")" == "$identity" ]] || return 1
            _mole_path_matches_identity "$target" "$bound_parent" "$bound_parent_id" "$bound_target_id"
        }
        original_transport=$(declare -f _mole_move_to_trash)
        [[ "$original_transport" == '_mole_move_to_trash ()'* ]] || uninstall_refuse 'Unsupported Trash transport'
        eval "${original_transport/#_mole_move_to_trash /_uninstall_fixture_trash_transport }"
        _mole_move_to_trash() {
            if [[ -n "${MOLE_TEST_TRASH_DIR:-}" && "${MOLE_TEST_NO_AUTH:-0}" == 1 ]]; then
                _uninstall_fixture_trash_transport "$@"
                return $?
            fi
            [[ "$2" == false ]] || return 1
            _mole_trash_target_still_safe "$1" "$3" "$4" "$5" "${6:-}" || return $?
            # One native attempt; no Finder, authorization, or permanent fallback.
            run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" trash "$1" > /dev/null 2>&1
        }
        export MOLE_DRY_RUN=0
        DRY_RUN=false
        absent=''
        [[ "$category" != uninstall-data ]] || absent="$app_path"
        mole_delete "$target" false "$identity" '' "$absent" || uninstall_refuse 'Move was not confirmed; check the original path and Trash' 66
        [[ ! -e "$target" && ! -L "$target" ]] || uninstall_refuse 'The original path is still present; check Trash' 66
        ;;
esac
