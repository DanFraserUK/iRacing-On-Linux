# iRacing Setup — Simple Edition for Linux

A fully automated setup script for iRacing on Linux. This script handles all the legwork — you just run it and follow the prompts.

## What It Does

This script automatically:
- Checks your system for required dependencies
- Installs and verifies Steam and protontricks
- Configures Proton (the compatibility layer for Windows games on Linux)
- Sets up Wine libraries needed for iRacing
- Symlinks iRacing documentation to your home folder

Everything is logged for troubleshooting if needed.

## Supported Operating Systems

- **Arch Linux** / CachyOS / EndeavourOS
- **Ubuntu** / Linux Mint / Pop!_OS
- **Fedora** / Nobara
- **Debian**

**Note:** This script will NOT work on immutable Linux distributions.  Don't even ask for flatpak issues!

## How to Get and Run the Script

### Download

1. Go to the **Releases** page (on the right side of this repository)
2. Download `iracing_setup_simple_gui.sh`
3. Save it to your Downloads folder

### Make It Executable

Right-click the `iracing_setup_simple_gui.sh` file and select **Properties** or **Permissions**, then check the box that says **Allow executing file as program** (or similar).

### Run the Script

Double-click the `iracing_setup_simple_gui.sh` file to start it.

A window will appear with the setup wizard. Follow the on-screen instructions — you may be asked for your password at certain steps.

## After Setup

Once the script completes, iRacing will be ready to play. Launch it through Steam as normal.

A log file is created in the same folder as the script (`danfrasers-iracing-setup.log`) if you need to check for any errors.
