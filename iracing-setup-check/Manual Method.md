# iRacing Manual Setup Guide for Linux

This is the manual, step-by-step way to get iRacing running on Linux using a Steam key.  If you'd rather not do it by hand, there's a script that automates all of this for you.

**This guide is for Steam key activation only.**  If you've already got iRacing activated as a proper Steam purchase on your Steam account, this guide isn't for you — you're already sorted.

Assumes a fresh install of a supported distro with Steam already installed.  Won't work on an immutable OS (SteamOS, Bazzite, NixOS, Fedora Silverblue, ChimeraOS, etc.) — more on why in the script's own error message if you try it there anyway.

## Supported Distributions

- Arch-based: EndeavourOS, CachyOS, Arch Linux
- Debian-based: Ubuntu, Linux Mint, Elementary OS
- RPM-based: Fedora, Nobara

---

## STEP 1 — Install Required Packages

Your distro's package manager needs to install protontricks.  Winetricks comes along for free as a dependency, so you don't need to install it separately.

**If you're on Arch / CachyOS / EndeavourOS:**
```
$ sudo pacman -S protontricks
```
(protontricks is in the official `extra` repo — no AUR helper needed)

**If you're on Ubuntu / Debian / Linux Mint:**
```
$ sudo apt update
$ sudo apt install protontricks
```

**If you're on Fedora / Nobara:**
```
$ sudo dnf install protontricks
```

---

## STEP 2 — Get Your Steam Key

You'll need to generate a Steam key for your iRacing account.  Head here:
https://support.iracing.com/support/solutions/articles/31000165400-how-to-generate-a-steam-key

---

## STEP 3 — Install iRacing on Steam

1. Open Steam.
2. Click Games in the menu bar.
3. Click "Activate a Product on Steam...".
4. Enter the Steam key you generated in Step 2.
5. Follow the prompts to install iRacing to your chosen Steam library.
6. At this stage you'll only have three .bat files — that's expected, don't panic.

**Optionally, if you want iRacing on a different drive:**
- Right-click Steam Library in Settings > Storage.
- Add a new library location on another drive.
- Select that library when installing iRacing.

---

## STEP 4 — Download the iRacing Installer

Grab the latest iRacing installer from:
https://members.iracing.com/download/member/noservice.jsp

Save it somewhere easy to find, e.g. `~/Downloads/iracing/`.

---

## STEP 5 — Run the iRacing Installer via Proton

### 5a. Confirm where the iRacing stub was installed

If you only added one Steam library, this will be:
```
~/.steam/steam/steamapps/common/iRacing
```

If you added an extra library back in Step 3, check that library's `steamapps/common/` folder instead — you can see all your library locations under Steam > Settings > Storage.  Whichever one has an `iRacing` folder inside `common/` is the one you want.

**Note:** The `~/.steam/steam` path can differ depending on your distro and how Steam's set up.  Adjust it if your setup puts things somewhere else.

### 5b. Run the installer, forced to that location

Convert the path from 5a into a Windows-style path by prefixing it with `Z:` and swapping every `/` for `\`.  For example:

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

The installer window opens as normal — the `/DIR=` switch just pre-fills and locks in the correct install location.  This means there's no risk of it landing in the wrong place, like the default `C:\Program Files (x86)`, which the .bat files can't handle anyway.

**Important: when the installer finishes, do not launch iRacing yet!  Untick "Launch iRacing" before closing the installer.**

### 5c. Confirm it installed correctly

The folder from 5a should now contain `iRacingSim64DX11.exe`, `EasyAntiCheat/`, `cars/`, and `tracks/`, along with a bunch of other game files — that's just a quick sanity check, not the full list.  If the folder looks empty or mostly empty, re-run the command from 5b.

---

## STEP 6 — Install Required protontricks Libraries

Once it's installed, use protontricks to install the Visual C++ runtimes and other libraries the Wine prefix needs:

```
$ protontricks 266410 -q --force vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022 d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact xact_x64 xaudio29
```

This can take several minutes.  The output should show each library being verified or installed as it goes.

---

## STEP 7 — Download and Install Custom Proton Build

Grab the latest proton-cachyos build from:
https://github.com/DanFraserUK/proton-cachyos/releases

Extract the tarball into your Steam compatibility tools directory:
```
$ mkdir -p ~/.steam/steam/compatibilitytools.d
$ tar -xf iracing-dnsapi-fixmes.tar.xz -C ~/.steam/steam/compatibilitytools.d
```

After extracting, you should have a new folder in that directory named:
```
iracing-dnsapi-fixmes
```

**Note:** The `~/.steam/steam` path can differ depending on your distro and Steam setup.  These paths are typical, not guaranteed, so adjust if yours is different.

**Restart Steam completely — fully close it and reopen it.**  New compatibility tools won't show up in the dropdown otherwise.

---

## STEP 8 — Set iRacing to Use the Custom Proton Build

1. Open Steam.
2. Right-click iRacing in your library.
3. Click Properties.
4. Select Compatibility on the left sidebar.
5. Tick "Force the use of a specific Steam Play compatibility tool".
6. From the dropdown, select `iracing-dnsapi-fixmes`.

---

## STEP 9 — Launch and Login

Click Play in Steam.  This launches iRacing for the first time and prompts you to log in with your iRacing account.

After you log in, iRacing downloads additional content — car models, tracks, and so on.  This can take a while on first run, so grab a coffee.

Trying to download everything at once can sometimes cause issues.  It's best to start with just the required files and grab the rest later.  For what it's worth, this happens on Windows too — it's not a Linux thing.

---

## STEP 10 — (Optional) Fix EAC / Easy Anti-Cheat CDN Access

To access Test Drive, Replays, or AI Racing through the iRacing UI, you'll need to block the EAC CDN by editing `/etc/hosts`.

**Warning:** modifying the EAC configuration could potentially get your account banned.  Do this at your own risk.

If you want to go ahead, add this line to `/etc/hosts`:
```
$ echo "0.0.0.0 modules-cdn.eac-prod.on.epicgames.com" | sudo tee -a /etc/hosts
```

Check it applied:
```
$ sudo cat /etc/hosts | grep modules-cdn
```

To undo it later:
```
$ sudo nano /etc/hosts
```
Find the line, delete it (or comment it out with a `#` at the start), then save with Ctrl+X.

---

## STEP 11 — (Optional) Create a Documents Shortcut

iRacing stores your car setups, replays, and settings deep inside the Steam prefix.  For easier access, you can create a shortcut in your home Documents folder.

First, launch iRacing once so it creates the Documents folder for you.

Then create the symlink:
```
$ ln -s ~/.steam/steam/steamapps/compatdata/266410/pfx/drive_c/users/steamuser/Documents/iRacing ~/Documents/iRacing
```

**Note:** The `~/.steam/steam` path can differ depending on your distro and Steam setup.  These paths are typical, not guaranteed, so adjust if yours is different.

Your setups and replays are now easy to get to at `~/Documents/iRacing`.

---

## STEP 12 — (Optional) Install Fonts for the UI

If you notice text rendering oddly in-game or in the UI, you may need the corefonts package.  Fair warning: this can take a very long time.

To install it on any distro, use protontricks:
```
$ protontricks 266410 corefonts
```

---

## STEP 13 — Set Launch Options

Since you installed iRacing via the direct installer download, you'll want to set these launch options:

1. Right-click iRacing in Steam.
2. Click Properties.
3. Go to General.
4. Under "Launch Options", paste:
```
PROTON_LOG=1 LD_PRELOAD="" %command%
```

---

## You're Done!

Your iRacing setup is complete.  Open Steam, click Play on iRacing, and enjoy your racing.

**If you run into issues:**
- Make sure Steam was fully restarted after installing the custom Proton build.
- Double-check the Compatibility settings are set to the iracing-dnsapi-fixmes build.
- Check the iRacing launcher logs for specific error messages.
- Search community Linux gaming forums and Discord servers — chances are someone's hit the same issue.

Safe racing!
