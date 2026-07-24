#!/usr/bin/env bash
# =============================================================================
# iRacing Setup — Simple Edition (Zenity GUI)
# Assumes: fresh distro install, Steam in $HOME/.steam/steam, single library
# Supports: Arch / CachyOS / EndeavourOS / Debian / Ubuntu / Fedora / Nobara
# =============================================================================
#
# VERSIONING: SCRIPT_VERSION below uses CalVer (YYYY.MM.DD, with a .N
# suffix if shipping more than once in a day). Bump it on every change
# and tag the matching commit (e.g. `git tag v2026.07.14`) — the version
# is logged as the very first line of every run, so any log a user sends
# in shows at a glance which revision produced it.
SCRIPT_VERSION="2026.07.24"
SCRIPT_START_TS=$(date +%s)

# --- Paths ---
STEAM_ROOT="$HOME/.steam/steam"
STEAM_APPS="$STEAM_ROOT/steamapps"
COMPAT_TOOLS_DIR="$STEAM_ROOT/compatibilitytools.d"
IRACING_APPID="266410"

# =============================================================================
# LOCKFILE — refuse to run a second instance alongside a first. Matters
# because an impatient/confused user re-launching the script (exactly what
# happened in the support case that prompted this) would otherwise cause
# the second instance's log truncation below to silently wipe out the
# first instance's in-progress log, plus both instances could race on the
# same config.vdf/localconfig.vdf writes, steam:// triggers, or Proton
# build extraction. Must run before anything below truncates the logs.
# =============================================================================
LOCKFILE="${XDG_RUNTIME_DIR:-/tmp}/danfrasers-iracing-setup-$(id -u).lock"

if [[ -f "$LOCKFILE" ]]; then
    EXISTING_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        LOCK_MSG="iRacing Setup is already running (PID $EXISTING_PID).

Please wait for that run to finish, or close it, before starting another."
        if command -v zenity &>/dev/null; then
            zenity --error --title="iRacing Setup — by Dan Fraser" --text="$LOCK_MSG" --width=500 2>/dev/null
        else
            echo "$LOCK_MSG" >&2
        fi
        exit 1
    fi
    # Stale lock (process no longer alive) — safe to take over
fi
if ! echo $$ >"$LOCKFILE" 2>/dev/null; then
    echo "Could not create lock file at $LOCKFILE — check permissions on ${XDG_RUNTIME_DIR:-/tmp}." >&2
    exit 1
fi
# Minimal early cleanup in case the script dies before the fuller
# cleanup_and_exit trap (defined later, once gui_close exists) takes over.
trap 'rm -f "$LOCKFILE" 2>/dev/null' EXIT INT TERM

# --- Log ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERAL_LOG="$SCRIPT_DIR/danfrasers-iracing-setup.log"
PROTONTRICKS_LOG="$SCRIPT_DIR/danfrasers-iracing-step7.log"
# Raw subprocess output (package manager chatter, wine/proton debug spew
# from launching the Windows installer, curl/tar output, etc) goes here
# instead of $GENERAL_LOG — GENERAL_LOG should only ever contain this
# script's own step-by-step narrative via log(), nothing else, so it
# stays short and readable when a user sends it over for support.
TECH_LOG="$SCRIPT_DIR/danfrasers-iracing-technical.log"
: >"$GENERAL_LOG"
: >"$TECH_LOG"

# Strip anything that could identify the user from a string before it's
# logged — the Linux username (both as $HOME's path component and as a
# bare word, since it shows up on its own inside Windows-style Z:\... paths
# too) gets replaced with the literal placeholder "<user>". Steam usernames
# are never logged in the first place (see Step 2), so this only needs to
# handle the OS-level username.
redact_path() {
    local s="$1"
    [[ -n "$HOME" ]] && s="${s//$HOME//home/<user>}"
    [[ -n "$USER" ]] && s="${s//$USER/<user>}"
    # STEAMID3 (set in Step 9, once resolved) is a persistent per-account
    # identifier — same sensitivity bucket as a username, so it gets the
    # same blanket treatment rather than relying on every call site to
    # remember not to log it.
    [[ -n "${STEAMID3:-}" ]] && s="${s//$STEAMID3/<steamid>}"
    echo "$s"
}

# All logging goes through this — log() itself calls redact_path on every
# message so a path pasted straight into a log call can never leak the
# username by accident, even if a future edit forgets to redact by hand.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $(redact_path "$*")" >>"$GENERAL_LOG"; }

log "=== iRacing Setup v$SCRIPT_VERSION starting ==="

# Runs a command, redacting the user's home directory / username from its
# combined stdout+stderr before appending it to the given log file — used
# anywhere raw command output would otherwise bypass log()'s redaction.
# Capturing stdout too (not just stderr, like the old 2>> redirects did)
# also means these logs actually show what each tool did, not just errors.
# Preserves and returns the original command's exit status.
run_redacted() {
    local logfile="$1"
    shift
    "$@" 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
        redact_path "$line"
    done >>"$logfile"
    return "${PIPESTATUS[0]}"
}

# =============================================================================
# SUMMARY — populated as each step runs, displayed at the end
# =============================================================================
SUMMARY_PACKAGES=""
SUMMARY_LOGIN=""
SUMMARY_IRACING_TYPE=""
SUMMARY_IRACING_FILES=""
SUMMARY_PROTON_LIBS=""
SUMMARY_PROTON_BUILD=""
SUMMARY_EAC=""
SUMMARY_DOCS=""

# =============================================================================
# HELPERS
# =============================================================================

TITLE="iRacing Setup — by Dan Fraser"

# Extract a quoted VDF value by key name
extract_value() {
    local key="$1" text="$2" line result
    while IFS= read -r line; do
        if [[ "$line" == *"\"${key}\""* ]]; then
            line="${line#*\""${key}"\"}"
            line="${line#*\"}"
            result="${line%\"*}"
            echo "$result"
            return
        fi
    done <<<"$text"
}

# Extract ALL quoted values for a given key name (one per line) —
# unlike extract_value, which only returns the first match.
extract_all_values() {
    local key="$1" text="$2" line
    while IFS= read -r line; do
        if [[ "$line" == *"\"${key}\""* ]]; then
            line="${line#*\""${key}"\"}"
            line="${line#*\"}"
            echo "${line%\"*}"
        fi
    done <<<"$text"
}

# Extract just the contents of the "InstalledDepots" block from an ACF
# file's text — used so depot-ID checks only match real depot keys, not
# any coincidental occurrence of "266411"/"266415" elsewhere in the file
# (buildid, size fields, timestamps, etc). Relies on Steam's ACF files
# always putting one token/brace per line, which holds true in practice.
extract_installed_depots_block() {
    awk '
        /"InstalledDepots"/ { found=1; next }
        found && /{/ { depth++; next }
        found && /}/ {
            depth--
            if (depth <= 0) { found=0 }
            next
        }
        found { print }
    ' "$1"
}

# Sets IRACING_DEPOT_PURCHASE / IRACING_DEPOT_DIRECT based on which depot
# ID actually appears as a key inside the InstalledDepots block of
# $IRACING_ACF. Shared by Step 3 (initial check) and Step 4 (re-check
# after triggering an install), so the detection logic only lives in one
# place. Always resets both vars first so stale state can't leak between
# calls.
detect_iracing_depot() {
    IRACING_DEPOT_PURCHASE=""
    IRACING_DEPOT_DIRECT=""
    [[ ! -f "$IRACING_ACF" ]] && return 1

    local depots_block
    depots_block=$(extract_installed_depots_block "$IRACING_ACF")

    if [[ -z "$depots_block" ]]; then
        log "InstalledDepots block not found or empty in $IRACING_ACF"
        return 1
    elif echo "$depots_block" | grep -q '"266415"'; then
        IRACING_DEPOT_PURCHASE="266415"
        log "Depot: Steam Purchase (266415)"
    elif echo "$depots_block" | grep -q '"266411"'; then
        IRACING_DEPOT_DIRECT="266411"
        log "Depot: Direct Account (266411)"
    else
        log "Depot type undetermined — InstalledDepots block present but matched neither known depot ID"
        return 1
    fi
    return 0
}

# =============================================================================
# VDF EDITING HELPERS — used by Step 9 to auto-configure the compatibility
# tool and launch options. These make narrowly SCOPED edits only: locate
# an exact block/line by walking the brace nesting, then touch only that
# line/block. Nothing else in the file is rewritten, so an existing
# config.vdf/localconfig.vdf (which Steam itself constantly rewrites and
# which may contain dozens of unrelated entries) is left otherwise intact.
# =============================================================================

# Finds a top-level "key" { ... } block within line range [rs,re] of file.
# Prints "keyline blockstart blockend" (blockstart = opening brace line,
# blockend = matching closing brace line) or nothing if not found.
vdf_find_key_block() {
    local file="$1" rs="$2" re="$3" key="$4"
    awk -v rs="$rs" -v re="$re" -v key="\"${key}\"" '
        NR < rs { next }
        NR > re { exit }
        {
            if (!found) {
                line = $0
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line == key) { found = 1; keyline = NR; next }
                next
            } else if (!opened) {
                line = $0
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line == "{") { opened = 1; depth = 1; start = NR; next }
                else { found = 0; next }
            } else {
                if ($0 ~ /{/) depth++
                if ($0 ~ /}/) {
                    depth--
                    if (depth == 0) { print keyline, start, NR; exit }
                }
            }
        }
    ' "$file"
}

# Descends through a path of nested keys starting from the whole file.
# Prints "keyline blockstart blockend" for the FINAL key in the path, or
# nothing if any level along the path isn't found — callers should treat
# "not found" as a signal to bail to the manual instructions rather than
# attempt to construct missing intermediate levels from scratch.
vdf_descend() {
    local file="$1"
    shift
    local rs=1 re
    re=$(wc -l <"$file")
    local result=""
    for key in "$@"; do
        result=$(vdf_find_key_block "$file" "$rs" "$re" "$key")
        [[ -z "$result" ]] && return 1
        local bstart bend
        read -r _ bstart bend <<<"$result"
        rs=$((bstart + 1))
        re=$((bend - 1))
    done
    echo "$result"
}

# Sets a "key" "value" pair within line range [rs,re] of file — replacing
# it in place if a line for that key already exists in range, otherwise
# inserting it as the new first line of the range. Deletes-then-inserts
# rather than using sed's s/// substitution, because s///'s replacement
# text has its own backslash/& escaping rules that silently mangle values
# containing literal quotes (e.g. LD_PRELOAD="" in launch options).
vdf_set_kv() {
    local file="$1" rs="$2" re="$3" key="$4" value="$5"
    local existing_line
    existing_line=$(awk -v rs="$rs" -v re="$re" -v key="\"${key}\"" '
        NR>=rs && NR<=re {
            line=$0; gsub(/^[ \t]+/, "", line)
            if (index(line, key) == 1) { print NR; exit }
        }
    ' "$file")

    local tmp_line
    tmp_line=$(mktemp)
    printf '\t\t\t\t\t\t"%s"\t\t"%s"\n' "$key" "$value" >"$tmp_line"

    if [[ -n "$existing_line" ]]; then
        sed -i "${existing_line}d" "$file"
        sed -i "$((existing_line - 1))r $tmp_line" "$file"
    else
        sed -i "${rs}r $tmp_line" "$file"
    fi
    rm -f "$tmp_line"
}

# Cheap corruption check after any write — every VDF block is brace
# delimited, so a mismatched count means something went wrong.
vdf_brace_balanced() {
    local file="$1" o c
    o=$(grep -o '{' "$file" | wc -l)
    c=$(grep -o '}' "$file" | wc -l)
    [[ "$o" -eq "$c" ]]
}

# Keeps only the newest N timestamped backups of a given file (e.g.
# config.vdf.bak-20260714-120000) — without this, every run of this
# script leaves another backup behind forever.
prune_old_backups() {
    local base_path="$1" keep="${2:-3}"
    ls -1t "${base_path}.bak-"* 2>/dev/null | tail -n +$((keep + 1)) | while IFS= read -r old; do
        rm -f "$old"
        log "Pruned old backup: $(basename "$old")"
    done
}

# Verifies an extracted Proton build against a published integrity
# manifest (a single sha256 of the whole tree, generated the same way at
# release time: `find . -type f -exec sha256sum {} \; | sort -k2 |
# sha256sum`). Catches corrupted/partial extractions that a simple "does
# the folder exist" check would miss entirely — which is exactly what let
# a partial extraction (missing files/bin) sit there silently reporting
# "already installed" on every run until it finally broke protontricks
# with a traceback.
# The manifest lives in THIS repo (iRacing-On-Linux), not proton-cachyos —
# committed alongside the setup script itself and fetched via
# raw.githubusercontent.com, which is built for exactly this "many
# clients, one small file" pattern and isn't subject to the throttling a
# release-asset URL can see under repeated hits from many install runs.
# Returns: 0 = verified match, 1 = mismatch (genuinely corrupted),
#          2 = no manifest published for this tag (not a failure —
#          older releases predate this check, so an unverifiable build
#          is still treated as installed, just without the guarantee).
IRACING_ON_LINUX_RAW_BASE="https://raw.githubusercontent.com/DanFraserUK/iRacing-On-Linux/main/iracing-setup-check/manifests"

verify_proton_build() {
    local dir="$1" tag="$2"
    local manifest_url="${IRACING_ON_LINUX_RAW_BASE}/${tag}.manifest.sha256"
    local manifest_tmp
    manifest_tmp=$(mktemp)

    if ! run_redacted "$TECH_LOG" curl -fsSL -o "$manifest_tmp" "$manifest_url"; then
        rm -f "$manifest_tmp"
        log "No integrity manifest found for $tag — skipping verification (older release, or not yet published)"
        return 2
    fi

    local expected_hash
    expected_hash=$(awk '{print $1; exit}' "$manifest_tmp")
    rm -f "$manifest_tmp"

    if [[ -z "$expected_hash" ]]; then
        log "[WARN] Manifest for $tag downloaded but empty/unreadable — skipping verification"
        return 2
    fi

    local actual_hash
    actual_hash=$(cd "$dir" && find . -type f -exec sha256sum {} \; | sort -k2 | sha256sum | awk '{print $1}')

    if [[ "$actual_hash" == "$expected_hash" ]]; then
        log "Integrity check passed for $tag (sha256: $actual_hash)"
        return 0
    else
        log "[ERROR] Integrity check FAILED for $tag — expected $expected_hash, got $actual_hash"
        return 1
    fi
}


# Resolve which userdata/<steamid3> folder belongs to the account that's
# actually logged in, for locating localconfig.vdf. If only one account
# has ever used this machine, that's an easy, unambiguous answer. If
# multiple exist, cross-reference loginusers.vdf's MostRecent=1 entry
# (steamid3 = steamid64 - 76561197960265728); if that lookup fails for any
# reason, fall back to whichever userdata folder was modified most recently.
resolve_steamid3() {
    local candidates=()
    local d
    while IFS= read -r d; do
        candidates+=("$(basename "$d")")
    done < <(find "$STEAM_ROOT/userdata" -maxdepth 1 -mindepth 1 -type d -regextype posix-extended -regex '.*/[1-9][0-9]*' 2>/dev/null)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    elif [[ ${#candidates[@]} -eq 1 ]]; then
        echo "${candidates[0]}"
        return 0
    fi

    local steamid64
    steamid64=$(awk '
        /"[0-9]{17}"[ \t]*$/ { candidate=$0; gsub(/[^0-9]/, "", candidate) }
        /"MostRecent"[ \t]*"1"/ { print candidate; exit }
    ' "$LOGIN_VDF" 2>/dev/null)

    if [[ -n "$steamid64" ]]; then
        local derived=$((steamid64 - 76561197960265728))
        for d in "${candidates[@]}"; do
            [[ "$d" == "$derived" ]] && {
                echo "$d"
                return 0
            }
        done
    fi

    # Fall back to the most recently modified userdata folder
    find "$STEAM_ROOT/userdata" -maxdepth 1 -mindepth 1 -type d -regextype posix-extended -regex '.*/[1-9][0-9]*' -printf '%T@ %f\n' 2>/dev/null |
        sort -rn | head -n1 | awk '{print $2}'
}

# Return every Steam library base path — the default library plus any
# additional ones the user has added via Steam's Storage Manager.
get_steam_libraries() {
    local vdf="$STEAM_ROOT/steamapps/libraryfolders.vdf"
    {
        echo "$STEAM_ROOT"
        [[ -f "$vdf" ]] && extract_all_values "path" "$(cat "$vdf")"
    } | sort -u
}

# Search every Steam library for an existing iRacing common/ folder.
# Only needed for the Direct Account flow, where the exact install path
# must be known to point the Windows installer's /DIR= switch correctly.
find_iracing_common_path() {
    local install_dir="$1" lib candidate
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        candidate="$lib/steamapps/common/$install_dir"
        [[ -d "$candidate" ]] && {
            echo "$candidate"
            return 0
        }
    done < <(get_steam_libraries)
    return 1
}

# Every blocking dialog below pauses briefly before opening. Zenity
# windows render in the same default screen position each time, so a
# click meant to dismiss the previous dialog can otherwise land on this
# one's OK button before the user has actually read it — a real risk
# anywhere two dialogs fire back-to-back with no gap between them.

# Show info popup — user clicks OK to continue
gui_info() {
    sleep 0.3
    zenity --info \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap 2>/dev/null
}

# Show warning popup — user clicks OK to continue
gui_warn() {
    sleep 0.3
    zenity --warning \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap 2>/dev/null
}

# Show error popup then exit
gui_error() {
    sleep 0.3
    zenity --error \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap 2>/dev/null
    log "[ERROR] $1"
    exit 1
}

# Show yes/no question — returns 0 for Yes, 1 for No.
# Pass "cancel" as $2 to make No the focused/default button — use this
# anywhere Yes has a real consequence (a large install, modifying a
# system file) so a rhythm-click or stray Enter lands on the safe option
# rather than the consequential one.
gui_question() {
    sleep 0.3
    local extra_flag=()
    [[ "${2:-}" == "cancel" ]] && extra_flag=(--default-cancel)
    zenity --question \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap \
        "${extra_flag[@]}" 2>/dev/null
}

# Show a pulsing "please wait" progress window while a background PID runs.
# Closes automatically when the PID finishes.
gui_wait() {
    local pid="$1"
    local msg="$2"
    (
        while kill -0 "$pid" 2>/dev/null; do
            echo ""
            sleep 0.5
        done
    ) | zenity --progress \
        --title="$TITLE" \
        --text="$msg" \
        --width=500 \
        --pulsate \
        --auto-close \
        --no-cancel 2>/dev/null
}

# Persistent progress window — stays open across steps to eliminate blink.
# gui_open "msg"   — opens the window
# gui_update "msg" — closes and immediately reopens with new message (fast enough, no blink)
# gui_close        — closes the window
_GUI_PID=""

gui_open() {
    (while true; do
        echo ""
        sleep 0.4
    done) |
        zenity --progress \
            --title="$TITLE" \
            --text="$1" \
            --width=500 \
            --pulsate \
            --no-cancel 2>/dev/null &
    _GUI_PID=$!
    sleep 0.1 # Let window render before work starts
}

gui_update() {
    gui_close
    gui_open "$1"
}

gui_close() {
    if [[ -n "$_GUI_PID" ]] && kill -0 "$_GUI_PID" 2>/dev/null; then
        kill "$_GUI_PID" 2>/dev/null
        wait "$_GUI_PID" 2>/dev/null
    fi
    _GUI_PID=""
    sleep 0.05 # Let window fully close before next one opens
}

# Safety net: if the script exits unexpectedly (Ctrl+C, gui_error, an
# unhandled error) while a gui_open pulse window is active, make sure its
# background loop and the zenity process it feeds don't get left orphaned.
# Also removes the lockfile — this replaces the minimal lockfile-only trap
# set at the very top of the script (before gui_close existed to call).
cleanup_and_exit() {
    gui_close
    rm -f "$LOCKFILE" 2>/dev/null
}
trap cleanup_and_exit EXIT INT TERM

# Closes Steam if it's running, waiting up to 20s total with a couple of
# re-checks. pgrep -x matches the process name exactly — avoids false
# positives from other apps (e.g. Kate) that have steam file paths in
# their arguments. Reused wherever a step needs Steam definitely closed
# (protontricks installs, and the config.vdf/localconfig.vdf auto-config
# step) — Steam gets reopened automatically via steam:// triggers earlier
# in the flow, so this only needs calling right before something that
# actually requires it closed, not proactively at the start of the script.
ensure_steam_closed() {
    local msg_first="${1:-<b>Steam needs to be closed before setup can continue.</b>

Please close Steam yourself now, then click OK.}"

    gui_open "Checking if Steam is running..."
    local steam_running=false
    pgrep -x steam &>/dev/null && steam_running=true
    gui_close
    log "ensure_steam_closed: Steam running = $steam_running"

    local waited_sec=0
    if $steam_running; then
        gui_warn "$msg_first"
        gui_open "Waiting 10 seconds for Steam to fully shut down..."
        sleep 10
        waited_sec=$((waited_sec + 10))
        gui_close
        if pgrep -x steam &>/dev/null; then
            log "ensure_steam_closed: Steam still running after first 10s wait"
            gui_warn "Steam still appears to be running.

Please make sure it's fully closed, then click OK."
            gui_open "Waiting 10 seconds for Steam to fully shut down..."
            sleep 10
            waited_sec=$((waited_sec + 10))
            gui_close
            if pgrep -x steam &>/dev/null; then
                log "[ERROR] ensure_steam_closed: Steam still running after second 10s wait, giving up"
                gui_error "Steam is still running.\n\nPlease close it completely and re-run this setup."
            fi
        fi
        log "ensure_steam_closed: Steam confirmed closed (waited ${waited_sec}s)"
    fi
}

# =============================================================================
# ROOT ELEVATION
# sudo caches credentials for several minutes after the first successful
# prompt, so on a terminal launch it only interrupts once even across
# several root calls. pkexec has no such caching — every single call pops
# its own GUI prompt, which adds up fast across this script (package
# installs, hosts backup, EAC toggle). So: use sudo when a terminal is
# attached (stdin is a tty) since its prompt is visible there and caching
# keeps it to one interruption; use pkexec's GUI dialog only when there's
# no terminal to show a prompt in at all (e.g. launched by double-click),
# where a terminal-only sudo prompt would otherwise be invisible.
# An array (not a plain string) avoids word-splitting issues if $HOME or
# $PATH ever contain spaces.
# =============================================================================

if [[ -t 0 ]]; then
    RUN_AS_ROOT=(sudo)
    log "Root elevation: using sudo (terminal attached, credentials will cache)"
elif command -v pkexec &>/dev/null; then
    RUN_AS_ROOT=(pkexec env "HOME=$HOME" "PATH=$PATH")
    log "Root elevation: using pkexec (no terminal attached, prompts each call)"
else
    RUN_AS_ROOT=(sudo)
    log "Root elevation: no terminal and pkexec not found — falling back to sudo, which may not have anywhere to prompt"
fi

# =============================================================================
# IMMUTABLE OS CHECK - Must run before everything else
# =============================================================================
check_not_immutable() {
    local os_id=""
    local os_name=""
    local variant_id=""

    if [[ -f /etc/os-release ]]; then
        os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        os_name=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
        variant_id=$(grep -E '^VARIANT_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        log "os-release: ID=$os_id VARIANT_ID=${variant_id:-<none>} PRETTY_NAME=$os_name"
    else
        log "No /etc/os-release found — skipping immutable-OS detection by ID"
    fi

    local is_immutable=false
    local detected_name=""

    # Check known immutable distro IDs
    case "$os_id" in
    steamos)
        is_immutable=true
        detected_name="SteamOS"
        ;;
    bazzite)
        is_immutable=true
        detected_name="Bazzite"
        ;;
    nixos)
        is_immutable=true
        detected_name="NixOS"
        ;;
    silverblue | fedora-silverblue)
        is_immutable=true
        detected_name="Fedora Silverblue"
        ;;
    kinoite | fedora-kinoite)
        is_immutable=true
        detected_name="Fedora Kinoite"
        ;;
    chimeraos)
        is_immutable=true
        detected_name="ChimeraOS"
        ;;
    endless)
        is_immutable=true
        detected_name="Endless OS"
        ;;
    bluefin | aurora)
        is_immutable=true
        detected_name="$os_name (Universal Blue)"
        ;;
    esac

    # Also catch Fedora atomic/ostree variants by VARIANT_ID
    if [[ "$is_immutable" == false ]]; then
        case "$variant_id" in
        silverblue | kinoite | sericea | onyx | lazurite | cosmic-atomic)
            is_immutable=true
            detected_name="$os_name (Fedora Atomic)"
            ;;
        esac
    fi

    # Catch any ostree-based system (reliable signal of immutability)
    if [[ "$is_immutable" == false ]]; then
        if [[ -d /ostree/repo ]]; then
            is_immutable=true
            detected_name="${os_name:-Unknown} (OSTree-based)"
            log "Immutable-OS check: /ostree/repo present, treating as immutable"
        else
            log "Immutable-OS check: no known immutable markers found, continuing"
        fi
    fi

    if [[ "$is_immutable" == true ]]; then
        cat <<EOF

╔════════════════════════════════════════════════════════════════════════════╗
║              INCOMPATIBLE OPERATING SYSTEM DETECTED                       ║
╚════════════════════════════════════════════════════════════════════════════╝

  Detected: $detected_name

  This script can't set up iRacing on your system.

  WHY:

  Your operating system is immutable.  That means the core filesystem is
  read-only and locked against modification.

  You've probably noticed Steam itself works fine — that's because Steam
  is either pre-installed as part of your OS, or runs as a self-contained
  Flatpak.  Neither one needs to touch the system filesystem.

  iRacing is different.  It needs additional system-level packages
  alongside Steam — Wine libraries, protontricks, and a custom Proton
  build — none of which can be delivered via Flatpak or pre-bundled.
  These have to be installed as real system packages, which your OS
  almost certainly won't allow without seriously modifying the system,
  and that's not something I'm going to support here.

  This script can't automate any of that on an immutable system.
  Experienced Linux users might be able to work through it manually
  using containers or OS-specific workarounds, but that's complex,
  unsupported, and well outside what this script does.

  To use this script, you'll need a standard (mutable) distribution,
  such as:

    • Arch Linux / CachyOS / EndeavourOS
    • Ubuntu / Linux Mint / Pop!_OS
    • Fedora (standard, not Silverblue/Kinoite)
    • Debian
    • Nobara

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        log "Blocked: immutable OS detected ($detected_name)"
        exit 1
    fi
}

check_not_immutable

# =============================================================================
# FLATPAK / SNAP STEAM CHECK — Must also run before anything touches
# $STEAM_ROOT. Not supported: Flatpak/Snap Steam sandbox their filesystem
# access in ways that can silently break the various -f/-d checks this
# script relies on (e.g. ~/.steam/steam may not be symlinked at all), so
# rather than failing confusingly deep into a later step, refuse up front.
# =============================================================================
check_not_flatpak_snap() {
    local reason=""

    if command -v flatpak &>/dev/null && flatpak list --app --columns=application 2>/dev/null | grep -qi "com.valvesoftware.steam"; then
        reason="Flatpak"
    elif [[ -d "$HOME/.var/app/com.valvesoftware.Steam" ]]; then
        reason="Flatpak"
    elif command -v snap &>/dev/null && snap list 2>/dev/null | grep -qi "^steam "; then
        reason="Snap"
    elif [[ -d /snap/steam ]]; then
        reason="Snap"
    fi

    if [[ -n "$reason" ]]; then
        cat <<EOF

╔════════════════════════════════════════════════════════════════════════════╗
║                  $reason STEAM DETECTED — NOT SUPPORTED                       ║
╚════════════════════════════════════════════════════════════════════════════╝

  This script only supports a native (distro-packaged) install of Steam.

  WHY:

  $reason Steam runs in a sandbox with its own filesystem view. Some of the
  paths this script relies on (Steam's config, compatibility tools folder,
  library manifests) may not exist where expected, or may not be
  reachable at all — which tends to fail confusingly deep into setup
  rather than with a clear error up front.

  TO USE THIS SCRIPT:

  Uninstall the $reason version and install Steam natively via your distro's
  package manager instead (pacman / apt / dnf), then re-run this setup.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        log "Blocked: $reason Steam detected"
        exit 1
    fi
}

check_not_flatpak_snap

# =============================================================================
# OS DETECTION
# =============================================================================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID,,}"
        OS_ID_LIKE="${ID_LIKE,,}"
        OS_NAME="${PRETTY_NAME:-$NAME}"
    else
        OS_ID="unknown"
        OS_ID_LIKE=""
        OS_NAME="Unknown"
    fi

    case "$OS_ID" in
    arch | cachyos | endeavouros | manjaro | artix | parabola | chakra)
        DISTRO_FAMILY="arch"
        ;;
    debian | ubuntu | linuxmint | elementary | trisquel | devuan | kali | parrot)
        DISTRO_FAMILY="debian"
        ;;
    fedora | nobara | rhel | centos | rocky | alma | openmandriva)
        DISTRO_FAMILY="fedora"
        ;;
    *)
        if [[ "$OS_ID_LIKE" == *arch* ]]; then
            DISTRO_FAMILY="arch"
        elif [[ "$OS_ID_LIKE" == *debian* || "$OS_ID_LIKE" == *ubuntu* ]]; then
            DISTRO_FAMILY="debian"
        elif [[ "$OS_ID_LIKE" == *fedora* || "$OS_ID_LIKE" == *rhel* ]]; then
            DISTRO_FAMILY="fedora"
        else
            gui_error "❌ Unsupported distribution: $OS_NAME\n\nSupported: Arch, CachyOS, EndeavourOS, Debian, Ubuntu, Fedora, Nobara"
        fi
        ;;
    esac

    log "Detected OS: $OS_NAME ($DISTRO_FAMILY)"
}

detect_os

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================
check_critical_dependencies() {
    local missing=()
    local tools=("zenity" "curl" "tar" "pgrep")

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           iRacing Linux Setup - Dependency Check           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Detected System: $OS_NAME"
    echo "Checking required packages..."
    echo ""

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
            echo "  ✗ $tool ... MISSING"
            log "MISSING: $tool"
        else
            echo "  ✓ $tool ... OK"
            log "FOUND: $tool"
        fi
    done

    echo ""

    if [[ ${#missing[@]} -gt 0 ]]; then
        local install_cmd
        case "$DISTRO_FAMILY" in
        debian) install_cmd="sudo apt update && sudo apt install -y ${missing[*]}" ;;
        fedora) install_cmd="sudo dnf install -y ${missing[*]}" ;;
        arch) install_cmd="sudo pacman -S --noconfirm ${missing[*]}" ;;
        *) install_cmd="# Please install manually: ${missing[*]}" ;;
        esac

        cat <<EOF
╔════════════════════════════════════════════════════════════════════════════╗
║                    MISSING REQUIRED PACKAGES                              ║
╚════════════════════════════════════════════════════════════════════════════╝

This script needs the following packages to run:
EOF
        for pkg in "${missing[@]}"; do echo "  • $pkg"; done
        cat <<EOF

System: $OS_NAME

TO INSTALL, COPY & PASTE THIS COMMAND:

    $install_cmd

WHAT TO DO NEXT:

1. Open a terminal window.
2. Copy the command above and press Enter.
3. Wait for the install to finish.
4. Run this script again.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        log "[FATAL] Missing critical dependencies: ${missing[*]}"
        exit 1
    fi

    echo "✓ All dependencies verified!"
    echo ""
    log "Dependency check passed"
}

check_critical_dependencies

# =============================================================================
# DISPLAY CHECK — must run before any zenity call is attempted for real.
# zenity existing on PATH doesn't mean it can actually show anything: with
# no DISPLAY and no WAYLAND_DISPLAY, every zenity call below fails
# instantly and silently, gui_question calls all default to "No", and the
# script would otherwise sprint through the ENTIRE flow unattended —
# installing packages, downloading a Proton build, editing config.vdf —
# with no visible UI and no way for anyone to notice or intervene.
# =============================================================================
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "iRacing Setup needs a graphical session (this uses zenity for its UI)." >&2
    echo "No \$DISPLAY or \$WAYLAND_DISPLAY is set — refusing to run headless." >&2
    echo "Run this from a desktop session, not a bare TTY or headless SSH session." >&2
    log "[FATAL] No DISPLAY or WAYLAND_DISPLAY set — refusing to run headless"
    exit 1
fi

# =============================================================================
# ENTRANCE
# =============================================================================
gui_info "<b>iRacing Setup for Linux</b>
<i>by Dan Fraser</i>

Detected OS: <b>$OS_NAME</b>

This tool walks you through setting up iRacing on Linux.  It assumes a
standard fresh install:

  • Steam is installed in the default location
  • iRacing is in any of your Steam libraries (default or added drives)
  • No network shares or unusual mount setups

<b>Some steps will show a password prompt window — enter your password there when asked.</b>

Click OK to begin."

log "GUI setup started"

# =============================================================================
# STEP 1 — Install Steam and protontricks
# =============================================================================
log "=== Step 1 — Steam & protontricks ==="
log "Step 1 — target distro family: $DISTRO_FAMILY"

DEBIAN_APT_UPDATED=false
PACKAGES_INSTALLED_THIS_RUN=false

install_if_missing() {
    local pkg="$1"
    case "$DISTRO_FAMILY" in
    debian)
        if [[ "$pkg" == "protontricks" ]]; then
            # protontricks is installed via pipx on Debian/Ubuntu, not apt,
            # so check for the actual command rather than dpkg's database.
            if command -v protontricks &>/dev/null; then
                log "$pkg already installed (found on PATH via pipx)"
                return
            fi
        elif dpkg -s "$pkg" 2>/dev/null | grep -q "^Status: install ok installed"; then
            # dpkg -s + Status check (not dpkg -l, which returns success even
            # for a purged/removed package still known to dpkg's database)
            log "$pkg already installed (dpkg status: install ok installed)"
            return
        fi
        log "$pkg not found — installing via apt-get..."
        # Batched into a single root call per package (update+install
        # together via bash -c) rather than two separate root calls —
        # matters a lot under pkexec, which has no credential caching and
        # would otherwise prompt once per call. Also memoized across both
        # install_if_missing calls (steam, then protontricks) so a fully
        # fresh install only updates apt once, not twice.
        local skip_update=$DEBIAN_APT_UPDATED
        (
            if [[ "$pkg" == "protontricks" ]]; then
                if $skip_update; then
                    run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" apt-get install -y pipx
                else
                    run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" bash -c 'apt-get update -qq && apt-get install -y pipx'
                fi
                run_redacted "$TECH_LOG" pipx install protontricks
                run_redacted "$TECH_LOG" pipx ensurepath
            else
                if $skip_update; then
                    run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" apt-get install -y "$pkg"
                else
                    run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" bash -c "apt-get update -qq && apt-get install -y $pkg"
                fi
            fi
        ) &
        local install_pid=$!
        gui_wait $install_pid "Installing <b>$pkg</b>...\n\nA password prompt window may appear — enter your password there if asked."
        if wait $install_pid; then
            DEBIAN_APT_UPDATED=true
            log "$pkg installed successfully via apt-get"; PACKAGES_INSTALLED_THIS_RUN=true
        else
            local install_exit=$?
            log "[ERROR] $pkg install via apt-get failed (exit $install_exit) — see $TECH_LOG for apt/pipx output"
            gui_error "❌ Could not install <b>$pkg</b>.\n\nPlease check your internet connection and try again."
        fi
        ;;
    fedora)
        if rpm -q "$pkg" &>/dev/null; then
            log "$pkg already installed (rpm -q confirmed)"
            return
        fi
        log "$pkg not found — installing via dnf..."
        (
            if [[ "$pkg" == "protontricks" ]]; then
                run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" dnf install -y \
                    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
                    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" ||
                    true
            fi
            run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" dnf install -y "$pkg"
        ) &
        local install_pid=$!
        gui_wait $install_pid "Installing <b>$pkg</b>...\n\nA password prompt window may appear — enter your password there if asked."
        if wait $install_pid; then
            log "$pkg installed successfully via dnf"; PACKAGES_INSTALLED_THIS_RUN=true
        else
            local install_exit=$?
            log "[ERROR] $pkg install via dnf failed (exit $install_exit) — see $TECH_LOG for dnf output"
            gui_error "❌ Could not install <b>$pkg</b>.\n\nPlease check your internet connection and try again."
        fi
        ;;
    arch)
        if pacman -Qi "$pkg" &>/dev/null; then
            log "$pkg already installed (pacman -Qi confirmed)"
            return
        fi
        log "$pkg not found — installing via pacman..."
        (
            run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" pacman -S --noconfirm "$pkg"
        ) &
        local install_pid=$!
        gui_wait $install_pid "Installing <b>$pkg</b>...\n\nA password prompt window may appear — enter your password there if asked."
        if wait $install_pid; then
            log "$pkg installed successfully via pacman"; PACKAGES_INSTALLED_THIS_RUN=true
        else
            local install_exit=$?
            log "[ERROR] $pkg install via pacman failed (exit $install_exit) — see $TECH_LOG for pacman output"
            gui_error "❌ Could not install <b>$pkg</b>.\n\nPlease check your internet connection and try again."
        fi
        ;;
    esac
}

gui_open "Checking Steam and protontricks..."
install_if_missing "steam"
install_if_missing "protontricks"
gui_close

if ! command -v protontricks &>/dev/null; then
    case "$DISTRO_FAMILY" in
    debian) HINT="Try opening a terminal and running:\n\n<tt>pipx ensurepath &amp;&amp; source ~/.bashrc</tt>" ;;
    fedora) HINT="Check your RPMFusion installation." ;;
    arch) HINT="Try opening a terminal and running:\n\n<tt>sudo pacman -S protontricks</tt>" ;;
    esac
    log "[ERROR] protontricks installed but not found on PATH ($DISTRO_FAMILY) — likely a shell PATH issue"
    gui_error "❌ protontricks was installed but can't be found.\n\nThis is usually a PATH issue.\n\n$HINT\n\nThen re-run this setup."
fi

if ! protontricks --version &>/dev/null; then
    log "[ERROR] protontricks found on PATH but 'protontricks --version' failed to run"
    gui_error "❌ protontricks is installed but won't run.\n\nCheck the installation and try again."
fi

PROTONTRICKS_VERSION=$(protontricks --version 2>&1 | head -n1)
log "Step 1 complete — Steam and protontricks ready (protontricks: $PROTONTRICKS_VERSION)"
log "Step 1 — root elevation mechanism for later steps: ${RUN_AS_ROOT[*]}"
if $PACKAGES_INSTALLED_THIS_RUN; then
    SUMMARY_PACKAGES="Installed this run"
else
    SUMMARY_PACKAGES="Already installed"
fi

# =============================================================================
# STEP 2 — Check Steam is logged in
# =============================================================================
log "=== Step 2 — Steam Login ==="

gui_open "Checking Steam login..."

LOGIN_VDF="$STEAM_ROOT/config/loginusers.vdf"
steam_logged_in=false

# Note: STEAM_USER (the Steam persona/display name) is intentionally never
# written to the log, per the same privacy rule as the Linux username.
if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"[[:space:]]*"1"' "$LOGIN_VDF"; then
    STEAM_USER=$(extract_value "PersonaName" "$(cat "$LOGIN_VDF")")
    steam_logged_in=true
    log "Steam login detected via loginusers.vdf (MostRecent=1 entry found)"
elif [[ -d "$STEAM_ROOT/userdata" ]] && compgen -G "$STEAM_ROOT/userdata/[0-9]*" 2>/dev/null | grep -qv '/0$'; then
    steam_logged_in=true
    log "loginusers.vdf had no MostRecent entry, but userdata/ has at least one real account folder — treating as logged in"
else
    log "No Steam login detected yet (no loginusers.vdf MostRecent entry, no userdata/ account folders)"
fi

gui_close

# Excludes "0" — Steam's anonymous/not-actually-logged-in placeholder
# folder, not a real account, would otherwise inflate this count.
USERDATA_ACCOUNT_COUNT=$(compgen -G "$STEAM_ROOT/userdata/[0-9]*" 2>/dev/null | grep -cv '/0$')
log "Step 2 — userdata account folder count: $USERDATA_ACCOUNT_COUNT"

if ! $steam_logged_in; then
    log "Steam login not detected — waiting for the user to log in"
    # Record the current timestamp of loginusers.vdf (0 if it doesn't exist yet)
    LOGIN_VDF_MTIME_BEFORE=$(stat -c "%Y" "$LOGIN_VDF" 2>/dev/null || echo "0")

    gui_warn "Steam doesn't appear to be logged in.\n\nPlease open Steam and log into your account, then click OK to continue."

    # Check if the file has changed since the first check — if so, Steam wrote new login data
    check_login_updated() {
        local current_mtime
        current_mtime=$(stat -c "%Y" "$LOGIN_VDF" 2>/dev/null || echo "0")
        if [[ "$current_mtime" != "$LOGIN_VDF_MTIME_BEFORE" ]]; then
            return 0 # File changed — login likely completed
        fi
        return 1
    }

    attempt=0
    LOGIN_WAIT_LOOPS=0
    while true; do
        LOGIN_WAIT_LOOPS=$((LOGIN_WAIT_LOOPS + 1))
        if check_login_updated; then
            # File changed — give Steam a moment to finish writing then check content
            gui_open "Detected Steam activity, checking login..."
            sleep 2
            gui_close
            if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"[[:space:]]*"1"' "$LOGIN_VDF"; then
                STEAM_USER=$(extract_value "PersonaName" "$(cat "$LOGIN_VDF")")
                steam_logged_in=true
                log "Steam login confirmed after loginusers.vdf changed (after $LOGIN_WAIT_LOOPS polling pass(es))"
                break
            fi
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -ge 2 ]]; then
            # Two attempts with no change — ask the user what to do
            if ! zenity --question --title="$TITLE" --text="Steam login still not detected.\n\nHave you logged in to Steam? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                log "User quit at Step 2 — Steam login still not detected after 2 attempts"
                exit 0
            fi
            attempt=0
            LOGIN_VDF_MTIME_BEFORE=$(stat -c "%Y" "$LOGIN_VDF" 2>/dev/null || echo "0")
        else
            gui_open "Checking for Steam login..."
            sleep 2
            gui_close
        fi
    done
fi

if [[ -n "$STEAM_USER" ]]; then
    log "Step 2 complete — Steam login confirmed (persona name available: yes)"
    SUMMARY_LOGIN="✓ Logged in"
else
    log "Step 2 complete — Steam login confirmed via userdata/ (persona name available: no)"
    SUMMARY_LOGIN="Login confirmed"
fi

# =============================================================================
# STEP 3 — Detect iRacing installation type
# =============================================================================
log "=== Step 3 — Detecting iRacing ==="

gui_open "Checking your Steam library..."

IRACING_ACF="$STEAM_APPS/appmanifest_${IRACING_APPID}.acf"
IRACING_DEPOT_PURCHASE=""
IRACING_DEPOT_DIRECT=""

if [[ -f "$IRACING_ACF" ]]; then
    log "Found appmanifest at $IRACING_ACF"
    detect_iracing_depot
else
    log "No iRacing appmanifest found at $IRACING_ACF"
fi

gui_close

if [[ -n "$IRACING_DEPOT_PURCHASE" ]]; then
    SUMMARY_IRACING_TYPE="Steam Purchase"
elif [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    SUMMARY_IRACING_TYPE="Direct Account / Steam Key"
elif [[ ! -f "$IRACING_ACF" ]]; then
    gui_warn "iRacing wasn't found in your Steam library."
    SUMMARY_IRACING_TYPE="Not found in library"
else
    gui_warn "iRacing was found, but I couldn't figure out the account type.\n\nSetup will carry on anyway."
    SUMMARY_IRACING_TYPE="Found - type undetermined"
fi

log "Step 3 complete — initial read: $SUMMARY_IRACING_TYPE"

# NOTE: there used to be a "Step 4 — Close Steam" here that force-closed
# Steam before continuing. It's gone — the next step needs Steam *open*
# (to fire steam:// triggers / let the user interact with the Library),
# so closing it here only to have the very next step reopen it again was
# pure back-and-forth for no benefit. Steam only actually needs to be
# closed later, right before protontricks and the config.vdf edits —
# ensure_steam_closed() (see helpers, above) is called there instead.

# =============================================================================
# STEP 4 — Confirm iRacing is in Steam library (and trigger install if needed)
# =============================================================================
log "=== Step 4 — iRacing in Steam Library ==="

# Polls for $IRACING_ACF to appear. Silent for the first few checks (a
# key redemption or install trigger is often just a few seconds late to
# show up, not actually stuck), then switches to a visible, reassuring
# progress window, then finally offers a "keep waiting / quit" question if
# it's genuinely taking a long time. Deliberately never hard-exits —
# that was the bug that made Step 4 far less forgiving than every other
# wait-loop in this script.
wait_for_iracing_acf() {
    local silent_checks=4   # ~8s silent
    local patient_checks=6  # ~12s more with a visible "be patient" window
    local attempt=0
    ACF_WAIT_TOTAL_LOOPS=0

    while [[ ! -f "$IRACING_ACF" ]]; do
        attempt=$((attempt + 1))
        ACF_WAIT_TOTAL_LOOPS=$((ACF_WAIT_TOTAL_LOOPS + 1))

        if [[ $attempt -le $silent_checks ]]; then
            sleep 2
        elif [[ $attempt -le $((silent_checks + patient_checks)) ]]; then
            gui_open "Still checking your Steam library...\n\nThis can take a little while right after activating a key or starting an install — hang tight."
            sleep 2
            gui_close
        else
            if ! zenity --question --title="$TITLE" --text="Still haven't spotted iRacing in your Steam library.\n\nStill working on it in Steam? Click <b>Yes</b> to keep waiting, or <b>No</b> to quit." --ok-label="Yes, keep waiting" --cancel-label="No, quit" --width=500 2>/dev/null; then
                log "User quit at Step 4 — iRacing still not detected in Steam library (after $ACF_WAIT_TOTAL_LOOPS polling passes)"
                exit 0
            fi
            attempt=0
        fi
    done
}

if [[ ! -f "$IRACING_ACF" ]]; then
    log "iRacing not in Steam library yet — attempting automated Steam triggers"

    gui_info "⚠️  <b>iRacing isn't in your Steam library yet.</b>

Click OK and Steam will open:

  • If you have a <b>direct iRacing account</b> key to redeem, paste it
    into the activation screen that appears.
  • If you've already <b>purchased iRacing on Steam</b>, Steam will be
    told to install it directly — no need to hunt through your Library.

Need a key first? Generate one here:
<tt>https://support.iracing.com/support/solutions/articles/31000165400</tt>"

    # steam://open/activateproduct only does anything if the user actually
    # has a key dialog to act on. steam://install is harmless either way —
    # if the account doesn't own the app it typically lands on the store
    # page instead of failing silently. Firing both covers Direct Account
    # and Steam Purchase without needing to know in advance which one this
    # user is.
    (steam steam://open/activateproduct >/dev/null 2>&1 &) 2>/dev/null
    sleep 1
    (steam "steam://install/${IRACING_APPID}" >/dev/null 2>&1 &) 2>/dev/null
    log "Fired steam://open/activateproduct and steam://install/${IRACING_APPID}"

    wait_for_iracing_acf
    log "iRacing appmanifest now found at $IRACING_ACF (after $ACF_WAIT_TOTAL_LOOPS polling passes)"
    log "Step 4 — remediation path taken: steam:// triggers"
    detect_iracing_depot
else
    log "Step 4 — iRacing already in Steam library, confirming depot type"
    log "Step 4 — remediation path taken: none needed (already present)"
    detect_iracing_depot
fi

# appmanifest exists but the depot type (Purchase vs Direct) still isn't
# known — ask the user to check Steam directly rather than silently
# skipping installation entirely (which is what used to happen: neither
# Step 5 nor Step 6 would run if depot detection came back empty).
if [[ -z "$IRACING_DEPOT_PURCHASE" && -z "$IRACING_DEPOT_DIRECT" ]]; then
    log "[WARN] Step 4 — appmanifest present but depot type undetermined; asking user to verify"
    gui_warn "iRacing was found in your library, but I couldn't confirm what's actually installed yet.

Please open Steam and check <b>Library -> iRacing</b> (install or verify the files if needed), then click OK to re-check."

    attempt=0
    while [[ -z "$IRACING_DEPOT_PURCHASE" && -z "$IRACING_DEPOT_DIRECT" ]]; do
        gui_open "Re-checking iRacing depot info..."
        sleep 2
        gui_close
        detect_iracing_depot
        [[ -n "$IRACING_DEPOT_PURCHASE" || -n "$IRACING_DEPOT_DIRECT" ]] && break

        attempt=$((attempt + 1))
        if [[ $attempt -ge 3 ]]; then
            if ! zenity --question --title="$TITLE" --text="Still can't confirm iRacing's install type.\n\nKeep waiting? Click <b>Yes</b> to check again, or <b>No</b> to stop and check things manually." --ok-label="Yes, check again" --cancel-label="No, stop" --width=500 2>/dev/null; then
                log "User stopped at Step 4 — depot type still undetermined after manual verification prompt"
                exit 0
            fi
            attempt=0
        fi
    done
fi

if [[ -n "$IRACING_DEPOT_PURCHASE" ]]; then
    SUMMARY_IRACING_TYPE="Steam Purchase"
elif [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    SUMMARY_IRACING_TYPE="Direct Account / Steam Key"
fi

log "Step 4 complete — iRacing confirmed in library (type: ${IRACING_DEPOT_PURCHASE:+Steam Purchase}${IRACING_DEPOT_DIRECT:+Direct Account})"

# =============================================================================
# STEP 5 — Steam Purchase: verify game files
# =============================================================================
# NOTE: this is a quick sanity check, not an exhaustive file listing.
# A real iRacing install contains many more files/folders than this — these
# are just a handful of reliable, always-present items used as a fast way
# to tell "fully installed" apart from "stub only" or "partial install".
IRACING_FINGERPRINT=(
    "iRacingSim64DX11.exe"
    "iRacingService64.exe"
    "iRacingLauncher64.exe"
    "EasyAntiCheat"
    "ui"
    "cars"
    "tracks"
)

# Checks all fingerprint items exist under the given path. Used instead of
# watching the appmanifest's mtime to detect "install/verify finished" —
# mtime changes the moment Steam *starts* an install or verify, not when
# it completes, so mtime-based waits can report false-complete seconds
# into a multi-minute download. This is un-spammable: repeatedly clicking
# "check again" just runs the same real check again.
iracing_fingerprint_complete() {
    local path="$1" entry
    [[ ! -d "$path" ]] && return 1
    for entry in "${IRACING_FINGERPRINT[@]}"; do
        [[ ! -e "$path/$entry" ]] && return 1
    done
    return 0
}

if [[ -n "$IRACING_DEPOT_PURCHASE" ]]; then
    log "=== Step 5 — Steam Purchase Installation ==="

    gui_open "Checking iRacing game files..."
    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")
    # Search every Steam library, not just the default one — iRacing may be
    # installed on a secondary drive/library.
    IRACING_PATH=$(find_iracing_common_path "$INSTALL_DIR")
    if [[ -z "$IRACING_PATH" ]]; then
        IRACING_PATH="$STEAM_APPS/common/$INSTALL_DIR"
        log "installdir '$INSTALL_DIR' not found in any known library yet — defaulting to $IRACING_PATH"
    else
        log "installdir '$INSTALL_DIR' found at $IRACING_PATH"
    fi
    gui_close

    if [[ -d "$IRACING_PATH" ]]; then
        all_found=true
        for entry in "${IRACING_FINGERPRINT[@]}"; do
            [[ ! -e "$IRACING_PATH/$entry" ]] && {
                all_found=false
                log "Fingerprint check: missing '$entry' — treating install as incomplete"
                break
            }
        done

        if $all_found; then
            IRACING_SIZE_MB=$(du -sm "$IRACING_PATH" 2>/dev/null | cut -f1)
            log "Fingerprint check passed — all ${#IRACING_FINGERPRINT[@]} expected items present at $IRACING_PATH"
            log "Step 5 — install size: ${IRACING_SIZE_MB:-unknown} MB"
            gui_info "<b>iRacing game files found and look complete.</b>\n\nLocation: <tt>$IRACING_PATH</tt>"
            SUMMARY_IRACING_FILES="Files complete"
        else
            log "Prompting user to verify game files via Steam"

            gui_warn "<b>iRacing folder exists but looks incomplete.</b>

Please open Steam and verify the game files:
<b>Right-click iRacing -> Properties -> Installed Files -> Verify integrity</b>

Click OK once Steam has finished verifying."

            attempt=0
            while true; do
                gui_open "Checking iRacing files..."
                sleep 2
                gui_close
                if iracing_fingerprint_complete "$IRACING_PATH"; then
                    log "Fingerprint check passed — verification detected as complete"
                    break
                fi
                attempt=$((attempt + 1))
                if [[ $attempt -ge 2 ]]; then
                    if ! zenity --question --title="$TITLE" --text="Files still look incomplete.\n\nHas the verification finished? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                        log "User quit at Step 5 while waiting for Steam verification"
                        exit 0
                    fi
                    attempt=0
                fi
            done
            SUMMARY_IRACING_FILES="Verified"
        fi
    else
        log "$IRACING_PATH doesn't exist yet — prompting user to install via Steam"

        gui_warn "<b>iRacing hasn't been downloaded yet.</b>

Please open Steam and install it:
<b>Library -> iRacing -> Install</b>

Click OK once the install is done."

        attempt=0
        while true; do
            gui_open "Checking for iRacing installation..."
            sleep 2
            gui_close
            if iracing_fingerprint_complete "$IRACING_PATH"; then
                log "Fingerprint check passed — install detected as complete"
                break
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -ge 2 ]]; then
                if ! zenity --question --title="$TITLE" --text="iRacing doesn't look fully installed yet.\n\nHas it finished installing in Steam? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                    log "User quit at Step 5 while waiting for Steam install"
                    exit 0
                fi
                attempt=0
            fi
        done
        SUMMARY_IRACING_FILES="Installed via Steam"
    fi

    log "Step 5 complete — $SUMMARY_IRACING_FILES"
fi

# =============================================================================
# STEP 6 — Direct account: install via Windows installer
# =============================================================================

run_iracing_windows_installer_flow() {
    log "Entering stub/full-install flow (will open download + wait for installer)"

    if [[ ! -d "$IRACING_STEAM_PATH" ]]; then
        # Watch for the stub directory appearing after Steam installs it
        ACF_MTIME_BEFORE=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")

        gui_warn "<b>iRacing stub not found.</b>

Please open Steam and install iRacing:
<b>Library -> iRacing -> Install</b>

This just downloads a small stub, a few MB.  Click OK once Steam shows it as installed."

        attempt=0
        while true; do
            gui_open "Checking for iRacing stub..."
            sleep 2
            gui_close
            ACF_MTIME_NOW=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")
            if [[ -d "$IRACING_STEAM_PATH" && "$ACF_MTIME_NOW" != "$ACF_MTIME_BEFORE" ]]; then
                break
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -ge 2 ]]; then
                if ! zenity --question --title="$TITLE" --text="iRacing stub still not found.\n\nHas Steam finished installing it? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                    exit 0
                fi
                attempt=0
                ACF_MTIME_BEFORE=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")
            fi
        done
    fi

    IRACING_WIN_PATH="Z:${IRACING_STEAM_PATH//\//\\}"
    IRACING_WIN_PATH_DISPLAY=$(echo "$IRACING_WIN_PATH" | sed 's/\\/\&#92;/g')

    IRACING_DOWNLOAD_URL="https://members.iracing.com/download/member/noservice.jsp"

    gui_info "<b>iRacing stub detected — the full game files aren't installed yet.</b>

You'll need to run the iRacing Windows installer.  Here's what to do:

<b>Step 1:</b> Your browser is about to open the download page. Click the
download button on that page.

<i>Note: the page may open a new tab and then close it again on its own
once the download starts — that's normal for this site, not an error.
Don't worry if it happens.</i>

<b>Step 2:</b> Save it to your <b>Downloads</b> folder — that's the
<tt>Downloads</tt> folder in your file manager/home folder
(<tt>~/Downloads</tt>).
The filename looks like: <tt>iRacingInstaller_win_YYYY.MM.DD.NN.exe</tt>

<tt>──────────────────────────────────────────────────</tt>
<b>  Wait for the download to fully finish before clicking OK.</b>
<tt>──────────────────────────────────────────────────</tt>

Click OK to open the download page and continue."

    (xdg-open "$IRACING_DOWNLOAD_URL" >/dev/null 2>&1 &) 2>/dev/null
    log "Opened iRacing download page via xdg-open"

    find_latest_iracing_installer() {
        local f best="" best_key=""
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local base date_part key
            base=$(basename "$f")
            date_part="${base#iRacingInstaller_win_}"
            date_part="${date_part%.exe}"
            key=$(awk -F. '{ for (i=1;i<=NF;i++) printf "%04d.", $i }' <<<"$date_part")
            if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
                best="$f"
                best_key="$key"
            fi
        done < <(find "$HOME/Downloads" -maxdepth 1 -type f -size +1M -name 'iRacingInstaller_win_*.exe' 2>/dev/null)
        echo "$best"
    }

    INSTALLER_EXE=""
    installer_wait_attempt=0
    installer_silent_checks=4
    installer_patient_checks=6
    while [[ -z "$INSTALLER_EXE" ]]; do
        installer_wait_attempt=$((installer_wait_attempt + 1))
        INSTALLER_EXE=$(find_latest_iracing_installer)
        [[ -n "$INSTALLER_EXE" ]] && break

        if [[ $installer_wait_attempt -le $installer_silent_checks ]]; then
            sleep 2
        elif [[ $installer_wait_attempt -le $((installer_silent_checks + installer_patient_checks)) ]]; then
            gui_open "Still looking for the installer in Downloads...\n\nA real download can take a few minutes — hang tight."
            sleep 2
            gui_close
        else
            if ! zenity --question --title="$TITLE" --text="No iRacing installer found in ~/Downloads yet.\n\nHas the download finished? Click <b>Yes</b> to keep waiting, or <b>No</b> to quit." --ok-label="Yes, keep waiting" --cancel-label="No, quit" --width=500 2>/dev/null; then
                log "User quit at Step 6 while waiting for the installer download"
                exit 0
            fi
            installer_wait_attempt=0
        fi
    done

    log "Installer found after $installer_wait_attempt polling pass(es)"
    gui_info "Found installer: <tt>$(basename "$INSTALLER_EXE")</tt>

The installer will now run on its own and install iRacing to the
correct location in your Steam library:

<tt>$IRACING_WIN_PATH_DISPLAY</tt>

No action needed from you — it runs silently, and iRacing will
not launch automatically when it's done.

Click OK to begin."

    INSTALLER_SIZE_MB=$(du -sm "$INSTALLER_EXE" 2>/dev/null | cut -f1)
    log "Step 6 — installer file size: ${INSTALLER_SIZE_MB:-unknown} MB"

    ensure_steam_closed "<b>Steam needs to be closed before running the iRacing installer.</b>

Please close Steam now, then click OK."
    log "Steam confirmed closed before running Windows installer"

    log "Launching Windows installer: $INSTALLER_EXE -> $IRACING_STEAM_PATH"
    INSTALL_START_TS=$(date +%s)
    run_redacted "$TECH_LOG" protontricks-launch --appid "$IRACING_APPID" "$INSTALLER_EXE" \
        /SILENT /SUPPRESSMSGBOXES /NORESTART \
        /DIR="$IRACING_WIN_PATH" &
    INSTALL_PID=$!

    gui_wait $INSTALL_PID "Installing iRacing...\n\nDestination:\n<tt>$IRACING_WIN_PATH_DISPLAY</tt>\n\nThis will take a few minutes, please wait."
    wait "$INSTALL_PID"
    INSTALL_EXIT=$?
    INSTALL_ELAPSED=$(($(date +%s) - INSTALL_START_TS))
    log "Windows installer finished (exit $INSTALL_EXIT) after ${INSTALL_ELAPSED}s"

    gui_open "Verifying iRacing installation..."
    sleep 0.5
    gui_close

    if [[ ! -d "$IRACING_STEAM_PATH" ]] || [[ $(find "$IRACING_STEAM_PATH" -maxdepth 1 -type f | wc -l) -le 3 ]]; then
        log "[ERROR] Post-install check failed — $IRACING_STEAM_PATH missing or looks empty"
        gui_error "iRacing doesn't look like it installed correctly.

Expected location: <tt>$IRACING_STEAM_PATH</tt>

Please re-run the installer and make sure the install path is set to:

    <tt><b>$IRACING_WIN_PATH_DISPLAY</b></tt>"
    fi

    IRACING_INSTALLED_SIZE_MB=$(du -sm "$IRACING_STEAM_PATH" 2>/dev/null | cut -f1)
    log "Step 6 complete — install verified at $IRACING_STEAM_PATH"
    log "Step 6 — final install size: ${IRACING_INSTALLED_SIZE_MB:-unknown} MB"
    gui_info "<b>iRacing installation confirmed!</b>\n\nLocation: <tt>$IRACING_STEAM_PATH</tt>"
    SUMMARY_IRACING_FILES="Installed via Windows installer"
}

if [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    log "=== Step 6 — Direct Account Installation ==="
    
    INSTALL_DIR=""
    gui_open "Checking iRacing game files..."
    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")

    IRACING_STEAM_PATH=$(find_iracing_common_path "$INSTALL_DIR")
    if [[ -z "$IRACING_STEAM_PATH" ]]; then
        # Stub not created anywhere yet — default to the library the
        # appmanifest lives in, since that's where Steam will create it.
        IRACING_STEAM_PATH="$STEAM_APPS/common/$INSTALL_DIR"
    fi
    
    log "Step 6 paths: INSTALL_DIR=<$INSTALL_DIR> IRACING_STEAM_PATH=<$IRACING_STEAM_PATH> exists?=$([[ -d "$IRACING_STEAM_PATH" ]] && echo yes || echo no)"

    fully_installed=false
    stub_detected=false

    if [[ -d "$IRACING_STEAM_PATH" ]]; then
        all_found=true
        for entry in "${IRACING_FINGERPRINT[@]}"; do
            [[ ! -e "$IRACING_STEAM_PATH/$entry" ]] && {
                all_found=false
                break
            }
        done
        if $all_found; then
            fully_installed=true
        else
            FILE_COUNT=$(find "$IRACING_STEAM_PATH" -maxdepth 1 -type f | wc -l)
            DIR_SIZE=$(du -sb "$IRACING_STEAM_PATH" 2>/dev/null)
            DIR_SIZE="${DIR_SIZE%%$'\t'*}"
            [[ "$FILE_COUNT" -le 3 && "$DIR_SIZE" -lt 5000 ]] && stub_detected=true
        fi
    fi
    gui_close
    
    log "Step 6 decision vars: fully_installed=<$fully_installed> stub_detected=<$stub_detected> IRACING_STEAM_PATH=<$IRACING_STEAM_PATH> exists?=$([[ -d "$IRACING_STEAM_PATH" ]] && echo yes || echo no)"
    
    if $fully_installed; then
        gui_info "<b>iRacing is already fully installed.</b>\n\nLocation: <tt>$IRACING_STEAM_PATH</tt>"
        SUMMARY_IRACING_FILES="Files complete"
    elif $stub_detected || [[ ! -d "$IRACING_STEAM_PATH" ]]; then
        run_iracing_windows_installer_flow
    else
        # Partial install: directory exists but fingerprint missing -> run installer anyway
        log "Partial install state detected (dir exists but fingerprint incomplete). Forcing installer flow."
        stub_detected=true
        run_iracing_windows_installer_flow
    fi
fi

# =============================================================================
# STEP 7 — Install Proton/Wine libraries
# =============================================================================
log "=== Step 7 — Proton Libraries ==="

# Steam may have been reopened during Steps 5-7 (installing/verifying
# iRacing), so re-confirm it's closed before running protontricks.
ensure_steam_closed "<b>Steam needs to be closed before installing Proton libraries.</b>

Please close Steam now, then click OK."
log "Steam re-confirmed closed before Step 7"

: >"$PROTONTRICKS_LOG.list"
(run_redacted "$PROTONTRICKS_LOG.list" protontricks "$IRACING_APPID" list-installed) &
gui_wait $! "Checking installed Proton libraries..."

INSTALLED_LIST=$(cat "$PROTONTRICKS_LOG.list" 2>/dev/null || true)
rm -f "$PROTONTRICKS_LOG.list"

REQUIRED_PKGS=(
    vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022
    d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact xact_x64 xaudio29
)

MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! echo "$INSTALLED_LIST" | grep -qw "$pkg"; then
        MISSING+=("$pkg")
    fi
done
log "Proton library check: ${#MISSING[@]} of ${#REQUIRED_PKGS[@]} required libraries missing (${MISSING[*]:-none})"

# original line with both font packages:
# Install <b>corefonts</b> and <b>allfonts</b>?
if gui_question "  <b>Optional Fonts</b>

Install <b>corefonts</b>?

These aren't required to play iRacing, but without them you might see
text rendering oddly in-game or in the UI.

⚠️  Warning: installing these can take a very long time.

Click Yes to install fonts, No to skip." "cancel"; then
    # commented out for disabling allfonts
    #    for font_pkg in corefonts allfonts; do
    #        if ! echo "$INSTALLED_LIST" | grep -qw "$font_pkg"; then
    #            MISSING+=("$font_pkg")
    #        fi
    #    done
    if ! echo "$INSTALLED_LIST" | grep -qw "corefonts"; then
        MISSING+=("corefonts")
    fi
    log "Step 7 — user opted in to installing corefonts"
else
    log "Step 7 — user declined optional fonts"
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
    log "Step 7 complete — all ${#REQUIRED_PKGS[@]} required Proton libraries already present"
    gui_info "<b>All required Proton libraries are already installed.</b>"
    SUMMARY_PROTON_LIBS="All ${#REQUIRED_PKGS[@]} libraries already present"
else
    gui_info "⏳ <b>Installing ${#MISSING[@]} Proton library/libraries...</b>

This can take several minutes.

Libraries to install:
<tt>${MISSING[*]}</tt>

Click OK and a progress window will appear."

    PT_START_TS=$(date +%s)
    : >"$PROTONTRICKS_LOG"
    run_redacted "$PROTONTRICKS_LOG" protontricks "$IRACING_APPID" -q --force "${MISSING[@]}" &
    PT_PID=$!
    gui_wait $PT_PID "Installing Proton libraries...\n\nThis can take several minutes, please wait."
    wait "$PT_PID"
    PT_EXIT=$?
    PT_ELAPSED=$(( $(date +%s) - PT_START_TS ))

    if [[ $PT_EXIT -ne 0 ]]; then
        log "[ERROR] protontricks force-install failed (exit $PT_EXIT) after ${PT_ELAPSED}s — see $PROTONTRICKS_LOG"
        gui_error "❌ protontricks hit an error (code $PT_EXIT).\n\nCheck the log for details:\n<tt>$PROTONTRICKS_LOG</tt>"
    fi

    log "Step 7 complete — ${#MISSING[@]} Proton libraries installed successfully in ${PT_ELAPSED}s"
    gui_info "<b>All required Proton libraries are now installed.</b>"
    SUMMARY_PROTON_LIBS="${#MISSING[@]} libraries installed"
fi

# =============================================================================
# STEP 8 — Install custom Proton build
# =============================================================================
log "=== Step 8 — Custom Proton Build ==="

mkdir -p "$COMPAT_TOOLS_DIR"

# NOTE: deliberately NOT using api.github.com here — the REST API is capped
# at 60 unauthenticated requests/hour per source IP, which is easy to hit
# on shared/NAT'd connections (or just from repeatedly testing this
# script). github.com/<repo>/releases/latest is a plain web redirect, not
# part of the API, and isn't subject to that limit. The tag is resolved
# from the redirect's Location header, then the asset URL is built by
# convention (tag name == archive base name) instead of asking the API
# to enumerate release assets.
GH_REPO="DanFraserUK/proton-cachyos"

(run_redacted "$TECH_LOG" curl -fsSL -o /dev/null \
    -D /tmp/iracing_latest_headers.txt \
    "https://github.com/${GH_REPO}/releases/latest") &
gui_wait $! "Checking for the latest custom Proton build..."

LATEST_TAG=$(grep -i '^location:' /tmp/iracing_latest_headers.txt 2>/dev/null | tail -n1 | sed -E 's#.*/releases/tag/([^[:space:]/]+).*#\1#' | tr -d '\r')
rm -f /tmp/iracing_latest_headers.txt

if [[ -z "$LATEST_TAG" ]]; then
    log "[ERROR] Couldn't resolve latest release tag from github.com redirect"
    gui_error "❌ Couldn't reach GitHub.\n\nPlease check your internet connection and try again.\n\nManual download:\n<tt>https://github.com/${GH_REPO}/releases</tt>\n\nExtract to: <tt>$COMPAT_TOOLS_DIR</tt>"
fi

log "Latest release tag resolved via redirect: $LATEST_TAG"

PROTON_DIR_NAME="$LATEST_TAG"
TARBALL_NAME="${PROTON_DIR_NAME}.tar.xz"
TARBALL_URL="https://github.com/${GH_REPO}/releases/download/${LATEST_TAG}/${TARBALL_NAME}"
TARBALL_TMP="/tmp/$TARBALL_NAME"
log "Latest release asset: $TARBALL_NAME"

if [[ -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
    gui_open "Verifying existing Proton build..."
    verify_proton_build "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" "$LATEST_TAG"
    verify_result=$?
    gui_close

    case $verify_result in
    0)
        log "Step 8 complete — $PROTON_DIR_NAME already present and verified, skipping download"
        gui_info "<b>Custom Proton build is already installed and verified.</b>\n\n<tt>$PROTON_DIR_NAME</tt>"
        SUMMARY_PROTON_BUILD="Already installed, verified ($PROTON_DIR_NAME)"
        NEED_PROTON_DOWNLOAD=false
        ;;
    1)
        log "Existing Proton build failed integrity check — removing and will redownload"
        gui_warn "<b>The installed custom Proton build looks corrupted</b> (failed an integrity check).

This can happen after an interrupted extraction — for example, running low on disk space partway through.

It'll be automatically redownloaded now."
        rm -rf "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME"
        NEED_PROTON_DOWNLOAD=true
        ;;
    2)
        log "No manifest available for $LATEST_TAG — treating existing folder as installed without verification"
        gui_info "<b>Custom Proton build is already installed.</b>\n\n<tt>$PROTON_DIR_NAME</tt>\n\n<i>(No integrity manifest available for this release, so this couldn't be verified.)</i>"
        SUMMARY_PROTON_BUILD="Already installed, unverified ($PROTON_DIR_NAME)"
        NEED_PROTON_DOWNLOAD=false
        ;;
    esac
else
    NEED_PROTON_DOWNLOAD=true
fi

if $NEED_PROTON_DOWNLOAD; then
    DL_START_TS=$(date +%s)
    (run_redacted "$TECH_LOG" curl -fsSL -o "$TARBALL_TMP" "$TARBALL_URL") &
    DL_PID=$!
    gui_wait $DL_PID "Downloading custom Proton build...\n\n<tt>$TARBALL_NAME</tt>"
    wait "$DL_PID"
    DL_EXIT=$?
    DL_ELAPSED=$(( $(date +%s) - DL_START_TS ))

    if [[ $DL_EXIT -ne 0 ]] || [[ ! -s "$TARBALL_TMP" ]]; then
        log "[ERROR] Proton build download failed (exit $DL_EXIT) after ${DL_ELAPSED}s"
        rm -f "$TARBALL_TMP"
        gui_error "❌ Download failed.\n\nPlease check your internet connection and try again."
    fi
    TARBALL_SIZE_MB=$(du -sm "$TARBALL_TMP" 2>/dev/null | cut -f1)
    log "Downloaded $TARBALL_NAME successfully (${TARBALL_SIZE_MB:-unknown} MB in ${DL_ELAPSED}s)"

    # Snapshot existing top-level dirs so the newly-extracted one can be
    # spotted even if the tarball's internal folder name doesn't match its
    # filename.
    DIRS_BEFORE=$(find "$COMPAT_TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    (run_redacted "$TECH_LOG" tar -xf "$TARBALL_TMP" -C "$COMPAT_TOOLS_DIR") &
    TAR_PID=$!
    gui_wait $TAR_PID "Extracting Proton build...\n\nAlmost done!"
    wait "$TAR_PID"
    TAR_EXIT=$?
    rm -f "$TARBALL_TMP"

    if [[ $TAR_EXIT -ne 0 ]]; then
        log "[ERROR] tar extraction failed (exit $TAR_EXIT)"
        gui_error "❌ Extraction failed.\n\nCheck the log:\n<tt>$TECH_LOG</tt>"
    fi

    if [[ ! -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
        DIRS_AFTER=$(find "$COMPAT_TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
        ACTUAL_DIR=$(comm -13 <(echo "$DIRS_BEFORE") <(echo "$DIRS_AFTER") | head -n1)
        if [[ -n "$ACTUAL_DIR" ]]; then
            log "Expected folder name '$PROTON_DIR_NAME' not found after extraction — using actual extracted folder '$(basename "$ACTUAL_DIR")' instead"
            PROTON_DIR_NAME=$(basename "$ACTUAL_DIR")
        else
            log "[ERROR] Extraction finished but no new folder found in $COMPAT_TOOLS_DIR"
            gui_error "❌ Extraction finished but the expected folder wasn't there.\n\nExpected: <tt>$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME</tt>\n\nCheck <tt>$COMPAT_TOOLS_DIR</tt> by hand and pick the extracted folder as your compatibility tool in Steam."
        fi
    fi

    EXTRACTED_SIZE_MB=$(du -sm "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" 2>/dev/null | cut -f1)

    # Verify the fresh extraction immediately — catches a bad
    # download/extraction (e.g. disk ran out of space mid-write) right
    # now, loudly, instead of it silently sitting there as "installed"
    # and only surfacing weeks later as a cryptic protontricks traceback.
    gui_open "Verifying extracted Proton build..."
    verify_proton_build "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" "$LATEST_TAG"
    fresh_verify_result=$?
    gui_close

    case $fresh_verify_result in
    1)
        log "[ERROR] Freshly extracted build failed integrity check — download or extraction was corrupted"
        rm -rf "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME"
        gui_error "❌ The downloaded Proton build failed an integrity check after extracting.

This usually means the download or extraction was interrupted — for example, running low on disk space partway through.

Please check available disk space, then re-run this setup to try again."
        ;;
    2)
        log "No manifest available for $LATEST_TAG — skipping post-extraction verification"
        ;;
    *)
        log "Fresh extraction verified against manifest"
        ;;
    esac

    log "Step 8 complete — custom Proton build installed as $PROTON_DIR_NAME (${EXTRACTED_SIZE_MB:-unknown} MB extracted)"
    gui_info "<b>Custom Proton build installed!</b>\n\n<tt>$PROTON_DIR_NAME</tt>"
    SUMMARY_PROTON_BUILD="Installed ($PROTON_DIR_NAME)"
fi

# =============================================================================
# STEP 9 — Auto-configure compatibility tool & launch options
# =============================================================================
# Best-effort: attempts a narrowly scoped edit to config.vdf (compat tool
# override) and localconfig.vdf (launch options), verifies the write
# actually landed, and restores from a fresh backup if anything looks
# wrong. Falls back to manual instructions on the final screen for
# anything it can't safely automate — most notably if CompatToolMapping
# doesn't exist in config.vdf at all yet, in which case this deliberately
# avoids constructing that nesting from scratch.
log "=== Step 9 — Auto-Configuring Compatibility Tool & Launch Options ==="

SUMMARY_COMPAT_CONFIG="Not attempted"
SUMMARY_LAUNCH_OPTIONS="Not attempted"
IRACING_LAUNCH_OPTIONS='PROTON_LOG=1 LD_PRELOAD=\"\" %command%'

ensure_steam_closed "<b>Steam needs to be closed before we can auto-configure the compatibility tool and launch options.</b>

Please close Steam now, then click OK."
log "Steam re-confirmed closed before Step 9"

# Belt and braces: Steam rewrites both these files on every launch/exit,
# so re-check immediately before writing rather than trusting the check
# from a moment ago — a stray steam:// trigger or the user reopening it
# manually is a real possibility this deep into the script.
if pgrep -x steam &>/dev/null; then
    log "[ERROR] Step 9 — Steam still running immediately before config write, skipping automatic edit entirely"
    SUMMARY_COMPAT_CONFIG="Skipped — Steam was running"
    SUMMARY_LAUNCH_OPTIONS="Skipped — Steam was running"
else
    CONFIG_VDF="$STEAM_ROOT/config/config.vdf"
    BACKUP_TS=$(date '+%Y%m%d-%H%M%S')

    # --- Compatibility tool (config.vdf) ---
    if [[ -f "$CONFIG_VDF" ]]; then
        ctm=$(vdf_descend "$CONFIG_VDF" "InstallConfigStore" "Software" "Valve" "Steam" "CompatToolMapping" || true)
        if [[ -n "$ctm" ]]; then
            read -r _ ctm_start ctm_end <<<"$ctm"
            cp "$CONFIG_VDF" "$CONFIG_VDF.bak-$BACKUP_TS"
            log "Backed up config.vdf to config.vdf.bak-$BACKUP_TS"
            prune_old_backups "$CONFIG_VDF"

            appid_block=$(vdf_find_key_block "$CONFIG_VDF" "$((ctm_start + 1))" "$((ctm_end - 1))" "$IRACING_APPID")
            if [[ -n "$appid_block" ]]; then
                read -r _ a_start a_end <<<"$appid_block"
                OLD_COMPAT_NAME=$(sed -n "$((a_start + 1)),$((a_end - 1))p" "$CONFIG_VDF" | grep '"name"' | sed -E 's/.*"name"[^"]*"([^"]*)".*/\1/')
                vdf_set_kv "$CONFIG_VDF" "$((a_start + 1))" "$((a_end - 1))" "name" "$PROTON_DIR_NAME"
                if [[ "$OLD_COMPAT_NAME" == "$PROTON_DIR_NAME" ]]; then
                    log "Updated existing CompatToolMapping entry for $IRACING_APPID (unchanged: '$PROTON_DIR_NAME')"
                else
                    log "Updated existing CompatToolMapping entry for $IRACING_APPID (was: '${OLD_COMPAT_NAME:-<empty>}' -> now: '$PROTON_DIR_NAME')"
                fi
            else
                tmp_block=$(mktemp)
                printf '\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}\n' \
                    "$IRACING_APPID" "$PROTON_DIR_NAME" >"$tmp_block"
                sed -i "${ctm_start}r $tmp_block" "$CONFIG_VDF"
                rm -f "$tmp_block"
                log "Inserted new CompatToolMapping entry for $IRACING_APPID"
            fi

            verify_ok=false
            if vdf_brace_balanced "$CONFIG_VDF"; then
                ctm2=$(vdf_descend "$CONFIG_VDF" "InstallConfigStore" "Software" "Valve" "Steam" "CompatToolMapping" || true)
                if [[ -n "$ctm2" ]]; then
                    read -r _ ctm2_start ctm2_end <<<"$ctm2"
                    appid_block2=$(vdf_find_key_block "$CONFIG_VDF" "$((ctm2_start + 1))" "$((ctm2_end - 1))" "$IRACING_APPID")
                    if [[ -n "$appid_block2" ]]; then
                        read -r _ a2_start a2_end <<<"$appid_block2"
                        sed -n "${a2_start},${a2_end}p" "$CONFIG_VDF" | grep -qF "\"$PROTON_DIR_NAME\"" && verify_ok=true
                    fi
                fi
            fi

            if $verify_ok; then
                SUMMARY_COMPAT_CONFIG="Auto-configured ($PROTON_DIR_NAME)"
                log "Step 9 — compatibility tool auto-configured to $PROTON_DIR_NAME (verified)"
            else
                cp "$CONFIG_VDF.bak-$BACKUP_TS" "$CONFIG_VDF"
                SUMMARY_COMPAT_CONFIG="Auto-config failed — restored from backup"
                log "[ERROR] Step 9 — compat tool write verification failed, restored config.vdf from backup"
            fi
        else
            SUMMARY_COMPAT_CONFIG="Not found — CompatToolMapping section missing"
            log "Step 9 — CompatToolMapping section not found in config.vdf, skipping automatic edit"
        fi
    else
        SUMMARY_COMPAT_CONFIG="Not found — config.vdf missing"
        log "Step 9 — config.vdf not found at $CONFIG_VDF"
    fi

    # --- Launch options (localconfig.vdf) — both Steam Purchase and
    # Direct Account get PROTON_LOG=1 now, for the same reason: it's the
    # single most useful thing to have already in place if launch issues
    # come up later. ---
    STEAMID3=$(resolve_steamid3 || true)
    if [[ -n "$STEAMID3" ]]; then
        LOCALCONFIG_VDF="$STEAM_ROOT/userdata/$STEAMID3/config/localconfig.vdf"
        if [[ -f "$LOCALCONFIG_VDF" ]]; then
            apps_block=$(vdf_descend "$LOCALCONFIG_VDF" "UserLocalConfigStore" "Software" "Valve" "Steam" "apps" || true)
            if [[ -n "$apps_block" ]]; then
                read -r _ apps_start apps_end <<<"$apps_block"
                cp "$LOCALCONFIG_VDF" "$LOCALCONFIG_VDF.bak-$BACKUP_TS"
                log "Backed up localconfig.vdf to localconfig.vdf.bak-$BACKUP_TS"
                prune_old_backups "$LOCALCONFIG_VDF"

                app_block=$(vdf_find_key_block "$LOCALCONFIG_VDF" "$((apps_start + 1))" "$((apps_end - 1))" "$IRACING_APPID")
                if [[ -z "$app_block" ]]; then
                    # Build the new block already containing LaunchOptions in
                    # one insert, rather than inserting an empty {} shell and
                    # then calling vdf_set_kv on it — an empty block's open
                    # and close braces are adjacent lines, which produces an
                    # inverted (invalid) content range and silently misplaces
                    # the insert outside the block.
                    tmp_block=$(mktemp)
                    printf '\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"LaunchOptions"\t\t"%s"\n\t\t\t\t\t}\n' \
                        "$IRACING_APPID" "$IRACING_LAUNCH_OPTIONS" >"$tmp_block"
                    sed -i "${apps_start}r $tmp_block" "$LOCALCONFIG_VDF"
                    rm -f "$tmp_block"
                    log "Inserted new apps entry for $IRACING_APPID (with LaunchOptions) in localconfig.vdf"
                else
                    read -r _ ab_start ab_end <<<"$app_block"
                    OLD_LAUNCH_OPTIONS=$(sed -n "$((ab_start + 1)),$((ab_end - 1))p" "$LOCALCONFIG_VDF" | grep '"LaunchOptions"' | sed -E 's/.*"LaunchOptions"[^"]*"(.*)"[[:space:]]*$/\1/')
                    vdf_set_kv "$LOCALCONFIG_VDF" "$((ab_start + 1))" "$((ab_end - 1))" "LaunchOptions" "$IRACING_LAUNCH_OPTIONS"
                    if [[ "$OLD_LAUNCH_OPTIONS" == "$IRACING_LAUNCH_OPTIONS" ]]; then
                        log "Updated existing LaunchOptions entry for $IRACING_APPID (unchanged)"
                    else
                        log "Updated existing LaunchOptions entry for $IRACING_APPID (was: '${OLD_LAUNCH_OPTIONS:-<empty>}' -> now includes PROTON_LOG=1)"
                    fi
                fi

                verify_ok=false
                if vdf_brace_balanced "$LOCALCONFIG_VDF"; then
                    apps_block2=$(vdf_descend "$LOCALCONFIG_VDF" "UserLocalConfigStore" "Software" "Valve" "Steam" "apps" || true)
                    if [[ -n "$apps_block2" ]]; then
                        read -r _ apps2_start apps2_end <<<"$apps_block2"
                        app_block2=$(vdf_find_key_block "$LOCALCONFIG_VDF" "$((apps2_start + 1))" "$((apps2_end - 1))" "$IRACING_APPID")
                        if [[ -n "$app_block2" ]]; then
                            read -r _ ab2_start ab2_end <<<"$app_block2"
                            sed -n "${ab2_start},${ab2_end}p" "$LOCALCONFIG_VDF" | grep -qF "PROTON_LOG=1" && verify_ok=true
                        fi
                    fi
                fi

                if $verify_ok; then
                    SUMMARY_LAUNCH_OPTIONS="Auto-configured (PROTON_LOG=1)"
                    log "Step 9 — launch options auto-configured (verified)"
                else
                    cp "$LOCALCONFIG_VDF.bak-$BACKUP_TS" "$LOCALCONFIG_VDF"
                    SUMMARY_LAUNCH_OPTIONS="Auto-config failed — restored from backup"
                    log "[ERROR] Step 9 — launch options write verification failed, restored localconfig.vdf from backup"
                fi
            else
                SUMMARY_LAUNCH_OPTIONS="Not found — apps section missing"
                log "Step 9 — 'apps' section not found in localconfig.vdf, skipping automatic edit"
            fi
        else
            SUMMARY_LAUNCH_OPTIONS="Not found — localconfig.vdf missing"
            log "Step 9 — localconfig.vdf not found at $LOCALCONFIG_VDF"
        fi
    else
        SUMMARY_LAUNCH_OPTIONS="Not found — couldn't resolve Steam account folder"
        log "Step 9 — could not resolve steamid3 under $STEAM_ROOT/userdata"
    fi
fi

gui_info "<b>Compatibility tool:</b> $SUMMARY_COMPAT_CONFIG
<b>Launch options:</b> $SUMMARY_LAUNCH_OPTIONS

If either of those says anything other than auto-configured, you'll find manual instructions for it on the final screen."

log "Step 9 complete — compat config: $SUMMARY_COMPAT_CONFIG | launch options: $SUMMARY_LAUNCH_OPTIONS"

# =============================================================================
# STEP 10 — Optional extras
# =============================================================================
log "=== Step 10 — Optional Extras ==="

# --- Backup /etc/hosts before touching it ---
if [[ ! -f /etc/hosts.bak ]]; then
    (run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" cp /etc/hosts /etc/hosts.bak) &
    gui_wait $! "Backing up /etc/hosts...\n\nA password prompt window may appear — enter your password there if asked."
    log "Backed up /etc/hosts to /etc/hosts.bak"
else
    log "/etc/hosts.bak already exists — skipping backup"
fi

HOSTS_ENTRY="0.0.0.0 modules-cdn.eac-prod.on.epicgames.com"

# The Proton prefix (compatdata) lives in whichever Steam library iRacing was
# installed to — not necessarily the default library — so search all of them
# the same way find_iracing_common_path() does, rather than hardcoding a path.
find_iracing_compatdata_path() {
    local lib candidate
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        candidate="$lib/steamapps/compatdata/$IRACING_APPID/pfx/drive_c/users/steamuser/Documents/iRacing"
        [[ -d "$candidate" ]] && {
            echo "$candidate"
            return 0
        }
    done < <(get_steam_libraries)
    return 1
}

IRACING_DOCS=$(find_iracing_compatdata_path)
if [[ -z "$IRACING_DOCS" ]]; then
    # Not created yet in any library — default to where Steam will create it
    # for the default library, so the "not found yet" message below shows a
    # sensible path even before the first launch.
    IRACING_DOCS="$STEAM_APPS/compatdata/$IRACING_APPID/pfx/drive_c/users/steamuser/Documents/iRacing"
    log "iRacing Documents folder not found in any library yet — defaulting to $IRACING_DOCS"
else
    log "iRacing Documents folder found at $IRACING_DOCS"
fi
DOCS_LINK="$HOME/Documents/iRacing"

# --- EAC Workaround ---
if grep -qF "$HOSTS_ENTRY" /etc/hosts; then
    log "EAC hosts entry already present in /etc/hosts"
    if gui_question "The EAC (Easy Anti-Cheat) network workaround is already applied.

Want to <b>remove</b> it?" "cancel"; then
        (
            hosts_content=""
            while IFS= read -r hosts_line; do
                [[ "$hosts_line" != "$HOSTS_ENTRY" ]] && hosts_content+="$hosts_line"$'\n'
            done </etc/hosts
            echo -n "$hosts_content" | "${RUN_AS_ROOT[@]}" tee /etc/hosts >/dev/null
        ) &
        gui_wait $! "Removing EAC hosts entry...\n\nA password prompt window may appear — enter your password there if asked."
        log "EAC hosts entry removed"
        gui_info "The EAC workaround has been removed from /etc/hosts."
        SUMMARY_EAC="Removed"
    else
        log "User chose to keep the existing EAC hosts entry"
        SUMMARY_EAC="Already applied (kept)"
    fi
else
    log "No EAC hosts entry present — asking user whether to apply it"
    if gui_question "<b>EAC (Easy Anti-Cheat) Network Workaround</b>

This blocks the EAC CDN by adding one line to your /etc/hosts file.

<b>!! At your own risk:</b> circumventing anti-cheat software could
potentially get your account banned.

Want to apply this workaround?" "cancel"; then
        (echo "$HOSTS_ENTRY" | "${RUN_AS_ROOT[@]}" tee -a /etc/hosts >/dev/null) &
        gui_wait $! "Applying EAC workaround...\n\nA password prompt window may appear — enter your password there if asked."
        log "EAC hosts entry applied"
        gui_info "EAC workaround applied."
        SUMMARY_EAC="Applied"
    else
        log "User declined the EAC workaround"
        SUMMARY_EAC="Skipped"
    fi
fi

# --- Documents symlink ---
if [[ -L "$DOCS_LINK" ]]; then
    log "~/Documents/iRacing shortcut already exists"
    gui_info "<b>~/Documents/iRacing shortcut already exists.</b>"
    SUMMARY_DOCS="Already exists"
elif [[ -d "$IRACING_DOCS" && ! -e "$DOCS_LINK" ]]; then
    if gui_question "<b>iRacing Documents Shortcut</b>

Steam on Linux stores your iRacing settings, car setups, and replays
deep inside a hidden folder.  Want a shortcut created at:

<tt>~/Documents/iRacing</tt>

This makes it easy to get to your setups and replays."; then
        ln -s "$IRACING_DOCS" "$DOCS_LINK"
        log "Documents shortcut created"
        gui_info "Shortcut created at <tt>~/Documents/iRacing</tt>"
        SUMMARY_DOCS="Created"
    else
        log "User declined the Documents shortcut"
        SUMMARY_DOCS="Skipped"
    fi
else
    log "iRacing Documents folder doesn't exist yet — can't offer the shortcut"
    gui_warn "iRacing's Documents folder doesn't exist yet.\n\nLaunch iRacing once to create it, then you can make the shortcut by hand:\n\n<tt>ln -s \"$IRACING_DOCS\" \"$DOCS_LINK\"</tt>"
    SUMMARY_DOCS="Not yet - launch iRacing first"
fi

log "Step 10 complete — EAC: $SUMMARY_EAC | docs shortcut: $SUMMARY_DOCS"

# =============================================================================
# DONE — Summary screen then final instructions
# =============================================================================

# Build the summary text
SUMMARY_TEXT="<b>Setup Summary</b>
<tt>─────────────────────────────────────────────────────</tt>
<tt>Steam &amp; protontricks  </tt>${SUMMARY_PACKAGES}
<tt>Steam login           </tt>${SUMMARY_LOGIN}
<tt>iRacing type          </tt>${SUMMARY_IRACING_TYPE}
<tt>iRacing files         </tt>${SUMMARY_IRACING_FILES}
<tt>Proton libraries      </tt>${SUMMARY_PROTON_LIBS}
<tt>Custom Proton build   </tt>${SUMMARY_PROTON_BUILD}
<tt>Compatibility tool    </tt>${SUMMARY_COMPAT_CONFIG}
<tt>Launch options        </tt>${SUMMARY_LAUNCH_OPTIONS}
<tt>EAC workaround        </tt>${SUMMARY_EAC}
<tt>Documents shortcut    </tt>${SUMMARY_DOCS}
<tt>─────────────────────────────────────────────────────</tt>"

log "Setup summary — packages: $SUMMARY_PACKAGES | login: $SUMMARY_LOGIN | type: $SUMMARY_IRACING_TYPE | files: $SUMMARY_IRACING_FILES | proton libs: $SUMMARY_PROTON_LIBS | proton build: $SUMMARY_PROTON_BUILD | compat config: $SUMMARY_COMPAT_CONFIG | launch options: $SUMMARY_LAUNCH_OPTIONS | EAC: $SUMMARY_EAC | docs shortcut: $SUMMARY_DOCS"
gui_info "$SUMMARY_TEXT"

# Only show manual instructions for whichever half of Step 9 didn't
# succeed automatically — a fully-automated run shouldn't ask the user to
# redo work that's already done and verified.
COMPAT_DONE=false
[[ "$SUMMARY_COMPAT_CONFIG" == Auto-configured* ]] && COMPAT_DONE=true
LAUNCH_DONE=false
[[ "$SUMMARY_LAUNCH_OPTIONS" == Auto-configured* ]] && LAUNCH_DONE=true

if $COMPAT_DONE && $LAUNCH_DONE; then
    FINAL_STEPS="<b>Compatibility tool and launch options were already set for you</b> — <tt>$PROTON_DIR_NAME</tt> with <tt>PROTON_LOG=1</tt> enabled for troubleshooting.

Open Steam and you're ready to race.

If you ever want to double-check: Right-click iRacing -> Properties -> Compatibility, and Properties -> General -> Launch Options."
else
    MANUAL_STEPS=""
    if ! $COMPAT_DONE; then
        MANUAL_STEPS="${MANUAL_STEPS}
Right-click iRacing -> Properties -> Compatibility
Tick: <i>Force the use of a specific Steam Play compatibility tool</i>
Select: <b>$PROTON_DIR_NAME</b>
"
    fi
    if ! $LAUNCH_DONE; then
        MANUAL_STEPS="${MANUAL_STEPS}
Right-click iRacing -> Properties -> General -> Launch Options, paste:

    <tt><b>PROTON_LOG=1 LD_PRELOAD=\"\" %command%</b></tt>

<i>(highlight the line above to copy with CTRL+C, then paste with CTRL+V)</i>
"
    fi
    FINAL_STEPS="<b>If Steam is currently open, fully close it and reopen it now.</b>
New Proton/compatibility tools won't show up until Steam's been restarted.

<b>A couple of things couldn't be set automatically this run — please do these by hand:</b>
$MANUAL_STEPS"
fi

gui_info "<b>All done!</b>

$FINAL_STEPS

This was for you Pabs ❤️
Open Steam and enjoy your racing!"
# ^ Dedicated to PabloPGZ — the reason this script exists in the first place.
# Also just a little joke for whoever runs it.  Feel free to leave it in :)

SCRIPT_ELAPSED=$(( $(date +%s) - SCRIPT_START_TS ))
SCRIPT_ELAPSED_FMT=$(printf '%dm%02ds' $((SCRIPT_ELAPSED / 60)) $((SCRIPT_ELAPSED % 60)))
log "Setup complete — compatibility tool: $PROTON_DIR_NAME | compat auto-config: $COMPAT_DONE | launch options auto-config: $LAUNCH_DONE | total runtime: $SCRIPT_ELAPSED_FMT"
