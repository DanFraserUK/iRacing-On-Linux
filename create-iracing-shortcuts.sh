#!/usr/bin/env bash
# create-iracing-shortcuts.sh
# Finds iRacing companion apps and creates .desktop shortcuts

APPID=266410
DESKTOP_DIR="$HOME/Desktop"
STEAM_ROOT="$HOME/.steam/steam"

# Apps to search for: "Display Name|exe filename"
# Searched inside the Proton prefix (compatdata/266410)
# Can add more programs in the future
APPS=(
    "Garage61|Garage61.exe"
    "Trading Paints|Trading Paints.exe"
    "CrewChief|CrewChiefV4.exe"
)

# Print a labelled value, indenting any wrapped continuation lines
print_indented() {
    local label="$1"
    local value="$2"
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local prefix="    ${label}"
    local indent
    indent=$(printf '%*s' "${#prefix}" '')
    echo "${prefix}${value}" | fold -s -w "${cols}" |
        sed "2,\$s/^/${indent}/"
}

# --- Find all Steam library paths ---
LIBRARY_VDF="$STEAM_ROOT/steamapps/libraryfolders.vdf"
if [[ ! -f "$LIBRARY_VDF" ]]; then
    echo "Error: Could not find $LIBRARY_VDF — is Steam installed?"
    exit 1
fi

mapfile -t LIBRARY_PATHS < <(
    grep '"path"' "$LIBRARY_VDF" | awk -F'"' '{print $4}'
)
LIBRARY_PATHS+=("$STEAM_ROOT")

# --- Find the compatdata prefix across all libraries ---
PREFIX_DIR=""
for LIB in "${LIBRARY_PATHS[@]}"; do
    CANDIDATE="$LIB/steamapps/compatdata/$APPID/pfx"
    if [[ -d "$CANDIDATE" ]]; then
        PREFIX_DIR="$CANDIDATE"
        echo "Found iRacing Proton prefix at:"
        echo "  $PREFIX_DIR"
        break
    fi
done

if [[ -z "$PREFIX_DIR" ]]; then
    echo "Error: Proton prefix for iRacing (appid $APPID) not found."
    exit 1
fi

# --- Discovery phase ---
echo ""
FOUND_NAMES=()
FOUND_PATHS=()

for APP in "${APPS[@]}"; do
    NAME="${APP%%|*}"
    EXE_RELATIVE="${APP##*|}"
    EXE_PATH=$(
        find "$PREFIX_DIR" -iname "$EXE_RELATIVE" -type f 2>/dev/null |
            head -n 1
    )
    if [[ -z "$EXE_PATH" ]]; then
        echo "  [NOT FOUND] $NAME ($EXE_RELATIVE)"
    else
        FOUND_NAMES+=("$NAME")
        FOUND_PATHS+=("$EXE_PATH")
    fi
done

echo ""

if [[ ${#FOUND_NAMES[@]} -eq 0 ]]; then
    echo "No apps found. Nothing to do."
    exit 0
fi

# --- Print summary ---
if [[ ${#FOUND_NAMES[@]} -eq 1 ]]; then
    echo "Shortcuts: The following app shortcut can be created"
else
    echo "Shortcuts: The following app shortcuts can be created"
fi
echo ""
for i in "${!FOUND_NAMES[@]}"; do
    NUM=$((i + 1))
    echo "${NUM} - ${FOUND_NAMES[$i]}"
    print_indented "Path:   " "${FOUND_PATHS[$i]}"
    print_indented "Target: " \
        "protontricks-launch --appid $APPID \"${FOUND_PATHS[$i]}\""
    echo ""
done

# --- Prompt ---
echo "Select the shortcut(s) to create (e.g. 1 3 5),"
echo "select 0 to create them all, or press \"enter\" to skip:"
read -rp "> " SELECTION
echo ""

# --- Resolve selection ---
SELECTED_INDICES=()
if [[ -z "$SELECTION" ]]; then
    echo "No shortcuts created."
    exit 0
elif [[ "$SELECTION" == "0" ]]; then
    for i in "${!FOUND_NAMES[@]}"; do
        SELECTED_INDICES+=("$i")
    done
else
    for TOKEN in $SELECTION; do
        if [[ "$TOKEN" =~ ^[0-9]+$ ]]; then
            IDX=$((TOKEN - 1))
            if [[ $IDX -ge 0 && $IDX -lt ${#FOUND_NAMES[@]} ]]; then
                SELECTED_INDICES+=("$IDX")
            else
                echo "  Warning: '$TOKEN' is out of range — skipping."
            fi
        else
            echo "  Warning: '$TOKEN' is not a valid number — skipping."
        fi
    done
fi

if [[ ${#SELECTED_INDICES[@]} -eq 0 ]]; then
    echo "No valid selection made. Nothing to do."
    exit 0
fi

# --- Create shortcuts ---
mkdir -p "$DESKTOP_DIR"
CREATED=0

for IDX in "${SELECTED_INDICES[@]}"; do
    NAME="${FOUND_NAMES[$IDX]}"
    EXE_PATH="${FOUND_PATHS[$IDX]}"
    SHORTCUT="$DESKTOP_DIR/${NAME// /_}.desktop"

    cat >"$SHORTCUT" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$NAME
Exec=protontricks-launch --appid $APPID "$EXE_PATH"
Icon=wine
Terminal=false
Categories=Game;
EOF

    chmod +x "$SHORTCUT"
    echo "  Created: $SHORTCUT"
    ((CREATED++))
done

echo ""
echo "Done. $CREATED shortcut(s) created in $DESKTOP_DIR."
