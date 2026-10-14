# iRacing On Linux

A collaborative effort to record and document as much information as possible about
running iRacing on Linux: peripherals, accompanying software, distributions and more.

## Game status: kind of inoperative

iRacing's anticheat does not currently support Linux, so **online racing does not work**.
Test Drive, Replays, Time Attack and AI Racing can be accessed, at your own risk.

Nothing here gets you past anticheat, and nothing here is a workaround for it.  The goal
is to demonstrate that everything else about iRacing runs properly on Linux, and to make
the case to iRacing that Linux support is worth enabling.

## Setting it up: LapZero

The setup script that used to live here has been replaced by **[LapZero](https://github.com/DanFraserUK/LapZero)**.
It's a proper app.  It sets up Steam, protontricks, iRacing and the LapZero Proton build,
and it installs the programs that run alongside iRacing, like Trading Paints and CrewChief.

Download it from the [LapZero Releases](https://github.com/DanFraserUK/LapZero/releases/latest).
There are packages for Arch, Debian, Ubuntu and Fedora.

If you'd rather do it by hand, `iracing-setup-check/Manual Method.md` covers it step by step.

## What's in this repository

| Path | Contents |
| --- | --- |
| `iracing-setup-check/Manual Method.md` | Setting iRacing up by hand |
| `iracing-setup-check/manifests/` | Checksums for the Proton builds |
| `OS Specific Instructions/` | Per-distribution notes |
| `One Reason To Use Linux/` | Background on why any of this matters |
| `Letter to iRacing` | The case for official Linux support |
| `create-iracing-shortcuts.sh` | Desktop shortcuts for iRacing |

## Contributing

Documentation for a distribution must be specific to that distribution, even where the
upstream is shared.  Clean Arch, Manjaro and EndeavourOS are all Arch based, but their
install processes differ enough that combining them helps nobody.

Problems with setting iRacing up belong on [LapZero's issues](https://github.com/DanFraserUK/LapZero/issues).
