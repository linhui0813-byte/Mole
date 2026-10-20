#!/bin/bash
# Narrow native Clean adapter. All deletion goes through the pinned Mole funnel.
set -euo pipefail

[[ "$EUID" -ne 0 && $# -ge 4 ]] || exit 64
engine_root="$1"
action="$2"
category="$3"
target="$4"
shift 4

# No path interpolation into shell source, terminal automation, or full-clean invocation.
# Source the original helpers; bin/clean.sh does not run main when sourced.
source "$engine_root/bin/clean.sh" > /dev/null
export MOLE_CURRENT_COMMAND=clean
export MOLE_DELETE_MODE=trash
SYSTEM_CLEAN=false

refuse() {
    if [[ "$action" == trash ]]; then
        log_operation clean SKIPPED "$target" "$1"
    fi
    printf 'CLEAN_REASON:%s\n' "$1" >&2
    exit "${2:-65}"
}

# A real user run exposed this authentication state inside the broad cache
# root. Its location is not proof of regenerability. Keep the exact path and
# aliases of its current object without opening or parsing credential values.
dashboard_auth_cache_is_kept() {
    [[ "$target" == "$HOME/Library/Caches/aws_credentials_cache.json" ||
        "$target" -ef "$HOME/Library/Caches/aws_credentials_cache.json" ]]
}

# The UI cannot submit an arbitrary path or a containing directory. These are
# existing upstream clean_user_essentials / diagnostic-report targets only.
parent="${target%/*}"
case "$category:$parent" in
    "caches:$HOME/Library/Caches") ;;
    "logs:$HOME/Library/Logs")
        [[ ! "$target" -ef "$HOME/Library/Logs/DiagnosticReports" &&
            ! "$target" -ef "$HOME/Library/Logs/mole" ]] || refuse 'Kept: report directory or Mole history'
        ;;
    "reports:$HOME/Library/Logs/DiagnosticReports" | "reports:$HOME/Library/DiagnosticReports") ;;
    *) refuse 'Outside the supported Clean scope' ;;
esac
[[ "$target" == "$parent/"* && "${target##*/}" != . && "${target##*/}" != .. &&
    -e "$target" && ! -L "$target" ]] || refuse 'Missing or redirected item'

# Reject redirected roots and ancestors below HOME in preview and execution.
ancestor="$parent"
while [[ "$ancestor" != "$HOME" ]]; do
    [[ "$ancestor" == "$HOME/"* && ! -L "$ancestor" ]] || refuse 'Redirected parent directory'
    ancestor="${ancestor%/*}"
done

if dashboard_auth_cache_is_kept; then refuse 'Authentication cache is kept'; fi

if should_protect_path "$target"; then refuse 'Protected by Mole'; fi
if is_path_whitelisted "$target"; then refuse 'Protected by your whitelist'; fi
if holds_compiled_model_cache "$target"; then refuse 'Compiled model cache is kept'; fi
if [[ "$category" == caches ]]; then
    _user_cache_deno_delete_guard "$target" || refuse 'Deno data is kept'
fi

_mole_snapshot_path_identity "$target" || refuse 'Cannot verify item identity' 66
bound_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
bound_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
bound_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
identity=$(mole_deletion_identity "$target") || refuse 'Cannot verify item identity' 66

validate_path_for_deletion "$target" || refuse "Kept by Mole: ${_MOLE_VALIDATION_REASON:-protected or unverified item}"
# Use Mole's target-specific owner/SQLite policy. A blanket complete-process
# visibility requirement would make even ordinary disposable logs require root.
# validate_path_for_deletion and the final Trash guard retain required probes.

case "$action" in
    inspect)
        size=$(get_path_size_kb "$target") || refuse 'Size is unavailable or incomplete' 66
        [[ "$size" =~ ^[0-9]+$ ]] || refuse 'Size is unavailable' 66
        [[ "$(mole_deletion_identity "$target")" == "$identity" ]] || refuse 'Item changed while scanning' 66
        _mole_path_matches_identity "$target" "$bound_parent" "$bound_parent_id" "$bound_target_id" ||
            refuse 'Parent changed while scanning' 66
        printf '%s\0' "$size" "$identity" "$bound_parent" "$bound_parent_id" "$bound_target_id"
        ;;
    trash)
        [[ $# -eq 4 ]] || exit 64
        [[ "$identity" == "$1" && "$bound_parent" == "$2" &&
            "$bound_parent_id" == "$3" && "$bound_target_id" == "$4" ]] ||
            refuse 'Item changed since the scan; scan again'
        # Extend, rather than replace, the upstream final Trash guard. The
        # function text is trusted bundled source; no path/user text enters
        # eval. Upstream rechecks owners/SQLite; add Deno/ancestor rebinding.
        original_guard=$(declare -f _mole_trash_target_still_safe)
        [[ "$original_guard" == '_mole_trash_target_still_safe ()'* ]] || refuse 'Unsupported engine guard' 66
        eval "${original_guard/#_mole_trash_target_still_safe /_dashboard_original_trash_guard }"
        _mole_trash_target_still_safe() {
            if dashboard_auth_cache_is_kept; then return 1; fi
            _dashboard_original_trash_guard "$@" || return $?
            validate_path_for_deletion "$target" || return $?
            local ancestor="$parent"
            while [[ "$ancestor" != "$HOME" ]]; do
                [[ "$ancestor" == "$HOME/"* && ! -L "$ancestor" ]] || return 1
                ancestor="${ancestor%/*}"
            done
            if [[ "$category" == caches ]]; then
                _user_cache_deno_delete_guard "$target" || return 1
            fi
            [[ "$(mole_deletion_identity "$target")" == "$identity" ]] || return 1
            _mole_path_matches_identity "$target" "$bound_parent" "$bound_parent_id" "$bound_target_id"
        }
        # Recheck all identity and owner rules inside mole_delete and its Trash
        # sink. No permanent-delete fallback and no administrator privileges.
        export MOLE_DRY_RUN=0
        DRY_RUN=false
        if ! mole_delete "$target" false "$identity"; then
            refuse 'Mole could not confirm the Trash move; check the item and history' 66
        fi
        [[ ! -e "$target" && ! -L "$target" ]] || refuse 'The item is still present' 66
        ;;
    *) exit 64 ;;
esac
