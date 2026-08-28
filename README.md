# Tidy

Two small rules that keep your Downloads and screenshots in order, run from the menu
bar. No Dock icon, no window, no dependencies, no App Store paperwork.

Requires macOS 14+ and Swift 5.9+.

## Build & run

```bash
./build-app.sh --install     # release build, copy to /Applications, launch
./build-app.sh               # just produce ./Tidy.app
./build-app.sh --universal   # arm64 + x86_64
```

The bundle is ad-hoc signed (`codesign --sign -`). No developer account, provisioning
profile, or notarization is involved. Tidy needs no permissions.

## The rules

| Rule | Default | What it does |
|---|---|---|
| Rename screenshots | on | `Screenshot 2026-08-27 at 8.42.11 PM.png` becomes `Safari — 2026-08-27 20.42.11.png`, using whichever app was in front |
| Sort Downloads | **off** | Moves files into `Images`, `Documents`, `Archives`, `Installers`, `Media` beside them |
| Trash old installers | **off** | Moves `.dmg` and `.pkg` older than your cutoff to the Trash |

The two rules that move things are off until you turn them on. A tool that
rearranges your files without being asked is worse than no tool.

Tidy watches the folders and runs a second or so after they settle down. **Tidy now**
in the popover runs everything immediately, and **Recently** lists the last twenty
things it did, so you can see what happened rather than trusting it.

## What it will not touch

- **Nothing is ever deleted.** Files are moved beside themselves or sent to the Trash.
  A rule that misfires costs you a drag back.
- **Unknown file types are left where they are.** There is no `Other` folder — a
  catch-all bucket just relocates the mess.
- **Part-finished downloads** — `.download`, `.crdownload`, `.part`, `.opdownload`,
  `.tmp` — are skipped, because moving one mid-flight corrupts it.
- **Anything modified in the last minute**, so a file still being written is left to
  finish.
- Folders. Only files are sorted.

Name collisions never overwrite: a second `Safari — ….png` becomes `Safari — … 2.png`.

## About screenshots

Tidy renames screenshots wherever macOS is currently saving them, read from
`com.apple.screencapture`'s `location` — the Desktop if you have never changed it.

If your screenshots go to the **clipboard** rather than to a file, this rule will
almost never fire, because there is no file to rename. Check with:

```bash
defaults read com.apple.screencapture
```

A `target = clipboard` there means ⌘⇧5 is set to copy rather than save. The rule costs
nothing when idle, but it will look broken until something writes a file.

Screenshots are matched by the name macOS gives them — `Screenshot …` or the older
`Screen Shot …`. The `kMDItemIsScreenCapture` Spotlight attribute would be the tidier
test and is not reliably set, so it is not used.

## How it works

`Sources/Tidy/`

- **`TidyApp.swift`** — `@main`, `AppDelegate`, status item, popover, and the
  `SMAppService` login-item switch.
- **`Janitor.swift`** — the rules, the folder watchers, and the log.
- **`PopoverView.swift`** — the SwiftUI popover.

`DirectoryWatcher` is a `DispatchSource` on a directory file descriptor. One download
produces a burst of events, so sweeps are debounced by 1.5 seconds.

## Known limits

- The frontmost app is read when Tidy *notices* the screenshot, not when you took it.
  Switch apps within that second and the name will be wrong.
- Categories are by file extension, not by UTI, so an extensionless file is ignored.
- There is no undo beyond moving the file back yourself; the log says where it went.
