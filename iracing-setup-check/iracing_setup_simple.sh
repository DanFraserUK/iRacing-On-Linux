#!/usr/bin/env bash
# =============================================================================
# iRacing Setup — Simple Edition
# Assumes: fresh distro install, Steam in $HOME/.steam/steam, single library
# Supports: Arch / CachyOS / EndeavourOS / Debian / Ubuntu / Fedora / Nobara
# =============================================================================

# --- Colours ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
LIGHTYELLOW='\033[38;2;255;255;153m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PINK='\033[38;2;255;163;181m'
NC='\033[0m' # No Colour

# --- Paths — all assumed standard ---
STEAM_ROOT="$HOME/.steam/steam"
STEAM_APPS="$STEAM_ROOT/steamapps"
COMPAT_TOOLS_DIR="$STEAM_ROOT/compatibilitytools.d"
IRACING_APPID="266410"

# --- General log (same dir as script) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERAL_LOG="$SCRIPT_DIR/danfrasers-iracing-setup.log"
: >"$GENERAL_LOG"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$GENERAL_LOG"; }

# --- Helpers ---
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
    clear
    echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}"
    echo -e "${BOLD}${LIGHTYELLOW}  ${*}${NC}"
    echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}\n"
    log "=== $* ==="
}
press_any_key() {
    echo -e "\n${YELLOW}Press any key to continue...${NC}"
    read -n 1 -s -r
    echo
}

extract_value() {
    local key="$1" text="$2" line result
    while IFS= read -r line; do
        if [[ "$line" == *"\"${key}\""* ]]; then
            line="${line#*\"${key}\"}"
            line="${line#*\"}"
            result="${line%\"*}"
            echo "$result"
            return
        fi
    done <<<"$text"
}

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
            echo -e "${RED}${BOLD}Unsupported distribution: $OS_NAME${NC}"
            echo "Supported: Arch, CachyOS, EndeavourOS, Debian, Ubuntu, Fedora, Nobara"
            exit 1
        fi
        ;;
    esac

    log "Detected OS: $OS_NAME ($DISTRO_FAMILY)"
}

detect_os

# =============================================================================
# ENTRANCE
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
echo -e "  ${BOLD}Linux iRacing setup — Simple Edition${NC}"
echo -e "  ${CYAN}by Dan Fraser${NC}"
echo
echo -e "  ${BOLD}Detected OS:${NC} ${CYAN}${OS_NAME}${NC}"
echo
echo -e "  ${YELLOW}This version assumes a standard fresh install:${NC}"
echo -e "    • Steam is (or will be) installed and in ${BOLD}$HOME/.steam/steam${NC}"
echo -e "    • iRacing is in the default Steam library"
echo -e "    • No custom paths or network shares"
echo
echo -e "  ${YELLOW}Some steps require sudo — typically your login password.${NC}"
echo

press_any_key

log "Simple script started — log: $GENERAL_LOG"

# =============================================================================
# STEP 1 — Install Steam and protontricks if missing
# =============================================================================
header "Step 1 — Steam & protontricks"

install_if_missing() {
    local pkg="$1"
    case "$DISTRO_FAMILY" in
    debian)
        if dpkg -l "$pkg" &>/dev/null; then
            success "$pkg is already installed."
            return
        fi
        warn "$pkg is not installed. Installing..."
        sudo apt-get update -qq 2>>"$GENERAL_LOG"
        if [[ "$pkg" == "protontricks" ]]; then
            sudo apt-get install -y pipx 2>>"$GENERAL_LOG"
            pipx install protontricks 2>>"$GENERAL_LOG"
            pipx ensurepath 2>>"$GENERAL_LOG"
        else
            sudo apt-get install -y "$pkg" 2>>"$GENERAL_LOG"
        fi
        success "$pkg installed successfully."
        ;;
    fedora)
        if rpm -q "$pkg" &>/dev/null; then
            success "$pkg is already installed."
            return
        fi
        warn "$pkg is not installed. Installing via dnf..."
        if [[ "$pkg" == "protontricks" ]]; then
            sudo dnf install -y \
                "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
                "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" \
                2>>"$GENERAL_LOG" || true
        fi
        sudo dnf install -y "$pkg" 2>>"$GENERAL_LOG"
        success "$pkg installed successfully."
        ;;
    arch)
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
            if ! yay -S --noconfirm "$pkg" 2>>"$GENERAL_LOG"; then
                error "Failed to install $pkg via yay. Please install manually."
                exit 1
            fi
            success "$pkg installed successfully via yay."
        fi
        ;;
    esac
}

install_if_missing "steam"
install_if_missing "protontricks"

if ! command -v protontricks &>/dev/null; then
    error "protontricks command not found after install (PATH issue?)"
    case "$DISTRO_FAMILY" in
    debian) echo -e "  Try: ${CYAN}pipx ensurepath && source ~/.bashrc${NC}" ;;
    fedora) echo -e "  Check RPMFusion installation." ;;
    arch) echo -e "  Try: ${CYAN}yay -S protontricks${NC}" ;;
    esac
    exit 1
fi

if ! protontricks --version &>/dev/null; then
    error "protontricks exists but cannot run. Check the installation."
    exit 1
fi

success "protontricks is installed and operational."
press_any_key

# =============================================================================
# STEP 2 — Check Steam is logged in
# =============================================================================
header "Step 2 — Steam Login"

LOGIN_VDF="$STEAM_ROOT/config/loginusers.vdf"
steam_logged_in=false

if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"[[:space:]]*"1"' "$LOGIN_VDF"; then
    STEAM_USER=$(extract_value "PersonaName" "$(cat "$LOGIN_VDF")")
    success "Logged in as: ${BOLD}${STEAM_USER:-unknown}${NC}"
    steam_logged_in=true
elif [[ -d "$STEAM_ROOT/userdata" ]] && compgen -G "$STEAM_ROOT/userdata/[0-9]*" >/dev/null 2>&1; then
    success "Steam userdata found — Steam has been logged in previously."
    steam_logged_in=true
fi

if ! $steam_logged_in; then
    warn "Steam does not appear to be logged in."
    echo
    echo -e "  Please launch Steam, log in, then press any key to continue..."
    press_any_key

    if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"' "$LOGIN_VDF"; then
        success "Steam login detected."
    else
        error "Still no login detected. Log into Steam and re-run this script."
        exit 1
    fi
fi

press_any_key

# =============================================================================
# STEP 3 — Detect iRacing installation type
# =============================================================================
header "Step 3 — Detecting iRacing"

IRACING_ACF="$STEAM_APPS/appmanifest_${IRACING_APPID}.acf"
IRACING_DEPOT_PURCHASE=""
IRACING_DEPOT_DIRECT=""

if [[ -f "$IRACING_ACF" ]]; then
    info "Found iRacing app manifest."
    if grep -q "266415" "$IRACING_ACF"; then
        IRACING_DEPOT_PURCHASE="266415"
        success "iRacing detected as a ${BOLD}Steam Purchase${NC} (depot 266415)."
    elif grep -q "266411" "$IRACING_ACF"; then
        IRACING_DEPOT_DIRECT="266411"
        success "iRacing detected as a ${BOLD}Direct Account / Generated Steam Key${NC} (depot 266411)."
    else
        warn "iRacing manifest found but depot could not be determined. Proceeding anyway."
    fi
else
    warn "No iRacing manifest found."
fi

press_any_key

# =============================================================================
# STEP 4 — Close Steam
# =============================================================================
header "Step 4 — Close Steam"

info "Steam must be closed before the next steps."
echo

if pgrep -f steam &>/dev/null; then
    echo -e "  ${YELLOW}Please close Steam now.${NC}"
    sleep 5
    if pgrep -f steam &>/dev/null; then
        warn "Steam still running — please close it, then press any key..."
        press_any_key
        if pgrep -f steam &>/dev/null; then
            error "Steam still running. Close Steam and re-run this script."
            exit 1
        fi
    fi
fi

success "Steam is closed."
press_any_key

# =============================================================================
# STEP 5 — Confirm iRacing is in Steam library
# =============================================================================
header "Step 5 — iRacing in Steam Library"

if [[ -n "$IRACING_ACF" ]]; then
    success "iRacing is present in your Steam library."
    press_any_key
else
    warn "iRacing is not in your Steam library."
    echo
    echo -e "  ${BOLD}If you have a direct iRacing account${NC}, generate a Steam key here:"
    echo -e "  ${CYAN}  https://support.iracing.com/support/solutions/articles/31000165400-how-to-generate-a-steam-key${NC}"
    echo
    echo -e "  Add iRacing to Steam, then press any key..."
    press_any_key

    if [[ -f "$IRACING_ACF" ]]; then
        if grep -q "266415" "$IRACING_ACF"; then
            IRACING_DEPOT_PURCHASE="266415"
            success "iRacing confirmed as a Steam Purchase."
        elif grep -q "266411" "$IRACING_ACF"; then
            IRACING_DEPOT_DIRECT="266411"
            success "iRacing confirmed as a Direct Account key."
        fi
    else
        error "iRacing still not found. Restart Steam after adding, then re-run this script."
        exit 1
    fi

    press_any_key
fi

# =============================================================================
# STEP 6 — Steam Purchase: verify game files are present
# =============================================================================
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
    header "Step 6 — Steam Purchase Installation"

    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")
    IRACING_PATH="$STEAM_APPS/common/$INSTALL_DIR"

    if [[ -d "$IRACING_PATH" ]]; then
        all_found=true
        for entry in "${IRACING_FINGERPRINT[@]}"; do
            [[ ! -e "$IRACING_PATH/$entry" ]] && {
                all_found=false
                break
            }
        done

        if $all_found; then
            success "iRacing game files found and look complete."
        else
            warn "iRacing directory exists but looks incomplete."
            echo -e "  Open Steam → Right-click iRacing → Properties → Installed Files → Verify integrity"
            echo -e "  Press any key once verification is done..."
            press_any_key
        fi
    else
        warn "iRacing not downloaded yet."
        echo -e "  Open Steam → Library → iRacing → Install"
        echo -e "  Press any key once installation is complete..."
        press_any_key
    fi

    press_any_key
fi

# =============================================================================
# STEP 7 — Direct account: install via Windows installer if stub only
# =============================================================================
if [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    header "Step 7 — Direct Account Installation"

    info "iRacing is a direct account with generated Steam key (depot 266411)."

    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")
    IRACING_STEAM_PATH="$STEAM_APPS/common/$INSTALL_DIR"

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

    if $fully_installed; then
        success "iRacing is already fully installed at: $IRACING_STEAM_PATH"
        press_any_key
    elif $stub_detected || [[ -z "$IRACING_STEAM_PATH" || ! -d "$IRACING_STEAM_PATH" ]]; then
        if [[ ! -d "$IRACING_STEAM_PATH" ]]; then
            warn "iRacing stub not found. Install it via Steam first:"
            echo -e "  ${CYAN}  Library → iRacing → Install${NC}"
            echo -e "  Press any key once the stub is installed..."
            press_any_key

            if [[ ! -d "$IRACING_STEAM_PATH" ]]; then
                error "iRacing stub folder still not found. Re-run after Steam completes the install."
                exit 1
            fi
        fi

        echo
        warn "iRacing stub detected — only the launcher .bat files are present."
        echo
        echo -e "  ${BOLD}1.${NC} Download the iRacing Windows installer:"
        echo -e "     ${CYAN}  https://members.iracing.com/download/member/noservice.jsp${NC}"
        echo
        echo -e "  ${BOLD}2.${NC} File will be named like: ${CYAN}iRacingInstaller_win_YYYY.MM.DD.exe${NC}"
        echo
        echo -e "  ${BOLD}3.${NC} ${RED}${BOLD}Important:${NC} Set the install path to:"
        echo

        # Standard path: Z: maps / in Proton, so $HOME becomes Z:\users\$USER
        IRACING_WIN_PATH="${IRACING_STEAM_PATH/#$HOME/Z:\\users\\$USER}"
        IRACING_WIN_PATH="${IRACING_WIN_PATH//\//\\}"

        echo -e "     ${BOLD}${GREEN}Copy this path into the installer:${NC}"
        echo -e "     ${BOLD}${CYAN}${IRACING_WIN_PATH}${NC}"
        echo
        echo -e "     (Linux path for reference: ${CYAN}$IRACING_STEAM_PATH${NC})"
        echo
        echo -e "  Press any key once the installer is in ~/Downloads..."
        press_any_key

        INSTALLER_EXE=$(find "$HOME/Downloads" -maxdepth 1 -name 'iRacingInstaller_win_*.exe' | sort -t_ -k4 -V | tail -n1 || true)

        if [[ -z "$INSTALLER_EXE" ]]; then
            error "No iRacingInstaller_win_*.exe found in ~/Downloads."
            exit 1
        fi

        success "Found installer: $(basename "$INSTALLER_EXE")"
        echo
        info "Launching installer via protontricks-launch..."
        echo -e "  ${YELLOW}When the installer finishes: ${BOLD}do NOT launch iRacing!${NC}"
        echo -e "  ${YELLOW}Untick 'Launch iRacing' before closing the installer.${NC}"
        echo
        press_any_key

        protontricks-launch --appid "$IRACING_APPID" "$INSTALLER_EXE" >"$GENERAL_LOG" 2>&1

        success "Installer completed."
        echo -e "  Press any key once you've confirmed iRacing has finished installing..."
        press_any_key

        if [[ ! -d "$IRACING_STEAM_PATH" ]] || [[ $(find "$IRACING_STEAM_PATH" -maxdepth 1 -type f | wc -l) -le 3 ]]; then
            error "iRacing doesn't appear to have installed to: $IRACING_STEAM_PATH"
            echo -e "  Re-run the installer and set the path exactly as shown above."
            exit 1
        fi

        success "iRacing installation confirmed."
        press_any_key
    fi
fi

# =============================================================================
# STEP 8 — Install Proton/Wine libraries
# =============================================================================
header "Step 8 — Proton Libraries"

PROTONTRICKS_LOG="$SCRIPT_DIR/danfrasers-iracing-step8.log"

REQUIRED_PKGS=(
    vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022
    d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact
)

info "Checking what is already installed in the Proton prefix..."
echo

INSTALLED_LIST=$(protontricks "$IRACING_APPID" list-installed 2>>"$PROTONTRICKS_LOG" || true)

MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if echo "$INSTALLED_LIST" | grep -qw "$pkg"; then
        success "$pkg — already installed"
    else
        warn "$pkg — missing"
        MISSING+=("$pkg")
    fi
done

echo
echo -e "  ${BOLD}Optional fonts:${NC}"
echo -e "  corefonts and allfonts are not required but may help with text rendering."
echo -e "  ${YELLOW}Warning: These take a very long time to install.${NC}"
echo
echo -n "  Install corefonts and allfonts? [y/N]: "
read -r INSTALL_FONTS
echo

if [[ "$INSTALL_FONTS" =~ ^[Yy]$ ]]; then
    for font_pkg in corefonts allfonts; do
        if echo "$INSTALLED_LIST" | grep -qw "$font_pkg"; then
            success "$font_pkg — already installed"
        else
            MISSING+=("$font_pkg")
            warn "$font_pkg — will be installed"
        fi
    done
fi

if [[ ${#MISSING[@]} -eq 0 ]]; then
    success "All required libraries already present."
    press_any_key
else
    echo -e "  ${YELLOW}Installing ${#MISSING[@]} package(s): ${BOLD}${MISSING[*]}${NC}"
    echo -e "  ${YELLOW}This may take several minutes. Log: danfrasers-iracing-step8.log${NC}"
    echo

    protontricks "$IRACING_APPID" -q --force "${MISSING[@]}" >"$PROTONTRICKS_LOG" 2>&1 &
    PT_PID=$!

    spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    spin_i=0
    echo -ne "  ${CYAN}Please wait ...${NC} "
    while kill -0 "$PT_PID" 2>/dev/null; do
        printf '\b%s' "${spin_chars:$spin_i:1}"
        spin_i=$(((spin_i + 1) % ${#spin_chars}))
        sleep 0.1
    done
    printf '\b \n'

    wait "$PT_PID"
    PT_EXIT=$?
    if [[ $PT_EXIT -ne 0 ]]; then
        error "protontricks exited with an error (code $PT_EXIT)."
        echo -e "  Check: ${CYAN}$PROTONTRICKS_LOG${NC}"
        exit 1
    fi

    success "All required libraries installed."
    press_any_key
fi

# =============================================================================
# STEP 9 — Install custom Proton build
# =============================================================================
header "Step 9 — Custom Proton Build"

mkdir -p "$COMPAT_TOOLS_DIR"

info "Fetching latest release from GitHub (DanFraserUK)..."

RELEASES_JSON=$(curl -fsSL "https://api.github.com/repos/DanFraserUK/proton-cachyos/releases" \
    -H "Accept: application/vnd.github+json" 2>>"$GENERAL_LOG") || {
    error "Failed to reach GitHub API. Check your connection."
    echo -e "  Manual download: ${CYAN}https://github.com/DanFraserUK/proton-cachyos/releases${NC}"
    echo -e "  Extract to: ${BOLD}$COMPAT_TOOLS_DIR${NC}"
    exit 1
}

TARBALL_URL=""
while IFS= read -r line; do
    if [[ "$line" == *'"browser_download_url"'* ]] && [[ "$line" == *'.tar.xz"' ]]; then
        line="${line#*\"browser_download_url\"}"
        line="${line#*\"}"
        TARBALL_URL="${line%\"*}"
        break
    fi
done <<<"$RELEASES_JSON"

if [[ -z "$TARBALL_URL" ]]; then
    error "Could not find a downloadable archive in the latest release."
    echo -e "  Check: ${CYAN}https://github.com/DanFraserUK/proton-cachyos/releases${NC}"
    exit 1
fi

TARBALL_NAME=$(basename "$TARBALL_URL")
PROTON_DIR_NAME="${TARBALL_NAME%.tar.xz}"
TARBALL_TMP="/tmp/$TARBALL_NAME"

if [[ -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
    success "Latest version ($PROTON_DIR_NAME) is already installed."
    press_any_key
else
    info "Downloading: $TARBALL_NAME"
    echo -ne "  ${CYAN}Please wait ...${NC} "

    curl -fsSL -o "$TARBALL_TMP" "$TARBALL_URL" >>"$GENERAL_LOG" 2>&1 &
    DL_PID=$!
    spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    spin_i=0
    while kill -0 "$DL_PID" 2>/dev/null; do
        printf '\b%s' "${spin_chars:$spin_i:1}"
        spin_i=$(((spin_i + 1) % ${#spin_chars}))
        sleep 0.1
    done
    printf '\b \n'

    wait "$DL_PID"
    DL_EXIT=$?
    if [[ $DL_EXIT -ne 0 ]] || [[ ! -s "$TARBALL_TMP" ]]; then
        error "Download failed."
        rm -f "$TARBALL_TMP"
        exit 1
    fi

    info "Extracting to $COMPAT_TOOLS_DIR ..."
    echo -ne "  ${CYAN}Please wait ...${NC} "

    tar -xf "$TARBALL_TMP" -C "$COMPAT_TOOLS_DIR" >>"$GENERAL_LOG" 2>&1 &
    TAR_PID=$!
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
        error "Extraction failed."
        exit 1
    fi

    success "$PROTON_DIR_NAME installed."
    press_any_key
fi

# =============================================================================
# STEP 10 — Optional extras and done screen
# =============================================================================
header "Optional Extras"

# --- Backup /etc/hosts before touching it ---
if [[ ! -f /etc/hosts.bak ]]; then
    sudo cp /etc/hosts /etc/hosts.bak && success "Backed up /etc/hosts to /etc/hosts.bak"
fi

HOSTS_ENTRY="0.0.0.0 modules-cdn.eac-prod.on.epicgames.com"
IRACING_DOCS="$HOME/.local/share/Steam/steamapps/compatdata/266410/pfx/drive_c/users/steamuser/Documents/iRacing"
DOCS_LINK="$HOME/Documents/iRacing"

echo -e "  ${BOLD}EAC (Easy Anti-Cheat) Network Workaround${NC}"
echo -e "  Blocks the EAC CDN to prevent connection issues."
echo

if grep -qF "$HOSTS_ENTRY" /etc/hosts; then
    success "EAC hosts workaround already applied."
    echo -n "  Remove it? [y/N]: "
    read -r REMOVE_HOSTS
    echo
    if [[ "$REMOVE_HOSTS" =~ ^[Yy]$ ]]; then
        local hosts_content="" hosts_line
        while IFS= read -r hosts_line; do
            [[ "$hosts_line" != "$HOSTS_ENTRY" ]] && hosts_content+="$hosts_line"$'\n'
        done </etc/hosts
        echo -n "$hosts_content" | sudo tee /etc/hosts >/dev/null
        success "EAC hosts entry removed."
    fi
else
    echo -e "  ${RED}${BOLD}[!] AT YOUR OWN RISK${NC}"
    echo -e "  ${YELLOW}  Widely used in the iRacing Linux community but could risk a ban.${NC}"
    echo -e "  ${BOLD}Adds to /etc/hosts:${NC} ${CYAN}$HOSTS_ENTRY${NC}"
    echo
    echo -n "  Apply this workaround? [y/N]: "
    read -r APPLY_HOSTS
    echo
    if [[ "$APPLY_HOSTS" =~ ^[Yy]$ ]]; then
        echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts >/dev/null
        success "EAC hosts workaround applied."
    else
        warn "Skipped. To apply manually: ${CYAN}echo \"$HOSTS_ENTRY\" | sudo tee -a /etc/hosts${NC}"
    fi
fi

echo
echo -e "${PINK}$(printf '─%.0s' {1..80})${NC}"
echo
echo -e "  ${BOLD}iRacing Documents Folder Shortcut${NC}"
echo -e "  Creates ${BOLD}~/Documents/iRacing${NC} pointing to the Proton prefix documents folder."
echo

if [[ -L "$DOCS_LINK" ]]; then
    success "~/Documents/iRacing symlink already exists."
elif [[ -d "$IRACING_DOCS" && ! -e "$DOCS_LINK" ]]; then
    echo -n "  Create the symlink? [Y/n]: "
    read -r CREATE_LINK
    echo
    if [[ ! "$CREATE_LINK" =~ ^[Nn]$ ]]; then
        ln -s "$IRACING_DOCS" "$DOCS_LINK"
        success "Symlinked ~/Documents/iRacing"
    fi
else
    warn "iRacing documents folder not found yet — launch iRacing once, then run:"
    echo -e "  ${CYAN}  ln -s \"$IRACING_DOCS\" \"$DOCS_LINK\"${NC}"
fi

press_any_key

# --- Done screen ---
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
echo -e "${NC}${BOLD}  Setup complete! iRacing is ready to attempt to be played.${NC}"
echo -e "    ${GREEN}✔${NC} protontricks & Steam installed"
echo -e "    ${GREEN}✔${NC} Steam login verified"
echo -e "    ${GREEN}✔${NC} iRacing installation type detected"
echo -e "    ${GREEN}✔${NC} iRacing installed / verified"
echo -e "    ${GREEN}✔${NC} Proton libraries installed"
echo -e "    ${GREEN}✔${NC} Custom Proton build (${PROTON_DIR_NAME}) installed"
echo
echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}"
echo -e "${BOLD}${LIGHTYELLOW}  Next steps — open Steam and do the following:${NC}"
echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}"
echo -e "  ${BOLD}1.${NC} Set iRacing to use the custom Proton build:"
echo -e "     ${CYAN}Right-click iRacing → Properties → Compatibility${NC}"
echo -e "     ${CYAN}Tick 'Force the use of a specific Steam Play compatibility tool'${NC}"
echo -e "     ${CYAN}Select '${BOLD}${PROTON_DIR_NAME}${NC}${CYAN}' from the list${NC}"
if [[ -n "$IRACING_DEPOT_DIRECT" ]]; then
    echo
    echo -e "  ${BOLD}2.${NC} Set launch options:"
    echo -e "     ${CYAN}Right-click iRacing → Properties → General → Launch Options${NC}"
    echo -e "     ${BOLD}${GREEN}PROTON_LOG=1 LD_PRELOAD=\"\" %command%${NC}"
fi
echo
echo -e "${BOLD}${CYAN}  This was for you Pabs ${RED}<3${NC}"
echo
echo -e "${GREEN}  All done! Open Steam and enjoy your racing!${NC}"
echo
echo -e "${YELLOW}  Press any key to finish...${NC}"
read -n 1 -s -r
echo
