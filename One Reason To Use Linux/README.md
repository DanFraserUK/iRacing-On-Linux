# Getting Your Files Back From OneDrive, Then Removing the Piece of Shit Forever

OneDrive has a "feature" called Known Folder Move.  When it is active, it quietly relocates your real Documents, Pictures, and Desktop folders into `C:\Users\<you>\OneDrive\...` and then points the Documents/Pictures/Desktop shortcuts at that new location, so it looks like nothing happened.  It did not ask.  It did not warn you in any way that registered.  It just did it, because that is the kind of arrogant, petulant garbage OneDrive is.  Your files never actually left your PC, they were just shuffled sideways and relabeled.  And because everything got moved sideways without so much as a heads up, it fucks games and applications up like nobody's business, hardcoded save paths, mod folders, asset libraries, all of it pointing at a location that no longer exists or now lives somewhere completely different, because OneDrive couldn't be bothered to consider that other software might actually depend on knowing where your files are.

This guide does two things:

1.  Moves your files back to their real local folders.
2.  Rips OneDrive out completely, including the bits it hides so you'll forget it was ever there.

---

## Part 1: Confirm Where Your Files Actually Are

Open File Explorer and click Documents in the sidebar.  Look at the address bar.

- If it shows `C:\Users\<you>\OneDrive\Documents`, OneDrive has its grubby little hands on it.
- If it shows `C:\Users\<you>\Documents`, it is already local and you can skip ahead.

Repeat for Pictures and Desktop and anything else.  Do not skip this check.  Knowing where your files are before you start moving things is the difference between a clean fix and a bad fucking week, because if you get this wrong, microslop will absolutely let you eat the consequences.

---

## Part 2: Turn Off Folder Backup

This is the setting that tells OneDrive to stop claiming your folders like it has any right to them.

1.  Click the OneDrive cloud icon in the taskbar, then the gear icon, then **Settings**.
2.  Go to **Sync and backup**, then **Manage backup**.
3.  Turn off the toggle for Desktop, Documents, Pictures and anything else, one at a time.
4.  When prompted, choose **This computer only**.  This tells OneDrive to move the files back to your local profile instead of abandoning them in the OneDrive folder like it doesn't give a damn either way.

This prompt does not appear on every version of OneDrive, because of course it fucking doesn't, consistency would be too much to ask.  If you do not see it, move on to Part 3 and do it by hand.

---

## Part 3: Move the Files Back Manually (If OneDrive Did Not Offer To)

No downloading required here.  The files are already on your disk, sitting exactly where OneDrive dumped them.  You are just putting them back where they belonged in the first place.

1.  Open two File Explorer windows side by side.
2.  In the first, navigate to `C:\Users\<you>\OneDrive\Documents` (and repeat later for Pictures and Desktop and anything else).
3.  In the second, type `%userprofile%` into the address bar to land on your real local profile.
4.  Select everything in the OneDrive folder, cut it, and paste it into the matching local folder.

---

## Part 4: Verify the Redirect Actually Reverted

Right-click Documents in the sidebar, choose Properties, then the Location tab.  It should now read `C:\Users\<you>\Documents`.  If it still points at OneDrive, click **Restore Default**, because apparently this piece of shit needs to be told twice.

Do the same check for Pictures and Desktop and anything else.  Open a few of the moved files to make sure they are real and not some empty placeholder OneDrive left behind as a parting "fuck you."  Once you are satisfied everything is intact and local, you are done with the part that requires care.  Everything from here is just demolition.

---

## Part 5: Remove OneDrive

OneDrive will not leave quietly.  It never does.  You have to take it apart piece by piece like the clingy, badly-built mess it is.  I have pissed better concepts and implementations than this thing down a drain.

1.  **Unlink the account.** OneDrive icon, Settings, Account tab, Unlink this PC.
2.  **Uninstall the application.** Settings, Apps, Installed apps, search for Microsoft OneDrive, Uninstall.  This step alone will not finish the job, because OneDrive leaves debris behind on purpose, specifically so some trace of it survives a normal uninstall and it can worm its way back in later.

3.  **Delete the leftover folders it refuses to clean up after itself, because cleaning up after itself is apparently beneath it, it's lazier than my teenage kids:**
   ```
   C:\Users\<you>\OneDrive
   C:\Program Files\Microsoft OneDrive
   C:\Program Files (x86)\Microsoft OneDrive
   C:\ProgramData\Microsoft OneDrive
   ```
   Confirm your Documents, Pictures, and Desktop are not still living inside that OneDrive folder before you delete it.  You already moved them out in Part 3, but check anyway, because this software has earned every ounce of paranoia you can muster.

4.  **Remove the registry remnants.** Open `regedit` and delete the OneDrive key under:
   ```
   HKEY_CURRENT_USER\Software\Microsoft\OneDrive
   HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\OneDrive
   ```
   This is the part of OneDrive that hides in the dark hoping you forgot about it.  It does not get to stay.  None of it does.

5.  **Strip it from the File Explorer sidebar.** In `regedit`, go to:
   ```
   HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}
   ```
   Set `System.IsPinnedToNameSpaceTree` to `0`.  OneDrive does not get a permanent seat in your sidebar just because it used to squat there uninvited.

---

## Part 6: Keep It From Coming Back

This is the part that should make you angry, because it is not optional vigilance, it is OneDrive's actual design philosophy.  Major Windows updates have a habit of quietly re-enabling folder backup, sometimes during setup, sometimes after a feature update, often without asking again in any way that registers.  After any large Windows update, check Documents, Pictures, and Desktop (and anything else) locations again.  If you see `OneDrive` in the path, the piece of shit crawled back in like it always does, because it has all the persistence of Japanese knotweed.

Treat every future update as a potential reinfection and check accordingly.

We hate OneDrive.  We hate that it renames a hostage situation "backup," like quietly relocating someone's files without clearly asking first is some kind of favor instead of the bullshit move it actually is.  We hate that it hides your own damn files from you under a folder it created without permission.  We hate that uninstalling it does not actually uninstall it, that it leaves folders and registry keys scattered around like a shitty houseguest who "forgets" their crap on purpose so they have an excuse to weasel their way back in next week.It is gone, every last fucking trace of it, and good riddance to the whole rotten, presumptuous, half-built piece of shit.  Until Microslop enables it again.

---
