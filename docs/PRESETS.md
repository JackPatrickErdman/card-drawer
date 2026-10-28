# Presets

A preset is one JSON file in the `presets\` folder. Every file there shows up
in *Add a camera → Start from a preset*, sorted by file name. To share a setup,
open *My cameras → (camera) → S Save as a preset*. That writes a file with your
card serials and folder choices removed, and anyone can drop it into their own
`presets\` folder.

## Format

```json
{
  "preset": "Dashcam / DVR (videos only)",
  "description": "One or two sentences shown in the menu.",
  "camera": {
    "match": {
      "serials":   [],
      "exifModel": "",
      "exifMake":  "",
      "fileNames": "",
      "drive":     "",
      "content":   "videos"
    },
    "naming":         "{name} ({n})",
    "dates":          "import",
    "deleteFromCard": false,
    "convertVideo":   true,
    "rawMode":        "local",
    "review":         "never",
    "autoStart":      false,
    "photoHook":      ""
  }
}
```

Any field you leave out gets its default, so a preset can be tiny.

### `match`: how a card is recognized

A card belongs to the first camera (top of *My cameras* first) whose
**specific** rule matches. Only if none does are **catch-all** rules tried.

| field | kind | meaning |
|---|---|---|
| `serials` | specific | Volume serial numbers of exact cards, e.g. `"1A2B3C4D"` (no dash). Leave empty in shared presets. |
| `exifModel` | specific | Regular expression against the camera model in the first JPEG, e.g. `"^DSC-T7$"` |
| `exifMake` | specific | Regular expression against the camera maker, e.g. `"^SONY$"`, `"KODAK"` |
| `fileNames` | specific | Regular expression against any media file name, e.g. `"^KIF_\\d{4}"` |
| `drive` | specific | A drive letter, e.g. `"A:"`: anything in that drive belongs to this camera. For a reader that always gets the same letter. (Older files may say `"floppy": true`, which means `"A:"`.) |
| `content` | catch-all | `"photos"` (any card with photos), `"videos"` (cards with only videos), `"any"` |

### What happens to the files

| field | values | default |
|---|---|---|
| `naming` | A file-name pattern built from tags (below). `"{name} ({n})"` gives *Sony (1).JPG, Sony (2).JPG*; `"{date} {time}"` gives *2026-06-15 14-30-05.JPG*; `"{orig}"` keeps the camera's names. A taken name gets `_2`, `_3`... (older files may say `"sequential"` or `"keep"`). | `{name} ({n})` |
| `dates` | `"capture"` keeps the camera's time, `"import"` stamps today (for dead clocks) | `capture` |
| `deleteFromCard` | `true` deletes each file after its copy's SHA256 matches | `false` |
| `convertVideo` | `true` converts AVI, MPG, MTS, ASF, WMV, 3GP, MOD, TOD to MP4 and keeps the original | `true` |
| `rawMode` | `"local"` keeps RAW on the PC and sends a JPG; `"copy"` sends the RAW itself | `local` |
| `review` | After an import, before photos go out: `"ask"` whether to open the review window (rotate / delete), `"always"` open it, `"never"` | `ask` |
| `autoStart` | `true` starts this camera's imports without the "Press Enter to start" question | `false` |
| `photoHook` | Command run on each outgoing JPG; `{file}` is replaced by its quoted path. Exit code 0 = keep the result, anything else = restore the original. | `""` |

### Naming tags

| tag | becomes |
|---|---|
| `{name}` | the camera's label (its name, unless changed) |
| `{n}` / `{n:4}` | running count for this camera, continuing across imports / zero-padded to 4 digits |
| `{orig}` | the camera's own file name, without extension |
| `{date}` `{time}` | `2026-06-15`, `14-30-05`, when the shot was taken (or the import time for a wrong-clock camera) |
| `{year}` `{month}` `{day}` `{hour}` `{minute}` `{second}` | the parts on their own |

`destination` and `prefix` are deliberately not part of a preset. Each user
picks their own folder, and files are named after the camera name they choose.
