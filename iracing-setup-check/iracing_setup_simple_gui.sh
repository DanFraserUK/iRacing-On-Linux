#!/usr/bin/env bash
# =============================================================================
# iRacing Setup — Simple Edition (Zenity GUI)
# Assumes: fresh distro install, Steam in $HOME/.steam/steam, single library
# Supports: Arch / CachyOS / EndeavourOS / Debian / Ubuntu / Fedora / Nobara
# =============================================================================
#
# VERSIONING: SCRIPT_VERSION below uses CalVer (YYYY.MM.DD, with a .N
# suffix if shipping more than once in a day). Bump it on every change
# and tag the matching commit (e.g. `git tag v2026.07.24`) — the version
# is logged as the very first line of every run, so any log a user sends
# in shows at a glance which revision produced it.
SCRIPT_VERSION="2026.08.05.1"
SCRIPT_START_TS=$(date +%s)

# --- Arguments ---
# Dry run: every check and dialog, nothing that writes, installs or
# launches Proton. Skipped actions log a DRY-RUN line, so the log reads
# as what a real run would have done. Beats testing against a real
# Steam install every time.
DRY_RUN=false
TEST_MODE=false
for arg in "$@"; do
    case "$arg" in
    -d | --dryrun | --dry-run)
        DRY_RUN=true
        ;;
    -t | --test)
        TEST_MODE=true
        ;;
    -h | --help)
        echo "iRacing Setup — Simple Edition (v$SCRIPT_VERSION)"
        echo
        echo "  usage: $(basename "$0") [-d|--dryrun] [-t|--test]"
        echo
        echo "  -d, --dryrun   Walk the whole flow without changing anything"
        echo "  -t, --test     Report on an existing install and exit"
        echo "  -h, --help     Show this message"
        exit 0
        ;;
    *)
        echo "Unknown argument: $arg (try --help)" >&2
        exit 1
        ;;
    esac
done

# --- Paths ---
# ~/.steam/steam is a symlink on most distros. Canonicalise so paths from
# here and paths from libraryfolders.vdf spell the same directory the same
# way - otherwise sort -u in get_steam_libraries can't dedupe them.
STEAM_ROOT="$HOME/.steam/steam"
[[ -e "$STEAM_ROOT" ]] && STEAM_ROOT=$(realpath -q "$STEAM_ROOT" 2>/dev/null || echo "$STEAM_ROOT")
STEAM_APPS="$STEAM_ROOT/steamapps"
COMPAT_TOOLS_DIR="$STEAM_ROOT/compatibilitytools.d"
IRACING_APPID="266410"
# Resolved properly (locale-aware) once the helpers are defined, below.
DOWNLOADS_DIR="$HOME/Downloads"

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

# noclobber makes the create atomic: two instances racing can't both
# decide the lock is stale and both take it. Storing the PID and the
# process start time (field 22 of /proc/PID/stat) together means a
# recycled PID can't make a fresh run refuse to start.
lock_holder_alive() {
    local pid="$1" started="$2" now_started
    [[ -z "$pid" ]] && return 1
    [[ -r "/proc/$pid/stat" ]] || return 1
    now_started=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
    [[ -n "$now_started" && "$now_started" == "$started" ]]
}

my_start_time() { awk '{print $22}' "/proc/$$/stat" 2>/dev/null; }

take_lock() {
    set -o noclobber
    if { printf '%s %s\n' "$$" "$(my_start_time)" >"$LOCKFILE"; } 2>/dev/null; then
        set +o noclobber
        return 0
    fi
    set +o noclobber
    return 1
}

if ! take_lock; then
    read -r EXISTING_PID EXISTING_START <"$LOCKFILE" 2>/dev/null || true
    if lock_holder_alive "$EXISTING_PID" "$EXISTING_START"; then
        LOCK_MSG="iRacing Setup is already running (PID $EXISTING_PID).

Please wait for that run to finish, or close it, before starting another."
        if command -v zenity &>/dev/null; then
            zenity --error --title="iRacing Setup — by Dan Fraser" --text="$LOCK_MSG" --width=500 2>/dev/null
        else
            echo "$LOCK_MSG" >&2
        fi
        exit 1
    fi
    # Stale lock (dead process, or a recycled PID) — clear and retake.
    rm -f "$LOCKFILE"
    if ! take_lock; then
        echo "Could not create lock file at $LOCKFILE — check permissions on ${XDG_RUNTIME_DIR:-/tmp}." >&2
        exit 1
    fi
fi

# Minimal early cleanup in case the script dies before the fuller
# cleanup_and_exit trap (defined later, once gui_close exists) takes over.
trap 'rm -f "$LOCKFILE" 2>/dev/null' EXIT INT TERM

# --- Log ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERAL_LOG="$SCRIPT_DIR/danfrasers-iracing-setup.log"
# Named for what it holds rather than which step number produces it —
# step numbers move, and a log called "step7" that's written by Step 10
# is worse than no hint at all.
PROTONTRICKS_LOG="$SCRIPT_DIR/danfrasers-iracing-protontricks.log"
PROTON_BOOTSTRAP_LOG="$SCRIPT_DIR/danfrasers-iracing-prefix.log"
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
    # STEAMID3 (set in Step 11, once resolved) is a persistent per-account
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
$DRY_RUN && log "=== DRY RUN — nothing will be installed, downloaded or written ==="

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
SUMMARY_PREFIX=""
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
# VDF EDITING HELPERS — used by Steps 7 and 11 to auto-configure the compatibility
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
    local vdf="$STEAM_ROOT/steamapps/libraryfolders.vdf" lib
    {
        echo "$STEAM_ROOT"
        [[ -f "$vdf" ]] && extract_all_values "path" "$(cat "$vdf")"
    } | while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        realpath -q "$lib" 2>/dev/null || echo "$lib"
    done | sort -u
}

# Search every Steam library for an existing iRacing common/ folder.
# Direct Account flow only: the installer's /DIR= switch needs the exact
# path.
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

# Search every Steam library for iRacing's appmanifest. Steam writes it
# into whichever library the game was installed to, not always the
# default one, so hardcoding $STEAM_APPS here meant anyone with iRacing
# on a second drive was told it wasn't in their library at all - and no
# amount of reinstalling in Steam would ever change that answer.
find_iracing_acf() {
    local lib candidate
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        candidate="$lib/steamapps/appmanifest_${IRACING_APPID}.acf"
        [[ -f "$candidate" ]] && {
            echo "$candidate"
            return 0
        }
    done < <(get_steam_libraries)
    return 1
}

# The Proton prefix belongs in the same library as the game, so derive it
# from wherever the appmanifest was found rather than assuming the
# default library.
iracing_compatdata_dir() {
    local acf_dir
    acf_dir=$(dirname "$IRACING_ACF")
    echo "$acf_dir/compatdata/$IRACING_APPID"
}

# A quick sanity check, not an exhaustive file listing. A real iRacing
# install contains many more files and folders than this - these are
# just a handful of reliable, always-present items used as a fast way to
# tell "fully installed" apart from "stub only" or "partial install".
#
# These were validated against a Steam-installed iRacing, where Steam
# lays out the whole depot. Used for detection on both account types.
IRACING_FINGERPRINT=(
    "iRacingSim64DX11.exe"
    "iRacingService64.exe"
    "iRacingLauncher64.exe"
    "EasyAntiCheat"
    "ui"
    "cars"
    "tracks"
)

# The Windows installer used by the Direct Account flow does NOT produce
# the same layout as Steam's depot. Confirmed by running the real
# installer (2026.06.09.01) into a scratch directory and listing the
# result: the three executables, EasyAntiCheat and ui are all created,
# but cars and tracks are NOT - the launcher fetches content on first
# run, so a freshly installed Direct Account folder is ~2.2 GB and has
# no content folders at all.
#
# This list is therefore used for BOTH detection and post-install
# verification on the Direct Account path. Using the full list above
# would classify a perfectly good fresh install as "partial" on the very
# next run and offer to repair it, forever.
#
# Kept deliberately short. Inno Setup writes unins000.exe only once every
# file has been extracted and CRC-checked, and version_system.txt lands
# at the end of the same run, so between them they are the installer's
# own statement that it finished rather than aborting partway. Neither
# exists in a Steam depot install, which is why they belong here and not
# in the list above. That makes the rest of the payload (the service and
# launcher executables, EasyAntiCheat, ui) redundant to check - they
# come out of the same extraction pass.
#
# iRacingSim64DX11.exe stays because this list also does detection on
# every later run, not just verification straight after an install. The
# two markers would still be sitting there months after someone deleted
# or corrupted the sim binary, and at 282 MB it is also the file most
# likely to be truncated by a disk filling up mid-install.
IRACING_INSTALLER_FINGERPRINT=(
    "iRacingSim64DX11.exe"
    "unins000.exe"
    "version_system.txt"
)

# Pass "verbose" as $2 to log the first missing entry, which over time
# shows which fingerprint items are unreliable in the wild. Off by
# default because the polling loops call this every two seconds and would
# otherwise flood the log a user sends in for support.
# Pass "installer" as $3 to check the Direct Account layout (see
# IRACING_INSTALLER_FINGERPRINT above) rather than the full Steam depot
# layout. Which one applies is decided by account type, not by step.
iracing_fingerprint_complete() {
    local path="$1" verbose="${2:-}" which="${3:-full}" entry
    local -a entries
    if [[ "$which" == "installer" ]]; then
        entries=("${IRACING_INSTALLER_FINGERPRINT[@]}")
    else
        entries=("${IRACING_FINGERPRINT[@]}")
    fi
    [[ ! -d "$path" ]] && {
        [[ "$verbose" == "verbose" ]] && log "Fingerprint check: $path does not exist"
        return 1
    }
    for entry in "${entries[@]}"; do
        [[ ! -e "$path/$entry" ]] && {
            [[ "$verbose" == "verbose" ]] && log "Fingerprint check ($which) at $path: missing '$entry'"
            return 1
        }
    done
    return 0
}

# Returns 0 (and logs) when an action should be skipped because this is a
# dry run. Call sites read as: `dry_skip "install foo" || <do it>`.
dry_skip() {
    if $DRY_RUN; then
        log "[DRY-RUN] would $1"
        return 0
    fi
    return 1
}

# iRacing publish 40 GB minimum, 225 GB for all content:
# https://www.iracing.com/membership/system-requirements/
# +50% because 40 is the bare minimum and a real install with a bit of
# content is well past it (mine is 91 GB). Warn-and-continue, not a block:
# the unins000.exe / version_system.txt checks catch a failed install
# afterwards, so this only exists to stop someone wasting an hour on a
# download that can't fit.
# Hardcoded, not scraped: the figure moves about once a year and the page
# is a WordPress layout with no stable markup around it.
IRACING_MIN_GB=40
IRACING_REQUIRED_GB=$((IRACING_MIN_GB + IRACING_MIN_GB / 2))

# Free space in GB on the filesystem holding the given path. Walks up to
# the nearest existing parent, since the path itself may not exist yet.
# Returns nothing if df fails or gives something non-numeric. Callers must
# test the shape, not just emptiness: [[ "abc" -lt 5 ]] is TRUE in bash.
free_space_gb() {
    local path="$1" out
    while [[ ! -d "$path" && "$path" != "/" ]]; do
        path=$(dirname "$path")
    done
    out=$(df -BG --output=avail "$path" 2>/dev/null | tail -n1 | tr -dc '0-9')
    [[ "$out" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$out"
}

# The user's Downloads folder, honouring their locale and any custom
# XDG setting. Hardcoding $HOME/Downloads meant anyone on a localised
# desktop (Téléchargements, Descargas, and so on) could never have their
# installer found, and sat in the polling loop until they gave up.
resolve_downloads_dir() {
    local dir=""
    if command -v xdg-user-dir &>/dev/null; then
        dir=$(xdg-user-dir DOWNLOAD 2>/dev/null)
    else
        log "[WARN] xdg-user-dir not installed (xdg-user-dirs package) — falling back to \$HOME/Downloads, which is wrong on a localised desktop"
    fi
    # xdg-user-dir echoes $HOME when it has no answer, which is not a
    # useful place to go hunting for an installer.
    [[ -z "$dir" || "$dir" == "$HOME" ]] && dir="$HOME/Downloads"
    # Canonicalise: Downloads is often a symlink to another drive, and the
    # installer poll needs the real path to find anything.
    realpath -q "$dir" 2>/dev/null || echo "$dir"
}

# Zenity parses dialog text as Pango markup, so a path containing & < or >
# breaks the dialog. Wrap any interpolated value in pe() - never the markup
# itself, or the tags get escaped too.
# NB: bash 5.2+ treats a bare & in the replacement as "the matched text"
# (like sed), so every & below must be backslash-escaped or &lt; comes out
# as <lt;.
pe() {
    local t="$1"
    t="${t//&/\&amp;}"
    t="${t//</\&lt;}"
    t="${t//>/\&gt;}"
    printf '%s' "$t"
}

DOWNLOADS_DIR=$(resolve_downloads_dir)

# A folder existing under compatibilitytools.d doesn't mean it's a
# working Proton build — an interrupted download, a tar that got killed
# partway, or a disk-full extraction can all leave a folder in place
# with core pieces missing. Steam itself also refuses to list a
# compatibility tool that's missing compatibilitytool.vdf. Checking only
# `-d` here previously meant a corrupt leftover folder would be treated
# as "already installed" forever, silently skipping the download every
# run — and, downstream, is the same kind of breakage that shows up as
# "wine: could not load kernel32.dll" when protontricks tries to use it.
proton_build_looks_complete() {
    local dir="$1"
    [[ -f "$dir/compatibilitytool.vdf" ]] || return 1
    [[ -f "$dir/proton" ]] || return 1
    [[ -d "$dir/files" || -d "$dir/dist" ]] || return 1
    return 0
}

# NOTE: deliberately NOT using api.github.com here — the REST API is capped
# at 60 unauthenticated requests/hour per source IP, which is easy to hit
# on shared/NAT'd connections (or just from repeatedly testing this
# script). github.com/<repo>/releases/latest is a plain web redirect, not
# part of the API, and isn't subject to that limit. Tag comes from the
# redirect's Location header, then scrape the real asset
# filename from the releases/expanded_assets/<tag> HTML fragment
# (see below) — also not part of the API, also not rate-limited.
# CompatToolMapping keys on the name declared in compatibilitytool.vdf,
# not the folder name. Folder iracing-dnsapi-fixmes declares itself
# iracing-dnsapi-fixmes-proton. Writing the folder name gives Steam an
# assignment it can't resolve, which silently does nothing.
# Layout: "compatibilitytools" { "compat_tools" { "<name>" { ... } } }
# so take the first quoted string after compat_tools. Falls back to the
# folder name, i.e. the old behaviour.
proton_tool_internal_name() {
    local dir="$1" vdf="$1/compatibilitytool.vdf" name=""
    if [[ -f "$vdf" ]]; then
        name=$(awk '
            /"compat_tools"/ { in_ct = 1; next }
            in_ct && /"[^"]+"/ {
                match($0, /"[^"]+"/)
                print substr($0, RSTART + 1, RLENGTH - 2)
                exit
            }
        ' "$vdf")
    fi
    if [[ -z "$name" ]]; then
        log "[WARN] Could not read a tool name from $vdf — falling back to the folder name"
        name=$(basename "$dir")
    fi
    echo "$name"
}

# Proton writes its version marker only once the prefix layout is
# finished, so requiring both that and system32 avoids treating a
# half-built prefix (interrupted first run) as ready. The marker is also
# what Proton itself reads to decide whether an upgrade is needed.
# Verified against a real Steam-created prefix: 907 files in system32
# and a 17-byte version file, so both halves hold for prefixes Steam
# made as well as ones this script bootstraps.
# Defined up here, not in the step that uses it, because test mode runs
# before every step and calls it too.
prefix_looks_ready() {
    [[ -d "$IRACING_COMPATDATA/pfx/drive_c/windows/system32" ]] || return 1
    [[ -s "$IRACING_COMPATDATA/version" ]] || return 1
    return 0
}

# What Steam SHOWS in the compatibility dropdown is display_name, which is
# a third string again: folder iracing-dnsapi-fixmes, internal key
# iracing-dnsapi-fixmes-proton, display name iracing-dnsapi-fixmes.
# Anything the user is told to look for must use this one, or they go
# hunting for a name that isn't in the list.
proton_tool_display_name() {
    local dir="$1" vdf="$1/compatibilitytool.vdf" name=""
    if [[ -f "$vdf" ]]; then
        name=$(grep -m1 '"display_name"' "$vdf" 2>/dev/null |
            sed -E 's/.*"display_name"[^"]*"([^"]*)".*/\1/')
    fi
    [[ -z "$name" ]] && name=$(proton_tool_internal_name "$dir")
    printf '%s' "$name"
}

GH_REPO="DanFraserUK/proton-cachyos"

# The Proton libraries iRacing needs. Defined here rather than inside
# the step that installs them, so test mode can check the same list
# without keeping a second copy of it in step with this one.
REQUIRED_PKGS=(
    vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022
    d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact xact_x64 xaudio29
)

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
    local evidence=""

    # Only two things prove a sandboxed Steam: the package manager says it is
    # installed, or the Steam root we resolved is inside a sandbox tree.
    #
    # Directory-existence tests were removed. ~/.var/app/com.valvesoftware.Steam
    # is created by other software (MangoHud writes its config there whether or
    # not Flatpak Steam exists), so its presence proves nothing and refused
    # native-Steam users outright.
    if command -v flatpak &>/dev/null && flatpak list --app --columns=application 2>/dev/null | grep -qi "com.valvesoftware.steam"; then
        reason="Flatpak"
        evidence="flatpak list reports com.valvesoftware.Steam installed"
    elif command -v snap &>/dev/null && snap list 2>/dev/null | grep -qi "^steam "; then
        reason="Snap"
        evidence="snap list reports steam installed"
    elif [[ "$STEAM_ROOT" == "$HOME/.var/app/"* ]]; then
        reason="Flatpak"
        evidence="resolved STEAM_ROOT is inside the Flatpak sandbox: $STEAM_ROOT"
    elif [[ "$STEAM_ROOT" == /snap/* || "$STEAM_ROOT" == "$HOME/snap/"* ]]; then
        reason="Snap"
        evidence="resolved STEAM_ROOT is inside the Snap sandbox: $STEAM_ROOT"
    fi

    log "Sandbox check: ${reason:-none detected} (STEAM_ROOT=$STEAM_ROOT)"

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
        log "Blocked: $reason Steam detected — $evidence"
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

if $DRY_RUN; then
    gui_info "<b>Dry run</b>

This walks through the whole setup and shows you every check and prompt, but doesn't install, download or change anything.

Every action it would have taken is written to:
<tt>$(pe "$GENERAL_LOG")</tt>"
fi

# =============================================================================
# TEST MODE — report on an existing install, change nothing
# =============================================================================
# Never calls into the setup steps - reuses the helpers but owns its
# reporting, so no path here can trigger a write. Every check is a read.
# Output is meant for pasting into a support thread, so each log line
# carries the same text as the screen.
if $TEST_MODE; then
    log "=== TEST MODE — read-only report, nothing will be changed ==="

    TEST_PASS=0
    TEST_FAIL=0
    TEST_WARN=0
    TEST_REPORT=""

    # result: pass | fail | warn
    test_result() {
        local result="$1" label="$2" detail="${3:-}"
        local mark
        case "$result" in
        pass)
            mark="✅"
            TEST_PASS=$((TEST_PASS + 1))
            ;;
        warn)
            mark="⚠️"
            TEST_WARN=$((TEST_WARN + 1))
            ;;
        *)
            mark="❌"
            TEST_FAIL=$((TEST_FAIL + 1))
            ;;
        esac
        TEST_REPORT="${TEST_REPORT}${mark}  ${label}${detail:+
        <tt>${detail}</tt>}
"
        log "TEST [$result] $label${detail:+ — $detail}"
    }

    gui_open "Checking your iRacing setup..."

    # --- Tools ---
    if command -v steam &>/dev/null; then
        test_result pass "Steam is installed"
    else
        test_result fail "Steam not found on PATH"
    fi

    if command -v protontricks &>/dev/null; then
        test_result pass "protontricks is installed" "$(protontricks --version 2>&1 | head -n1)"
    else
        test_result fail "protontricks not found on PATH" "pipx users may need to open a new terminal"
    fi

    if command -v zenity &>/dev/null; then
        test_result pass "zenity is installed"
    else
        test_result fail "zenity not found on PATH"
    fi

    # --- Steam login ---
    TEST_LOGIN_VDF="$STEAM_ROOT/config/loginusers.vdf"
    if [[ -f "$TEST_LOGIN_VDF" ]] && grep -q '"AccountName"' "$TEST_LOGIN_VDF" 2>/dev/null; then
        test_result pass "Steam has a logged-in account"
    else
        test_result fail "No logged-in Steam account found" "$TEST_LOGIN_VDF"
    fi

    # --- Library and appmanifest ---
    TEST_ACF=$(find_iracing_acf || true)
    if [[ -n "$TEST_ACF" ]]; then
        test_result pass "iRacing found in a Steam library" "$(dirname "$TEST_ACF")"
        IRACING_ACF="$TEST_ACF"
    else
        test_result fail "No iRacing appmanifest in any Steam library" "searched: $(get_steam_libraries | tr '\n' ' ')"
    fi

    # --- Account type and game files ---
    TEST_PATH=""
    if [[ -n "$TEST_ACF" ]]; then
        IRACING_DEPOT_PURCHASE=""
        IRACING_DEPOT_DIRECT=""
        detect_iracing_depot

        if [[ -n "$IRACING_DEPOT_PURCHASE" ]]; then
            test_result pass "Account type: Steam Purchase"
            TEST_SET="full"
        elif [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
            test_result pass "Account type: Direct Account / Steam Key"
            TEST_SET="installer"
        else
            test_result warn "Account type could not be determined from the appmanifest"
            TEST_SET="full"
        fi

        TEST_INSTALL_DIR=$(extract_value "installdir" "$(cat "$TEST_ACF")")
        TEST_PATH=$(find_iracing_common_path "$TEST_INSTALL_DIR" || true)
        if [[ -n "$TEST_PATH" ]]; then
            if iracing_fingerprint_complete "$TEST_PATH" verbose "$TEST_SET"; then
                test_result pass "Game files look complete ($TEST_SET layout)" "$TEST_PATH"
            else
                test_result fail "Game files incomplete for the $TEST_SET layout" "$TEST_PATH"
            fi
            test_result pass "Install size" "$(du -sh "$TEST_PATH" 2>/dev/null | cut -f1)"
        else
            test_result fail "Game folder not found in any library" "installdir: ${TEST_INSTALL_DIR:-unknown}"
        fi
    fi

    # --- Disk space ---
    if [[ -n "$TEST_PATH" ]]; then
        TEST_AVAIL=$(free_space_gb "$TEST_PATH")
        if [[ "$TEST_AVAIL" =~ ^[0-9]+$ && "$TEST_AVAIL" -lt "$IRACING_REQUIRED_GB" ]]; then
            test_result warn "Low free space on the iRacing drive" "${TEST_AVAIL} GB free, ${IRACING_REQUIRED_GB} GB suggested"
        else
            test_result pass "Free space on the iRacing drive" "${TEST_AVAIL:-unknown} GB"
        fi
    fi

    # --- Compatibility tool ---
    TEST_CONFIG_VDF="$STEAM_ROOT/config/config.vdf"
    TEST_ASSIGNED=""
    if [[ -f "$TEST_CONFIG_VDF" ]]; then
        ctm=$(vdf_descend "$TEST_CONFIG_VDF" "InstallConfigStore" "Software" "Valve" "Steam" "CompatToolMapping" || true)
        if [[ -n "$ctm" ]]; then
            read -r _ ctm_start ctm_end <<<"$ctm"
            appid_block=$(vdf_find_key_block "$TEST_CONFIG_VDF" "$((ctm_start + 1))" "$((ctm_end - 1))" "$IRACING_APPID" || true)
            if [[ -n "$appid_block" ]]; then
                read -r _ a_start a_end <<<"$appid_block"
                TEST_ASSIGNED=$(sed -n "$((a_start + 1)),$((a_end - 1))p" "$TEST_CONFIG_VDF" | grep '"name"' | sed -E 's/.*"name"[^"]*"([^"]*)".*/\1/')
            fi
        else
            test_result warn "config.vdf has no CompatToolMapping section" "no compatibility tool has ever been set in Steam"
        fi
    else
        test_result fail "config.vdf not found" "$TEST_CONFIG_VDF"
    fi

    # config.vdf holds the tool's DECLARED name, which is often not its
    # folder name, so match on what each installed build calls itself
    # rather than on directory names.
    TEST_TOOL_DIR=""
    if [[ -n "$TEST_ASSIGNED" && -d "$COMPAT_TOOLS_DIR" ]]; then
        while IFS= read -r cand; do
            [[ -z "$cand" ]] && continue
            if [[ "$(proton_tool_internal_name "$cand")" == "$TEST_ASSIGNED" ]]; then
                TEST_TOOL_DIR="$cand"
                break
            fi
        done < <(find "$COMPAT_TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    fi

    if [[ -n "$TEST_ASSIGNED" ]]; then
        test_result pass "Compatibility tool assigned to iRacing" "$TEST_ASSIGNED"
        if [[ -n "$TEST_TOOL_DIR" ]]; then
            if proton_build_looks_complete "$TEST_TOOL_DIR"; then
                TEST_TOOL_SHOWN=$(proton_tool_display_name "$TEST_TOOL_DIR")
                test_result pass "Assigned tool found and looks complete" "shown in Steam as: $TEST_TOOL_SHOWN | folder: $(basename "$TEST_TOOL_DIR")"
            else
                test_result fail "Assigned tool is present but incomplete" "$TEST_TOOL_DIR"
            fi
        else
            test_result warn "Assigned tool not found in compatibilitytools.d" "may be a built-in Steam Proton, which is fine"
        fi
    else
        test_result fail "No compatibility tool assigned to iRacing"
    fi

    # --- Latest release comparison (the one thing the setup never checks) ---
    TEST_LATEST=$(curl -fsSL -o /dev/null -D - "https://github.com/${GH_REPO:-DanFraserUK/proton-cachyos}/releases/latest" 2>/dev/null |
        grep -i '^location:' | tail -n1 | sed -E 's#.*/releases/tag/([^[:space:]/]+).*#\1#' | tr -d '\r')
    # Compare folder against tag, not declared-name against tag: the tool
    # calls itself "<something>-proton" while the release is tagged
    # differently again, so a naive comparison always reports a newer
    # build even when the latest one is already installed.
    TEST_INSTALLED_TAG=""
    [[ -n "$TEST_TOOL_DIR" ]] && TEST_INSTALLED_TAG=$(basename "$TEST_TOOL_DIR")
    TEST_LATEST_ASSETS=$(curl -fsSL "https://github.com/${GH_REPO}/releases/expanded_assets/${TEST_LATEST}" 2>/dev/null)
    TEST_LATEST_DIR=$(grep -oE "releases/download/${TEST_LATEST}/[^\"']+\.tar\.xz" <<<"$TEST_LATEST_ASSETS" | head -n1 | sed -E 's#.*/##')
    TEST_LATEST_DIR="${TEST_LATEST_DIR%.tar.xz}"

    if [[ -z "$TEST_LATEST" ]]; then
        test_result warn "Couldn't reach GitHub to check for a newer Proton build"
    elif [[ -z "$TEST_INSTALLED_TAG" ]]; then
        test_result warn "Can't tell whether the Proton build is current" "latest release: $TEST_LATEST"
    elif [[ -n "$TEST_LATEST_DIR" && "$TEST_INSTALLED_TAG" == "$TEST_LATEST_DIR" ]]; then
        test_result pass "Proton build is the latest release" "$TEST_LATEST"
    else
        test_result warn "A newer Proton build may be available" "installed: $TEST_INSTALLED_TAG | latest: ${TEST_LATEST_DIR:-$TEST_LATEST}"
    fi

    # --- Prefix ---
    if [[ -n "$TEST_ACF" ]]; then
        IRACING_COMPATDATA=$(iracing_compatdata_dir)
        if prefix_looks_ready; then
            test_result pass "Proton prefix present" "$IRACING_COMPATDATA ($(cat "$IRACING_COMPATDATA/version" 2>/dev/null || echo unknown))"
        else
            test_result fail "Proton prefix missing or incomplete" "$IRACING_COMPATDATA"
        fi
    fi

    # --- Proton libraries ---
    gui_close
    gui_open "Checking Proton libraries (this takes a moment)..."
    TEST_LIST_TMP=$(mktemp)
    protontricks "$IRACING_APPID" list-installed >"$TEST_LIST_TMP" 2>&1
    TEST_LIST_EXIT=$?
    TEST_LIST=$(cat "$TEST_LIST_TMP" 2>/dev/null || true)
    rm -f "$TEST_LIST_TMP"
    gui_close
    gui_open "Finishing the report..."

    if [[ $TEST_LIST_EXIT -ne 0 || -z "$TEST_LIST" ]]; then
        test_result fail "Couldn't query Proton libraries" "protontricks exit $TEST_LIST_EXIT — the prefix or the assigned tool can't start"
    else
        TEST_MISSING=()
        for pkg in "${REQUIRED_PKGS[@]}"; do
            echo "$TEST_LIST" | grep -qw "$pkg" || TEST_MISSING+=("$pkg")
        done
        if [[ ${#TEST_MISSING[@]} -eq 0 ]]; then
            test_result pass "All ${#REQUIRED_PKGS[@]} required Proton libraries present"
        else
            test_result fail "${#TEST_MISSING[@]} of ${#REQUIRED_PKGS[@]} Proton libraries missing" "${TEST_MISSING[*]}"
        fi
    fi

    # --- Launch options ---
    TEST_STEAMID3=$(resolve_steamid3 || true)
    if [[ -z "$TEST_STEAMID3" ]]; then
        test_result warn "Couldn't resolve the Steam account folder" "$STEAM_ROOT/userdata"
    else
        TEST_LOCALCONFIG="$STEAM_ROOT/userdata/$TEST_STEAMID3/config/localconfig.vdf"
        if [[ ! -f "$TEST_LOCALCONFIG" ]]; then
            test_result warn "localconfig.vdf not found" "$TEST_LOCALCONFIG"
        elif grep -qF "PROTON_LOG=1" "$TEST_LOCALCONFIG" 2>/dev/null; then
            test_result pass "Launch options include PROTON_LOG=1"
        else
            test_result warn "Launch options don't include PROTON_LOG=1" "not required to play, but useful for support"
        fi
    fi

    # --- Optional extras ---
    if grep -qF "0.0.0.0 modules-cdn.eac-prod.on.epicgames.com" /etc/hosts 2>/dev/null; then
        test_result pass "EAC hosts workaround is applied"
    else
        test_result warn "EAC hosts workaround is not applied" "optional, and at your own risk"
    fi

    # -L alone only asks "is this a symlink", not "does it point at
    # anything". A shortcut left behind by moving iRacing to another
    # library is still a symlink, and still completely broken.
    TEST_DOCS_LINK="$HOME/Documents/iRacing"
    TEST_DOCS_EXPECTED="$IRACING_COMPATDATA/pfx/drive_c/users/steamuser/Documents/iRacing"
    if [[ -L "$TEST_DOCS_LINK" ]]; then
        TEST_DOCS_TARGET=$(readlink "$TEST_DOCS_LINK")
        if [[ ! -d "$TEST_DOCS_LINK" ]]; then
            test_result fail "Documents shortcut is broken" "points at $TEST_DOCS_TARGET, which doesn't exist"
        elif [[ "$TEST_DOCS_TARGET" != "$TEST_DOCS_EXPECTED" ]]; then
            test_result warn "Documents shortcut points somewhere unexpected" "is: $TEST_DOCS_TARGET | expected: $TEST_DOCS_EXPECTED"
        else
            test_result pass "Documents shortcut is correct" "$TEST_DOCS_TARGET"
        fi
    elif [[ -e "$TEST_DOCS_LINK" ]]; then
        test_result warn "Documents shortcut path exists but isn't a symlink" "$TEST_DOCS_LINK"
    else
        test_result warn "No Documents shortcut yet" "created after iRacing has run once"
    fi

    gui_close

    log "TEST MODE complete — $TEST_PASS passed, $TEST_WARN warnings, $TEST_FAIL failed"

    TEST_VERDICT="<b>$TEST_PASS passed</b>, $TEST_WARN warning(s), <b>$TEST_FAIL failed</b>"
    if [[ $TEST_FAIL -eq 0 && $TEST_WARN -eq 0 ]]; then
        TEST_HEADLINE="<b>Everything looks right.</b>"
    elif [[ $TEST_FAIL -eq 0 ]]; then
        TEST_HEADLINE="<b>No failures, but a few things worth a look.</b>"
    else
        TEST_HEADLINE="<b>Some things need attention.</b>\n\nRe-running this script normally will try to fix most of them."
    fi

    gui_info "$TEST_HEADLINE

$TEST_REPORT
$TEST_VERDICT

This report is also saved to:
<tt>$(pe "$GENERAL_LOG")</tt>
Paste that file into a support thread if you need a hand."

    # cleanup_and_exit is the EXIT trap handler and only tidies up — it
    # does not exit on its own. Exiting here fires it anyway.
    exit 0
fi

# =============================================================================
# STEP 1 — Install Steam and protontricks
# =============================================================================
log "=== Step 1 — Steam & protontricks ==="
log "Step 1 — target distro family: $DISTRO_FAMILY"

DEBIAN_APT_UPDATED=false
PACKAGES_INSTALLED_THIS_RUN=false

install_if_missing() {
    local pkg="$1"
    # Guard here, not per package manager: the checks below are read-only,
    # everything past them shells out to a root install.
    if $DRY_RUN && ! command -v "$pkg" &>/dev/null; then
        log "[DRY-RUN] would install $pkg via $DISTRO_FAMILY package manager"
        PACKAGES_INSTALLED_THIS_RUN=true
        return
    fi
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
            log "$pkg installed successfully via apt-get"
            PACKAGES_INSTALLED_THIS_RUN=true
            # pipx ensurepath edits the profile, not this running shell. Without
            # this the failure surfaces at Step 10, after a Proton download
            # and a prefix bootstrap have already happened.
            if [[ "$pkg" == "protontricks" ]] && ! command -v protontricks &>/dev/null; then
                export PATH="$HOME/.local/bin:$PATH"
                if command -v protontricks &>/dev/null; then
                    log "Added ~/.local/bin to PATH for this run — pipx-installed protontricks now resolvable"
                else
                    log "[ERROR] protontricks installed via pipx but still not on PATH (checked ~/.local/bin)"
                    gui_error "❌ <b>protontricks</b> was installed but can't be found.\n\npipx usually puts it in <tt>~/.local/bin</tt>. Try opening a new terminal and running:\n\n<tt>protontricks --version</tt>\n\nIf that works, re-run this setup. If it doesn't, run <tt>pipx ensurepath</tt> and log out and back in."
                fi
            fi
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
            log "$pkg installed successfully via dnf"
            PACKAGES_INSTALLED_THIS_RUN=true
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
            log "$pkg installed successfully via pacman"
            PACKAGES_INSTALLED_THIS_RUN=true
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

    # File updated since the first look means Steam wrote new login data
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

# Default to the default library so the "not found" message and Step 4's
# polling both have a concrete path to name, then overwrite it if the
# appmanifest actually turns up in another library.
IRACING_ACF="$STEAM_APPS/appmanifest_${IRACING_APPID}.acf"
IRACING_ACF_FOUND=$(find_iracing_acf || true)
[[ -n "$IRACING_ACF_FOUND" ]] && IRACING_ACF="$IRACING_ACF_FOUND"
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
    local silent_checks=4  # ~8s silent
    local patient_checks=6 # ~12s more with a visible "be patient" window
    local attempt=0
    ACF_WAIT_TOTAL_LOOPS=0

    # Re-search every library on each pass rather than watching one fixed
    # path: the user may well pick a different drive in Steam's install
    # dialog, and libraryfolders.vdf can gain an entry mid-wait.
    local found
    while true; do
        found=$(find_iracing_acf || true)
        if [[ -n "$found" ]]; then
            IRACING_ACF="$found"
            break
        fi

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

    # Step 1 installs steam, but a pipx/pacman failure can leave it absent
    # while the run carries on. The steam:// triggers below silently do
    # nothing without it, and the user waits at a poll loop forever.
    if ! command -v steam &>/dev/null; then
        log "[ERROR] Step 4 — steam not on PATH, cannot fire steam:// triggers"
        gui_error "❌ Steam isn't on your PATH, so this setup can't ask it to install iRacing.

Try opening a new terminal and running:

    <tt>steam --version</tt>

If that fails, reinstall Steam and run this setup again."
    fi

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
    if ! dry_skip "fire steam://open/activateproduct and steam://install/${IRACING_APPID}"; then
        (steam steam://open/activateproduct >/dev/null 2>&1 &) 2>/dev/null
        sleep 1
        (steam "steam://install/${IRACING_APPID}" >/dev/null 2>&1 &) 2>/dev/null
    fi
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

# appmanifest exists but Purchase vs Direct is still unknown — ask the
# user to check Steam rather than silently skipping installation
# entirely (which is what used to happen: Step 5 would skip both the
# Purchase and the Direct branch if depot detection came back empty).
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
# STEP 5 — Detect game file state (and act on it where Steam can)
# =============================================================================
# No Proton work here: filesystem checks and Steam UI prompts only, both
# of which need Steam open. Steam stays closed from Step 6 on.
# Direct Account: this decides *whether* the installer runs. It actually
# runs at Step 9, once there's a build, an assignment and a prefix.
IRACING_INSTALL_ACTION="none" # none | install | repair
IRACING_FILE_STATE="unknown"  # unknown | complete | missing | stub | partial

if [[ -n "$IRACING_DEPOT_PURCHASE" || -n "$IRACING_DEPOT_DIRECT" ]]; then
    log "=== Step 5 — Game File State ==="

    gui_open "Checking iRacing game files..."
    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")

    # Search every Steam library, not just the default one — iRacing may
    # be installed on a secondary drive/library.
    IRACING_STEAM_PATH=$(find_iracing_common_path "$INSTALL_DIR")
    if [[ -z "$IRACING_STEAM_PATH" ]]; then
        # Not created anywhere yet — default to the library the
        # appmanifest lives in, since that's where Steam will create it.
        IRACING_STEAM_PATH="$(dirname "$IRACING_ACF")/common/$INSTALL_DIR"
        log "installdir '$INSTALL_DIR' not found in any known library yet — defaulting to $IRACING_STEAM_PATH"
    else
        log "installdir '$INSTALL_DIR' found at $IRACING_STEAM_PATH"
    fi
    gui_close

    # Which layout counts as "complete" depends on the account type, not
    # on the step. A Direct Account install comes from the Windows
    # installer, which ships no cars or tracks at all - checking it
    # against Steam's depot layout would call a healthy install partial
    # on every run after the first and keep offering to repair it.
    if [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
        FINGERPRINT_SET="installer"
    else
        FINGERPRINT_SET="full"
    fi
    log "Step 5 — using '$FINGERPRINT_SET' fingerprint set for this account type"

    # Classify into exactly one of four states. The stub heuristic only
    # applies once the fingerprint has already failed, so branch order
    # matters here.
    FILE_COUNT=""
    DIR_SIZE=""
    IRACING_FILE_STATE="missing"
    if iracing_fingerprint_complete "$IRACING_STEAM_PATH" verbose "$FINGERPRINT_SET"; then
        IRACING_FILE_STATE="complete"
    elif [[ -d "$IRACING_STEAM_PATH" ]]; then
        FILE_COUNT=$(find "$IRACING_STEAM_PATH" -maxdepth 1 -type f | wc -l)
        DIR_SIZE=$(du -sb "$IRACING_STEAM_PATH" 2>/dev/null)
        DIR_SIZE="${DIR_SIZE%%$'\t'*}"
        [[ "$FILE_COUNT" =~ ^[0-9]+$ ]] || FILE_COUNT=0
        [[ "$DIR_SIZE" =~ ^[0-9]+$ ]] || DIR_SIZE=0
        if [[ "$FILE_COUNT" -le 3 && "$DIR_SIZE" -lt 5000 ]]; then
            IRACING_FILE_STATE="stub"
        else
            IRACING_FILE_STATE="partial"
        fi
    fi

    log "Step 5 — path=<$IRACING_STEAM_PATH> state=<$IRACING_FILE_STATE> files=<${FILE_COUNT:-n/a}> bytes=<${DIR_SIZE:-n/a}>"

    # Checked here, not at download time, so a doomed run stops before the
    # Proton download rather than after it.
    if [[ "$IRACING_FILE_STATE" != "complete" ]]; then
        AVAIL_GB=$(free_space_gb "$IRACING_STEAM_PATH" || true)
        log "Step 5 — free space at $IRACING_STEAM_PATH: ${AVAIL_GB:-unknown} GB (want ${IRACING_REQUIRED_GB} GB)"
        if [[ "$AVAIL_GB" =~ ^[0-9]+$ && "$AVAIL_GB" -lt "$IRACING_REQUIRED_GB" ]]; then
            if ! gui_question "<b>That drive may not have enough free space.</b>

iRacing would be installed here:

    <tt><b>$(pe "$IRACING_STEAM_PATH")</b></tt>

Free space:  <b>${AVAIL_GB} GB</b>
Suggested:   <b>${IRACING_REQUIRED_GB} GB</b>

iRacing's published minimum is ${IRACING_MIN_GB} GB, and a lot more once you buy cars and tracks.

<b>Carry on anyway?</b>" "cancel"; then
                log "User quit at Step 5 — only ${AVAIL_GB} GB free, wanted ${IRACING_REQUIRED_GB} GB"
                exit 0
            fi
            log "[WARN] Step 5 — continuing with only ${AVAIL_GB} GB free"
        fi
    fi
fi

# --- Steam Purchase: Steam owns the files, so remediate through Steam ---
if [[ -n "$IRACING_DEPOT_PURCHASE" ]]; then
    case "$IRACING_FILE_STATE" in
    complete)
        IRACING_SIZE_MB=$(du -sm "$IRACING_STEAM_PATH" 2>/dev/null | cut -f1)
        log "Step 5 — all ${#IRACING_FINGERPRINT[@]} expected items present, install size ${IRACING_SIZE_MB:-unknown} MB"
        gui_info "<b>iRacing game files found and look complete.</b>\n\nLocation: <tt>$(pe "$IRACING_STEAM_PATH")</tt>"
        SUMMARY_IRACING_FILES="Files complete"
        ;;
    missing)
        log "$IRACING_STEAM_PATH doesn't exist yet — prompting user to install via Steam"

        gui_warn "<b>iRacing hasn't been downloaded yet.</b>

Please open Steam and install it:
<b>Library -> iRacing -> Install</b>

Click OK once the install is done."

        attempt=0
        while true; do
            gui_open "Checking for iRacing installation..."
            sleep 2
            gui_close
            if iracing_fingerprint_complete "$IRACING_STEAM_PATH"; then
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
        ;;
    *)
        log "Prompting user to verify game files via Steam (state: $IRACING_FILE_STATE)"

        gui_warn "<b>iRacing folder exists but looks incomplete.</b>

Please open Steam and verify the game files:
<b>Right-click iRacing -> Properties -> Installed Files -> Verify integrity</b>

Click OK once Steam has finished verifying."

        attempt=0
        while true; do
            gui_open "Checking iRacing files..."
            sleep 2
            gui_close
            if iracing_fingerprint_complete "$IRACING_STEAM_PATH"; then
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
        ;;
    esac

    log "Step 5 complete — $SUMMARY_IRACING_FILES"
fi

# --- Direct Account: only the part that needs Steam open happens here ---

# Steam creates the stub folder, so this wait has to sit while Steam is
# still open and the user can reach their Library. The installer that
# fills the folder runs much later, in Step 9.
wait_for_iracing_stub() {
    local acf_mtime_before acf_mtime_now attempt=0 found

    acf_mtime_before=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")

    gui_warn "<b>iRacing stub not found.</b>

Please open Steam and install iRacing:
<b>Library -> iRacing -> Install</b>

This just downloads a small stub, a few MB.  Click OK once Steam shows it as installed."

    while true; do
        gui_open "Checking for iRacing stub..."
        sleep 2
        gui_close

        # Re-resolve rather than re-testing the path guessed before the
        # stub existed: Steam's install dialog lets the user pick any
        # library, and the guess defaulted to whichever one holds the
        # appmanifest. Pointing the installer's /DIR= at the wrong drive
        # is a silent, expensive mistake.
        found=$(find_iracing_common_path "$INSTALL_DIR" || true)
        acf_mtime_now=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")

        if [[ -n "$found" && "$acf_mtime_now" != "$acf_mtime_before" ]]; then
            if [[ "$found" != "$IRACING_STEAM_PATH" ]]; then
                log "Stub landed in a different library than expected — correcting path from $IRACING_STEAM_PATH to $found"
                IRACING_STEAM_PATH="$found"
            fi
            log "iRacing stub detected at $IRACING_STEAM_PATH"
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -ge 2 ]]; then
            if ! zenity --question --title="$TITLE" --text="iRacing stub still not found.\n\nHas Steam finished installing it? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                log "User quit at Step 5 while waiting for the iRacing stub"
                exit 0
            fi
            attempt=0
            acf_mtime_before=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")
        fi
    done
}

if [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    case "$IRACING_FILE_STATE" in
    complete)
        gui_info "<b>iRacing is already fully installed.</b>\n\nLocation: <tt>$(pe "$IRACING_STEAM_PATH")</tt>"
        SUMMARY_IRACING_FILES="Files complete"
        IRACING_INSTALL_ACTION="none"
        ;;
    missing)
        wait_for_iracing_stub
        IRACING_INSTALL_ACTION="install"
        SUMMARY_IRACING_FILES="Pending — Windows installer"
        ;;
    stub)
        IRACING_INSTALL_ACTION="install"
        SUMMARY_IRACING_FILES="Pending — Windows installer"
        ;;
    partial)
        # Not necessarily a broken install: the fingerprint has seven
        # entries and some depend on install layout or content ownership,
        # so a false positive here would otherwise force a multi-gigabyte
        # download on every single run with no way past it. Ask instead.
        if gui_question "<b>Your iRacing folder is missing some expected files.</b>

That usually means an install was interrupted partway through.

The folder checked was:

    <tt><b>$(pe "$IRACING_STEAM_PATH")</b></tt>

<b>Run the iRacing installer later in this setup to repair it?</b>" "cancel"; then
            IRACING_INSTALL_ACTION="repair"
            SUMMARY_IRACING_FILES="Pending — repair install"
            log "Step 5 — user opted to repair the partial install"
        else
            IRACING_INSTALL_ACTION="none"
            SUMMARY_IRACING_FILES="Skipped — folder looked incomplete, user chose to continue"
            log "Step 5 — user declined the repair install, continuing anyway"
        fi
        ;;
    esac

    log "Step 5 complete — state: $IRACING_FILE_STATE | planned action: $IRACING_INSTALL_ACTION"
fi

# =============================================================================
# STEP 6 — Install custom Proton build
# =============================================================================
log "=== Step 6 — Custom Proton Build ==="

mkdir -p "$COMPAT_TOOLS_DIR"

TAG_ERR_TMP=$(mktemp)
(curl -fsSL -o /dev/null \
    -D /tmp/iracing_latest_headers.txt \
    "https://github.com/${GH_REPO}/releases/latest" 2>"$TAG_ERR_TMP") &
TAG_PID=$!
gui_wait $TAG_PID "Checking for the latest custom Proton build..."
wait "$TAG_PID"
TAG_CURL_EXIT=$?

LATEST_TAG=$(grep -i '^location:' /tmp/iracing_latest_headers.txt 2>/dev/null | tail -n1 | sed -E 's#.*/releases/tag/([^[:space:]/]+).*#\1#' | tr -d '\r')
rm -f /tmp/iracing_latest_headers.txt

TAG_ERR_MSG=$(redact_path "$(cat "$TAG_ERR_TMP" 2>/dev/null)")
{
    echo "[resolve latest tag, curl exit $TAG_CURL_EXIT]"
    echo "$TAG_ERR_MSG"
} >>"$TECH_LOG"
rm -f "$TAG_ERR_TMP"

if [[ -z "$LATEST_TAG" ]]; then
    log "[ERROR] Couldn't resolve latest release tag from github.com redirect (curl exit $TAG_CURL_EXIT): ${TAG_ERR_MSG:-no error output}"
    gui_error "❌ Couldn't reach GitHub (curl exit $TAG_CURL_EXIT).\n\nCheck your internet connection and try re-running this setup.\n\nOr paste this into a terminal to see the releases page directly:\n\n<tt>xdg-open https://github.com/${GH_REPO}/releases</tt>\n\nThen download the latest .tar.xz and extract it into:\n<tt>$(pe "$COMPAT_TOOLS_DIR")</tt>"
fi

log "Latest release tag resolved via redirect: $LATEST_TAG"

# The release asset's filename doesn't always match the tag name — e.g.
# tag "iracing-dnsapi-fix-11.0-20260601" actually ships an asset named
# "iracing-dnsapi-fixmes.tar.xz". Guessing "<tag>.tar.xz" produces a
# silent 404 that looks exactly like a network failure. GitHub's
# releases/expanded_assets/<tag> endpoint returns the asset list as the
# same HTML fragment used by the "Assets" disclosure on the releases
# page — it isn't part of the REST API, so it isn't subject to the
# 60/hour unauthenticated rate limit either.
ASSETS_ERR_TMP=$(mktemp)
ASSETS_HTML=$(curl -fsSL "https://github.com/${GH_REPO}/releases/expanded_assets/${LATEST_TAG}" 2>"$ASSETS_ERR_TMP")
ASSETS_CURL_EXIT=$?
ASSETS_ERR_MSG=$(redact_path "$(cat "$ASSETS_ERR_TMP" 2>/dev/null)")
{
    echo "[list release assets, curl exit $ASSETS_CURL_EXIT]"
    echo "$ASSETS_ERR_MSG"
} >>"$TECH_LOG"
rm -f "$ASSETS_ERR_TMP"

# Trust boundary: this name comes from GitHub HTML and flows into
# TARBALL_URL and MANUAL_CMD unquoted-ish. Only exploitable by whoever
# controls the release, i.e. me. Left as-is deliberately.
TARBALL_NAME=$(grep -oE "releases/download/${LATEST_TAG}/[^\"']+\.tar\.xz" <<<"$ASSETS_HTML" | head -n1 | sed -E 's#.*/##')

if [[ -z "$TARBALL_NAME" ]]; then
    # Loud on purpose. This is HTML scraping of a page GitHub can change
    # without notice, and the fallback below is a naming guess that is
    # already known to 404 for at least one live release tag. If this
    # line starts showing up in user logs, the scrape has broken and the
    # download is about to fail for everyone.
    log "[WARN] ============================================================"
    log "[WARN] expanded_assets scrape returned no .tar.xz for tag $LATEST_TAG"
    log "[WARN] (curl exit $ASSETS_CURL_EXIT, ${#ASSETS_HTML} bytes of HTML)"
    log "[WARN] GitHub's markup may have changed. Falling back to the"
    log "[WARN] '<tag>.tar.xz' naming guess, which is expected to 404."
    log "[WARN] ============================================================"
    TARBALL_NAME="${PROTON_DIR_NAME}.tar.xz"
else
    log "expanded_assets scrape resolved asset name: $TARBALL_NAME"
fi

# Folder is named after the ASSET, not the tag: tag
# iracing-dnsapi-fix-11.0-20260601 ships iracing-dnsapi-fixmes.tar.xz.
# Deriving from the tag meant the "already installed" check looked for a
# folder that could never exist - 300 MB re-downloaded every run - and
# overwriting the real folder left no NEW folder for the snapshot diff.
# Confirmed from the tarball itself after download.
PROTON_DIR_NAME="${TARBALL_NAME%.tar.xz}"
log "Expected Proton folder name (from asset filename): $PROTON_DIR_NAME"

TARBALL_URL="https://github.com/${GH_REPO}/releases/download/${LATEST_TAG}/${TARBALL_NAME}"
TARBALL_TMP="/tmp/$TARBALL_NAME"
log "Latest release asset: $TARBALL_NAME"

COMPAT_AVAIL_GB=$(free_space_gb "$COMPAT_TOOLS_DIR")
log "Step 6 — free space at $COMPAT_TOOLS_DIR: ${COMPAT_AVAIL_GB:-unknown} GB"
if [[ "$COMPAT_AVAIL_GB" =~ ^[0-9]+$ && "$COMPAT_AVAIL_GB" -lt 5 ]]; then
    gui_error "❌ Not enough free space to download and extract the Proton build.\n\nLocation: <tt>$(pe "$COMPAT_TOOLS_DIR")</tt>\nFree space: <b>${COMPAT_AVAIL_GB} GB</b>\n\nFree up a few GB and re-run this setup."
fi

if [[ -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]] && proton_build_looks_complete "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME"; then
    log "Step 6 complete — $PROTON_DIR_NAME already present and looks complete, skipping download"
    gui_info "<b>Custom Proton build is already installed and up to date.</b>\n\n<tt>$(pe "$PROTON_DIR_NAME")</tt>"
    SUMMARY_PROTON_BUILD="Already installed ($PROTON_DIR_NAME)"
else
    if [[ -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
        log "Existing $PROTON_DIR_NAME folder found but looks incomplete/corrupt (missing compatibilitytool.vdf, proton launcher, or files/dist) — removing and re-downloading"
        # :? aborts if the name is ever empty. Without it an empty
        # PROTON_DIR_NAME makes this rm -rf compatibilitytools.d itself.
        rm -rf "${COMPAT_TOOLS_DIR:?}/${PROTON_DIR_NAME:?}"
    fi
    if dry_skip "download $TARBALL_URL and extract into $COMPAT_TOOLS_DIR"; then
        SUMMARY_PROTON_BUILD="Would install ($PROTON_DIR_NAME) [dry run]"
    else
        DL_START_TS=$(date +%s)
        DL_ERR_TMP=$(mktemp)
        (curl -fSL -o "$TARBALL_TMP" "$TARBALL_URL" 2>"$DL_ERR_TMP") &
        DL_PID=$!
        gui_wait $DL_PID "Downloading custom Proton build...\n\n<tt>$TARBALL_NAME</tt>"
        wait "$DL_PID"
        DL_EXIT=$?
        DL_ELAPSED=$(($(date +%s) - DL_START_TS))

        DL_ERR_MSG=$(redact_path "$(cat "$DL_ERR_TMP" 2>/dev/null)")
        {
            echo "[download tarball, curl exit $DL_EXIT]"
            echo "$DL_ERR_MSG"
        } >>"$TECH_LOG"
        rm -f "$DL_ERR_TMP"

        MANUAL_CMD="mkdir -p \"$COMPAT_TOOLS_DIR\" && curl -fL -o \"/tmp/$TARBALL_NAME\" \"$TARBALL_URL\" && tar -xf \"/tmp/$TARBALL_NAME\" -C \"$COMPAT_TOOLS_DIR\" && rm -f \"/tmp/$TARBALL_NAME\""

        if [[ $DL_EXIT -ne 0 ]] || [[ ! -s "$TARBALL_TMP" ]]; then
            log "[ERROR] Proton build download failed (curl exit $DL_EXIT) after ${DL_ELAPSED}s: ${DL_ERR_MSG:-no error output}"
            rm -f "$TARBALL_TMP"
            gui_error "❌ Download failed (curl exit $DL_EXIT).\n\nCheck your internet connection and try re-running this setup.\n\nOr paste this single line into a terminal to do it manually:\n\n<tt>$(pe "$MANUAL_CMD")</tt>"
        fi
        TARBALL_SIZE_MB=$(du -sm "$TARBALL_TMP" 2>/dev/null | cut -f1)
        log "Downloaded $TARBALL_NAME successfully (${TARBALL_SIZE_MB:-unknown} MB in ${DL_ELAPSED}s)"

        # Snapshot top-level dirs to spot the newly-extracted one even if the
        # tarball's internal folder name doesn't match its filename.
        # The tarball knows its own top-level directory, so ask it rather
        # than inferring one. Falls through to the snapshot diff below if the
        # listing is unreadable for any reason.
        TAR_TOPDIR=$(tar -tf "$TARBALL_TMP" 2>/dev/null | head -n1 | cut -d/ -f1)
        if [[ -n "$TAR_TOPDIR" && "$TAR_TOPDIR" != "$PROTON_DIR_NAME" ]]; then
            log "Tarball's top-level folder is '$TAR_TOPDIR', not '$PROTON_DIR_NAME' — using the tarball's name"
            PROTON_DIR_NAME="$TAR_TOPDIR"
        elif [[ -n "$TAR_TOPDIR" ]]; then
            log "Tarball top-level folder confirmed as '$TAR_TOPDIR'"
        fi

        DIRS_BEFORE=$(find "$COMPAT_TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

        # No --no-same-owner or path-traversal guard: a hostile tarball could
        # write outside COMPAT_TOOLS_DIR. Same trust boundary as above.
        (run_redacted "$TECH_LOG" tar -xf "$TARBALL_TMP" -C "$COMPAT_TOOLS_DIR") &
        TAR_PID=$!
        gui_wait $TAR_PID "Extracting Proton build...\n\nAlmost done!"
        wait "$TAR_PID"
        TAR_EXIT=$?
        rm -f "$TARBALL_TMP"

        if [[ $TAR_EXIT -ne 0 ]]; then
            log "[ERROR] tar extraction failed (exit $TAR_EXIT)"
            gui_error "❌ Extraction failed (tar exit $TAR_EXIT).\n\nCheck the log:\n<tt>$(pe "$TECH_LOG")</tt>\n\nOr paste this single line into a terminal to do it manually:\n\n<tt>$(pe "$MANUAL_CMD")</tt>"
        fi

        if [[ ! -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
            DIRS_AFTER=$(find "$COMPAT_TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
            ACTUAL_DIR=$(comm -13 <(echo "$DIRS_BEFORE") <(echo "$DIRS_AFTER") | head -n1)
            if [[ -n "$ACTUAL_DIR" ]]; then
                log "Expected folder name '$PROTON_DIR_NAME' not found after extraction — using actual extracted folder '$(basename "$ACTUAL_DIR")' instead"
                PROTON_DIR_NAME=$(basename "$ACTUAL_DIR")
            else
                log "[ERROR] Extraction finished but $COMPAT_TOOLS_DIR/$PROTON_DIR_NAME is absent and no new folder appeared"
                gui_error "❌ Extraction finished but the expected folder wasn't there.\n\nExpected: <tt>$(pe "$COMPAT_TOOLS_DIR")/$(pe "$PROTON_DIR_NAME")</tt>\n\nOr paste this single line into a terminal to do it manually:\n\n<tt>$(pe "$MANUAL_CMD")</tt>"
            fi
        fi

        if ! proton_build_looks_complete "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME"; then
            log "[ERROR] Extraction finished but $PROTON_DIR_NAME is missing expected files (compatibilitytool.vdf, proton launcher, or files/dist) — likely a truncated download or interrupted extraction"
            gui_error "❌ The Proton build was extracted but looks incomplete.\n\nExpected files weren't found in:\n<tt>$(pe "$COMPAT_TOOLS_DIR")/$(pe "$PROTON_DIR_NAME")</tt>\n\nThis is usually a truncated download. Re-running this setup will remove and re-download it automatically — or paste this single line into a terminal to do it manually:\n\n<tt>$(pe "$MANUAL_CMD")</tt>"
        fi

        EXTRACTED_SIZE_MB=$(du -sm "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" 2>/dev/null | cut -f1)
        log "Step 6 complete — custom Proton build installed as $PROTON_DIR_NAME (${EXTRACTED_SIZE_MB:-unknown} MB extracted)"
        gui_info "<b>Custom Proton build installed!</b>\n\n<tt>$(pe "$PROTON_DIR_NAME")</tt>"
        SUMMARY_PROTON_BUILD="Installed ($PROTON_DIR_NAME)"
    fi
fi

# =============================================================================
# STEP 7 — Assign the compatibility tool
# =============================================================================
# Ahead of everything touching protontricks: it resolves which Proton to
# use from this mapping. Unassigned meant Step 8 and 10 ran against
# whatever Steam happened to have set, which is why a clean machine could
# never be set up in one pass.
# Narrow edit to config.vdf, verified after writing, restored on failure.
log "=== Step 7 — Assigning Compatibility Tool ==="

SUMMARY_COMPAT_CONFIG="Not attempted"

# The one and only "close Steam" prompt. Everything from here to the end
# of the run needs it closed, so it's asked once rather than three times.
ensure_steam_closed "<b>Steam needs to be closed for the rest of this setup.</b>

Please close Steam now, then click OK.

Leave it closed until the setup finishes."
log "Steam confirmed closed before Step 7 — stays closed for the rest of the run"

# Belt and braces: Steam rewrites config.vdf on every launch/exit, so
# re-check immediately before writing rather than trusting the check from
# a moment ago.
if pgrep -x steam &>/dev/null; then
    log "[ERROR] Step 7 — Steam still running immediately before config write"
    gui_error "❌ Steam is still running, so the compatibility tool can't be set safely.\n\nEverything after this point depends on it, so setup can't continue.\n\nPlease close Steam completely and re-run this setup."
fi

CONFIG_VDF="$STEAM_ROOT/config/config.vdf"
BACKUP_TS=$(date '+%Y%m%d-%H%M%S')

# What goes into config.vdf is the tool's declared name, which is not
# necessarily its folder name. PROTON_DIR_NAME stays the folder (Step 8
# needs it to find the proton launcher on disk); PROTON_TOOL_NAME is
# what Steam matches against.
PROTON_TOOL_NAME=$(proton_tool_internal_name "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME")
PROTON_DISPLAY_NAME=$(proton_tool_display_name "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME")
log "Step 7 — names: folder=<$PROTON_DIR_NAME> key=<$PROTON_TOOL_NAME> shown in Steam=<$PROTON_DISPLAY_NAME>"
if [[ "$PROTON_TOOL_NAME" != "$PROTON_DIR_NAME" ]]; then
    log "Step 7 — tool declares itself as '$PROTON_TOOL_NAME' (folder is '$PROTON_DIR_NAME'); using the declared name for Steam"
else
    log "Step 7 — tool name matches folder name: $PROTON_TOOL_NAME"
fi

if dry_skip "set iRacing's compatibility tool to $PROTON_DIR_NAME in config.vdf"; then
    SUMMARY_COMPAT_CONFIG="Auto-configured ($PROTON_DIR_NAME) [dry run]"
else

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
                vdf_set_kv "$CONFIG_VDF" "$((a_start + 1))" "$((a_end - 1))" "name" "$PROTON_TOOL_NAME"
                if [[ "$OLD_COMPAT_NAME" == "$PROTON_TOOL_NAME" ]]; then
                    log "Updated existing CompatToolMapping entry for $IRACING_APPID (unchanged: '$PROTON_TOOL_NAME')"
                else
                    log "Updated existing CompatToolMapping entry for $IRACING_APPID (was: '${OLD_COMPAT_NAME:-<empty>}' -> now: '$PROTON_TOOL_NAME')"
                fi
            else
                tmp_block=$(mktemp)
                printf '\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}\n' \
                    "$IRACING_APPID" "$PROTON_TOOL_NAME" >"$tmp_block"
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
                        sed -n "${a2_start},${a2_end}p" "$CONFIG_VDF" | grep -qF "\"$PROTON_TOOL_NAME\"" && verify_ok=true
                    fi
                fi
            fi

            if $verify_ok; then
                SUMMARY_COMPAT_CONFIG="Auto-configured ($PROTON_DISPLAY_NAME)"
                log "Step 7 — compatibility tool auto-configured to $PROTON_TOOL_NAME (verified)"
            else
                cp "$CONFIG_VDF.bak-$BACKUP_TS" "$CONFIG_VDF"
                SUMMARY_COMPAT_CONFIG="Auto-config failed — restored from backup"
                log "[ERROR] Step 7 — compat tool write verification failed, restored config.vdf from backup"
            fi
        else
            SUMMARY_COMPAT_CONFIG="Not found — CompatToolMapping section missing"
            log "Step 7 — CompatToolMapping section not found in config.vdf, skipping automatic edit"
        fi
    else
        SUMMARY_COMPAT_CONFIG="Not found — config.vdf missing"
        log "Step 7 — config.vdf not found at $CONFIG_VDF"
    fi

fi

# Anything from here on that fails leaves config.vdf already written but
# the prefix/install unfinished. Re-running recovers it, but log the point
# of no return so a support log shows exactly how far it got.
log "Step 7 — config.vdf write is the first irreversible change of the run"

# Unlike before, this is now a hard stop rather than a note on the final
# screen. Steps 8, 9 and 10 all depend on the mapping being right, so
# carrying on past a failure here just produces three more confusing
# errors downstream instead of one clear one here.
if [[ "$SUMMARY_COMPAT_CONFIG" != Auto-configured* ]]; then
    log "[ERROR] Step 7 — compatibility tool not assigned ($SUMMARY_COMPAT_CONFIG), cannot continue"
    gui_error "❌ Couldn't set iRacing's compatibility tool automatically.

Reason: <b>$SUMMARY_COMPAT_CONFIG</b>

The rest of this setup depends on it, so it can't continue. To set it by hand:

  1. Open Steam, right-click <b>iRacing</b> -> <b>Properties</b> -> <b>Compatibility</b>
  2. Tick <b>Force the use of a specific Steam Play compatibility tool</b>
  3. Choose <b>$(pe "${PROTON_DISPLAY_NAME:-$PROTON_DIR_NAME}")</b>
  4. Close Steam completely, then re-run this setup

If <tt>$(pe "${PROTON_DISPLAY_NAME:-$PROTON_DIR_NAME}")</tt> isn't in that list, restart Steam once first — it only scans <tt>$(pe "$COMPAT_TOOLS_DIR")</tt> at startup."
fi

gui_info "<b>Compatibility tool:</b> $SUMMARY_COMPAT_CONFIG"
log "Step 7 complete — $SUMMARY_COMPAT_CONFIG"

# =============================================================================
# STEP 8 — Bootstrap the Proton prefix
# =============================================================================
# Nothing used to create compatdata/$IRACING_APPID. Steam makes it on
# first launch, but a Direct Account user has no game to launch, so
# Steps 9 and 10 worked inside a prefix that didn't exist - the
# "could not load kernel32.dll" failures.
# Running the build directly with the STEAM_COMPAT_* vars is what Steam
# does on first launch, minus the game.
# Runs Windows code from the downloaded build. Same trust boundary as the
# tarball itself.
log "=== Step 8 — Proton Prefix ==="

SUMMARY_PREFIX="Not attempted"
IRACING_COMPATDATA=$(iracing_compatdata_dir)
PROTON_BIN="$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME/proton"

log "Step 8 — prefix path: $IRACING_COMPATDATA"

if [[ ! -x "$PROTON_BIN" ]]; then
    log "[ERROR] Step 8 — Proton launcher not executable at $PROTON_BIN"
    gui_error "❌ The Proton build's launcher is missing or not executable:\n\n<tt>$(pe "$PROTON_BIN")</tt>\n\nDelete <tt>$(pe "$COMPAT_TOOLS_DIR")/$(pe "$PROTON_DIR_NAME")</tt> and re-run this setup so it can be freshly downloaded."
fi

if prefix_looks_ready; then
    log "Step 8 complete — prefix already present at $IRACING_COMPATDATA, skipping bootstrap"
    SUMMARY_PREFIX="Already present"
else
    if dry_skip "bootstrap a Proton prefix at $IRACING_COMPATDATA"; then
        SUMMARY_PREFIX="Would be created [dry run]"
        # Step 10 needs to know the prefix isn't real, or its
        # (read-only, so otherwise unguarded) protontricks query fails
        # against a prefix that was never created.
        DRY_PREFIX_SKIPPED=true
        log "Step 8 complete — skipped (dry run)"
    else
        mkdir -p "$IRACING_COMPATDATA"

        # Some Proton builds refuse to run outside the Steam Linux Runtime
        # container. Try the plain invocation first (fast, and works for most
        # builds), then fall back to the runtime entry point if one is
        # installed. Both attempts get logged so a failure report shows which
        # path was taken.
        SLR_ENTRY=""
        while IFS= read -r slr_lib; do
            [[ -z "$slr_lib" ]] && continue
            for slr in SteamLinuxRuntime_sniper SteamLinuxRuntime_soldier; do
                [[ -x "$slr_lib/steamapps/common/$slr/_v2-entry-point" ]] && {
                    SLR_ENTRY="$slr_lib/steamapps/common/$slr/_v2-entry-point"
                    break 2
                }
            done
        done < <(get_steam_libraries)
        log "Step 8 — Steam Linux Runtime entry point: ${SLR_ENTRY:-none found}"

        BOOTSTRAP_START_TS=$(date +%s)
        : >"$PROTON_BOOTSTRAP_LOG"

        # SteamAppId/STEAM_COMPAT_APP_ID are set because Steam always sets
        # them: without one, protonfixes decides it's running under a unit
        # test and skips every fix, so this prefix would differ from the one
        # Steam builds on first launch.
        # MANGOHUD=0 keeps a globally-enabled overlay out of a headless run —
        # it has nothing to draw on, and its chatter buries the Proton output
        # this log exists to capture.
        (
            MANGOHUD=0 \
                SteamAppId="$IRACING_APPID" \
                STEAM_COMPAT_APP_ID="$IRACING_APPID" \
                STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" \
                STEAM_COMPAT_DATA_PATH="$IRACING_COMPATDATA" \
                run_redacted "$PROTON_BOOTSTRAP_LOG" "$PROTON_BIN" run cmd /c exit
        ) &
        BOOTSTRAP_PID=$!
        gui_wait $BOOTSTRAP_PID "Preparing the Windows environment for iRacing...\n\nThis is a one-off and takes a minute or two."
        wait "$BOOTSTRAP_PID"
        BOOTSTRAP_EXIT=$?
        log "Step 8 — direct bootstrap finished (exit $BOOTSTRAP_EXIT) after $(($(date +%s) - BOOTSTRAP_START_TS))s"

        if ! prefix_looks_ready && [[ -n "$SLR_ENTRY" ]]; then
            log "Step 8 — direct bootstrap didn't produce a usable prefix, retrying through $SLR_ENTRY"
            (
                MANGOHUD=0 \
                    SteamAppId="$IRACING_APPID" \
                    STEAM_COMPAT_APP_ID="$IRACING_APPID" \
                    STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" \
                    STEAM_COMPAT_DATA_PATH="$IRACING_COMPATDATA" \
                    run_redacted "$PROTON_BOOTSTRAP_LOG" "$SLR_ENTRY" --verb=run -- "$PROTON_BIN" run cmd /c exit
            ) &
            BOOTSTRAP_PID=$!
            gui_wait $BOOTSTRAP_PID "Preparing the Windows environment for iRacing...\n\nTrying again via the Steam Linux Runtime."
            wait "$BOOTSTRAP_PID"
            BOOTSTRAP_EXIT=$?
            log "Step 8 — runtime bootstrap finished (exit $BOOTSTRAP_EXIT)"
        fi

        BOOTSTRAP_ELAPSED=$(($(date +%s) - BOOTSTRAP_START_TS))

        # proton returns before wineserver has finished settling, so give the
        # prefix a few seconds to finish appearing rather than declaring
        # failure on a single check taken a moment too early.
        settle=0
        while ! prefix_looks_ready && [[ $settle -lt 10 ]]; do
            sleep 1
            settle=$((settle + 1))
        done
        [[ $settle -gt 0 ]] && log "Step 8 — prefix took ${settle}s to settle after proton returned"

        if ! prefix_looks_ready; then
            log "[ERROR] Step 8 — prefix bootstrap failed after ${BOOTSTRAP_ELAPSED}s, no system32 under $IRACING_COMPATDATA"
            log "[STATE] compat tool IS assigned ($PROTON_TOOL_NAME) but prefix is NOT created — re-running recovers"
            gui_error "❌ Couldn't prepare the Windows environment iRacing runs inside.

Everything after this point needs it, so setup can't continue.

Raw output is in:
<tt>$(pe "$PROTON_BOOTSTRAP_LOG")</tt>

You can also try it by hand — paste this single line into a terminal:

<tt>SteamAppId=$IRACING_APPID STEAM_COMPAT_APP_ID=$IRACING_APPID STEAM_COMPAT_CLIENT_INSTALL_PATH=\"$(pe "$STEAM_ROOT")\" STEAM_COMPAT_DATA_PATH=\"$(pe "$IRACING_COMPATDATA")\" \"$(pe "$PROTON_BIN")\" run cmd /c exit</tt>"
        fi

        log "Step 8 complete — prefix bootstrapped at $IRACING_COMPATDATA in ${BOOTSTRAP_ELAPSED}s"
        SUMMARY_PREFIX="Created (${BOOTSTRAP_ELAPSED}s)"
    fi
fi

# =============================================================================
# STEP 9 — Direct account: install via Windows installer
# =============================================================================
# Step 5 decided whether this runs. Left here is the part needing a
# working runtime: build (6), assignment (7), prefix (8). Running it
# before those was the ordering bug.

run_iracing_windows_installer_flow() {
    local entry_reason="$1" # install | repair

    log "Step 9 — entering Windows installer flow (reason: $entry_reason)"

    # Under Proton, Z: maps to the real filesystem root "/", so the correct
    # conversion is always "Z:" + the full path with slashes flipped —
    # regardless of whether the path lives under $HOME or on another
    # drive/library entirely. (Previously this only handled $HOME-relative
    # paths and used the wrong folder name, breaking secondary libraries.)
    IRACING_WIN_PATH="Z:${IRACING_STEAM_PATH//\//\\}"
    # Convert backslashes to Pango HTML entities so zenity renders them correctly
    IRACING_WIN_PATH_DISPLAY=$(echo "$IRACING_WIN_PATH" | sed 's/\\/\&#92;/g')

    IRACING_DOWNLOAD_URL="https://members.iracing.com/download/member/noservice.jsp"

    local opening
    if [[ "$entry_reason" == "repair" ]]; then
        opening="<b>Repairing your iRacing installation.</b>

Some expected files were missing, so the iRacing installer will be run over the top of what's already there."
    else
        opening="<b>iRacing stub detected — the full game files aren't installed yet.</b>"
    fi

    gui_info "$opening

You'll need to run the iRacing Windows installer.  Here's what to do:

  1. Log into the iRacing members site in the browser window that opens
  2. Download the Windows installer
  3. Save it to your <b>Downloads</b> folder
  4. Come back here — the rest is automatic

Click OK to open the download page and continue."

    if ! dry_skip "open $IRACING_DOWNLOAD_URL in a browser"; then
        (xdg-open "$IRACING_DOWNLOAD_URL" >/dev/null 2>&1 &) 2>/dev/null
        log "Opened iRacing download page via xdg-open"
    fi

    # xdg-open fails silently when there's no browser handler registered,
    # which used to drop the user straight into polling for a file they
    # were never prompted to fetch. Confirm rather than assume.
    if ! gui_question "<b>The iRacing download page should have opened in your browser.</b>

Log in, download the Windows installer, and save it here:

    <tt><b>$(pe "$DOWNLOADS_DIR")</b></tt>

<b>Did the page open, and has the download started?</b>" "cancel"; then
        log "[WARN] Step 9 — user reported the browser did not open"
        gui_warn "No problem — open this address yourself:

<tt>$(pe "$IRACING_DOWNLOAD_URL")</tt>

Log in, download the Windows installer, and save it to:
<tt>$(pe "$DOWNLOADS_DIR")</tt>

Click OK when the download has started."
    fi

    # Picks the installer with the latest embedded release date, not
    # just the most recently modified file — a stray older copy dragged
    # into Downloads (or a leftover partial download) shouldn't win
    # just because of its mtime. Filenames look like
    # iRacingInstaller_win_YYYY.MM.DD.NN.exe — sorted on the
    # YYYY.MM.DD.NN portion numerically, dot-field by dot-field.
    find_latest_iracing_installer() {
        local f best="" best_key=""
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local base date_part key
            base=$(basename "$f")
            date_part="${base#iRacingInstaller_win_}"
            date_part="${date_part%.exe}"
            # Zero-pad each dot-separated component to 4 digits so
            # string comparison sorts the same as numeric comparison
            # (handles YYYY.MM.DD.NN without needing `sort -V` quirks).
            key=$(awk -F. '{ for (i=1;i<=NF;i++) printf "%04d.", $i }' <<<"$date_part")
            if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
                best="$f"
                best_key="$key"
            fi
        done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -type f -size +100M -name 'iRacingInstaller_win_*.exe' 2>/dev/null)
        echo "$best"
    }

    INSTALLER_EXE=""
    installer_wait_attempt=0
    installer_silent_checks=4  # ~8s silent
    installer_patient_checks=6 # ~12s more with a visible "still looking" window
    while [[ -z "$INSTALLER_EXE" ]]; do
        installer_wait_attempt=$((installer_wait_attempt + 1))
        INSTALLER_EXE=$(find_latest_iracing_installer)
        [[ -n "$INSTALLER_EXE" ]] && break

        if [[ $installer_wait_attempt -le $installer_silent_checks ]]; then
            sleep 2
        elif [[ $installer_wait_attempt -le $((installer_silent_checks + installer_patient_checks)) ]]; then
            gui_open "Still looking for the installer in <tt>$DOWNLOADS_DIR</tt>...\n\nA real download can take a few minutes — hang tight."
            sleep 2
            gui_close
        else
            if ! zenity --question --title="$TITLE" --text="No iRacing installer found in <tt>$DOWNLOADS_DIR</tt> yet.\n\nHas the download finished? Click <b>Yes</b> to keep waiting, or <b>No</b> to quit." --ok-label="Yes, keep waiting" --cancel-label="No, quit" --width=500 2>/dev/null; then
                log "User quit at Step 9 while waiting for the installer download"
                exit 0
            fi
            installer_wait_attempt=0
        fi
    done

    # Size alone never ruled out a part-finished download - a real
    # installer is ~1.5 GB, so a partial can easily clear any floor worth
    # setting. Waiting for the size to stop changing does rule it out.
    INSTALLER_SIZE_A=$(stat -c %s "$INSTALLER_EXE" 2>/dev/null || echo 0)
    sleep 3
    INSTALLER_SIZE_B=$(stat -c %s "$INSTALLER_EXE" 2>/dev/null || echo 0)
    while [[ "$INSTALLER_SIZE_A" != "$INSTALLER_SIZE_B" ]]; do
        log "Installer still downloading ($INSTALLER_SIZE_A -> $INSTALLER_SIZE_B bytes), waiting"
        gui_open "The installer is still downloading...\n\nWaiting for it to finish."
        sleep 3
        gui_close
        INSTALLER_SIZE_A="$INSTALLER_SIZE_B"
        INSTALLER_SIZE_B=$(stat -c %s "$INSTALLER_EXE" 2>/dev/null || echo 0)
    done

    log "Installer found after $installer_wait_attempt polling pass(es), size stable at $INSTALLER_SIZE_B bytes"

    gui_info "Found installer: <tt>$(basename "$INSTALLER_EXE")</tt>

The installer will now run on its own and install iRacing to the
correct location in your Steam library:

<tt><b>$IRACING_WIN_PATH_DISPLAY</b></tt>

This takes a few minutes.  You won't see the installer's own window —
a progress window will appear here instead.

Click OK to begin."

    INSTALLER_SIZE_MB=$(du -sm "$INSTALLER_EXE" 2>/dev/null | cut -f1)
    log "Step 9 — installer file size: ${INSTALLER_SIZE_MB:-unknown} MB"

    # Steam has been closed since Step 7 and stays closed to the end of
    # the run, so there's no re-confirmation here any more — running the
    # installer into a prefix Steam still has open risks file-lock
    # conflicts, which is why it was closed once and left that way.
    if dry_skip "run $(basename "$INSTALLER_EXE") into $IRACING_STEAM_PATH via protontricks-launch"; then
        SUMMARY_IRACING_FILES="Would install via Windows installer [dry run]"
        return 0
    fi

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

    # The installer's Inno [Run] entry launches the iRacing UI when it
    # finishes, and /SILENT does not suppress it (confirmed: the shell
    # returns while XALIA warnings from the launched UI keep arriving).
    # That leaves processes holding the prefix open, which protontricks
    # in Step 10 then has to contend with. Shut the prefix down cleanly
    # before carrying on.
    gui_open "Closing the iRacing launcher the installer opened..."
    WINESERVER_BIN=""
    for d in files dist; do
        [[ -x "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME/$d/bin/wineserver" ]] && {
            WINESERVER_BIN="$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME/$d/bin/wineserver"
            break
        }
    done
    if [[ -n "$WINESERVER_BIN" ]]; then
        log "Shutting down prefix via $WINESERVER_BIN -k"
        WINEPREFIX="$IRACING_COMPATDATA/pfx" run_redacted "$TECH_LOG" "$WINESERVER_BIN" -k || true
        sleep 2
    else
        log "[WARN] Step 9 — no wineserver found under $COMPAT_TOOLS_DIR/$PROTON_DIR_NAME, cannot close the launcher the installer opened"
    fi
    gui_close

    gui_open "Verifying iRacing installation..."
    sleep 0.5
    gui_close

    # The old check counted top-level files and passed if there were more
    # than three, which a partial install satisfies trivially — so a
    # failed repair reported "installation confirmed" and put a tick on
    # the summary screen. Verified against the installer layout rather
    # than Steam's depot layout: a real run of the 2026.06.09.01
    # installer produces the executables, EasyAntiCheat, ui and its own
    # uninstaller, but no cars or tracks - the launcher fetches content
    # on first run, so content folders are not something this script
    # should ever wait for.

    if ! iracing_fingerprint_complete "$IRACING_STEAM_PATH" verbose installer; then
        log "[ERROR] Step 9 — post-install fingerprint check failed (installer exit $INSTALL_EXIT)"
        log "[STATE] tool assigned + prefix created, install incomplete at $IRACING_STEAM_PATH — next run classifies this as 'partial'"
        gui_error "iRacing doesn't look like it installed correctly (installer exit code $INSTALL_EXIT).

Expected location: <tt>$(pe "$IRACING_STEAM_PATH")</tt>

Please re-run the installer and make sure the install path is set to:

    <tt><b>$IRACING_WIN_PATH_DISPLAY</b></tt>

Raw installer output is in:
<tt>$(pe "$TECH_LOG")</tt>"
    fi

    IRACING_INSTALLED_SIZE_MB=$(du -sm "$IRACING_STEAM_PATH" 2>/dev/null | cut -f1)
    log "Step 9 complete — install verified at $IRACING_STEAM_PATH"
    log "Step 9 — final install size: ${IRACING_INSTALLED_SIZE_MB:-unknown} MB"
    gui_info "<b>iRacing installation confirmed!</b>\n\nLocation: <tt>$(pe "$IRACING_STEAM_PATH")</tt>"
    if [[ "$entry_reason" == "repair" ]]; then
        SUMMARY_IRACING_FILES="Repaired via Windows installer"
    else
        SUMMARY_IRACING_FILES="Installed via Windows installer"
    fi
}

if [[ "$IRACING_INSTALL_ACTION" != "none" ]]; then
    log "=== Step 9 — Direct Account Installation ==="
    run_iracing_windows_installer_flow "$IRACING_INSTALL_ACTION"
else
    log "=== Step 9 — skipped (no installer action planned) ==="
fi

# =============================================================================
# STEP 10 — Install Proton/Wine libraries
# =============================================================================
log "=== Step 10 — Proton Libraries ==="

# Steam was closed back in Step 7 and is meant to stay closed for the
# rest of the run, but a user reopening it is a real possibility this
# deep in, and protontricks against a live Steam is a file-lock hazard.
# Cheap check, no prompt unless it's actually running.
if pgrep -x steam &>/dev/null; then
    log "[WARN] Step 10 — Steam reopened since Step 7, asking user to close it again"
    ensure_steam_closed "<b>Steam has been reopened, and needs to be closed again.</b>

Please close Steam now, then click OK."
fi

if ${DRY_PREFIX_SKIPPED:-false}; then
    # No prefix was created this run, so there is nothing to query. An
    # empty list means everything reads as missing, which then hits the
    # dry-run guard on the install below and logs what a real run would
    # have installed.
    log "[DRY-RUN] would query protontricks for installed libraries (no prefix exists in a dry run)"
    INSTALLED_LIST=""
    LIST_EXIT=0
else
    : >"$PROTONTRICKS_LOG.list"
    (run_redacted "$PROTONTRICKS_LOG.list" protontricks "$IRACING_APPID" list-installed) &
    LIST_PID=$!
    gui_wait $LIST_PID "Checking installed Proton libraries..."
    wait "$LIST_PID"
    LIST_EXIT=$?

    INSTALLED_LIST=$(cat "$PROTONTRICKS_LOG.list" 2>/dev/null || true)
fi

# A failed (or empty-output) list-installed almost always means the
# Wine/Proton prefix itself can't run right now — most commonly an
# incomplete or corrupted custom Proton build under
# compatibilitytools.d (see Step 6's validity check) — rather than the
# prefix genuinely having zero libraries. Treating that silently as
# "13/13 missing" was masking the real problem and sending users
# straight into a doomed force-install. Surface it instead.
if ! ${DRY_PREFIX_SKIPPED:-false} && { [[ $LIST_EXIT -ne 0 ]] || [[ -z "$INSTALLED_LIST" ]]; }; then
    log "[ERROR] protontricks list-installed failed (exit $LIST_EXIT, output ${#INSTALLED_LIST} bytes) — see $PROTONTRICKS_LOG.list"
    gui_error "❌ Couldn't check which Proton libraries are already installed (protontricks list-installed failed).\n\nThis almost always means the Proton/Wine runtime currently assigned to iRacing can't start at all — often because a custom Proton build under:\n<tt>$(pe "$COMPAT_TOOLS_DIR")</tt>\nis incomplete or corrupted.\n\nTry deleting that Proton build's folder and re-running this setup so it can be freshly downloaded, then try again.\n\nRaw output saved to:\n<tt>$(pe "$PROTONTRICKS_LOG").list</tt>"
    # gui_error exits — the .list file is deliberately left on disk here
    # (not cleaned up) so the user/support has the raw output to look at.
fi
rm -f "$PROTONTRICKS_LOG.list"

MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! echo "$INSTALLED_LIST" | grep -qw "$pkg"; then
        MISSING+=("$pkg")
    fi
done
log "Proton library check: ${#MISSING[@]} of ${#REQUIRED_PKGS[@]} required libraries missing (${MISSING[*]:-none})"

# original line with both font packages:
# Install <b>corefonts</b> and <b>allfonts</b>?
if gui_question "<b>Optional fonts</b>

<b>corefonts</b> isn't required to play iRacing, but without it you may see
text rendering oddly in-game or in the UI.

⚠️  Be aware this can take a very long time to install.

<b>Install corefonts?</b>" "cancel"; then
    # commented out for disabling allfonts
    #    for font_pkg in corefonts allfonts; do
    #        if ! echo "$INSTALLED_LIST" | grep -qw "$font_pkg"; then
    #            MISSING+=("$font_pkg")
    #        fi
    #    done
    if ! echo "$INSTALLED_LIST" | grep -qw "corefonts"; then
        MISSING+=("corefonts")
    fi
    log "Step 10 — user opted in to installing corefonts"
else
    log "Step 10 — user declined optional fonts"
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
    log "Step 10 complete — all ${#REQUIRED_PKGS[@]} required Proton libraries already present"
    gui_info "<b>All required Proton libraries are already installed.</b>"
    SUMMARY_PROTON_LIBS="All ${#REQUIRED_PKGS[@]} libraries already present"
else
    gui_info "⏳ <b>Installing ${#MISSING[@]} Proton library/libraries...</b>

This can take several minutes.

Libraries to install:
<tt>${MISSING[*]}</tt>

Click OK and a progress window will appear."

    if dry_skip "install Proton libraries via protontricks: ${MISSING[*]}"; then
        SUMMARY_PROTON_LIBS="Would install ${#MISSING[@]} libraries [dry run]"
    else
        PT_START_TS=$(date +%s)
        : >"$PROTONTRICKS_LOG"
        run_redacted "$PROTONTRICKS_LOG" protontricks "$IRACING_APPID" -q --force "${MISSING[@]}" &
        PT_PID=$!
        gui_wait $PT_PID "Installing Proton libraries...\n\nThis can take several minutes, please wait."
        wait "$PT_PID"
        PT_EXIT=$?
        PT_ELAPSED=$(($(date +%s) - PT_START_TS))

        if [[ $PT_EXIT -ne 0 ]]; then
            log "[ERROR] protontricks force-install failed (exit $PT_EXIT) after ${PT_ELAPSED}s — see $PROTONTRICKS_LOG"
            gui_error "❌ protontricks hit an error (code $PT_EXIT).\n\nCheck the log for details:\n<tt>$(pe "$PROTONTRICKS_LOG")</tt>"
        fi

        log "Step 10 complete — ${#MISSING[@]} Proton libraries installed successfully in ${PT_ELAPSED}s"
        gui_info "<b>All required Proton libraries are now installed.</b>"
        SUMMARY_PROTON_LIBS="${#MISSING[@]} libraries installed"
    fi
fi

# =============================================================================
# STEP 11 — Auto-configure launch options
# =============================================================================
# Split from the compatibility tool write (now Step 7) because nothing
# depends on launch options, so they can stay late where a failure is
# only a note on the final screen rather than a hard stop.
log "=== Step 11 — Auto-Configuring Launch Options ==="

SUMMARY_LAUNCH_OPTIONS="Not attempted"
IRACING_LAUNCH_OPTIONS='PROTON_LOG=1 LD_PRELOAD=\"\" %command%'

# Steam rewrites localconfig.vdf on every launch/exit, so re-check right
# before writing rather than trusting Step 7's check. Unlike Step 7 this
# is a skip, not a stop.
if pgrep -x steam &>/dev/null; then
    log "[ERROR] Step 11 — Steam running immediately before config write, skipping automatic edit"
    SUMMARY_LAUNCH_OPTIONS="Skipped — Steam was running"
elif dry_skip "set iRacing's launch options to PROTON_LOG=1 in localconfig.vdf"; then
    SUMMARY_LAUNCH_OPTIONS="Auto-configured (PROTON_LOG=1) [dry run]"
else
    BACKUP_TS=$(date '+%Y%m%d-%H%M%S')

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
                    log "Step 11 — launch options auto-configured (verified)"
                else
                    cp "$LOCALCONFIG_VDF.bak-$BACKUP_TS" "$LOCALCONFIG_VDF"
                    SUMMARY_LAUNCH_OPTIONS="Auto-config failed — restored from backup"
                    log "[ERROR] Step 11 — launch options write verification failed, restored localconfig.vdf from backup"
                fi
            else
                SUMMARY_LAUNCH_OPTIONS="Not found — apps section missing"
                log "Step 11 — 'apps' section not found in localconfig.vdf, skipping automatic edit"
            fi
        else
            SUMMARY_LAUNCH_OPTIONS="Not found — localconfig.vdf missing"
            log "Step 11 — localconfig.vdf not found at $LOCALCONFIG_VDF"
        fi
    else
        SUMMARY_LAUNCH_OPTIONS="Not found — couldn't resolve Steam account folder"
        log "Step 11 — could not resolve steamid3 under $STEAM_ROOT/userdata"
    fi
fi

gui_info "<b>Launch options:</b> $SUMMARY_LAUNCH_OPTIONS

If that says anything other than auto-configured, you'll find manual instructions for it on the final screen."

log "Step 11 complete — launch options: $SUMMARY_LAUNCH_OPTIONS"

# =============================================================================
# STEP 12 — Optional extras
# =============================================================================
log "=== Step 12 — Optional Extras ==="

# --- Backup /etc/hosts before touching it ---
# .orig.bak is written once and never again, so a pristine copy survives
# however many times this gets re-run. hosts.bak is the rolling one.
if [[ ! -f /etc/hosts.orig.bak ]]; then
    if ! dry_skip "back up /etc/hosts to /etc/hosts.orig.bak (one-off pristine copy)"; then
        (run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" cp /etc/hosts /etc/hosts.orig.bak) &
        gui_wait $! "Backing up /etc/hosts...\n\nA password prompt window may appear — enter your password there if asked."
        log "Wrote pristine /etc/hosts.orig.bak"
    fi
else
    log "/etc/hosts.orig.bak already exists — leaving it alone"
fi

if [[ ! -f /etc/hosts.bak ]]; then
    (run_redacted "$TECH_LOG" "${RUN_AS_ROOT[@]}" cp /etc/hosts /etc/hosts.bak) &
    gui_wait $! "Backing up /etc/hosts...\n\nA password prompt window may appear — enter your password there if asked."
    log "Backed up /etc/hosts to /etc/hosts.bak"
else
    log "/etc/hosts.bak already exists — skipping backup"
fi

HOSTS_ENTRY="0.0.0.0 modules-cdn.eac-prod.on.epicgames.com"

# Step 8 already resolved and created the prefix, so derive the Documents
# folder from it rather than searching the libraries a second time. The
# iRacing subfolder itself is created by the game on first launch, so it
# still won't exist on a first run — the shortcut step below handles that.
IRACING_DOCS="$IRACING_COMPATDATA/pfx/drive_c/users/steamuser/Documents/iRacing"
if [[ -d "$IRACING_DOCS" ]]; then
    log "iRacing Documents folder found at $IRACING_DOCS"
else
    log "iRacing Documents folder not created yet — expected at $IRACING_DOCS"
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
        if dry_skip "add '$HOSTS_ENTRY' to /etc/hosts"; then
            SUMMARY_EAC="Would apply [dry run]"
        else
            (echo "$HOSTS_ENTRY" | "${RUN_AS_ROOT[@]}" tee -a /etc/hosts >/dev/null) &
            gui_wait $! "Applying EAC workaround...\n\nA password prompt window may appear — enter your password there if asked."
            if grep -qF "$HOSTS_ENTRY" /etc/hosts 2>/dev/null; then
                log "EAC hosts entry applied and verified"
                gui_info "EAC workaround applied."
                SUMMARY_EAC="Applied"
            else
                log "[ERROR] EAC hosts write did not land — /etc/hosts has no entry after tee"
                gui_warn "The EAC workaround didn't get written to /etc/hosts.\n\nAdd this line yourself if you want it:\n\n<tt>$HOSTS_ENTRY</tt>"
                SUMMARY_EAC="Failed — not written"
            fi
        fi
    else
        log "User declined the EAC workaround"
        SUMMARY_EAC="Skipped"
    fi
fi

# --- Documents symlink ---
# A symlink existing doesn't mean it works. Moving libraries moves the
# prefix, leaving this dangling, and the old -L check called that fine.
# Repoint when stale: covers dangling and wrong-library both.
if [[ -L "$DOCS_LINK" ]]; then
    DOCS_CURRENT_TARGET=$(readlink "$DOCS_LINK")
    if [[ "$DOCS_CURRENT_TARGET" == "$IRACING_DOCS" && -d "$DOCS_LINK" ]]; then
        log "Documents shortcut already points at the current prefix"
        gui_info "<b>Documents shortcut already exists.</b>\n\n<tt>$(pe "$DOCS_LINK")</tt>"
        SUMMARY_DOCS="Already exists"
    elif [[ ! -d "$IRACING_DOCS" ]]; then
        log "[WARN] Documents shortcut is stale (-> $DOCS_CURRENT_TARGET) but the current prefix has no iRacing Documents folder yet"
        gui_warn "Your <tt>$(pe "$DOCS_LINK")</tt> shortcut points somewhere that no longer exists:\n\n<tt>$(pe "$DOCS_CURRENT_TARGET")</tt>\n\niRacing hasn't created its Documents folder in the current prefix yet, so it can't be repointed. Launch iRacing once, then re-run this setup."
        SUMMARY_DOCS="Stale — target missing, launch iRacing first"
    elif gui_question "<b>Your iRacing Documents shortcut is out of date.</b>

This usually happens after moving iRacing to a different drive.

It points here now, and this folder no longer exists:

    <tt><b>$(pe "$DOCS_CURRENT_TARGET")</b></tt>

iRacing actually keeps its files here:

    <tt><b>$(pe "$IRACING_DOCS")</b></tt>

<b>Update the shortcut to point at the new location?</b>"; then
        if ! dry_skip "repoint $DOCS_LINK -> $IRACING_DOCS"; then
            rm -f "$DOCS_LINK"
            ln -s "$IRACING_DOCS" "$DOCS_LINK"
        fi
        log "Documents shortcut repointed (was: $DOCS_CURRENT_TARGET -> now: $IRACING_DOCS)"
        gui_info "Shortcut updated.\n\n<tt>$(pe "$DOCS_LINK")</tt>"
        SUMMARY_DOCS="Repointed to the current prefix"
    else
        log "User declined to repoint the stale Documents shortcut"
        SUMMARY_DOCS="Stale — left as-is by choice"
    fi
elif [[ -d "$IRACING_DOCS" && ! -e "$DOCS_LINK" ]]; then
    if gui_question "<b>iRacing Documents shortcut</b>

Steam on Linux keeps your iRacing settings, car setups and replays deep
inside a hidden folder. A shortcut makes them easy to get to.

It would be created here:

    <tt><b>$(pe "$DOCS_LINK")</b></tt>

pointing at:

    <tt><b>$(pe "$IRACING_DOCS")</b></tt>

<b>Create the shortcut?</b>"; then
        dry_skip "symlink $DOCS_LINK -> $IRACING_DOCS" || ln -s "$IRACING_DOCS" "$DOCS_LINK"
        log "Documents shortcut created"
        gui_info "Shortcut created at <tt>~/Documents/iRacing</tt>"
        SUMMARY_DOCS="Created"
    else
        log "User declined the Documents shortcut"
        SUMMARY_DOCS="Skipped"
    fi
else
    log "iRacing Documents folder doesn't exist yet — can't offer the shortcut"
    gui_warn "iRacing's Documents folder doesn't exist yet.\n\nLaunch iRacing once to create it, then you can make the shortcut by hand:\n\n<tt>ln -s \"$(pe "$IRACING_DOCS")\" \"$(pe "$DOCS_LINK")\"</tt>"
    SUMMARY_DOCS="Not yet - launch iRacing first"
fi

log "Step 12 complete — EAC: $SUMMARY_EAC | docs shortcut: $SUMMARY_DOCS"

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
<tt>Proton prefix         </tt>${SUMMARY_PREFIX}
<tt>Compatibility tool    </tt>${SUMMARY_COMPAT_CONFIG}
<tt>Launch options        </tt>${SUMMARY_LAUNCH_OPTIONS}
<tt>EAC workaround        </tt>${SUMMARY_EAC}
<tt>Documents shortcut    </tt>${SUMMARY_DOCS}
<tt>─────────────────────────────────────────────────────</tt>"

log "Setup summary — packages: $SUMMARY_PACKAGES | login: $SUMMARY_LOGIN | type: $SUMMARY_IRACING_TYPE | files: $SUMMARY_IRACING_FILES | proton libs: $SUMMARY_PROTON_LIBS | proton build: $SUMMARY_PROTON_BUILD | prefix: $SUMMARY_PREFIX | compat config: $SUMMARY_COMPAT_CONFIG | launch options: $SUMMARY_LAUNCH_OPTIONS | EAC: $SUMMARY_EAC | docs shortcut: $SUMMARY_DOCS"
gui_info "$SUMMARY_TEXT"

# Only the launch options can still be outstanding here: Step 7 exits on
# a failed compatibility tool write, so reaching this point means that
# one succeeded. The manual instructions for it live in Step 7's error
# dialog rather than being duplicated below.
COMPAT_DONE=true
LAUNCH_DONE=false
[[ "$SUMMARY_LAUNCH_OPTIONS" == Auto-configured* ]] && LAUNCH_DONE=true

if $LAUNCH_DONE; then
    FINAL_STEPS="<b>Compatibility tool and launch options were already set for you</b> — <tt>$(pe "${PROTON_DISPLAY_NAME:-$PROTON_DIR_NAME}")</tt> with <tt>PROTON_LOG=1</tt> enabled for troubleshooting.

Open Steam and you're ready to race.

If you ever want to double-check: Right-click iRacing -> Properties -> Compatibility, and Properties -> General -> Launch Options."
else
    MANUAL_STEPS=""
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

SCRIPT_ELAPSED=$(($(date +%s) - SCRIPT_START_TS))
SCRIPT_ELAPSED_FMT=$(printf '%dm%02ds' $((SCRIPT_ELAPSED / 60)) $((SCRIPT_ELAPSED % 60)))
log "Setup complete — compatibility tool: $PROTON_DIR_NAME | compat auto-config: $COMPAT_DONE | launch options auto-config: $LAUNCH_DONE | total runtime: $SCRIPT_ELAPSED_FMT"
