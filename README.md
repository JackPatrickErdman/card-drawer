# Card Drawer

Card Drawer is a memory-card importer for Windows, for people who have more
than one camera. Put a card in and it figures out which camera the card came
from, then imports it the way that camera needs: numbered file names that
don't collide, the real capture date (or today's date if the camera's clock is
wrong), old video formats converted to MP4, RAW files kept on the PC, and
nothing imported twice.

It's a small point-and-click program that looks like it came with Windows 98.
There are no config files to edit and nothing to install first.

A Mac version is in the works. I'm testing it now and will put it up here
when it's ready.

![The Card Drawer window](docs/screenshot.png)

![The photo window reviewing an import](docs/viewer.png)

The full guide, including how to set it up with iCloud, is in
[`How to use.html`](How%20to%20use.html) (also under Help → Guide in the
window).

## Why I wrote it

I have a drawer full of old cameras: a floppy-disk Mavica, a couple of 2004
compacts, a thermal camera, a glitchy analog video camera, a mirrorless that
shoots RAW. Every importer I tried does the same thing: copy the card into
dated folders. That falls apart with a drawer like that.

- Half the cameras name files `DSC00001.JPG` or `IMG_0001.JPG`, so imports
  collide.
- Some of them have no clock, or a clock that reset to 2018, so photos land
  years off in the timeline.
- AVI, MPG, MTS and ASF videos don't play in iCloud or Google Photos.
- RAW files eat cloud storage for no reason.
- iCloud and Google Photos upload a file the moment it appears in the synced
  folder, and they don't re-read it afterwards. If you rotate a sideways shot
  later, the cloud copy stays sideways.
- Putting a card in twice gives you two of everything.

Card Drawer deals with each of those, per camera, so I stopped doing it by
hand.

## Getting started

1. Download the zip and unzip it anywhere: Desktop, Documents, a USB stick.
2. Double-click `Card Drawer.bat` and click Set Up. It asks where to keep the
   library, offers to install the free video converter, then opens Add Camera.
   File → Create Desktop Shortcut gives you an icon.
3. In Add Camera, click Use Card to learn the card that's plugged in, pick a
   preset if there is one for your camera, and choose where files go and how
   they're named. It shows an example name as you change things. At the end
   it offers a practice run, which copies the card into a practice folder
   and doesn't touch the card.

After that it's: put a card in, the window says which camera it is, click
Import Now. A camera you've set to start on its own imports without asking.

If you'd rather use the keyboard, `Text Menus.bat` does everything from
numbered menus, and `Import Now.bat` is a one-click import with no window.

## What it does

Recognizes cards by the card's serial number, the camera make or model in the
photos' EXIF, the file-name style, a fixed drive letter, or a catch-all rule
like "any card that only has videos". Specific rules win over catch-alls.

Comes with presets for Sony, Canon, Nikon, Fujifilm, Panasonic, Olympus and
Kodak cameras, dashcams, camcorders, cameras with a broken clock, and plain
archiving. A preset is one JSON file; see [docs/PRESETS.md](docs/PRESETS.md)
to write your own.

Keeps a SHA256 fingerprint ledger per camera, so a file is never imported
twice even if it was renamed or it's been months.

Deleting from the card is off by default. When it's on, a file is only removed
after the copy's fingerprint matches. It never formats anything.

Shows each photo in a window as it comes off the card, then that window
becomes the review: rotate or delete anything before it goes out. Photos sit
in a local Incoming folder until you click Done. If a run is interrupted, the
leftovers are offered for review next time instead of being sent blind.

Converts AVI, MPG, MTS, ASF and similar to MP4 with HandBrakeCLI or ffmpeg,
and writes the capture date inside the MP4 so photo timelines sort it
correctly. The original is kept locally.

Keeps RAW files on the PC. The destination gets the camera's own JPG if it
shot RAW+JPEG, or one rendered with rawpy. You can send the RAW as-is instead.

For a camera with a wrong clock, writes today's date inside the JPEG
(byte-level, no re-compression) and inside MP4 and MOV files, which is what
iCloud sorts by. An untouched copy is kept.

Sends files to any folder: the library, iCloud Photos (found automatically),
OneDrive, Google Drive, a NAS.

Names files per camera: running count, date and time taken, date plus count,
the camera's own names, or a pattern like `{year}-{month} {name} {n:4}`.
Counts carry on across imports.

A camera can be set to start without asking and skip the review, so plugging
in its card is the whole job.

If you need to, you can run your own command on every JPG before it goes out
(the untouched copy is kept).

## What's optional

It needs Windows 10 or 11 and nothing else; it runs on the Windows PowerShell
that's already there. The menus offer to install these with `winget` from
their official sources:

- ffmpeg or HandBrakeCLI, for converting AVI and MPG-style videos. Without
  them, those videos are copied as they are.
- Python with rawpy, for making a JPG from a RAW-only shot. Without them, RAW
  files are still kept, there's just no JPG. RAW+JPEG cameras don't need it.

None of these are bundled. They have their own licenses (GPL/LGPL).

## What it's been tested with

Through this program, on real cards, on Windows 11, going to iCloud Photos
for Windows:

- Kyocera Finecam SL300R (a 2004 compact): 51 photos over three sessions,
  sideways shots rotated in the review before they went to iCloud.
- Sony Cyber-shot DSC-T7: 54 files in one go, including MPG and AVI clips
  converted to MP4 with the capture date written in.

Set up in my own copy, but actually imported with the older scripts this
program grew out of. The per-camera rules are proven on real cards; this
exact code path isn't yet:

- Sony Mavica floppy-disk camera (3.5" floppy in a USB drive, no EXIF dates,
  matched by drive letter)
- Panasonic D-snap SV-AV50 (2004 SD hybrid camera, ASF video)
- Panasonic Lumix DMC-SZ1
- Sony NEX-5N (RAW+JPEG; the ARW stays local, the JPG goes out)
- Canon PowerShot SD870 IS
- A thermal camera built into a receipt-printer body. Matched strictly by
  card serial, names kept exactly as the firmware wrote them, deleting
  never allowed.
- A handheld analog glitch-video camera that records AVI to a mini-DVR card
  with its clock stuck in 2018. Videos-only catch-all, import-date mode.

The window can also list cameras that have their own importer and launch it.
I use that for a Raspberry Pi stereo camera pulled over SSH and a 1997 Nikon
Coolpix 300 read over a serial cable. Neither goes through this program.

The brand presets have only been tested against generated files with the
standard EXIF maker and model strings, not real cameras from each brand.

## Limits

- Windows only, for now.
- The card needs a drive letter. A camera plugged in by USB that shows up as
  a "portable device" (MTP/PTP) isn't seen. Use a card reader.
- The brand presets are a best guess. If one misses your camera, use Custom
  setup, which learns from the actual card.
- A card's serial number changes if you format it in a computer. Formatting
  in the camera usually keeps it. If it changes, re-learn it under My
  Cameras → Recognition rules.
- Wi-Fi cameras and phones aren't sources. Phones have their own photo apps
  that do this better.

## Mac

Coming. The engine is PowerShell and ports to PowerShell 7 on a Mac; the
window and the card detection are Windows-specific and are being redone. I'm
testing it myself before it goes up. If you want to help test, open an issue.

## Folder layout

```
Card Drawer\
  Card Drawer.bat        the window (start here)
  Text Menus.bat         the same things as numbered text menus
  Import Now.bat         one-click scan + import, no window
  How to use.html        the user guide
  presets\               ready-made camera setups (add your own)
  src\                   the program (PowerShell + one Python helper): App.ps1 is the main window,
                         Viewer.ps1 the photo window, Retro.ps1 the shared Windows 98 look
  tests\                 unit tests, stress tests, scripted menu walkthrough
  data\config.json       your settings (created on first run)

Library\ (you choose where; default Pictures\Card Drawer)
  <Camera name>\
    Media\                 finished files (unless you picked another destination)
    Incoming\              photos waiting for review before they go out
    Working\               videos being converted / re-dated before they go out (empty when idle)
    Converted Originals\   original AVI/MPG/MTS files
    RAW Originals\         RAW files
    Unprocessed Originals\ untouched copies of anything re-dated or patched
    imported_media.csv     fingerprint ledger (what was imported, as what, when)
```

## Command line

```
powershell -ExecutionPolicy Bypass -File src\Import.ps1                  # scan + import
powershell -ExecutionPolicy Bypass -File src\Import.ps1 -Yes             # no questions (scheduled task)
powershell -ExecutionPolicy Bypass -File src\Import.ps1 -Source D:\Backup -Camera "Sony RX100" -Practice
```

## Tests

```
powershell -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
powershell -ExecutionPolicy Bypass -File tests\Stress-Tests.ps1
```

Run them one at a time. Both do imports, and only one import can run at once.

The unit tests build fake cards in a temp folder (JPEGs with real EXIF, a
RAW+JPEG pair, an AVI, junk system folders) and cover recognition, presets,
numbering, dedup, keep-names clashes, wrong-clock dates, practice runs,
interrupted-run recovery, video conversion with embedded dates, review deletes
and the photo hook. The EXIF checks need Python with Pillow and the video
checks need ffmpeg; without those they're reported as skipped.
`tests\Drive-Menu.ps1` runs the real menus with scripted answers.
`tests\Viewer-Demo.ps1` drives the photo window through a live import and a
scripted review that turns and deletes photos, then checks the files.

The stress tests are there to answer one question: can it lose a photo? After
every scenario they check that every file that was on the card still exists
byte-for-byte, either on the card or in the library, and that no library file
was changed. The scenarios are a 1,500-file card with hostile file names;
injected failures (a failed copy, a corrupted copy, a pulled card, a crash
before and after logging, a failed send); two windows at once, reused names,
overlapping folders, damaged photos in the review, a lost ledger; and a few
hundred randomized fault rounds. Before any of that runs, the checker is
shown deliberate damage to prove it notices.

What has actually run on real cards is in the section above.

## Problems

Open an issue on GitHub. Say which camera and card it was, and paste the
Activity text from the window if there is any.

## License

MIT. See [LICENSE](LICENSE).
