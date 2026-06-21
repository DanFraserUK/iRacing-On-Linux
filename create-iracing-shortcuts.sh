#!/usr/bin/env bash
# Finds iRacing companion apps across all Steam libraries and creates .desktop shortcuts
# Assumes any additional applications are installed with
#     $ protontricks-launch --appid 266410 /path/to/installer
# and the default install location is left untouched installing the application to the
# Proton prefix for iRacing

APPID=266410
DESKTOP_DIR="$HOME/Desktop"
STEAM_ROOT="$HOME/.steam/steam"

# Apps to search for: "Display Name|relative/path/to/exe"
# Path is relative to the iRacing install directory
# Can add more programs in the future
APPS=(
    "Garage61|Garage61.exe"
    "Trading Paints|Trading Paints.exe"
    "CrewChief|CrewChiefV4.exe"
)

# --- Find all Steam library paths ---
LIBRARY_VDF="$STEAM_ROOT/steamapps/libraryfolders.vdf"
if [[ ! -f "$LIBRARY_VDF" ]]; then
    echo "Error: Could not find $LIBRARY_VDF — is Steam installed?"
    exit 1
fi

mapfile -t LIBRARY_PATHS < <(grep '"path"' "$LIBRARY_VDF" | awk -F'"' '{print $4}')
LIBRARY_PATHS+=("$STEAM_ROOT")  # Always include default library

# --- Find the compatdata prefix for iRacing across all libraries ---
PREFIX_DIR=""
for LIB in "${LIBRARY_PATHS[@]}"; do
    CANDIDATE="$LIB/steamapps/compatdata/$APPID/pfx"
    if [[ -d "$CANDIDATE" ]]; then
        PREFIX_DIR="$CANDIDATE"
        echo "Found iRacing Proton prefix at: $PREFIX_DIR"
        break
    fi
done

if [[ -z "$PREFIX_DIR" ]]; then
    echo "Error: Proton prefix for iRacing (appid $APPID) not found in any Steam library."
    exit 1
fi

# --- Discovery phase: find all apps first ---
echo ""
FOUND_NAMES=()
FOUND_PATHS=()

for APP in "${APPS[@]}"; do
    NAME="${APP%%|*}"
    EXE_RELATIVE="${APP##*|}"
    EXE_PATH=$(find "$PREFIX_DIR" -iname "$EXE_RELATIVE" -type f 2>/dev/null | head -n 1)

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

# --- Print summary of found apps ---
echo "Found ${#FOUND_NAMES[@]} app(s):"
echo ""
for i in "${!FOUND_NAMES[@]}"; do
    NUM=$(( i + 1 ))
    echo "  [$NUM] ${FOUND_NAMES[$i]}"
    echo "       Path:   ${FOUND_PATHS[$i]}"
    echo "       Target: protontricks-launch --appid $APPID \"${FOUND_PATHS[$i]}\""
    echo ""
done

# --- Prompt for selection ---
echo "Which shortcuts would you like to create?"
echo "  [Enter] = all  |  N or none = none  |  numbers separated by spaces (e.g. 1 3)"
echo ""
read -rp "> " SELECTION
echo ""

# --- Resolve selection to indices ---
SELECTED_INDICES=()
SELECTION_LOWER="${SELECTION,,}"
if [[ -z "$SELECTION" ]]; then
    for i in "${!FOUND_NAMES[@]}"; do
        SELECTED_INDICES+=("$i")
    done
elif [[ "$SELECTION_LOWER" == "n" || "$SELECTION_LOWER" == "none" ]]; then
    echo "Aborted. No shortcuts created."
    exit 0
else
    for TOKEN in $SELECTION; do
        if [[ "$TOKEN" =~ ^[0-9]+$ ]]; then
            IDX=$(( TOKEN - 1 ))
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

# --- Create Desktop dir and shortcuts ---
mkdir -p "$DESKTOP_DIR"
CREATED=0

for IDX in "${SELECTED_INDICES[@]}"; do
    NAME="${FOUND_NAMES[$IDX]}"
    EXE_PATH="${FOUND_PATHS[$IDX]}"
    SHORTCUT="$DESKTOP_DIR/${NAME// /_}.desktop"

    cat > "$SHORTCUT" <<EOF
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
    (( CREATED++ ))
done

echo ""
echo "Done. $CREATED shortcut(s) created in $DESKTOP_DIR."
