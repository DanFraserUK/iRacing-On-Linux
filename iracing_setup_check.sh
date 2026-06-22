#!/usr/bin/env bash
# =============================================================================
# iRacing Setup Checker for Linux
# Supports: Arch / CachyOS / EndeavourOS ##/ Debian / Ubuntu / Fedora / Nobara
# =============================================================================

set -euo pipefail

# --- Colours ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LIGHTYELLOW='\033[38;2;255;255;153m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PINK='\033[38;2;255;163;181m'
NC='\033[0m' # No Colour

# --- General log (same dir as script) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERAL_LOG="$SCRIPT_DIR/danfrasers-iracing-setup.log"
>"$GENERAL_LOG" # Clear on each run
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$GENERAL_LOG"; }

# --- Helpers (print to terminal AND log) ---
info() {
    echo -e "${CYAN}[INFO]${NC}  $*"
    log "[INFO]  $*"
}
success() {
    echo -e "${GREEN}[OK]${NC}    $*"
    log "[OK]    $*"
}
warn() {
    echo -e "${YELLOW}[WARN]${NC}  $*"
    log "[WARN]  $*"
}
error() {
    echo -e "${RED}[ERROR]${NC} $*"
    log "[ERROR] $*"
}
header() {
    echo -e "\n${PINK}$(printf '═%.0s' {1..80})${NC}"
    echo -e "${BOLD}${LIGHTYELLOW}  ${*}${NC}"
    echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}\n"
    log "=== $* ==="
}

press_any_key() {
    echo -e "\n${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
    echo
}

press_any_key_exit() {
    echo -e "\n${YELLOW}Press any key to exit...${NC}"
    read -n 1 -s -r
    echo
    exit 0
}

# --- OS Detection ---
# NOTE: Multi-distro support partially stubbed out for now — CachyOS only.
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

    # case "$OS_ID" in
    #     arch|cachyos|endeavouros|manjaro)
    #         DISTRO_FAMILY="arch" ;;
    #     debian|ubuntu|linuxmint|elementary)
    #         DISTRO_FAMILY="debian" ;;
    #     fedora|nobara|rhel|centos)
    #         DISTRO_FAMILY="fedora" ;;
    #     nixos)
    #         DISTRO_FAMILY="unsupported_nixos" ;;
    #     pop)
    #         DISTRO_FAMILY="unsupported_pop" ;;
    #     *)
    #         if [[ "$OS_ID_LIKE" == *arch* ]]; then
    #             DISTRO_FAMILY="arch"
    #         elif [[ "$OS_ID_LIKE" == *debian* || "$OS_ID_LIKE" == *ubuntu* ]]; then
    #             DISTRO_FAMILY="debian"
    #         elif [[ "$OS_ID_LIKE" == *fedora* || "$OS_ID_LIKE" == *rhel* ]]; then
    #             DISTRO_FAMILY="fedora"
    #         else
    #             DISTRO_FAMILY="unsupported_unknown"
    #         fi
    #         ;;
    # esac

    DISTRO_FAMILY="arch"
    log "Detected OS: $OS_NAME (family: $DISTRO_FAMILY)"
}

detect_os

# =============================================================================
# ENTRANCE MESSAGE
# =============================================================================
clear
echo -e "${BOLD}${PINK}"
cat <<'EOF'
   ██████╗  █████╗  ██████╗██╗███╗   ██╗ ██████╗
██║██╔══██╗██╔══██╗██╔════╝██║████╗  ██║██╔════╝
██║██████╔╝███████║██║     ██║██╔██╗ ██║██║  ███╗
██║██╔══██╗██╔══██║██║     ██║██║╚██╗██║██║   ██║
██║██║  ██║██║  ██║╚██████╗██║██║ ╚████║╚██████╔╝
╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝╚═╝  ╚═══╝ ╚═════╝
███████╗███████╗████████╗██╗   ██╗██████╗
██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
███████╗█████╗     ██║   ██║   ██║██████╔╝
╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝
███████║███████╗   ██║   ╚██████╔╝██║
╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝
EOF
echo -e "${NC}"
echo -e "${BOLD}This short walkthrough checks a Linux install to get ready to launch iRacing.${NC}"
echo
echo -e "  ${BOLD}Supported distributions:${NC}"
echo -e "  ${CYAN}  Arch / CachyOS / EndeavourOS${NC}"
# echo -e "  ${CYAN}  Arch / CachyOS / EndeavourOS / Debian / Ubuntu / Fedora / Nobara${NC}"
echo
echo -e "  ${BOLD}A custom Proton build by ${PINK}Dan Fraser${NC}${BOLD} will be installed — this is a fork of${NC}"
echo -e "  ${BOLD}proton-cachyos containing a specific fix for iRacing not yet upstream.${NC}"
echo
echo -e "This script will guide you through:"
echo -e "  ${GREEN}✔${NC} Checking & installing protontricks and Steam"
echo -e "  ${GREEN}✔${NC} Verifying Steam login"
echo -e "  ${GREEN}✔${NC} Detecting your iRacing installation type"
echo -e "  ${GREEN}✔${NC} Installing iRacing if needed"
echo -e "  ${GREEN}✔${NC} Installing required Proton/Wine libraries"
echo -e "  ${GREEN}✔${NC} Installing Custom Proton Build by Dan Fraser"
echo -e "  ${GREEN}✔${NC} Optionally applying EAC network fix"
echo
echo -e "  ${YELLOW}Some steps require sudo — you may be prompted for your password.${NC}"
echo -e "  ${YELLOW}This is typically the same password you use to log in to your PC.${NC}"
echo
echo -e "  ${YELLOW}Logs are written to the script directory:${NC}"
echo -e "  ${CYAN}  danfrasers-iracing-setup.log${NC}  — general activity log"
echo -e "  ${CYAN}  danfrasers-iracing-step7.log${NC}  — protontricks library install log"
echo
echo -e "  ${BOLD}Detected OS: ${CYAN}${OS_NAME}${NC}"
echo

# --- Bail out early for unsupported distros ---
# NOTE: Extended distro checks stubbed out for now.
# case "$DISTRO_FAMILY" in
#     unsupported_nixos)
#         echo -e "  ${RED}${BOLD}NixOS is not supported by this script.${NC}"
#         echo -e "  Steam and Proton on NixOS require a different setup process."
#         echo -e "  Please refer to the NixOS wiki for guidance on running Steam games."
#         press_any_key_exit
#         ;;
#     unsupported_pop)
#         echo -e "  ${RED}${BOLD}Pop!_OS is not supported by this script.${NC}"
#         echo -e "  Please set up Steam via the Pop!_Shop and install protontricks manually,"
#         echo -e "  then re-run from Step 2 onwards."
#         press_any_key_exit
#         ;;
#     unsupported_unknown)
#         echo -e "  ${RED}${BOLD}Your distribution (${OS_NAME}) is not supported by this script.${NC}"
#         echo -e "  Supported: Arch, CachyOS, EndeavourOS, Debian, Ubuntu, Fedora, Nobara."
#         press_any_key_exit
#         ;;
# esac

press_any_key

log "Script started — general log: $GENERAL_LOG"

# =============================================================================
# STEP 1 — Check & install protontricks and Steam
# =============================================================================
header "Checking protontricks & Steam"

install_if_missing() {
    local pkg="$1"
    # NOTE: Debian and Fedora install paths stubbed out for now.
    # case "$DISTRO_FAMILY" in
    #     debian)
    #         if dpkg -l "$pkg" &>/dev/null; then success "$pkg is already installed."; return; fi
    #         warn "$pkg is not installed. Installing..."
    #         sudo apt-get update -qq 2>>"$GENERAL_LOG"
    #         if [[ "$pkg" == "protontricks" ]]; then
    #             sudo apt-get install -y pipx 2>>"$GENERAL_LOG"
    #             pipx install protontricks 2>>"$GENERAL_LOG"
    #             pipx ensurepath 2>>"$GENERAL_LOG"
    #         else
    #             sudo apt-get install -y "$pkg" 2>>"$GENERAL_LOG"
    #         fi
    #         success "$pkg installed successfully."
    #         ;;
    #     fedora)
    #         if rpm -q "$pkg" &>/dev/null; then success "$pkg is already installed."; return; fi
    #         warn "$pkg is not installed. Installing via dnf..."
    #         if [[ "$pkg" == "protontricks" ]]; then
    #             sudo dnf install -y \
    #                 "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
    #                 "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
    #                 2>>"$GENERAL_LOG" || true
    #         fi
    #         sudo dnf install -y "$pkg" 2>>"$GENERAL_LOG"
    #         success "$pkg installed successfully."
    #         ;;
    # esac

    if pacman -Qi "$pkg" &>/dev/null; then
        success "$pkg is already installed."
        return
    fi
    warn "$pkg is not installed. Installing via pacman..."
    if sudo pacman -S --noconfirm "$pkg" 2>>"$GENERAL_LOG"; then
        success "$pkg installed successfully."
    else
        warn "pacman could not install $pkg — trying yay..."
        if ! command -v yay &>/dev/null; then
            error "yay not found and pacman failed. Please install yay: https://github.com/Jguer/yay"
            exit 1
        fi
        yay -S --noconfirm "$pkg" 2>>"$GENERAL_LOG"
        success "$pkg installed successfully via yay."
    fi
}

install_if_missing "steam"
install_if_missing "protontricks"

press_any_key

# =============================================================================
# STEP 2 — Check if Steam is logged in
# =============================================================================
header "Checking Steam Login"

STEAM_CONFIG_DIR="$HOME/.steam/steam"
STEAM_USERDATA_DIR="$HOME/.steam/steam/userdata"

steam_logged_in=false

# Check for loginusers.vdf which contains logged-in Steam accounts
LOGIN_VDF="$STEAM_CONFIG_DIR/config/loginusers.vdf"

if [[ -f "$LOGIN_VDF" ]]; then
    # Look for at least one account with MostRecent = 1
    if grep -q '"MostRecent"' "$LOGIN_VDF" && grep -q '"1"' "$LOGIN_VDF"; then
        STEAM_USER=$(grep -m1 '"PersonaName"' "$LOGIN_VDF" | sed 's/.*"PersonaName"[[:space:]]*"\(.*\)"/\1/' || true)
        success "Steam appears to be configured for user: ${BOLD}${STEAM_USER:-unknown}${NC}"
        steam_logged_in=true
    fi
fi

# Also check userdata directory for any user folders (numeric IDs)
if ! $steam_logged_in; then
    if [[ -d "$STEAM_USERDATA_DIR" ]] && compgen -G "$STEAM_USERDATA_DIR/[0-9]*" >/dev/null 2>&1; then
        success "Steam userdata folder detected — Steam has been logged in previously."
        steam_logged_in=true
    fi
fi

if ! $steam_logged_in; then
    warn "Steam does not appear to be logged in or no account data was found."
    echo
    echo -e "  Please launch Steam and log in to your account, then come back."
    echo -e "  ${CYAN}$ steam${NC}"
    echo
    echo -e "Once you're logged in to Steam, press any key to continue..."
    press_any_key

    # Re-check
    if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"' "$LOGIN_VDF"; then
        success "Steam login detected. Continuing."
    else
        error "Still unable to confirm Steam login. Please ensure you've logged in and re-run this script."
        exit 1
    fi
fi

press_any_key

# =============================================================================
# STEP 3 — Detect iRacing installation type
# =============================================================================
header "Detecting iRacing Installation Type"

STEAM_LIBRARY_DIRS=()

# Always include the default Steam library
STEAM_LIBRARY_DIRS+=("$HOME/.steam/steam/steamapps")

# Parse additional library folders from libraryfolders.vdf
LIBRARY_VDF="$HOME/.steam/steam/steamapps/libraryfolders.vdf"
if [[ -f "$LIBRARY_VDF" ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ \"path\" ]]; then
            path=$(echo "$line" | sed 's/.*"\(.*\)".*/\1/')
            if [[ -d "$path/steamapps" ]]; then
                STEAM_LIBRARY_DIRS+=("$path/steamapps")
            fi
        fi
    done <"$LIBRARY_VDF"
fi

IRACING_DEPOT_PURCHASE="" # 266415
IRACING_DEPOT_DIRECT=""   # 266411
IRACING_APPID="266410"
IRACING_ACF=""

for lib in "${STEAM_LIBRARY_DIRS[@]}"; do
    ACF="$lib/appmanifest_${IRACING_APPID}.acf"
    if [[ -f "$ACF" ]]; then
        IRACING_ACF="$ACF"
        info "Found iRacing app manifest at: $ACF"
        break
    fi
done

# Depot detection via appmanifest InstalledDepots section
if [[ -n "$IRACING_ACF" ]]; then
    if grep -q "266415" "$IRACING_ACF"; then
        IRACING_DEPOT_PURCHASE="266415"
        success "iRacing detected as a ${BOLD}Steam Purchase${NC} (depot 266415)."
    elif grep -q "266411" "$IRACING_ACF"; then
        IRACING_DEPOT_DIRECT="266411"
        success "iRacing detected as a ${BOLD}Direct Account / Generated Steam Key${NC} (depot 266411)."
    else
        warn "iRacing manifest found but depot could not be determined. Will proceed with checks."
    fi
else
    warn "No iRacing app manifest found in any Steam library."
fi

press_any_key

# =============================================================================
# STEP 4 — Close Steam
# =============================================================================
header "Closing Steam"

# Steam is not needed from this point on, and must be closed before
# the direct account .bat fix (Step 7) and Proton install (Step 9)
# make changes to the prefix and localconfig.vdf.
info "Steam is not needed for the remaining steps and must be closed before changes are applied."
echo
info "Closing Steam now..."
pkill -f steam 2>/dev/null || true
WAIT_SECS=0
while pgrep -f steam &>/dev/null; do
    if [[ $WAIT_SECS -ge 30 ]]; then
        error "Steam did not close after 30 seconds. Please close it manually then press any key to continue."
        press_any_key
        break
    fi
    sleep 1
    ((WAIT_SECS++))
done
success "Steam is closed."

press_any_key

# =============================================================================
# STEP 5 — Confirm iRacing is in Steam, or prompt user to add it
# =============================================================================
header "iRacing Availability Check"

if [[ -n "$IRACING_ACF" ]]; then
    success "iRacing is present in your Steam library — no action needed here."
    press_any_key
else
    warn "iRacing does not appear to be added to your Steam account/library."
    echo
    echo -e "  ${BOLD}If you have a direct iRacing account${NC}, you can generate a Steam key here:"
    echo
    echo -e "  ${CYAN}  https://support.iracing.com/support/solutions/articles/31000165400-how-to-generate-a-steam-key${NC}"
    echo -e "  ${YELLOW}  (Ctrl+Click the URL above to open in your browser)${NC}"
    echo
    echo -e "  Once you have added iRacing to Steam, press any key and we will continue..."
    press_any_key

    # Re-check after user has added iRacing
    for lib in "${STEAM_LIBRARY_DIRS[@]}"; do
        ACF="$lib/appmanifest_${IRACING_APPID}.acf"
        if [[ -f "$ACF" ]]; then
            IRACING_ACF="$ACF"
            break
        fi
    done

    if [[ -z "$IRACING_ACF" ]]; then
        error "iRacing still not found. You may need to restart Steam after adding the game, then re-run this script."
        exit 1
    fi

    # Detect depot now that it's been added
    if grep -q "266415" "$IRACING_ACF"; then
        IRACING_DEPOT_PURCHASE="266415"
        success "iRacing confirmed as a Steam Purchase (depot 266415)."
    elif grep -q "266411" "$IRACING_ACF"; then
        IRACING_DEPOT_DIRECT="266411"
        success "iRacing confirmed as a Direct Account / Generated Steam Key (depot 266411)."
    else
        warn "Depot type undetermined, proceeding anyway."
    fi

    press_any_key
fi

# =============================================================================
# STEP 6 — Steam Purchase path (depot 266415) — skipped for direct accounts
# =============================================================================
header "Steam Purchase — Installation Check"

if [[ -z "$IRACING_DEPOT_PURCHASE" ]]; then
    info "Not applicable — iRacing is not a Steam purchase on this account. Skipping."
    press_any_key
else
    INSTALL_DIR=$(grep '"installdir"' "$IRACING_ACF" | sed 's/.*"\(.*\)".*/\1/' || true)
    IRACING_PATH=""
    for lib in "${STEAM_LIBRARY_DIRS[@]}"; do
        if [[ -d "$lib/common/$INSTALL_DIR" ]]; then
            IRACING_PATH="$lib/common/$INSTALL_DIR"
            break
        fi
    done

    if [[ -n "$IRACING_PATH" ]]; then
        success "iRacing game files found at: $IRACING_PATH"
        success "Steam purchase installation looks good — ready for the next step."
    else
        warn "iRacing does not appear to be downloaded/installed yet."
        echo
        echo -e "  Please open Steam and install iRacing:"
        echo -e "  ${CYAN}  Library → iRacing → Install${NC}"
        echo
        echo -e "  Once installation is complete, press any key to continue..."
        press_any_key
        success "Continuing — please ensure iRacing has finished installing before proceeding."
    fi

    press_any_key
fi

# =============================================================================
# STEP 7 — Direct account / Steam key path (depot 266411) — skipped for purchases
# =============================================================================
header "Direct Account — Installation Check"

if [[ -z "$IRACING_DEPOT_DIRECT" ]]; then
    info "Not applicable — iRacing is not a direct account key on this machine. Skipping."
    press_any_key
else
    info "iRacing is a direct account with generated Steam key (depot 266411)."

    INSTALL_DIR=$(grep '"installdir"' "$IRACING_ACF" | sed 's/.*"\(.*\)".*/\1/' || true)
    IRACING_STEAM_PATH=""
    for lib in "${STEAM_LIBRARY_DIRS[@]}"; do
        if [[ -d "$lib/common/$INSTALL_DIR" ]]; then
            IRACING_STEAM_PATH="$lib/common/$INSTALL_DIR"
            break
        fi
    done

    # Direct account depot only downloads a stub (~1.97 KB, 3 files) — detect this.
    stub_detected=false
    if [[ -n "$IRACING_STEAM_PATH" ]]; then
        FILE_COUNT=$(find "$IRACING_STEAM_PATH" -maxdepth 2 -type f | wc -l)
        DIR_SIZE=$(du -sb "$IRACING_STEAM_PATH" 2>/dev/null | awk '{print $1}')
        if [[ "$FILE_COUNT" -le 3 && "$DIR_SIZE" -lt 5000 ]]; then
            stub_detected=true
        fi
    fi

    if [[ -z "$IRACING_STEAM_PATH" ]]; then
        warn "iRacing game folder not found. Please install the stub via Steam first:"
        echo -e "  ${CYAN}  Library → iRacing → Install${NC}"
        echo
        echo -e "  This will download a small stub. Press any key once Steam shows it as installed..."
        press_any_key
        stub_detected=true
    fi

    if $stub_detected; then
        echo
        warn "iRacing stub detected — only the 3 launcher .bat files are present."
        echo
        echo -e "  The full iRacing files need to be installed using the iRacing installer."
        echo -e "  ${BOLD}   Do NOT proceed until iRacing has been fully installed via the installer below.${NC}"
        echo
        echo -e "  ${BOLD}1.${NC} Open this URL and download the installer to ${BOLD}~/Downloads${NC}:"
        echo -e "     ${CYAN}  https://members.iracing.com/download/member/noservice.jsp${NC}"
        echo -e "     ${YELLOW}  (Ctrl+Click the URL above to open in your browser)${NC}"
        echo
        echo -e "  ${BOLD}2.${NC} The file will be named something like:"
        echo -e "     ${CYAN}  iRacingInstaller_win_2026.06.09.01.exe${NC}  (date will vary — grab the latest)"
        echo
        echo -e "  Press any key once the installer has downloaded to ~/Downloads..."
        press_any_key

        INSTALLER_EXE=$(find "$HOME/Downloads" -maxdepth 1 -name 'iRacingInstaller_win_*.exe' |
            sort -t_ -k4 -V | tail -n1 || true)

        if [[ -z "$INSTALLER_EXE" ]]; then
            error "No iRacingInstaller_win_*.exe found in ~/Downloads."
            echo -e "  Please download the installer from the members site and try again."
            exit 1
        fi

        success "Found installer: $INSTALLER_EXE"
        echo
        info "Launching iRacing installer via protontricks-launch..."
        echo -e "  ${YELLOW}   IMPORTANT: When the installer finishes — ${BOLD}do NOT launch iRacing!${NC}"
        echo -e "  ${YELLOW}             Make sure to ${BOLD}untick the 'Launch iRacing' option${NC}${YELLOW} before closing!${NC}"
        echo
        press_any_key

        protontricks-launch --appid "$IRACING_APPID" "$INSTALLER_EXE"

        success "iRacing installer completed."
        echo
        echo -e "  ${BOLD}   Before continuing: confirm that iRacing has finished installing.${NC}"
        echo -e "  The installer should have placed iRacing at:"
        echo -e "  ${CYAN}  C:\\Program Files (x86)\\iRacing\\${NC}"
        echo -e "  which on disk is inside your Proton prefix at:"
        echo -e "  ${CYAN}  ~/.local/share/Steam/steamapps/compatdata/266410/pfx/drive_c/Program Files (x86)/iRacing/${NC}"
        echo
        echo -e "  Press any key once you have confirmed iRacing is fully installed..."
        press_any_key

        # Verify the iRacing install actually exists in the Proton prefix Program Files location
        PROTON_IRACING_DIR="$HOME/.local/share/Steam/steamapps/compatdata/${IRACING_APPID}/pfx/drive_c/Program Files (x86)/iRacing"
        if [[ ! -d "$PROTON_IRACING_DIR" ]]; then
            error "iRacing does not appear to be installed at the expected location:"
            echo -e "  ${CYAN}  $PROTON_IRACING_DIR${NC}"
            echo -e "  Please re-run the installer and try again."
            exit 1
        fi
        success "iRacing installation confirmed at: $PROTON_IRACING_DIR"

        # --- Copy the three stub .bat files into the Program Files iRacing directory ---
        echo
        info "Copying launcher .bat files from Steam stub into iRacing install directory..."

        BAT_FILES=(
            "StartServiceAndPlayNow.bat"
            "StartPlayingNow.bat"
            "StartPlayingBetaUINow.bat"
        )

        for bat in "${BAT_FILES[@]}"; do
            SRC="$IRACING_STEAM_PATH/$bat"
            DST="$PROTON_IRACING_DIR/$bat"
            if [[ -f "$SRC" ]]; then
                # Back up any existing file in the destination
                if [[ -f "$DST" ]]; then
                    cp "$DST" "${DST}.backup"
                    log "Backed up existing $bat to ${DST}.backup"
                fi
                cp "$SRC" "$DST"
                success "Copied $bat → $PROTON_IRACING_DIR/"
            else
                warn "$bat not found in Steam stub directory ($IRACING_STEAM_PATH) — skipping."
            fi
        done

        # --- Edit localconfig.vdf to set launch options ---
        echo
        info "Setting Steam launch options for iRacing to point at the correct directory..."

        STEAM_ID=$(ls "$HOME/.steam/steam/userdata/" | grep -E '^[0-9]+$' | head -1)
        if [[ -z "$STEAM_ID" ]]; then
            error "Could not determine Steam user ID from userdata directory."
            exit 1
        fi

        VDF_PATH="$HOME/.steam/steam/userdata/$STEAM_ID/config/localconfig.vdf"
        if [[ ! -f "$VDF_PATH" ]]; then
            error "localconfig.vdf not found at: $VDF_PATH"
            exit 1
        fi

        # Back up localconfig.vdf
        cp "$VDF_PATH" "${VDF_PATH}.backup"
        success "Backed up localconfig.vdf to ${VDF_PATH}.backup"

        # The new launch command — runs the bat from the Program Files location via cmd
        # We use the Wine/Proton C: path as that's what the bat expects as its working directory
        #NEW_LAUNCH_OPTS='PROTON_LOG=1 LD_PRELOAD="" %command% "C:\\Program Files (x86)\\iRacing\\StartServiceAndPlayNow.bat"'
        NEW_LAUNCH_OPTS='PROTON_LOG=1 LD_PRELOAD="" "C:\\Program Files (x86)\\iRacing\\StartServiceAndPlayNow.bat"'

        # Use sed to update LaunchOptions inside the 266410 app block.
        # If LaunchOptions already exists for this app, update it.
        # If it doesn't exist, insert it after the opening brace of the 266410 block.
        if grep -q '"LaunchOptions"' <(sed -n '/"266410"/,/^[[:space:]]*}[[:space:]]*$/p' "$VDF_PATH" 2>/dev/null || true); then
            sed -i "/\"${IRACING_APPID}\"/{
                n
                :loop
                /\"LaunchOptions\"/{
                    s|\"LaunchOptions\"[[:space:]]*\"[^\"]*\"|\"LaunchOptions\"\t\t\"${NEW_LAUNCH_OPTS}\"|
                    b end
                }
                n
                b loop
                :end
            }" "$VDF_PATH"
        else
            # LaunchOptions key doesn't exist yet — insert it after the opening of the 266410 block
            sed -i "/\"${IRACING_APPID}\"/{
                n
                /^[[:space:]]*{/{
                    a\\
\t\t\t\t\"LaunchOptions\"\t\t\"${NEW_LAUNCH_OPTS}\"
                }
            }" "$VDF_PATH"
        fi

        # Verify the edit landed
        if grep -q "LaunchOptions" "$VDF_PATH"; then
            success "Launch options updated in localconfig.vdf."
            log "LaunchOptions set to: $NEW_LAUNCH_OPTS"
        else
            warn "Could not confirm LaunchOptions was written. Please check $VDF_PATH manually."
            log "LaunchOptions sed edit may not have matched — manual check needed"
        fi

    else
        success "iRacing game files are fully installed at: $IRACING_STEAM_PATH"
        success "Direct account installation looks good — ready for the next step."
    fi

    press_any_key
fi

# =============================================================================
# STEP 8 — Install Proton/Wine redistributable libraries
# =============================================================================
header "Installing Required Proton Libraries"

PROTONTRICKS_LOG="$SCRIPT_DIR/danfrasers-iracing-step7.log"

REQUIRED_PACKAGES=(
    vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022
    d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact
)

info "Checking what is already installed in the Proton prefix..."
echo

# Get list of already-installed winetricks packages for this prefix, stderr to log
INSTALLED_LIST=$(protontricks "$IRACING_APPID" list-installed 2>>"$PROTONTRICKS_LOG" || true)

MISSING=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if echo "$INSTALLED_LIST" | grep -qw "$pkg"; then
        success "$pkg — already installed"
    else
        warn "$pkg — missing"
        MISSING+=("$pkg")
    fi
done

echo

if [[ ${#MISSING[@]} -eq 0 ]]; then
    success "Proton prefix appears to be ready — all required libraries are already present."
    press_any_key
else
    echo -e "  ${YELLOW}${#MISSING[@]} package(s) need to be installed: ${BOLD}${MISSING[*]}${NC}"
    echo -e "  ${YELLOW}This may take several minutes. Output is logged to danfrasers-iracing-step7.log in the script directory.${NC}"
    echo

    # Run protontricks on only the missing packages, all output to log
    protontricks "$IRACING_APPID" -q --force \
        "${MISSING[@]}" \
        >"$PROTONTRICKS_LOG" 2>&1 &
    PT_PID=$!

    # Spinner while protontricks runs
    spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    spin_i=0
    echo -ne "  ${CYAN}Please wait ...${NC} "
    while kill -0 "$PT_PID" 2>/dev/null; do
        printf '\b%s' "${spin_chars:$spin_i:1}"
        spin_i=$(((spin_i + 1) % ${#spin_chars}))
        sleep 0.1
    done
    printf '\b \n'

    # Check exit code
    wait "$PT_PID"
    PT_EXIT=$?
    if [[ $PT_EXIT -ne 0 ]]; then
        echo
        error "protontricks exited with an error (code $PT_EXIT)."
        echo -e "  Check the log for details: ${CYAN}$PROTONTRICKS_LOG${NC}"
        exit 1
    fi

    success "All required libraries are now installed in the Proton prefix."
    press_any_key
fi

# =============================================================================
# STEP 9 — Install custom Proton build
# =============================================================================
header "Installing Custom Proton Build by Dan Fraser"

COMPAT_TOOLS_DIR="$HOME/.steam/steam/compatibilitytools.d"
mkdir -p "$COMPAT_TOOLS_DIR"

info "Fetching the latest release of proton-cachyos from GitHub (DanFraserUK)..."

# Use /releases list (not /releases/latest) so pre-releases are included.
# Pick the very first release entry — GitHub returns newest first.
RELEASES_JSON=$(curl -fsSL \
    "https://api.github.com/repos/DanFraserUK/proton-cachyos/releases" \
    -H "Accept: application/vnd.github+json" 2>>"$GENERAL_LOG") || {
    error "Failed to reach GitHub API. Check your internet connection."
    log "curl to GitHub API failed"
    echo -e "  Manual download: ${CYAN}https://github.com/DanFraserUK/proton-cachyos/releases${NC}"
    echo -e "  Extract the .tar.gz to: ${BOLD}$COMPAT_TOOLS_DIR${NC}"
    exit 1
}

# Grab the browser_download_url for the first .tar.gz / .tar.xz / .tar.zst asset
TARBALL_URL=$(echo "$RELEASES_JSON" |
    grep '"browser_download_url"' |
    grep -E '\.(tar\.gz|tar\.xz|tar\.zst)"' |
    head -1 |
    sed 's/.*"\(https:\/\/[^"]*\)".*/\1/')

if [[ -z "$TARBALL_URL" ]]; then
    error "Could not find a downloadable archive in the latest release."
    log "No .tar.gz/.tar.xz/.tar.zst asset found in releases JSON"
    echo -e "  Please check: ${CYAN}https://github.com/DanFraserUK/proton-cachyos/releases${NC}"
    echo -e "  Download the archive manually and extract it to: ${BOLD}$COMPAT_TOOLS_DIR${NC}"
    exit 1
fi

log "Resolved tarball URL: $TARBALL_URL"
TARBALL_NAME=$(basename "$TARBALL_URL")
TARBALL_TMP="/tmp/$TARBALL_NAME"

info "Downloading: $TARBALL_NAME"
echo

# Download with progress bar visible — stderr must go to terminal for the bar to show
curl -L --progress-bar -o "$TARBALL_TMP" "$TARBALL_URL" || {
    error "Download failed. Check your internet connection."
    log "curl download of $TARBALL_URL failed"
    rm -f "$TARBALL_TMP"
    exit 1
}
log "Download complete: $TARBALL_TMP ($(du -sh "$TARBALL_TMP" 2>/dev/null | cut -f1))"
echo

# Peek inside the archive to find the top-level directory name
log "Peeking inside archive: $TARBALL_TMP"
PROTON_DIR_NAME=$(tar -tf "$TARBALL_TMP" 2>>"$GENERAL_LOG" | head -1 | cut -d'/' -f1 || true)

if [[ -z "$PROTON_DIR_NAME" ]]; then
    error "Could not determine directory name inside the archive."
    log "tar -tf output was empty or failed — archive may be corrupt or incomplete"
    rm -f "$TARBALL_TMP"
    exit 1
fi

info "Archive contains directory: $PROTON_DIR_NAME"

info "Extracting to $COMPAT_TOOLS_DIR ..."
echo -ne "  ${CYAN}Please wait ...${NC} "

tar -xf "$TARBALL_TMP" -C "$COMPAT_TOOLS_DIR" >>"$GENERAL_LOG" 2>&1 &
TAR_PID=$!
spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
spin_i=0
while kill -0 "$TAR_PID" 2>/dev/null; do
    printf '\b%s' "${spin_chars:$spin_i:1}"
    spin_i=$(((spin_i + 1) % ${#spin_chars}))
    sleep 0.1
done
printf '\b \n'

wait "$TAR_PID"
TAR_EXIT=$?
rm -f "$TARBALL_TMP"

if [[ $TAR_EXIT -ne 0 ]]; then
    error "Extraction failed (exit code $TAR_EXIT)."
    echo -e "  Check the log for details: ${CYAN}$GENERAL_LOG${NC}"
    exit 1
fi

success "Proton build installed to $COMPAT_TOOLS_DIR/$PROTON_DIR_NAME"
echo
info "When you next launch Steam, set iRacing to use this Proton build:"
echo -e "  ${CYAN}  Right-click iRacing → Properties → Compatibility → Force the use of a specific Steam Play compatibility tool${NC}"
echo -e "  ${CYAN}  Select '${PROTON_DIR_NAME}' from the list.${NC}"

press_any_key

# =============================================================================
# STEP 10 — EAC hosts workaround
# =============================================================================
header "EAC (Easy Anti-Cheat) Network Workaround"

HOSTS_ENTRY="0.0.0.0 modules-cdn.eac-prod.on.epicgames.com"

if grep -qF "$HOSTS_ENTRY" /etc/hosts; then
    success "EAC hosts entry already present in /etc/hosts — nothing to do."
else
    echo -e "  iRacing uses Easy Anti-Cheat (EAC). On Linux, a known workaround is to"
    echo -e "  block the EAC CDN in your hosts file to prevent connection issues."
    echo
    echo -e "  ${RED}${BOLD}  AT YOUR OWN RISK${NC}"
    echo -e "  ${YELLOW}  This workaround modifies how Easy Anti-Cheat communicates with its servers.${NC}"
    echo -e "  ${YELLOW}  Blocking anti-cheat network traffic is not officially sanctioned by iRacing.${NC}"
    echo -e "  ${YELLOW}  You apply this workaround at your own risk.${NC}"
    echo
    echo -e "  ${BOLD}The following line will be added to /etc/hosts:${NC}"
    echo -e "  ${CYAN}  $HOSTS_ENTRY${NC}"
    echo
    echo -e "  ${YELLOW}   This also requires sudo (administrator) privileges.${NC}"
    echo
    echo -n "  Do you want to apply this workaround? [y/N]: "
    read -r APPLY_HOSTS
    echo

    if [[ "$APPLY_HOSTS" =~ ^[Yy]$ ]]; then
        echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts >/dev/null
        success "EAC hosts entry added to /etc/hosts."
    else
        warn "Skipped. You can apply it manually later if you experience EAC issues:"
        echo -e "  ${CYAN}  echo \"$HOSTS_ENTRY\" | sudo tee -a /etc/hosts${NC}"
    fi
fi

press_any_key

# =============================================================================
# DONE!
# =============================================================================
clear
echo -e "${BOLD}${PINK}"
cat <<'EOF'
  ██████╗  ██████╗ ███╗   ██╗███████╗██╗
  ██╔══██╗██╔═══██╗████╗  ██║██╔════╝██║
  ██║  ██║██║   ██║██╔██╗ ██║█████╗  ██║
  ██║  ██║██║   ██║██║╚██╗██║██╔══╝  ╚═╝
  ██████╔╝╚██████╔╝██║ ╚████║███████╗██╗
  ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝
EOF
echo -e "${NC}"
echo -e "${BOLD}  Setup checks complete! iRacing is ready to attempt to be played.${NC}"
echo
echo -e "  ${GREEN}✔${NC} protontricks & Steam installed"
echo -e "  ${GREEN}✔${NC} Steam login verified"
echo -e "  ${GREEN}✔${NC} iRacing installation type detected"
echo -e "  ${GREEN}✔${NC} iRacing installed / verified"
echo -e "  ${GREEN}✔${NC} Proton libraries installed"
echo -e "  ${GREEN}✔${NC} Custom Proton build (${PROTON_DIR_NAME}) installed"
echo -e "  ${GREEN}✔${NC} EAC network workaround applied (if chosen)"
echo
echo -e "  ${BOLD}${CYAN}Remember:${NC} Set iRacing to use ${BOLD}${PROTON_DIR_NAME}${NC} in Steam Play settings"
echo -e "  before your first launch!"
echo
echo -e "${BOLD}${CYAN}  This was for you Pabs ${RED}<3${NC}"
echo
echo -e "${GREEN}  All done! Open Steam and enjoy your racing!${NC}"
echo
echo -e "${YELLOW}  Press any key to finish...${NC}"
read -n 1 -s -r
echo
