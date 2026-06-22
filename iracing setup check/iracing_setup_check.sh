#!/usr/bin/env bash
# =============================================================================
# iRacing Setup Checker for Linux
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

# --- General log (same dir as script) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERAL_LOG="$SCRIPT_DIR/danfrasers-iracing-setup.log"
> "$GENERAL_LOG"  # Clear on each run
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$GENERAL_LOG"; }

# --- Helpers (print to terminal AND log) ---
info()    { echo -e "${CYAN}[INFO]${NC}  $*";  log "[INFO]  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*";  log "[OK]    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*";  log "[WARN]  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*";  log "[ERROR] $*"; }
header()  {
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

press_any_key_exit() {
    echo -e "\n${YELLOW}Press any key to exit...${NC}"
    read -n 1 -s -r
    echo
    exit 0
}

# Extract the quoted value for a given key from a block of text.
# Usage: result=$(extract_value "key" "$text_block")
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
    done <<< "$text"
}

# =============================================================================
# SHARED: Done screen — called from both the preflight pass and the full run
# =============================================================================
show_done_screen() {
    local proton_dir="$1"
    local depot_direct="$2"
    clear
    echo -e "${BOLD}${PINK}"
    cat << 'EOF'
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
    echo -e "    ${GREEN}✔${NC} Custom Proton build (${proton_dir}) installed"
    echo
    echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}"
    echo -e "${BOLD}${LIGHTYELLOW}  Next steps — open Steam and do the following:${NC}"
    echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}"
    echo -e "  ${BOLD}1.${NC} Set iRacing to use the custom Proton build:"
    echo -e "     ${CYAN}Right-click iRacing → Properties → Compatibility${NC}"
    echo -e "     ${CYAN}Tick 'Force the use of a specific Steam Play compatibility tool'${NC}"
    echo -e "     ${CYAN}Select '${BOLD}${proton_dir}${NC}${CYAN}' from the list${NC}"
    if [[ -n "$depot_direct" ]]; then
        echo
        echo -e "  ${BOLD}2.${NC} Set the following launch options for iRacing:"
        echo -e "     ${CYAN}Right-click iRacing → Properties → General → Launch Options${NC}"
        echo -e "     ${BOLD}${GREEN}PROTON_LOG=1 LD_PRELOAD=\"\" %command%${NC}"
    fi
}

# =============================================================================
# SHARED: Optional steps — EAC workaround and Documents symlink
# Always shown regardless of whether the user went through the full setup or not.
# =============================================================================
run_optional_steps() {
    local depot_direct="$1"
    local proton_dir="$2"

    # --- Optional Extras: EAC workaround + Documents symlink ---
    header "Optional Extras"

    local HOSTS_ENTRY="0.0.0.0 modules-cdn.eac-prod.on.epicgames.com"
    local IRACING_DOCS="$HOME/.local/share/Steam/steamapps/compatdata/266410/pfx/drive_c/users/steamuser/Documents/iRacing"
    local DOCS_LINK="$HOME/Documents/iRacing"

    echo -e "  ${BOLD}EAC (Easy Anti-Cheat) Network Workaround${NC}"
    echo -e "  iRacing uses Easy Anti-Cheat. On Linux, a known workaround is to block"
    echo -e "  the EAC CDN in your hosts file to prevent connection issues."
    echo

    if grep -qF "$HOSTS_ENTRY" /etc/hosts; then
        success "EAC hosts workaround is already applied."
        echo
        echo -n "  Do you want to remove it? [y/N]: "
        read -r REMOVE_HOSTS
        echo
        if [[ "$REMOVE_HOSTS" =~ ^[Yy]$ ]]; then
            local hosts_content="" hosts_line
            while IFS= read -r hosts_line; do
                if [[ "$hosts_line" != "$HOSTS_ENTRY" ]]; then
                    hosts_content+="$hosts_line"$'\n'
                fi
            done < /etc/hosts
            echo -n "$hosts_content" | sudo tee /etc/hosts > /dev/null
            success "EAC hosts entry removed from /etc/hosts."
        else
            info "Leaving EAC hosts workaround in place."
        fi
    else
        echo -e "  ${RED}${BOLD}[!] AT YOUR OWN RISK${NC}"
        echo -e "  ${YELLOW}  This workaround modifies how EAC communicates with its servers.${NC}"
        echo -e "  ${YELLOW}  While widely used in the iRacing Linux community,${NC}"
        echo -e "  ${YELLOW}  circumventing anti-cheat could potentially result in your account being banned.${NC}"
        echo
        echo -e "  ${BOLD}The following line will be added to /etc/hosts:${NC}"
        echo -e "  ${CYAN}  $HOSTS_ENTRY${NC}"
        echo -e "  ${YELLOW}  Note: This requires sudo (administrator) privileges.${NC}"
        echo
        echo -n "  Do you want to apply this workaround? [y/N]: "
        read -r APPLY_HOSTS
        echo
        if [[ "$APPLY_HOSTS" =~ ^[Yy]$ ]]; then
            echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null
            success "EAC hosts entry added to /etc/hosts."
        else
            warn "Skipped. To apply manually later:"
            echo -e "  ${CYAN}  echo \"$HOSTS_ENTRY\" | sudo tee -a /etc/hosts${NC}"
        fi
    fi

    echo
    echo -e "${PINK}$(printf '─%.0s' {1..80})${NC}"
    echo
    echo -e "  ${BOLD}iRacing Documents Folder Shortcut${NC}"
    echo -e "  iRacing stores your settings, setups, and replays in a Documents folder"
    echo -e "  deep inside the Proton prefix. A symlink brings it to ${BOLD}~/Documents/iRacing${NC}"
    echo -e "  for easy access."
    echo

    if [[ -L "$DOCS_LINK" ]]; then
        success "~/Documents/iRacing symlink already exists — nothing to do."
    elif [[ -d "$IRACING_DOCS" && ! -e "$DOCS_LINK" ]]; then
        echo -n "  Do you want to create the symlink? [Y/n]: "
        read -r CREATE_LINK
        echo
        if [[ ! "$CREATE_LINK" =~ ^[Nn]$ ]]; then
            ln -s "$IRACING_DOCS" "$DOCS_LINK"
            success "Symlinked iRacing documents folder to ~/Documents/iRacing"
        else
            info "Skipped. To create manually later:"
            echo -e "  ${CYAN}  ln -s \"$IRACING_DOCS\" \"$DOCS_LINK\"${NC}"
        fi
    else
        warn "iRacing documents folder not found — launch iRacing once to create it, then run:"
        echo -e "  ${CYAN}  ln -s \"$IRACING_DOCS\" \"$DOCS_LINK\"${NC}"
    fi

    press_any_key

    # --- Done screen ---
    show_done_screen "$proton_dir" "$depot_direct"

    # --- Sign-off ---
    echo -e "${BOLD}${CYAN}  This was for you Pabs ${RED}<3${NC}"
    echo
    echo -e "${GREEN}  All done! Open Steam and enjoy your racing!${NC}"
    echo
    echo -e "${YELLOW}  Press any key to finish...${NC}"
    read -n 1 -s -r
    echo
}

# =============================================================================
# PRE-FLIGHT CHECK — Run silently after intro pages.
# Checks all conditions that the full setup covers. If everything passes,
# show the congratulations screen, run optional steps, and exit.
# If anything fails, fall through to the full setup flow.
# =============================================================================
run_preflight_check() {
    local pf_failures=()
    local pf_skip_packages=true
    local pf_skip_login=true
    local pf_skip_iracing=true
    local pf_skip_libraries=true
    local pf_skip_proton=true
    local pf_depot_direct="" pf_proton_dir_name=""

    # --- 1. steam and protontricks installed ---
    if ! pacman -Qi steam &>/dev/null; then
        pf_failures+=("steam is not installed")
        pf_skip_packages=false
    fi
    if ! pacman -Qi protontricks &>/dev/null; then
        pf_failures+=("protontricks is not installed")
        pf_skip_packages=false
    fi

    # --- 2. Steam logged in ---
    local pf_login_vdf="$HOME/.steam/steam/config/loginusers.vdf"
    local pf_userdata_dir="$HOME/.steam/steam/userdata"
    local pf_steam_ok=false
    if [[ -f "$pf_login_vdf" ]] && grep -q '"MostRecent"[[:space:]]*"1"' "$pf_login_vdf"; then
        pf_steam_ok=true
    elif [[ -d "$pf_userdata_dir" ]] && compgen -G "$pf_userdata_dir/[0-9]*" > /dev/null 2>&1; then
        pf_steam_ok=true
    fi
    if ! $pf_steam_ok; then
        pf_failures+=("Steam is not logged in")
        pf_skip_login=false
    fi

    # --- 3. iRacing manifest, depot type, and game files ---
    local pf_steam_libs=("$HOME/.steam/steam/steamapps")
    local pf_library_vdf="$HOME/.steam/steam/steamapps/libraryfolders.vdf"
    if [[ -f "$pf_library_vdf" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ \"path\" ]]; then
                local pf_path="${line#*\"}"
                pf_path="${pf_path%\"*}"
                if [[ -d "$pf_path/steamapps" ]]; then
                    pf_steam_libs+=("$pf_path/steamapps")
                fi
            fi
        done < "$pf_library_vdf"
    fi

    local pf_acf="" pf_depot_purchase="" pf_install_dir="" pf_game_path=""
    for lib in "${pf_steam_libs[@]}"; do
        if [[ -f "$lib/appmanifest_266410.acf" ]]; then
            pf_acf="$lib/appmanifest_266410.acf"
            break
        fi
    done

    if [[ -z "$pf_acf" ]]; then
        pf_failures+=("iRacing is not in your Steam library")
        pf_skip_iracing=false
    else
        if grep -q "266415" "$pf_acf"; then
            pf_depot_purchase="266415"
        elif grep -q "266411" "$pf_acf"; then
            pf_depot_direct="266411"
        else
            pf_failures+=("iRacing depot type could not be determined")
            pf_skip_iracing=false
        fi

        if [[ -z "${pf_failures[*]}" ]] || ! echo "${pf_failures[*]}" | grep -q "depot\|library"; then
            pf_install_dir=$(extract_value "installdir" "$(cat "$pf_acf")")
            for lib in "${pf_steam_libs[@]}"; do
                if [[ -d "$lib/common/$pf_install_dir" ]]; then
                    pf_game_path="$lib/common/$pf_install_dir"
                    break
                fi
            done

            if [[ -z "$pf_game_path" ]]; then
                pf_failures+=("iRacing game files are not installed")
                pf_skip_iracing=false
            else
                local pf_fingerprint=("iRacingSim64DX11.exe" "iRacingService64.exe" "iRacingLauncher64.exe" "EasyAntiCheat" "ui" "cars" "tracks")
                for entry in "${pf_fingerprint[@]}"; do
                    if [[ ! -e "$pf_game_path/$entry" ]]; then
                        pf_failures+=("iRacing installation appears incomplete (missing: $entry)")
                        pf_skip_iracing=false
                        break
                    fi
                done
            fi
        fi
    fi

    # --- 4. Required winetricks packages ---
    local pf_required=(vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022 d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact)
    local pf_installed
    pf_installed=$(protontricks 266410 list-installed 2>/dev/null || true)
    local pf_missing_pkgs=()
    for pkg in "${pf_required[@]}"; do
        if ! echo "$pf_installed" | grep -qw "$pkg"; then
            pf_missing_pkgs+=("$pkg")
        fi
    done
    if [[ ${#pf_missing_pkgs[@]} -gt 0 ]]; then
        pf_failures+=("Missing Proton libraries: ${pf_missing_pkgs[*]}")
        pf_skip_libraries=false
    fi

    # --- 5. Custom Proton build ---
    local pf_compat_dir="$HOME/.steam/steam/compatibilitytools.d"
    local pf_releases_json pf_tarball_url pf_tarball_name pf_line
    pf_releases_json=$(curl -fsSL "https://api.github.com/repos/DanFraserUK/proton-cachyos/releases" -H "Accept: application/vnd.github+json" 2>/dev/null || true)
    if [[ -z "$pf_releases_json" ]]; then
        log "Pre-flight: GitHub API unreachable — falling back to directory check"
        if ! compgen -G "$pf_compat_dir/proton-cachyos*" > /dev/null 2>&1; then
            pf_failures+=("Custom Proton build is not installed (GitHub unreachable for version check)")
            pf_skip_proton=false
        fi
    else
        while IFS= read -r pf_line; do
            if [[ "$pf_line" == *'"browser_download_url"'* ]] && [[ "$pf_line" == *'.tar.xz"' ]]; then
                pf_line="${pf_line#*\"browser_download_url\"}"
                pf_line="${pf_line#*\"}"
                pf_tarball_url="${pf_line%\"*}"
                break
            fi
        done <<< "$pf_releases_json"
        pf_tarball_name=$(basename "$pf_tarball_url")
        pf_proton_dir_name="${pf_tarball_name%.tar.xz}"
        if [[ ! -d "$pf_compat_dir/$pf_proton_dir_name" ]]; then
            pf_failures+=("Custom Proton build is not installed or is out of date")
            pf_skip_proton=false
        fi
    fi

    # --- Expose results directly to the calling scope ---
    PF_SKIP_PACKAGES=$pf_skip_packages
    PF_SKIP_LOGIN=$pf_skip_login
    PF_SKIP_IRACING=$pf_skip_iracing
    PF_SKIP_LIBRARIES=$pf_skip_libraries
    PF_SKIP_PROTON=$pf_skip_proton
    PREFLIGHT_PROTON_DIR="$pf_proton_dir_name"
    PREFLIGHT_DEPOT_DIRECT="$pf_depot_direct"
    PREFLIGHT_FAILURES=("${pf_failures[@]}")

    if [[ ${#pf_failures[@]} -eq 0 ]]; then
        log "Pre-flight passed — system is already fully set up"
        return 0
    else
        log "Pre-flight found ${#pf_failures[@]} issue(s)"
        return 1
    fi
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
# ENTRANCE MESSAGE — Page 1: Quick intro
# =============================================================================
clear
echo -e "${BOLD}${PINK}"
cat << 'EOF'
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
echo -e "  ${BOLD}Linux iRacing setup walkthrough${NC}"
echo -e "  ${CYAN}by Dan Fraser${NC}"
echo
echo -e "  ${BOLD}Detected OS:${NC} ${CYAN}${OS_NAME}${NC}"
echo -e "  ${BOLD}Supported:${NC}   ${CYAN}Arch / CachyOS / EndeavourOS${NC}"
# echo -e "  ${BOLD}Supported:${NC}   ${CYAN}Arch / CachyOS / EndeavourOS / Debian / Ubuntu / Fedora / Nobara${NC}"
echo
echo -e "  ${YELLOW}Some steps require sudo — typically your login password.${NC}"
echo

press_any_key

# =============================================================================
# ENTRANCE MESSAGE — Page 2: What this script does
# =============================================================================
clear
echo -e "${BOLD}${LIGHTYELLOW}  What this script will do:${NC}\n"
echo -e "  First, a quick check of your current system runs automatically."
echo -e "  If everything is already set up, you will be told straight away."
echo -e "  If anything needs attention, only those specific steps will run.\n"
echo -e "  ${GREEN}✔${NC} Check & install protontricks and Steam"
echo -e "  ${GREEN}✔${NC} Verify Steam is logged in"
echo -e "  ${GREEN}✔${NC} Detect your iRacing installation type"
echo -e "  ${GREEN}✔${NC} Close Steam (required for the steps that follow)"
echo -e "  ${GREEN}✔${NC} Check iRacing is in your Steam library"
echo -e "  ${GREEN}✔${NC} Install or verify iRacing game files"
echo -e "  ${GREEN}✔${NC} Install required Proton/Wine libraries"
echo -e "  ${GREEN}✔${NC} Install a custom Proton build by Dan Fraser"
echo -e "  ${GREEN}✔${NC} Optionally apply the EAC network workaround"
echo
echo -e "  ${BOLD}A custom Proton build by ${PINK}Dan Fraser${NC}${BOLD} will be installed.${NC}"
echo -e "  This is a fork of proton-cachyos containing a specific fix for iRacing"
echo -e "  that has not yet made it into the upstream build."
echo
echo -e "  ${BOLD}Logs are written to the script directory:${NC}"
echo -e "  ${CYAN}  danfrasers-iracing-setup.log${NC}  — general activity log"
echo -e "  ${CYAN}  danfrasers-iracing-step8.log${NC}  — protontricks library install log"
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
# PRE-FLIGHT — Run all checks silently. Skip the full setup if already good.
# =============================================================================
clear
echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}"
echo -e "${BOLD}${LIGHTYELLOW}  Checking your system...${NC}"
echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}\n"

PF_SKIP_PACKAGES=false
PF_SKIP_LOGIN=false
PF_SKIP_IRACING=false
PF_SKIP_LIBRARIES=false
PF_SKIP_PROTON=false
PREFLIGHT_PROTON_DIR=""
PREFLIGHT_DEPOT_DIRECT=""
PREFLIGHT_FAILURES=()

echo -e "  ${CYAN}This will take a few seconds — please wait...${NC}"
echo

run_preflight_check
PF_EXIT=$?

if [[ $PF_EXIT -eq 0 ]]; then
    # Everything is already set up — show congratulations and run optional steps
    clear
    echo -e "${BOLD}${PINK}"
    cat << 'EOF'
   ██████╗ ██████╗ ███╗   ██╗ ██████╗ ██████╗  █████╗ ████████╗███████╗██╗
  ██╔════╝██╔═══██╗████╗  ██║██╔════╝ ██╔══██╗██╔══██╗╚══██╔══╝██╔════╝██║
  ██║     ██║   ██║██╔██╗ ██║██║  ███╗██████╔╝███████║   ██║   ███████╗██║
  ██║     ██║   ██║██║╚██╗██║██║   ██║██╔══██╗██╔══██║   ██║   ╚════██║╚═╝
  ╚██████╗╚██████╔╝██║ ╚████║╚██████╔╝██║  ██║██║  ██║   ██║   ███████║██╗
   ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝
EOF
    echo -e "${NC}"
    echo -e "${BOLD}  Your system is already fully set up for iRacing!${NC}"
    echo
    echo -e "    ${GREEN}✔${NC} protontricks & Steam installed"
    echo -e "    ${GREEN}✔${NC} Steam login verified"
    echo -e "    ${GREEN}✔${NC} iRacing detected and fully installed"
    echo -e "    ${GREEN}✔${NC} All required Proton libraries present"
    echo -e "    ${GREEN}✔${NC} Custom Proton build (${PREFLIGHT_PROTON_DIR}) installed and up to date"
    echo
    press_any_key
    run_optional_steps "$PREFLIGHT_DEPOT_DIRECT" "$PREFLIGHT_PROTON_DIR"
    exit 0
fi

# Show what needs fixing before continuing
clear
echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}"
echo -e "${BOLD}${LIGHTYELLOW}  The following items need attention:${NC}"
echo -e "${PINK}$(printf '═%.0s' {1..80})${NC}\n"
echo -e "  The quick check found the following issues to resolve:\n"
for failure in "${PREFLIGHT_FAILURES[@]}"; do
    echo -e "  ${YELLOW}  - ${failure}${NC}"
done
echo
echo -e "  The script will now step through only what needs fixing."
echo -e "  Steps that are already correctly set up will be skipped."
echo
press_any_key

# =============================================================================
# STEP 1 — Check & install protontricks and Steam
# =============================================================================
if ! $PF_SKIP_PACKAGES; then
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
fi # end PF_SKIP_PACKAGES

# =============================================================================
# STEP 2 — Check if Steam is logged in
# =============================================================================
if ! $PF_SKIP_LOGIN; then
header "Checking Steam Login"

STEAM_CONFIG_DIR="$HOME/.steam/steam"
STEAM_USERDATA_DIR="$HOME/.steam/steam/userdata"

steam_logged_in=false

# Check for loginusers.vdf which contains logged-in Steam accounts
LOGIN_VDF="$STEAM_CONFIG_DIR/config/loginusers.vdf"

if [[ -f "$LOGIN_VDF" ]]; then
    # Look for at least one account with MostRecent set to 1 on the same line
    if grep -q '"MostRecent"[[:space:]]*"1"' "$LOGIN_VDF"; then
        STEAM_USER=$(extract_value "PersonaName" "$(cat "$LOGIN_VDF")")
        success "Steam appears to be configured for user: ${BOLD}${STEAM_USER:-unknown}${NC}"
        steam_logged_in=true
    fi
fi

# Also check userdata directory for any user folders (numeric IDs)
if ! $steam_logged_in; then
    if [[ -d "$STEAM_USERDATA_DIR" ]] && compgen -G "$STEAM_USERDATA_DIR/[0-9]*" > /dev/null 2>&1; then
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

    if [[ -f "$LOGIN_VDF" ]] && grep -q '"MostRecent"' "$LOGIN_VDF"; then
        success "Steam login detected. Continuing."
    else
        error "Still unable to confirm Steam login. Please ensure you've logged in and re-run this script."
        exit 1
    fi
fi

press_any_key
fi # end PF_SKIP_LOGIN

# =============================================================================
# STEP 3 — Detect iRacing installation type
# Steps 3/4/5 always run — detection populates variables needed by later steps.
# =============================================================================
header "Detecting iRacing Installation Type"

STEAM_LIBRARY_DIRS=()
STEAM_LIBRARY_DIRS+=("$HOME/.steam/steam/steamapps")

LIBRARY_VDF="$HOME/.steam/steam/steamapps/libraryfolders.vdf"
if [[ -f "$LIBRARY_VDF" ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ \"path\" ]]; then
            path="${line#*\"}"
            path="${path%\"*}"
            if [[ -d "$path/steamapps" ]]; then
                STEAM_LIBRARY_DIRS+=("$path/steamapps")
            fi
        fi
    done < "$LIBRARY_VDF"
fi

IRACING_DEPOT_PURCHASE=""
IRACING_DEPOT_DIRECT=""
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

info "Steam is not needed for the remaining steps and must be closed before changes are applied."
echo

if pgrep -f steam &>/dev/null; then
    echo -e "  ${YELLOW}Please close Steam now.${NC}"
    echo
    sleep 5
    if pgrep -f steam &>/dev/null; then
        warn "Steam still appears to be running."
        echo -e "  Please close Steam manually, then press any key to continue..."
        press_any_key
        if pgrep -f steam &>/dev/null; then
            error "Steam still running. Please close Steam and re-run this script."
            exit 1
        fi
    fi
fi

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

# Core top-level files and folders present in any complete iRacing install,
# regardless of account type or purchased content. Used by both Step 6 and Step 7
# as a cheap fingerprint check to confirm a real installation exists.
IRACING_FINGERPRINT=(
    "iRacingSim64DX11.exe"
    "iRacingService64.exe"
    "iRacingLauncher64.exe"
    "EasyAntiCheat"
    "ui"
    "cars"
    "tracks"
)

if [[ -n "$IRACING_DEPOT_PURCHASE" ]] && ! $PF_SKIP_IRACING; then
    header "Steam Purchase — Installation Check"

    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")
    IRACING_PATH=""
    for lib in "${STEAM_LIBRARY_DIRS[@]}"; do
        if [[ -d "$lib/common/$INSTALL_DIR" ]]; then
            IRACING_PATH="$lib/common/$INSTALL_DIR"
            break
        fi
    done

    if [[ -n "$IRACING_PATH" ]]; then
        all_found=true
        for entry in "${IRACING_FINGERPRINT[@]}"; do
            if [[ ! -e "$IRACING_PATH/$entry" ]]; then
                all_found=false
                break
            fi
        done

        if $all_found; then
            success "iRacing game files found at: $IRACING_PATH"
            success "Steam purchase installation looks good — ready for the next step."
        else
            warn "iRacing directory exists but appears incomplete."
            echo
            echo -e "  Please open Steam and verify or reinstall iRacing:"
            echo -e "  ${CYAN}  Right-click iRacing → Properties → Installed Files → Verify integrity${NC}"
            echo
            echo -e "  Once verification is complete, press any key to continue..."
            press_any_key
            success "Continuing — please ensure iRacing has finished verifying before proceeding."
        fi
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
if [[ -n "$IRACING_DEPOT_DIRECT" ]] && ! $PF_SKIP_IRACING; then
    header "Direct Account — Installation Check"

    info "iRacing is a direct account with generated Steam key (depot 266411)."

    INSTALL_DIR=$(extract_value "installdir" "$(cat "$IRACING_ACF")")
    IRACING_STEAM_PATH=""
    for lib in "${STEAM_LIBRARY_DIRS[@]}"; do
        if [[ -d "$lib/common/$INSTALL_DIR" ]]; then
            IRACING_STEAM_PATH="$lib/common/$INSTALL_DIR"
            break
        fi
    done

    fully_installed=false
    stub_detected=false

    if [[ -n "$IRACING_STEAM_PATH" ]]; then
        all_found=true
        for entry in "${IRACING_FINGERPRINT[@]}"; do
            if [[ ! -e "$IRACING_STEAM_PATH/$entry" ]]; then
                all_found=false
                break
            fi
        done
        if $all_found; then
            fully_installed=true
        else
            FILE_COUNT=$(find "$IRACING_STEAM_PATH" -maxdepth 1 -type f | wc -l)
            DIR_SIZE=$(du -sb "$IRACING_STEAM_PATH" 2>/dev/null)
            DIR_SIZE="${DIR_SIZE%%$'\t'*}"
            if [[ "$FILE_COUNT" -le 3 && "$DIR_SIZE" -lt 5000 ]]; then
                stub_detected=true
            fi
        fi
    fi

    if $fully_installed; then
        success "iRacing is already fully installed at: $IRACING_STEAM_PATH"
        success "Direct account installation looks good — ready for the next step."
        press_any_key
    elif $stub_detected || [[ -z "$IRACING_STEAM_PATH" ]]; then
        if [[ -z "$IRACING_STEAM_PATH" ]]; then
            warn "iRacing game folder not found. Please install the stub via Steam first:"
            echo -e "  ${CYAN}  Library → iRacing → Install${NC}"
            echo
            echo -e "  This will download a small stub. Press any key once Steam shows it as installed..."
            press_any_key

            for lib in "${STEAM_LIBRARY_DIRS[@]}"; do
                if [[ -d "$lib/common/$INSTALL_DIR" ]]; then
                    IRACING_STEAM_PATH="$lib/common/$INSTALL_DIR"
                    break
                fi
            done

            if [[ -z "$IRACING_STEAM_PATH" ]]; then
                error "iRacing stub folder still not found. Please ensure the Steam install completed and re-run this script."
                exit 1
            fi
        fi

        echo
        warn "iRacing stub detected — only the 3 launcher .bat files are present."
        echo
        echo -e "  The full iRacing files need to be installed using the iRacing installer."
        echo -e "  Do NOT proceed until iRacing has been fully installed via the installer below."
        echo
        echo -e "  ${BOLD}1.${NC} Open this URL and download the installer:"
        echo -e "     ${CYAN}  https://members.iracing.com/download/member/noservice.jsp${NC}"
        echo -e "     ${YELLOW}  (Ctrl+Click to open in your browser)${NC}"
        echo
        echo -e "  ${BOLD}2.${NC} The file will be named something like:"
        echo -e "     ${CYAN}  iRacingInstaller_win_2026.06.09.01.exe${NC}  (date will vary — grab the latest)"
        echo
        echo -e "  ${BOLD}3.${NC} ${RED}${BOLD}Important:${NC} When the installer asks where to install iRacing,"
        echo -e "     you ${BOLD}must${NC} change the install path to the following location:"
        echo
        IRACING_WIN_PATH="${IRACING_STEAM_PATH/#$HOME/Z:\\users\\$USER}"
        IRACING_WIN_PATH="${IRACING_WIN_PATH//\//\\}"
        echo -e "     ${BOLD}${GREEN}Copy this path:${NC}"
        echo -e "     ${BOLD}${CYAN}${IRACING_WIN_PATH}${NC}"
        echo
        echo -e "     Or as a Linux path for reference:"
        echo -e "     ${CYAN}  $IRACING_STEAM_PATH${NC}"
        echo
        echo -e "     ${YELLOW}  This ensures iRacing installs alongside the stub files so that${NC}"
        echo -e "     ${YELLOW}  Steam can launch it correctly using relative paths.${NC}"
        echo
        echo -e "  Press any key once the installer has been downloaded to ~/Downloads..."
        press_any_key

        INSTALLER_EXE=$(find "$HOME/Downloads" -maxdepth 1 -name 'iRacingInstaller_win_*.exe' | sort -t_ -k4 -V | tail -n1 || true)

        if [[ -z "$INSTALLER_EXE" ]]; then
            error "No iRacingInstaller_win_*.exe found in ~/Downloads."
            echo -e "  Please download the installer from the members site and try again."
            exit 1
        fi

        success "Found installer: $(basename "$INSTALLER_EXE")"
        echo
        info "Launching iRacing installer via protontricks-launch..."
        echo -e "  ${YELLOW}IMPORTANT: When the installer finishes — ${BOLD}do NOT launch iRacing!${NC}"
        echo -e "  ${YELLOW}           Make sure to ${BOLD}untick the 'Launch iRacing' option${NC}${YELLOW} before closing!${NC}"
        echo
        press_any_key

        # Installer output goes to the general log. We deliberately start with > (not >>)
        # to keep the log clean and manageable — installer output is verbose and we only
        # care about what happened in this run.
        protontricks-launch --appid "$IRACING_APPID" "$INSTALLER_EXE" >"$GENERAL_LOG" 2>&1

        success "iRacing installer completed."
        echo
        echo -e "  Press any key once you have confirmed iRacing has finished installing..."
        press_any_key

        # Cheap top-level scan only — same approach as IRACING_FINGERPRINT above.
        # We're just confirming more than 3 files exist, not doing a deep integrity check.
        if [[ ! -d "$IRACING_STEAM_PATH" ]] || [[ $(find "$IRACING_STEAM_PATH" -maxdepth 1 -type f | wc -l) -le 3 ]]; then
            error "iRacing does not appear to have installed to the expected location:"
            echo -e "  ${CYAN}  $IRACING_STEAM_PATH${NC}"
            echo -e "  Please re-run the installer, ensuring you set the install path as shown above."
            exit 1
        fi
        success "iRacing installation confirmed at: $IRACING_STEAM_PATH"
        press_any_key
    fi

fi

# =============================================================================
# STEP 8 — Install Proton/Wine redistributable libraries
# =============================================================================
if ! $PF_SKIP_LIBRARIES; then
    header "Installing Required Proton Libraries"

    PROTONTRICKS_LOG="$SCRIPT_DIR/danfrasers-iracing-step8.log"

    REQUIRED_PACKAGES=(
        vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022
        d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact
    )

    info "Checking what is already installed in the Proton prefix..."
    echo

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

    echo -e "  ${BOLD}Optional fonts:${NC}"
    echo -e "  Installing ${BOLD}corefonts${NC} and ${BOLD}allfonts${NC} is not required to play iRacing, but"
    echo -e "  without them you may see visual text rendering issues in-game or in the UI."
    echo -e "  ${YELLOW}Warning: Installing these can take a very, very long time.${NC}"
    echo
    echo -n "  Do you want to install corefonts and allfonts? [y/N]: "
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
        success "Proton prefix appears to be ready — all required libraries are already present."
        press_any_key
    else
        echo -e "  ${YELLOW}${#MISSING[@]} package(s) to install: ${BOLD}${MISSING[*]}${NC}"
        echo -e "  ${YELLOW}This may take several minutes. Output is logged to danfrasers-iracing-step8.log.${NC}"
        echo

        protontricks "$IRACING_APPID" -q --force "${MISSING[@]}" >"$PROTONTRICKS_LOG" 2>&1 &
        PT_PID=$!

        spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        spin_i=0
        echo -ne "  ${CYAN}Please wait ...${NC} "
        while kill -0 "$PT_PID" 2>/dev/null; do
            printf '\b%s' "${spin_chars:$spin_i:1}"
            spin_i=$(( (spin_i + 1) % ${#spin_chars} ))
            sleep 0.1
        done
        printf '\b \n'

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
fi # end PF_SKIP_LIBRARIES

# =============================================================================
# STEP 9 — Install custom Proton build
# =============================================================================
if ! $PF_SKIP_PROTON; then
    header "Installing Custom Proton Build by Dan Fraser"

    COMPAT_TOOLS_DIR="$HOME/.steam/steam/compatibilitytools.d"
    mkdir -p "$COMPAT_TOOLS_DIR"

    info "Fetching the latest release from GitHub (DanFraserUK)..."

    RELEASES_JSON=$(curl -fsSL "https://api.github.com/repos/DanFraserUK/proton-cachyos/releases" -H "Accept: application/vnd.github+json" 2>>"$GENERAL_LOG") || {
        error "Failed to reach GitHub API. Check your internet connection."
        log "curl to GitHub API failed"
        echo -e "  Manual download: ${CYAN}https://github.com/DanFraserUK/proton-cachyos/releases${NC}"
        echo -e "  Extract the archive to: ${BOLD}$COMPAT_TOOLS_DIR${NC}"
        exit 1
    }

    LATEST_TAG=$(extract_value "tag_name" "$RELEASES_JSON")

    TARBALL_URL=""
    while IFS= read -r line; do
        if [[ "$line" == *'"browser_download_url"'* ]] && [[ "$line" == *'.tar.xz"' ]]; then
            line="${line#*\"browser_download_url\"}"
            line="${line#*\"}"
            TARBALL_URL="${line%\"*}"
            break
        fi
    done <<< "$RELEASES_JSON"

    if [[ -z "$TARBALL_URL" ]]; then
        error "Could not find a downloadable archive in the latest release."
        log "No .tar.xz asset found in releases JSON"
        echo -e "  Please check: ${CYAN}https://github.com/DanFraserUK/proton-cachyos/releases${NC}"
        echo -e "  Download the archive manually and extract it to: ${BOLD}$COMPAT_TOOLS_DIR${NC}"
        exit 1
    fi

    log "Latest tag: $LATEST_TAG"
    log "Resolved tarball URL: $TARBALL_URL"
    TARBALL_NAME=$(basename "$TARBALL_URL")
    TARBALL_TMP="/tmp/$TARBALL_NAME"

    PROTON_DIR_NAME="$TARBALL_NAME"
    PROTON_DIR_NAME="${PROTON_DIR_NAME%.tar.xz}"

    if [[ -d "$COMPAT_TOOLS_DIR/$PROTON_DIR_NAME" ]]; then
        success "Latest version (${PROTON_DIR_NAME}) is already installed — nothing to do."
        log "Skipping download — $PROTON_DIR_NAME already present in $COMPAT_TOOLS_DIR"
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
            spin_i=$(( (spin_i + 1) % ${#spin_chars} ))
            sleep 0.1
        done
        printf '\b \n'

        wait "$DL_PID"
        DL_EXIT=$?
        if [[ $DL_EXIT -ne 0 ]] || [[ ! -s "$TARBALL_TMP" ]]; then
            error "Download failed. Check your internet connection."
            log "curl download of $TARBALL_URL failed (exit $DL_EXIT)"
            rm -f "$TARBALL_TMP"
            exit 1
        fi
        LOG_SIZE=$(du -sh "$TARBALL_TMP" 2>/dev/null)
        LOG_SIZE="${LOG_SIZE%%$'\t'*}"
        log "Download complete: $TARBALL_TMP ($LOG_SIZE)"
        echo

        ARCHIVE_TOP=$(tar -tf "$TARBALL_TMP" 2>>"$GENERAL_LOG" | head -1)
        ARCHIVE_TOP="${ARCHIVE_TOP%%/*}"

        if [[ -z "$ARCHIVE_TOP" ]]; then
            error "Could not read the archive — it may be corrupt or incomplete."
            log "tar -tf returned empty output for $TARBALL_TMP"
            rm -f "$TARBALL_TMP"
            exit 1
        fi

        log "Archive top-level directory confirmed: $ARCHIVE_TOP"
        info "Extracting to $COMPAT_TOOLS_DIR ..."
        echo -ne "  ${CYAN}Please wait ...${NC} "

        tar -xf "$TARBALL_TMP" -C "$COMPAT_TOOLS_DIR" >>"$GENERAL_LOG" 2>&1 &
        TAR_PID=$!
        spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        spin_i=0
        while kill -0 "$TAR_PID" 2>/dev/null; do
            printf '\b%s' "${spin_chars:$spin_i:1}"
            spin_i=$(( (spin_i + 1) % ${#spin_chars} ))
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

        success "${PROTON_DIR_NAME} installed to $COMPAT_TOOLS_DIR"
        press_any_key
    fi
else
    # Proton was already up to date per pre-flight — reuse the name for the done screen
    PROTON_DIR_NAME="$PREFLIGHT_PROTON_DIR"
fi # end PF_SKIP_PROTON

# =============================================================================
# STEP 10 — EAC workaround, Documents symlink, and done screen
# =============================================================================
run_optional_steps "$IRACING_DEPOT_DIRECT" "$PROTON_DIR_NAME"
