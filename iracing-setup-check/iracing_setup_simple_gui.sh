#!/usr/bin/env bash
# =============================================================================
# iRacing Setup — Simple Edition (Zenity GUI)
# Assumes: fresh distro install, Steam in $HOME/.steam/steam, single library
# Supports: Arch / CachyOS / EndeavourOS / Debian / Ubuntu / Fedora / Nobara
# =============================================================================

# --- Paths ---
STEAM_ROOT="$HOME/.steam/steam"
STEAM_APPS="$STEAM_ROOT/steamapps"
COMPAT_TOOLS_DIR="$STEAM_ROOT/compatibilitytools.d"
IRACING_APPID="266410"

# --- Log ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERAL_LOG="$SCRIPT_DIR/danfrasers-iracing-setup.log"
PROTONTRICKS_LOG="$SCRIPT_DIR/danfrasers-iracing-step8.log"
: >"$GENERAL_LOG"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$GENERAL_LOG"; }

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
# Only needed for the Direct Account flow, where we must know exactly
# where to point the Windows installer's /DIR= switch.
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

# Show info popup — user clicks OK to continue
gui_info() {
    zenity --info \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap 2>/dev/null
}

# Show warning popup — user clicks OK to continue
gui_warn() {
    zenity --warning \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap 2>/dev/null
}

# Show error popup then exit
gui_error() {
    zenity --error \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap 2>/dev/null
    log "[ERROR] $1"
    exit 1
}

# Show yes/no question — returns 0 for Yes, 1 for No
gui_question() {
    zenity --question \
        --title="$TITLE" \
        --text="$1" \
        --width=500 \
        --no-wrap 2>/dev/null
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
trap 'gui_close' EXIT INT TERM

# =============================================================================
# SUDO — password prompt appears in the terminal window
# =============================================================================

RUN_AS_ROOT="sudo"

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
    if [[ "$is_immutable" == false ]] && [[ -d /ostree/repo ]]; then
        is_immutable=true
        detected_name="${os_name:-Unknown} (OSTree-based)"
    fi

    if [[ "$is_immutable" == true ]]; then
        cat <<EOF

╔════════════════════════════════════════════════════════════════════════════╗
║              INCOMPATIBLE OPERATING SYSTEM DETECTED                       ║
╚════════════════════════════════════════════════════════════════════════════╝

  Detected: $detected_name

  This script cannot set up iRacing on your system.

  WHY:

  Your operating system is immutable. This means the core filesystem is
  read-only and locked against modification.

  You may have noticed that Steam itself works fine on your system —
  this is because Steam is either pre-installed as part of your OS, or
  installed as a self-contained Flatpak. Neither requires touching the
  system filesystem.

  iRacing is different. It requires additional system-level packages to
  be installed alongside Steam — Wine libraries, protontricks, and
  custom Proton builds — that cannot be delivered via Flatpak or
  pre-bundled. These must be installed as real system packages, which
  your OS probably will not allow without serious modification of your
  system which I will not support.

  This script cannot automate this process on an immutable system.
  Experienced Linux users may be able to work through the steps
  manually using containers or OS-specific workarounds, but this is
  complex, unsupported, and well outside the scope of this script.

  To use this script to set up and run iRacing on Linux, you need a
  standard (mutable) distribution such as:

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

This script requires the following packages to run:
EOF
        for pkg in "${missing[@]}"; do echo "  • $pkg"; done
        cat <<EOF

System: $OS_NAME

TO INSTALL, COPY & PASTE THIS COMMAND:

    $install_cmd

WHAT TO DO NEXT:

1. Open a terminal window
2. Copy the command above and press Enter
3. Wait for installation to complete
4. Run this script again

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
# ENTRANCE
# =============================================================================
gui_info "<b>iRacing Setup for Linux</b>
<i>by Dan Fraser</i>

Detected OS: <b>$OS_NAME</b>

This tool will walk you through setting up iRacing on Linux.
It assumes a standard fresh install:

  • Steam is installed in the default location
  • iRacing is in your default Steam library
  • No custom paths or network shares

<b>Some steps will ask for your sudo password in the terminal window.</b>

Click OK to begin."

log "GUI setup started"

# =============================================================================
# STEP 1 — Install Steam and protontricks
# =============================================================================
log "=== Step 1 — Steam & protontricks ==="

install_if_missing() {
    local pkg="$1"
    case "$DISTRO_FAMILY" in
    debian)
        if [[ "$pkg" == "protontricks" ]]; then
            # protontricks is installed via pipx on Debian/Ubuntu, not apt,
            # so check for the actual command rather than dpkg's database.
            if command -v protontricks &>/dev/null; then
                log "$pkg already installed"
                return
            fi
        elif dpkg -s "$pkg" 2>/dev/null | grep -q "^Status: install ok installed"; then
            # dpkg -s + Status check (not dpkg -l, which returns success even
            # for a purged/removed package still known to dpkg's database)
            log "$pkg already installed"
            return
        fi
        log "Installing $pkg via apt..."
        (
            $RUN_AS_ROOT apt-get update -qq 2>>"$GENERAL_LOG"
            if [[ "$pkg" == "protontricks" ]]; then
                $RUN_AS_ROOT apt-get install -y pipx 2>>"$GENERAL_LOG"
                pipx install protontricks 2>>"$GENERAL_LOG"
                pipx ensurepath 2>>"$GENERAL_LOG"
            else
                $RUN_AS_ROOT apt-get install -y "$pkg" 2>>"$GENERAL_LOG"
            fi
        ) &
        gui_wait $! "Installing <b>$pkg</b>...\n\nPlease enter your password in the terminal if prompted."
        ;;
    fedora)
        if rpm -q "$pkg" &>/dev/null; then
            log "$pkg already installed"
            return
        fi
        log "Installing $pkg via dnf..."
        (
            if [[ "$pkg" == "protontricks" ]]; then
                $RUN_AS_ROOT dnf install -y \
                    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
                    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
                    2>>"$GENERAL_LOG" || true
            fi
            $RUN_AS_ROOT dnf install -y "$pkg" 2>>"$GENERAL_LOG"
        ) &
        gui_wait $! "Installing <b>$pkg</b>...\n\nPlease enter your password in the terminal if prompted."
        ;;
    arch)
        if pacman -Qi "$pkg" &>/dev/null; then
            log "$pkg already installed"
            return
        fi
        log "Installing $pkg via pacman..."
        (
            $RUN_AS_ROOT pacman -S --noconfirm "$pkg" 2>>"$GENERAL_LOG"
        ) &
        local install_pid=$!
        gui_wait $install_pid "Installing <b>$pkg</b>...\n\nPlease enter your password in the terminal if prompted."
        wait $install_pid || gui_error "❌ Could not install <b>$pkg</b>.\n\nPlease check your internet connection and try again."
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
    gui_error "❌ protontricks was installed but cannot be found.\n\nThis is usually a PATH issue.\n\n$HINT\n\nThen re-run this setup."
fi

if ! protontricks --version &>/dev/null; then
    gui_error "❌ protontricks is installed but cannot run.\n\nCheck the installation and try again."
fi

gui_info "<b>Steam and protontricks are installed and ready.</b>"
SUMMARY_PACKAGES="Already installed"

# =============================================================================
# STEP 2 — Check Steam is logged in
# =============================================================================
log "=== Step 2 — Steam Login ==="

gui_open "Checking Steam login..."

LOGIN_VDF="$STEAM_ROOT/config/loginusers.vdf"
steam_logged_in=false

if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"[[:space:]]*"1"' "$LOGIN_VDF"; then
    STEAM_USER=$(extract_value "PersonaName" "$(cat "$LOGIN_VDF")")
    steam_logged_in=true
    log "Steam login detected"
elif [[ -d "$STEAM_ROOT/userdata" ]] && compgen -G "$STEAM_ROOT/userdata/[0-9]*" >/dev/null 2>&1; then
    steam_logged_in=true
    log "Steam userdata found"
fi

gui_close

if ! $steam_logged_in; then
    # Record the current timestamp of loginusers.vdf (0 if it doesn't exist yet)
    LOGIN_VDF_MTIME_BEFORE=$(stat -c "%Y" "$LOGIN_VDF" 2>/dev/null || echo "0")

    gui_warn "Steam does not appear to be logged in.\n\nPlease open Steam and log into your account, then click OK to continue."

    # Check if the file has been updated since we first looked — if so, Steam wrote new login data
    check_login_updated() {
        local current_mtime
        current_mtime=$(stat -c "%Y" "$LOGIN_VDF" 2>/dev/null || echo "0")
        if [[ "$current_mtime" != "$LOGIN_VDF_MTIME_BEFORE" ]]; then
            return 0 # File changed — login likely completed
        fi
        return 1
    }

    attempt=0
    while true; do
        if check_login_updated; then
            # File changed — give Steam a moment to finish writing then check content
            gui_open "Detected Steam activity, checking login..."
            sleep 2
            gui_close
            if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"[[:space:]]*"1"' "$LOGIN_VDF"; then
                STEAM_USER=$(extract_value "PersonaName" "$(cat "$LOGIN_VDF")")
                steam_logged_in=true
                break
            fi
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -ge 2 ]]; then
            # Two attempts with no change — ask the user what to do
            if ! zenity --question --title="$TITLE" --text="Steam login still not detected.\n\nHave you logged in to Steam? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
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
    gui_info "<b>Steam is logged in</b> as: <b>$STEAM_USER</b>"
    SUMMARY_LOGIN="✓ Logged in"
else
    gui_info "<b>Steam login confirmed.</b>"
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
    if grep -q "266415" "$IRACING_ACF"; then
        IRACING_DEPOT_PURCHASE="266415"
        log "Depot: Steam Purchase (266415)"
    elif grep -q "266411" "$IRACING_ACF"; then
        IRACING_DEPOT_DIRECT="266411"
        log "Depot: Direct Account (266411)"
    else
        log "Depot type undetermined"
    fi
else
    log "No iRacing ACF found"
fi

gui_close

if [[ -n "$IRACING_DEPOT_PURCHASE" ]]; then
    gui_info "<b>iRacing detected as a Steam Purchase.</b>"
    SUMMARY_IRACING_TYPE="Steam Purchase"
elif [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    gui_info "<b>iRacing detected as a Direct Account / Generated Steam Key.</b>"
    SUMMARY_IRACING_TYPE="Direct Account / Steam Key"
elif [[ ! -f "$IRACING_ACF" ]]; then
    gui_warn "iRacing was not found in your Steam library."
    SUMMARY_IRACING_TYPE="Not found in library"
else
    gui_warn "iRacing was found but the account type could not be determined.\n\nSetup will continue anyway."
    SUMMARY_IRACING_TYPE="Found - type undetermined"
fi

# =============================================================================
# STEP 4 — Close Steam
# =============================================================================
log "=== Step 4 — Close Steam ==="

# pgrep -x matches the process name exactly — avoids false positives from
# other apps (e.g. Kate) that have steam file paths in their arguments.
# Reusable — Steps 5-7 ask the user to reopen Steam to trigger installs, so
# we need to check and close it again before Step 8's protontricks run.
ensure_steam_closed() {
    local msg_first="${1:-<b>Steam needs to be closed before setup can continue.</b>

Please close Steam yourself now, then click OK.}"

    gui_open "Checking if Steam is running..."
    local steam_running=false
    pgrep -x steam &>/dev/null && steam_running=true
    gui_close

    if $steam_running; then
        gui_warn "$msg_first"
        gui_open "Waiting 10 seconds for Steam to fully shut down..."
        sleep 10
        gui_close
        if pgrep -x steam &>/dev/null; then
            gui_warn "Steam still appears to be running.

Please make sure Steam is fully closed, then click OK."
            gui_open "Waiting 10 seconds for Steam to fully shut down..."
            sleep 10
            gui_close
            if pgrep -x steam &>/dev/null; then
                gui_error "Steam is still running.\n\nPlease close Steam completely and re-run this setup."
            fi
        fi
    fi
}

ensure_steam_closed
log "Steam is closed"

# =============================================================================
# STEP 5 — Confirm iRacing is in Steam library
# =============================================================================
log "=== Step 5 — iRacing in Steam Library ==="

if [[ -z "$IRACING_ACF" ]] || [[ ! -f "$IRACING_ACF" ]]; then
    gui_warn "⚠️  <b>iRacing is not in your Steam library yet.</b>

If you have a direct iRacing account, generate a Steam key here:
<tt>https://support.iracing.com/support/solutions/articles/31000165400</tt>

Add iRacing to Steam, then click OK to continue."

    gui_open "Checking Steam library for iRacing..."
    sleep 0.5
    gui_close

    if [[ -f "$IRACING_ACF" ]]; then
        if grep -q "266415" "$IRACING_ACF"; then
            IRACING_DEPOT_PURCHASE="266415"
        elif grep -q "266411" "$IRACING_ACF"; then
            IRACING_DEPOT_DIRECT="266411"
        fi
    else
        gui_error "❌ iRacing still not found in Steam.\n\nPlease restart Steam after adding iRacing, then re-run this setup."
    fi
fi

# =============================================================================
# STEP 6 — Steam Purchase: verify game files
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

if [[ -n "$IRACING_DEPOT_PURCHASE" ]]; then
    log "=== Step 6 — Steam Purchase Installation ==="

    gui_open "Checking iRacing game files..."
    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")
    # Search every Steam library, not just the default one — iRacing may be
    # installed on a secondary drive/library.
    IRACING_PATH=$(find_iracing_common_path "$INSTALL_DIR")
    if [[ -z "$IRACING_PATH" ]]; then
        IRACING_PATH="$STEAM_APPS/common/$INSTALL_DIR"
    fi
    gui_close

    if [[ -d "$IRACING_PATH" ]]; then
        all_found=true
        for entry in "${IRACING_FINGERPRINT[@]}"; do
            [[ ! -e "$IRACING_PATH/$entry" ]] && {
                all_found=false
                break
            }
        done

        if $all_found; then
            gui_info "<b>iRacing game files found and look complete.</b>\n\nLocation: <tt>$IRACING_PATH</tt>"
            SUMMARY_IRACING_FILES="Files complete"
        else
            # Watch appmanifest for Steam updating it during verify
            ACF_MTIME_BEFORE=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")

            gui_warn "<b>iRacing folder exists but looks incomplete.</b>

Please open Steam and verify the game files:
<b>Right-click iRacing -> Properties -> Installed Files -> Verify integrity</b>

Click OK once Steam has finished verifying."

            attempt=0
            while true; do
                gui_open "Checking for changes to iRacing files..."
                sleep 2
                gui_close
                ACF_MTIME_NOW=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")
                if [[ "$ACF_MTIME_NOW" != "$ACF_MTIME_BEFORE" ]]; then
                    break
                fi
                attempt=$((attempt + 1))
                if [[ $attempt -ge 2 ]]; then
                    if ! zenity --question --title="$TITLE" --text="No changes detected from Steam yet.\n\nHas the verification finished? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                        exit 0
                    fi
                    attempt=0
                    ACF_MTIME_BEFORE=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")
                fi
            done
            SUMMARY_IRACING_FILES="Verified"
        fi
    else
        # Watch for the directory appearing during Steam install
        ACF_MTIME_BEFORE=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")

        gui_warn "<b>iRacing has not been downloaded yet.</b>

Please open Steam and install it:
<b>Library -> iRacing -> Install</b>

Click OK once the installation is complete."

        attempt=0
        while true; do
            gui_open "Checking for iRacing installation..."
            sleep 2
            gui_close
            ACF_MTIME_NOW=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")
            if [[ -d "$IRACING_PATH" && "$ACF_MTIME_NOW" != "$ACF_MTIME_BEFORE" ]]; then
                break
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -ge 2 ]]; then
                if ! zenity --question --title="$TITLE" --text="iRacing doesn't appear to have installed yet.\n\nHas the installation finished in Steam? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                    exit 0
                fi
                attempt=0
                ACF_MTIME_BEFORE=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")
            fi
        done
        SUMMARY_IRACING_FILES="Installed via Steam"
    fi
fi

# =============================================================================
# STEP 7 — Direct account: install via Windows installer
# =============================================================================
if [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    log "=== Step 7 — Direct Account Installation ==="

    gui_open "Checking iRacing game files..."
    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")

    IRACING_STEAM_PATH=$(find_iracing_common_path "$INSTALL_DIR")
    if [[ -z "$IRACING_STEAM_PATH" ]]; then
        # Stub not created anywhere yet — default to the library the
        # appmanifest lives in, since that's where Steam will create it.
        IRACING_STEAM_PATH="$STEAM_APPS/common/$INSTALL_DIR"
    fi
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

    if $fully_installed; then
        gui_info "<b>iRacing is already fully installed.</b>\n\nLocation: <tt>$IRACING_STEAM_PATH</tt>"
        SUMMARY_IRACING_FILES="Files complete"
    elif $stub_detected || [[ ! -d "$IRACING_STEAM_PATH" ]]; then
        if [[ ! -d "$IRACING_STEAM_PATH" ]]; then
            # Watch for the stub directory appearing after Steam installs it
            ACF_MTIME_BEFORE=$(stat -c "%Y" "$IRACING_ACF" 2>/dev/null || echo "0")

            gui_warn "<b>iRacing stub not found.</b>

Please open Steam and install iRacing:
<b>Library -> iRacing -> Install</b>

This downloads a small stub (a few MB). Click OK once Steam shows it as installed."

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

        # Under Proton, Z: maps to the real filesystem root "/", so the correct
        # conversion is always "Z:" + the full path with slashes flipped —
        # regardless of whether the path lives under $HOME or on another
        # drive/library entirely. (Previously this only handled $HOME-relative
        # paths and used the wrong folder name, breaking secondary libraries.)
        IRACING_WIN_PATH="Z:${IRACING_STEAM_PATH//\//\\}"
        # Convert backslashes to Pango HTML entities so zenity renders them correctly
        IRACING_WIN_PATH_DISPLAY=$(echo "$IRACING_WIN_PATH" | sed 's/\\/\&#92;/g')

        gui_info "<b>iRacing stub detected - the full game files are not installed yet.</b>

You need to run the iRacing Windows installer. Here's what to do:

<b>Step 1:</b> Download the installer - click the link to open in your browser:
<a href='https://members.iracing.com/download/member/noservice.jsp'>https://members.iracing.com/download/member/noservice.jsp</a>

<b>Step 2:</b> Save it to your Downloads folder.
The filename looks like: <tt>iRacingInstaller_win_YYYY.MM.DD.exe</tt>

<tt>&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;</tt>
<b>  Wait for the download to fully complete before clicking OK.</b>
<tt>&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;&#9472;</tt>

Click OK once the download has finished."

        while true; do
            gui_open "Looking for iRacing installer in Downloads..."
            INSTALLER_EXE=$(find "$HOME/Downloads" -maxdepth 1 -name 'iRacingInstaller_win_*.exe' | sort -t_ -k4 -V | tail -n1 || true)
            gui_close

            if [[ -n "$INSTALLER_EXE" ]]; then
                break
            fi

            if ! zenity --question --title="$TITLE" --text="No iRacing installer found in ~/Downloads yet.\n\nHas the download finished? Click <b>Yes</b> to check again, or <b>No</b> to quit." --ok-label="Yes, check again" --cancel-label="No, quit" --width=500 2>/dev/null; then
                exit 0
            fi
        done

        gui_info "Found installer: <tt>$(basename "$INSTALLER_EXE")</tt>

The installer will now run automatically and install iRacing to the
correct location in your Steam library:

<tt>$IRACING_WIN_PATH_DISPLAY</tt>

No action is needed from you - it will run silently and iRacing will
NOT be launched automatically when it finishes.

Click OK to begin."

        protontricks-launch --appid "$IRACING_APPID" "$INSTALLER_EXE" \
            /SILENT /SUPPRESSMSGBOXES /NORESTART \
            /DIR="$IRACING_WIN_PATH" \
            >"$GENERAL_LOG" 2>&1 &
        INSTALL_PID=$!
        gui_wait $INSTALL_PID "Installing iRacing...\n\nDestination:\n<tt>$IRACING_WIN_PATH_DISPLAY</tt>\n\nThis will take a few minutes, please wait."
        wait "$INSTALL_PID"

        gui_open "Verifying iRacing installation..."
        sleep 0.5
        gui_close

        if [[ ! -d "$IRACING_STEAM_PATH" ]] || [[ $(find "$IRACING_STEAM_PATH" -maxdepth 1 -type f | wc -l) -le 3 ]]; then
            gui_error "iRacing doesn't appear to have installed correctly.

Expected location: <tt>$IRACING_STEAM_PATH</tt>

Please re-run the installer and make sure you set the install path to:

    <tt><b>$IRACING_WIN_PATH_DISPLAY</b></tt>"
        fi

        gui_info "<b>iRacing installation confirmed!</b>\n\nLocation: <tt>$IRACING_STEAM_PATH</tt>"
        SUMMARY_IRACING_FILES="Installed via Windows installer"
    fi
fi

# =============================================================================
# STEP 8 — Install Proton/Wine libraries
# =============================================================================
log "=== Step 8 — Proton Libraries ==="

# Steam may have been reopened during Steps 5-7 (installing/verifying
# iRacing), so re-confirm it's closed before running protontricks.
ensure_steam_closed "<b>Steam needs to be closed before installing Proton libraries.</b>

Please close Steam now, then click OK."
log "Steam re-confirmed closed before Step 8"

(protontricks "$IRACING_APPID" list-installed >"$PROTONTRICKS_LOG.list" 2>&1) &
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

# original line with both font packages:
# Install <b>corefonts</b> and <b>allfonts</b>?
if gui_question "  <b>Optional Fonts</b>

Install <b>corefonts</b>?

These are not required to play iRacing, but without them you may see
text rendering issues in-game or in the UI.

⚠️  Warning: installing these can take a very long time.

Click Yes to install fonts, No to skip."; then
    # commented out for disabling allfonts
    #    for font_pkg in corefonts allfonts; do
    #        if ! echo "$INSTALLED_LIST" | grep -qw "$font_pkg"; then
    #            MISSING+=("$font_pkg")
    #        fi
    #    done
    if ! echo "$INSTALLED_LIST" | grep -qw "corefonts"; then
        MISSING+=("corefonts")
    fi
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
    gui_info "<b>All required Proton libraries are already installed.</b>"
    SUMMARY_PROTON_LIBS="All ${#REQUIRED_PKGS[@]} libraries already present"
else
    gui_info "⏳ <b>Installing ${#MISSING[@]} Proton library/libraries...</b>

This may take several minutes.

Libraries to install:
<tt>${MISSING[*]}</tt>

Click OK and a progress window will appear."

    protontricks "$IRACING_APPID" -q --force "${MISSING[@]}" >"$PROTONTRICKS_LOG" 2>&1 &
    PT_PID=$!
    gui_wait $PT_PID "Installing Proton libraries...\n\nThis may take several minutes, please wait."
    wait "$PT_PID"
    PT_EXIT=$?

    if [[ $PT_EXIT -ne 0 ]]; then
        gui_error "❌ protontricks encountered an error (code $PT_EXIT).\n\nCheck the log for details:\n<tt>$PROTONTRICKS_LOG</tt>"
    fi

    gui_info "<b>All required Proton libraries are now installed.</b>"
    SUMMARY_PROTON_LIBS="${#MISSING[@]} libraries installed"
fi

# =============================================================================
# STEP 9 — Install custom Proton build
# =============================================================================
log "=== Step 9 — Custom Proton Build ==="

mkdir -p "$COMPAT_TOOLS_DIR"

(curl -fsSL "https://api.github.com/repos/DanFraserUK/proton-cachyos/releases/latest" \
    -H "Accept: application/vnd.github+json" -o /tmp/iracing_releases.json 2>>"$GENERAL_LOG") &
gui_wait $! "Checking for the latest custom Proton build..."

RELEASES_JSON=$(cat /tmp/iracing_releases.json 2>/dev/null)
rm -f /tmp/iracing_releases.json

[[ -z "$RELEASES_JSON" ]] &&
    gui_error "❌ Could not reach GitHub.\n\nPlease check your internet connection and try again.\n\nManual download:\n<tt>https://github.com/DanFraserUK/proton-cachyos/releases</tt>\n\nExtract to: <tt>$COMPAT_TOOLS_DIR</tt>"

TARBALL_URL=""
while IFS= read -r line; do
    if [[ "$line" == *'"browser_download_url"'* ]] && [[ "$line" == *'.tar.xz"' ]]; then
        line="${line#*\"browser_download_url\"}"
        line="${line#*\"}"
        TARBALL_URL="${line%\"*}"
        break
    fi
done <<<"$RELEASES_JSON"

[[ -z "$TARBALL_URL" ]] &&
    gui_error "❌ Could not find a download link in the latest GitHub release.\n\nPlease download manually:\n<tt>https://github.com/DanFraserUK/proton-cachyos/releases</tt>\n\nExtract to: <tt>$COMPAT_TOOLS_DIR</tt>"

TARBALL_NAME=$(basename "$TARBALL_URL")
PROTON_DIR_NAME="${TARBALL_NAME%.tar.xz}"
TARBALL_TMP="/tmp/$TARBALL_NAME"

if [[ -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
    gui_info "<b>Custom Proton build is already installed and up to date.</b>\n\n<tt>$PROTON_DIR_NAME</tt>"
    SUMMARY_PROTON_BUILD="Already installed ($PROTON_DIR_NAME)"
else
    (curl -fsSL -o "$TARBALL_TMP" "$TARBALL_URL" >>"$GENERAL_LOG" 2>&1) &
    DL_PID=$!
    gui_wait $DL_PID "Downloading custom Proton build...\n\n<tt>$TARBALL_NAME</tt>"
    wait "$DL_PID"
    DL_EXIT=$?

    if [[ $DL_EXIT -ne 0 ]] || [[ ! -s "$TARBALL_TMP" ]]; then
        rm -f "$TARBALL_TMP"
        gui_error "❌ Download failed.\n\nPlease check your internet connection and try again."
    fi

    # Snapshot existing top-level dirs so we can spot the newly-extracted one
    # even if the tarball's internal folder name doesn't match its filename.
    DIRS_BEFORE=$(find "$COMPAT_TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    (tar -xf "$TARBALL_TMP" -C "$COMPAT_TOOLS_DIR" >>"$GENERAL_LOG" 2>&1) &
    TAR_PID=$!
    gui_wait $TAR_PID "Extracting Proton build...\n\nAlmost done!"
    wait "$TAR_PID"
    TAR_EXIT=$?
    rm -f "$TARBALL_TMP"

    [[ $TAR_EXIT -ne 0 ]] && gui_error "❌ Extraction failed.\n\nCheck the log:\n<tt>$GENERAL_LOG</tt>"

    if [[ ! -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
        DIRS_AFTER=$(find "$COMPAT_TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
        ACTUAL_DIR=$(comm -13 <(echo "$DIRS_BEFORE") <(echo "$DIRS_AFTER") | head -n1)
        if [[ -n "$ACTUAL_DIR" ]]; then
            PROTON_DIR_NAME=$(basename "$ACTUAL_DIR")
        else
            gui_error "❌ Extraction completed but the expected folder wasn't found.\n\nExpected: <tt>$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME</tt>\n\nCheck <tt>$COMPAT_TOOLS_DIR</tt> manually and select the extracted folder as your compatibility tool in Steam."
        fi
    fi

    gui_info "<b>Custom Proton build installed!</b>\n\n<tt>$PROTON_DIR_NAME</tt>"
    SUMMARY_PROTON_BUILD="Installed ($PROTON_DIR_NAME)"
fi

# =============================================================================
# STEP 10 — Optional extras
# =============================================================================
log "=== Step 10 — Optional Extras ==="

# --- Backup /etc/hosts before touching it ---
if [[ ! -f /etc/hosts.bak ]]; then
    ($RUN_AS_ROOT cp /etc/hosts /etc/hosts.bak 2>>"$GENERAL_LOG") &
    gui_wait $! "Backing up /etc/hosts...\n\nPlease enter your password in the terminal if prompted."
    log "Backed up /etc/hosts"
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
fi
DOCS_LINK="$HOME/Documents/iRacing"

# --- EAC Workaround ---
if grep -qF "$HOSTS_ENTRY" /etc/hosts; then
    if gui_question "The EAC (Easy Anti-Cheat) network workaround is already applied.

Do you want to <b>remove</b> it?"; then
        (
            hosts_content=""
            while IFS= read -r hosts_line; do
                [[ "$hosts_line" != "$HOSTS_ENTRY" ]] && hosts_content+="$hosts_line"$'\n'
            done </etc/hosts
            echo -n "$hosts_content" | $RUN_AS_ROOT tee /etc/hosts >/dev/null
        ) &
        gui_wait $! "Removing EAC hosts entry...\n\nPlease enter your password in the terminal if prompted."
        gui_info "EAC workaround has been removed from /etc/hosts."
        SUMMARY_EAC="Removed"
    else
        SUMMARY_EAC="Already applied (kept)"
    fi
else
    if gui_question "<b>EAC (Easy Anti-Cheat) Network Workaround</b>

This blocks the EAC CDN by adding one line to your /etc/hosts file.

<b>!! AT YOUR OWN RISK:</b> circumventing anti-cheat software could
potentially result in your account being banned.

Do you want to apply this workaround?"; then
        (echo "$HOSTS_ENTRY" | $RUN_AS_ROOT tee -a /etc/hosts >/dev/null) &
        gui_wait $! "Applying EAC workaround...\n\nPlease enter your password in the terminal if prompted."
        gui_info "EAC workaround applied."
        SUMMARY_EAC="Applied"
    else
        SUMMARY_EAC="Skipped"
    fi
fi

# --- Documents symlink ---
if [[ -L "$DOCS_LINK" ]]; then
    gui_info "<b>~/Documents/iRacing shortcut already exists.</b>"
    SUMMARY_DOCS="Already exists"
elif [[ -d "$IRACING_DOCS" && ! -e "$DOCS_LINK" ]]; then
    if gui_question "<b>iRacing Documents Shortcut</b>

Steam on Linux stores your iRacing settings, car setups, and replays
deep inside a hidden folder. Would you like a shortcut created at:

<tt>~/Documents/iRacing</tt>

This makes it easy to access your setups and replays."; then
        ln -s "$IRACING_DOCS" "$DOCS_LINK"
        gui_info "Shortcut created at <tt>~/Documents/iRacing</tt>"
        SUMMARY_DOCS="Created"
    else
        SUMMARY_DOCS="Skipped"
    fi
else
    gui_warn "iRacing documents folder not found yet.\n\nLaunch iRacing once to create it, then you can create the shortcut manually:\n\n<tt>ln -s \"$IRACING_DOCS\" \"$DOCS_LINK\"</tt>"
    SUMMARY_DOCS="Not yet - launch iRacing first"
fi

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
<tt>EAC workaround        </tt>${SUMMARY_EAC}
<tt>Documents shortcut    </tt>${SUMMARY_DOCS}
<tt>─────────────────────────────────────────────────────</tt>"

gui_info "$SUMMARY_TEXT"

if [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    LAUNCH_OPTIONS="\n\n<b>Launch Options:</b>\nRight-click iRacing in Steam -> Properties -> General -> Launch Options\n\n    <tt><b>PROTON_LOG=1 LD_PRELOAD=\"\" %command%</b></tt>\n\n<i>(highlight the line above to copy with CTRL+C, then paste with CTRL+V)</i>"
else
    LAUNCH_OPTIONS=""
fi

gui_info "<b>All done!</b>

<b>If Steam is currently open, fully close and reopen it now.</b>
New Proton/compatibility tools won't show up in the dropdown below
until Steam has been restarted.

<b>Final step - in Steam, do the following:</b>

Right-click iRacing -> Properties -> Compatibility
Tick: <i>Force the use of a specific Steam Play compatibility tool</i>
Select: <b>$PROTON_DIR_NAME</b>$LAUNCH_OPTIONS

This was for you Pabs ❤️
Open Steam and enjoy your racing!"
# ^ Dedicated to PabloPGZ — the reason this script exists in the first place.
# Also just a little joke for whoever runs it. Feel free to leave it in :)

log "Setup complete"
