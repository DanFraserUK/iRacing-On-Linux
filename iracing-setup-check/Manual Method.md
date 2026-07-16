# iRacing Manual Setup Guide for Linux

This is the manual, step-by-step way to get iRacing running on Linux, with no script involved.

Steps 2 through 5 are only for getting iRacing onto Steam using a Steam key (a direct iRacing account activated through Steam). If iRacing is already owned as a normal Steam purchase, skip from Step 1 straight to Step 6 — everything from there on (protontricks, the custom Proton build, launch options, EAC workaround) is needed regardless of how iRacing was obtained.

Assumes a fresh install of a supported distro with Steam already installed. Won't work on an immutable OS (SteamOS, Bazzite, NixOS, Fedora Silverblue, ChimeraOS, etc.).

## Supported Distributions

- **Arch-based:** EndeavourOS, CachyOS, Arch Linux
- **Debian-based:** Ubuntu, Linux Mint, Elementary OS
- **RPM-based:** Fedora, Nobara

---

## STEP 1 — Install Required Packages (everyone)

**Arch / CachyOS / EndeavourOS:**
```
sudo pacman -S protontricks
```
(protontricks is in the official `extra` repo — no AUR helper needed)

**Ubuntu / Debian / Linux Mint:**

protontricks isn't reliably available as a plain apt package, so it's installed via `pipx` instead:
```
sudo apt update
sudo apt install pipx
pipx install protontricks
pipx ensurepath
```

**Fedora / Nobara:**

protontricks needs RPM Fusion enabled first:
```
sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install protontricks
```

Winetricks comes along automatically as a dependency on every distro — no separate install needed.

---

## STEP 2 — Get a Steam Key (Steam key / Direct Account only)

Generate a Steam key for the iRacing account here: https://support.iracing.com/support/solutions/articles/31000165400-how-to-generate-a-steam-key

## STEP 3 — Install iRacing on Steam (Steam key / Direct Account only)

1. Open Steam.
2. **Games → Activate a Product on Steam...**
3. Enter the Steam key from Step 2.
4. Follow the prompts to install iRacing to a Steam library.
5. At this stage there will only be three `.bat` files — that's expected.

Optional — installing to a different drive: **Steam → Settings → Storage**, add the new library location, then select it during install.

## STEP 4 — Download the iRacing Installer (Steam key / Direct Account only)

Get the latest installer from: https://members.iracing.com/download/member/noservice.jsp

Save it somewhere easy to find, e.g. `~/Downloads/`.

## STEP 5 — Run the iRacing Installer via Proton (Steam key / Direct Account only)

Confirm where the iRacing stub landed — normally:
```
~/.steam/steam/steamapps/common/iRacing
```
(if a different library was chosen in Step 3, check that library's `steamapps/common/` instead)

Convert that path to a Windows-style path Proton understands: prefix it with `Z:` and swap every `/` for `\`:
```
Z:\home\[username]\.steam\steam\steamapps\common\iRacing
```

Run the installer through Proton, forced to that location:
```
protontricks-launch --appid 266410 [path/to/iRacingInstaller.exe] \
    /DIR="Z:\home\[username]\.steam\steam\steamapps\common\iRacing"
```

**Important:** when the installer finishes, untick "Launch iRacing" before closing it — don't launch iRacing yet.

Confirm it installed correctly: the folder from the first command should now contain `iRacingSim64DX11.exe`, `EasyAntiCheat/`, `cars/`, and `tracks/` among many other files.

---

## STEP 6 — Install Required protontricks Libraries (everyone — Steam Purchase users start here)

```
protontricks 266410 -q --force vcrun2010 vcrun2012 vcrun2013 vcrun2015 vcrun2017 vcrun2022 d3dx9_43 d3dx10_43 d3dx11_43 d3dcompiler_43 xact xact_x64 xaudio29
```
Takes several minutes. Output shows each library being verified or installed.

## STEP 7 — Download and Install the Custom Proton Build (everyone)

Grab the latest release from: https://github.com/DanFraserUK/proton-cachyos/releases/latest

Extract it into the Steam compatibility tools directory:
```
mkdir -p ~/.steam/steam/compatibilitytools.d
tar -xf <downloaded-file>.tar.xz -C ~/.steam/steam/compatibilitytools.d
```
This creates a new folder in that directory named after the release.

Restart Steam completely — fully close it and reopen it. New compatibility tools won't show up in the dropdown otherwise.

## STEP 8 — Set iRacing to Use the Custom Proton Build (everyone)

1. Open Steam.
2. Right-click iRacing → **Properties → Compatibility**.
3. Tick "Force the use of a specific Steam Play compatibility tool".
4. Select the folder name from Step 7 in the dropdown.

## STEP 9 — Launch and Log In (everyone)

Click **Play** in Steam. This launches iRacing for the first time and prompts a login.

After logging in, iRacing downloads car and track content — this can take a while on first run. Downloading everything at once can cause issues; starting with just the required files and grabbing the rest later tends to go more smoothly.

## STEP 10 — (Optional) Fix EAC / Easy Anti-Cheat CDN Access

Needed to access Test Drive, Replays, or AI Racing through the iRacing UI.

**Warning:** modifying this could carry a risk to the account. Proceed at your own discretion.

```
echo "0.0.0.0 modules-cdn.eac-prod.on.epicgames.com" | sudo tee -a /etc/hosts
```
Confirm it applied:
```
grep modules-cdn /etc/hosts
```
To undo later: open `/etc/hosts` in an editor, delete or comment out that line, save.

## STEP 11 — (Optional) Create a Documents Shortcut

iRacing stores setups, replays, and settings deep inside the Steam prefix. Launch iRacing once first so the Documents folder actually exists, then:
```
ln -s ~/.steam/steam/steamapps/compatdata/266410/pfx/drive_c/users/steamuser/Documents/iRacing ~/Documents/iRacing
```
(if iRacing was installed to a non-default library back in Step 3, adjust the path to that library's `compatdata/266410/...` instead)

Setups and replays are then available at `~/Documents/iRacing`.

## STEP 12 — (Optional) Install Fonts for the UI

Fixes odd text rendering in-game or in the UI. Can take a long time to install.
```
protontricks 266410 corefonts
```

## STEP 13 — Set Launch Options (everyone)

1. Right-click iRacing in Steam → **Properties → General**.
2. Under "Launch Options", paste:
```
PROTON_LOG=1 LD_PRELOAD="" %command%
```

---

## Done

Open Steam, click Play on iRacing, and go racing.

If something's not working:
- Confirm Steam was fully restarted after installing the custom Proton build (Step 7).
- Double-check the Compatibility tool selected in Step 8 matches what was actually extracted.
- Check the iRacing launcher logs for specific error messages.
