# iRacing Manual Setup Guide for Linux

This guide provides manual step-by-step instructions for setting up iRacing on Linux using a Steam key to activate iRacing through Steam.

**This guide is for Steam key activation ONLY.** If you have a Steam account version of iRacing already activated through your Steam account, this guide does not apply to you.

Assumes a fresh install of a supported distro and Steam already installed. Not compatible with immutable OS (SteamOS, Bazzite, NixOS, Fedora Silverblue, ChimeraOS, etc.).

## Supported Distributions

- Arch-based: EndeavourOS, CachyOS, Arch Linux
- Debian-based: Ubuntu, Linux Mint, Elementary OS
- RPM-based: Fedora, Nobara

---

## STEP 1 — Install Required Packages

Your distro's package manager will need to install protontricks. (winetricks will be installed automatically as a dependency)

**If you are on Arch / CachyOS / EndeavourOS:**
```
$ sudo pacman -S protontricks
```
(protontricks is in the official `extra` repo — no AUR helper needed)

**If you are on Ubuntu / Debian / Linux Mint:**
```
$ sudo apt update
$ sudo apt install protontricks
```

**If you are on Fedora / Nobara:**
```
$ sudo dnf install protontricks
```

---

## STEP 2 — Get Your Steam Key

You will need to generate a Steam key for your iRacing account. Visit:
https://support.iracing.com/support/solutions/articles/31000165400-how-to-generate-a-steam-key

---

## STEP 3 — Install iRacing on Steam

1. Open Steam
2. Click on Games in the menu bar
3. Click "Activate a Product on Steam..."
4. Enter the Steam key code you generated in Step 2
5. Follow the prompts to install iRacing to your chosen Steam library
6. Note: You will only have three .bat files at this stage

**Optionally, if you need iRacing on a different drive:**
- Right-click Steam Library in Settings > Storage
- Add a new library location on another drive
- Select that library when installing iRacing

---

## STEP 4 — Download the iRacing Installer

Download the latest iRacing installer from:
https://members.iracing.com/download/member/noservice.jsp

Save this to an easy-to-locate directory (e.g., ~/Downloads/iracing/).

---

## STEP 5 — Run the iRacing Installer via Proton

### 5a. Confirm where the iRacing stub was installed

If you only added one Steam library, this will be:
```
~/.steam/steam/steamapps/common/iRacing
```

If you added an extra library in Step 3 (a different drive), check that library's `steamapps/common/` folder instead — you can see all your library locations under Steam > Settings > Storage. Whichever one has an `iRacing` folder inside `common/` is the one you'll use below.

**Note:** The ~/.steam/steam path may differ depending on your distro and Steam installation configuration. Adjust accordingly if your Steam library is in a different location.

### 5b. Run the installer, forced to that location

Convert the path from 5a to a Windows-style path by prefixing it with `Z:` and swapping every `/` for `\`. For example:

```
~/.steam/steam/steamapps/common/iRacing
```

becomes:

```
Z:\home\[username]\.steam\steam\steamapps\common\iRacing
```

Then run:

```
$ protontricks-launch --appid 266410 [path/to/installer/iracing-installer.exe] \
    /DIR="Z:\home\[username]\.steam\steam\steamapps\common\iRacing"
```

The installer window will still open as normal — the `/DIR=` switch just pre-fills and locks in the correct install location, so there's no risk of it landing in the wrong place (like the default `C:\Program Files (x86)`, which the .bat files can't handle).

**NOTE: When the installer finishes - do NOT launch iRacing!
Untick 'Launch iRacing' before closing the installer.**

### 5c. Confirm it installed correctly

The folder from 5a should now contain `iRacingSim64DX11.exe`, `EasyAntiCheat/`, `cars/`, and `tracks/`. If it looks empty or mostly empty, re-run the command in 5b.

---

## STEP 6 — Install Required protontricks Libraries

After installation, use protontricks to install required Visual C++ runtimes and other libraries in the Wine prefix:

```
$ protontricks 266410 -q --force vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022 d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact xact_x64 xaudio29
```

This step may take several minutes. The output should show each library being verified or installed.

---

## STEP 7 — Download and Install Custom Proton Build

Download the latest proton-cachyos build from:
https://github.com/DanFraserUK/proton-cachyos/releases

Extract the tarball to your Steam compatibility tools directory:
```
$ mkdir -p ~/.steam/steam/compatibilitytools.d
$ tar -xf iracing-dnsapi-fixmes.tar.xz -C ~/.steam/steam/compatibilitytools.d
```

After extraction, you should have a new folder in that directory named:
```
iracing-dnsapi-fixmes
```

**Note:** The ~/.steam/steam path may differ depending on your distro and Steam installation configuration. These paths in this guide are typical but not necessarily the default for your system. Adjust accordingly if your Steam library is in a different location.

**RESTART STEAM completely (close and reopen).**

---

## STEP 8 — Set iRacing to Use Custom Proton Build

1. Open Steam
2. Right-click iRacing in your library
3. Click Properties
4. Select Compatibility on the left sidebar
5. Tick the box: "Force the use of a specific Steam Play compatibility tool"
6. From the dropdown, select: iracing-dnsapi-fixmes

---

## STEP 9 — Launch and Login

Click PLAY in Steam. This will launch iRacing for the first time and prompt you to log in with your iRacing account.

After login, iRacing will download additional content (car models, tracks, etc.). This may take a significant amount of time on first run.

An issue can arise attempting to download everything at once. It is recommended to start with just required files then download the rest later. Note: This happens on Windows too.

---

## STEP 10 — (Optional) Fix EAC / Easy Anti-Cheat CDN Access

To access Test Drive, Replays, or AI Racing through the iRacing UI, you need to block the EAC CDN by editing /etc/hosts.

**WARNING:** Modifying the EAC configuration could potentially result in your account being banned. Do this at your own risk.

If you choose to proceed, add this line to /etc/hosts:
```
$ echo "0.0.0.0 modules-cdn.eac-prod.on.epicgames.com" | sudo tee -a /etc/hosts
```

Verify the change was applied:
```
$ sudo cat /etc/hosts | grep modules-cdn
```

To remove this workaround later:
```
$ sudo nano /etc/hosts
```
Find the line and either delete it, or comment it out by adding # at the start, then save with Ctrl+X.

---

## STEP 11 — (Optional) Create Documents Shortcut

iRacing stores your car setups, replays, and settings deep inside the Steam prefix. For easier access, create a shortcut in your home Documents folder.

First, launch iRacing once to create the documents folder.

Then create the symlink:
```
$ ln -s ~/.steam/steam/steamapps/compatdata/266410/pfx/drive_c/users/steamuser/Documents/iRacing ~/Documents/iRacing
```

**Note:** The ~/.steam/steam path may differ depending on your distro and Steam installation configuration. These paths in this guide are typical but not necessarily the default for your system. Adjust accordingly if your Steam library is in a different location.

Your setups and replays are now easily accessible at ~/Documents/iRacing

---

## STEP 12 — (Optional) Install Fonts for UI

If you notice text rendering issues in-game or in the UI, you may need to install the corefonts package. This can take a very long time.

To install on any distro, use protontricks:
```
$ protontricks 266410 corefonts
```

---

## STEP 13 — Set Launch Options

Since you installed iRacing via the direct installer download, you should set these launch options:

1. Right-click iRacing in Steam
2. Click Properties
3. Go to General
4. In "Launch Options", paste:
```
PROTON_LOG=1 LD_PRELOAD="" %command%
```

---

## YOU'RE DONE!

Your iRacing setup is complete. Open Steam, click PLAY on iRacing, and enjoy your racing.

**If you encounter any issues:**
- Make sure Steam is fully restarted after installing the custom Proton build
- Verify the Compatibility settings are set to the iracing-dnsapi-fixmes build
- Check the iRacing launcher logs for specific error messages
- Search community Linux gaming forums and Discord servers for troubleshooting help

Safe racing!
