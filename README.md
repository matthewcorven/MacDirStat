# MacDirStat: Free Disk Space Analyzer for Mac

[![Latest release](https://img.shields.io/github/v/release/phalladar/MacDirStat?label=latest%20release)](https://github.com/phalladar/MacDirStat/releases/latest)
[![Requires macOS 15 or later](https://img.shields.io/badge/macOS-15%2B-blue?logo=apple)](#what-version-of-macos-does-macdirstat-require)
[![MIT License](https://img.shields.io/github/license/phalladar/MacDirStat)](LICENSE)

**MacDirStat is a free, open-source disk space analyzer for macOS. It scans your Mac and draws every file as a color-coded treemap, so you can see what's taking up space and free up storage.**

It's a native Mac app inspired by WinDirStat on Windows, with no ads, subscriptions, accounts, or tracking.

<a href="https://github.com/phalladar/MacDirStat/releases/latest/download/MacDirStat.zip"><img alt="Download MacDirStat for Mac" src="https://img.shields.io/badge/Download_for_Mac-MacDirStat.zip-2ea44f?style=for-the-badge&logo=apple&logoColor=white"></a>

**[Download MacDirStat (.zip)](https://github.com/phalladar/MacDirStat/releases/latest/download/MacDirStat.zip)** · Free · macOS 15 Sequoia or later · Apple silicon and Intel · Notarized by Apple · [All releases](https://github.com/phalladar/MacDirStat/releases)

![MacDirStat showing a treemap of a Mac's startup disk: nested, color-coded rectangles sized by disk usage, with the largest files labeled, next to an inspector panel listing total size, file count, and a breakdown by file type](screenshot.png)

*Each rectangle is a file. Its area is how much space it uses, its color is its file type, and files are grouped inside their folders.*

## How to install MacDirStat

1. **[Download MacDirStat.zip](https://github.com/phalladar/MacDirStat/releases/latest/download/MacDirStat.zip).**
2. **Unzip it.** Safari unzips downloads automatically. With another browser, double-click `MacDirStat.zip` in your Downloads folder.
3. **Drag `MacDirStat.app` into your Applications folder.**
4. **Open MacDirStat.** macOS asks you to confirm opening an app downloaded from the internet. Click **Open**. MacDirStat is signed with an Apple Developer ID and notarized by Apple, so no Gatekeeper workarounds are needed.

### Optional: allow Full Disk Access

MacDirStat runs without special permissions, but macOS stops apps from reading some protected folders, such as Mail, Messages, and other apps' data. When Full Disk Access is off, MacDirStat's start screen shows a banner that takes you to the right setting. To include those folders in scans:

1. Click **Open System Settings** in the banner, or open **System Settings → Privacy & Security → Full Disk Access** yourself.
2. Turn on **MacDirStat**. If it isn't listed, click **+** and choose it from your Applications folder.
3. Click **Relaunch** in the banner, or quit and reopen MacDirStat.

You only need to do this once: the permission carries over when you update to a newer download. Without Full Disk Access, macOS may ask during a scan whether MacDirStat can access folders like Desktop, Documents, or Downloads. Click **Allow** so they're measured.

### Updating and uninstalling

MacDirStat never connects to the internet, so it doesn't check for updates itself. To update, download the latest zip and replace the app in Applications. To be notified of new versions, click **Watch → Custom → Releases** at the top of this page (requires a GitHub account).

To uninstall, quit MacDirStat and drag it from Applications to the Trash. It doesn't install background services or helper tools.

## How to see what's taking up space on your Mac

1. **Open MacDirStat.** The start screen lists your drives, with a bar showing how full each one is.
2. **Pick what to scan.** Click your startup disk (usually **Macintosh HD**) to scan the whole Mac, click an external drive, or click **Choose a Custom Folder...** to scan a single folder.
3. **Wait for the scan.** MacDirStat shows the number of files and the allocated disk space found so far. You can cancel at any time.
4. **Look for the biggest rectangles.** They are the files using the most space. Hover over any rectangle to see its full path and size in the status bar at the bottom.
5. **Zoom in on crowded areas** with the scroll wheel, a trackpad pinch, or the zoom buttons in the toolbar.
6. **Drill into a folder.** Double-click any rectangle to show just the folder it's in. The breadcrumb bar above the treemap, or the **Back** button, takes you back up.
7. **Check folder totals.** The sidebar lists folders sorted largest first. Select a folder to see its size, file count, and breakdown by file type in the inspector on the right, or click a file in the treemap to see its details.
8. **Act on what you find.** Right-click a file and choose **Reveal in Finder**, then delete it in Finder if you're sure you don't need it. Click **Rescan** in the toolbar to refresh the treemap.

MacDirStat only deletes files through an explicit **Move Worktree to Trash** / **Delete Worktree Immediately** action on a detected git worktree. Everything else stays read-only.

## Features

- **Interactive treemap.** Every file is drawn as a rectangle sized by its disk usage, nested inside its folders, using the squarified treemap layout. Large files and folders stand out at a glance, and bigger rectangles are labeled with their name and size.
- **Color-coded file types.** Files are colored by category: documents, images, video, audio, code, archives, applications, system, caches, and other.
- **Folder tree sidebar.** Browse the folder hierarchy, sorted largest first, with each folder's size.
- **Inspector panel.** Shows size, allocated size, file and folder counts, last-modified date, and a bar chart of what each folder contains by file type.
- **Drill down.** Double-click a rectangle to focus the treemap on its folder, then go back up with the breadcrumb bar or the Back button.
- **Zoom and pan.** Zoom with the scroll wheel, a trackpad pinch, or the toolbar. Pan by dragging with the middle mouse button.
- **File Size or Allocated Size.** Allocated Size is the default. Switch to File Size to see logical content sizes, including online-only files.
- **Cloud-aware scanning.** File Provider placeholders (including OneDrive, synced SharePoint libraries, iCloud Drive, and other providers using macOS dataless files) are measured without downloading their contents. Cloud-only folders are skipped and marked as incomplete.
- **Drive overview.** The start screen shows your mounted drives with their used and available space, or you can scan any folder.
- **Git worktree awareness.** Turn on the **Git Worktrees** option before (or after) scanning to color linked git worktrees consistently and show a legend with how many worktrees the scan contains and how much space they use. The total updates immediately when a worktree is moved to the Trash from MacDirStat, or when one is deleted outside the app.
- **Which worktrees are safe to delete.** The **Worktree Report** lists every worktree with its branch, whether it has uncommitted changes, when a file last changed, and its size. The **Stale & Clean** filter narrows the list to the ones you can usually delete, and deleting is refused while a worktree has uncommitted changes. Detached worktrees are always listed as candidates.
- **Cross-checked with git.** After the scan, `git worktree list --porcelain` runs for each repository found. That adds real branch names, reports **prunable** registrations whose folder is gone (with a one-click **Prune**), flags a `.git` file that points at a moved or missing gitdir, and marks a worktree as **orphaned** when its main repository is gone. Without git installed, the filesystem view is shown on its own.
- **Honest about gaps.** Folders the scan could not read are counted in the main window, together with the Full Disk Access state, because worktrees inside them would otherwise be invisible.
- **Reveal in Finder and Copy Path** from the inspector or the right-click menu.
- **Parallel scanning with live progress.** MacDirStat reads file metadata in batches and scans folders in parallel, with a POSIX fallback for unsupported filesystems. Hard-linked files are counted once.
- **Native and lightweight.** Built with SwiftUI, with no external dependencies, no Electron, and no bundled runtimes.
- **Private by design.** The app has no networking code: no analytics, no crash reporting, no update checks. Your file list never leaves your Mac.

## FAQ

### Is there a WinDirStat for Mac?

WinDirStat itself is Windows-only, but MacDirStat is a free, open-source macOS app inspired by it. It scans a drive or folder and shows disk usage as a color-coded treemap next to a folder tree. MacDirStat is an independent project and isn't affiliated with WinDirStat.

### Is there a free, open-source alternative to WizTree for Mac?

Yes. MacDirStat is a free, open-source disk space analyzer for macOS that shows disk usage as a treemap, and the MIT License allows both personal and commercial use. WizTree itself is also available for macOS as WizTreeMac.

### How do I find what's using disk space on my Mac?

Open MacDirStat, click your startup disk (usually Macintosh HD), and wait for the scan to finish: the largest rectangles in the treemap are the files using the most space. Hover over a rectangle to see its path, then right-click and choose Reveal in Finder to deal with it. macOS also has a built-in overview under **System Settings → General → Storage**, but it sorts usage into broad categories such as Applications, Documents, and System Data rather than showing your whole folder structure. See [How to see what's taking up space on your Mac](#how-to-see-whats-taking-up-space-on-your-mac) for step-by-step instructions.

### Is MacDirStat free?

Yes. MacDirStat is free and open source under the MIT License, with no ads, in-app purchases, subscriptions, or sign-up. That makes it a free alternative to commercial Mac disk analyzers such as DaisyDisk.

### Is MacDirStat safe? Does it upload my data?

MacDirStat works entirely offline: the app contains no networking code, so it can't send your file names or any other data off your Mac. It reads file information such as names, sizes, and dates, not file contents. Scans never modify, move, or delete files; the only destructive action is the explicit **Move Worktree to Trash** / **Delete Worktree Immediately** command on a detected git worktree. Downloads are signed with an Apple Developer ID and notarized by Apple, and the full source code is in this repository for anyone to review.

### Can MacDirStat delete files?

Not during a scan. To remove something you find, right-click it, choose **Reveal in Finder**, and move it to the Trash in Finder. Then click **Rescan** to update the treemap. The one exception is a detected git worktree: right-click it and choose **Move Worktree to Trash**, or **Delete Worktree Immediately** to skip the Trash, and the worktree total updates without a rescan.

Because a worktree is drawn as one block, right-clicking anywhere inside it offers the worktree actions, and selecting any folder inside it shows the worktree's delete button in the inspector. Deleting is **refused while the worktree has uncommitted changes** (or while they can't be verified), and the reason is shown in an alert. **Delete Worktree Immediately** removes the folder outright instead of moving it to the Trash, but the uncommitted-changes check still applies.

### Does MacDirStat work on Intel Macs?

Yes. MacDirStat is a universal app that runs natively on both Apple silicon (M-series) and Intel Macs, as long as the Mac runs macOS 15 Sequoia or later.

### What version of macOS does MacDirStat require?

MacDirStat requires macOS 15 Sequoia or later. It doesn't run on macOS 14 Sonoma or earlier.

### Why does MacDirStat need Full Disk Access?

MacDirStat doesn't need Full Disk Access to run; the permission only lets it measure folders that macOS protects, such as Mail, Messages, and other apps' data. Without it, protected folder contents are skipped and marked as incomplete, so totals can come out lower than the space actually in use. MacDirStat only reads file information and has no networking code, so granting access doesn't send anything anywhere. See [Optional: allow Full Disk Access](#optional-allow-full-disk-access).

### Why doesn't MacDirStat's total match macOS Storage settings?

MacDirStat adds up the files it can read, which can differ from the numbers macOS shows:

- Protected or cloud-only folders that cannot be enumerated are marked as incomplete; their contents are not included.
- APFS snapshots, including local Time Machine snapshots, take up space but aren't regular files, so a file scan can't see them.
- Hard-linked files are counted once, and symbolic links aren't followed.
- A scan stays on one volume: other drives or volumes mounted inside the scanned folder aren't included.
- File Size and Allocated Size can differ a lot (see the next question).
- APFS clones can share storage blocks while reporting allocated sizes for each file. Summed allocated sizes are not an exact measurement of unique physical blocks or how much deleting files would free.

### What's the difference between File Size and Allocated Size?

File Size is the size of a file's contents; Allocated Size is the disk space the file actually occupies. Allocated Size can be smaller for compressed or sparse files, such as some virtual machine disk images, and is often slightly larger for small files, because disk space is allocated in whole blocks. Allocated Size is the default for the treemap, folder ordering, and category breakdown. Scan progress always shows allocated space. Switch between them with the toggle in the toolbar.

Online-only cloud files can have a large File Size and little or no Allocated Size. A logical total above your drive capacity does not mean those bytes are stored on your Mac.

### Will scanning download my OneDrive, SharePoint, or iCloud files?

MacDirStat disables dataless-file materialization on each scanning thread using [Apple's recommended I/O policy](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files). It reads metadata and does not open file contents. Locally enumerated placeholders retain their logical and allocated sizes. Cloud-only folders, or folders that would require materialization to enumerate, are not expanded; the app reports an incomplete scan instead. Already downloaded cloud files are scanned normally. This relies on macOS File Provider/dataless-file support rather than provider names or path-based exclusions.

If a parent folder of the selected scan path is cloud-only, the scan may fail without downloading it. Choose a locally available parent folder instead. Cancel stops scheduling work and cancels the scanner; an already-running filesystem call must return before its worker can exit.

### What do the colors in the treemap mean?

Colors show file type, based on the file extension. Rectangles get slightly darker the deeper they're nested.

| Color | Category | Examples |
| --- | --- | --- |
| Blue | Documents | PDF, Word, Excel, Pages, TXT, Markdown |
| Green | Images | JPEG, PNG, HEIC, camera RAW, PSD, SVG |
| Red | Video | MP4, MOV, MKV, AVI |
| Orange | Audio | MP3, WAV, FLAC, M4A |
| Purple | Code | Swift, Python, JavaScript, HTML, JSON |
| Teal | Archives | ZIP, DMG, ISO, PKG, TAR |
| Pink | Applications | DYLIB, SO, DLL, EXE, APK |
| Light gray | System | PLIST, STRINGS, .DS_Store |
| Brown | Caches | CACHE, TMP, O, PYC, CLASS |
| Cyan | Git Worktrees | A linked git worktree, counted as one block rather than by file type |
| Gray | Other | Everything else, including files without an extension |

When the **Git Worktrees** option is on, a linked git worktree and everything inside it are drawn in cyan (`#1AD6EB`) instead of their file-type colors, so each worktree reads as one solid block sized by its real content. A **Git Worktrees** legend with their count and combined size stays in the corner of the treemap. The legend also shows how many are unused and how many are prunable; click it to open the **Worktree Report**. The main repository, its submodules, and ordinary folders keep their normal colors.

Worktrees are recognized while a folder is being scanned, not in a second pass, so detection adds no extra tree walk. The `.git` check is skipped inside `node_modules`, `.build`, `.swiftpm`, `Library`, `Pods`, `DerivedData` and virtualenv folders, which are large and never hold worktrees; their sizes are still measured exactly.

### Can MacDirStat scan external drives?

Yes. Mounted drives, including external ones, appear on the start screen with their used and available space. Click one to scan it, or choose any folder on it with **Choose a Custom Folder...**.

## Alternatives and related projects

- [WinDirStat](https://windirstat.net/): the original Windows disk usage analyzer that inspired MacDirStat
- [WizTree](https://diskanalyzer.com/): disk space analyzer for Windows, now also available for macOS
- [GrandPerspective](https://grandperspectiv.sourceforge.net/): treemap disk usage visualizer for macOS
- [DaisyDisk](https://daisydiskapp.com/): commercial disk analyzer for macOS
- [OmniDiskSweeper](https://www.omnigroup.com/more): macOS utility from The Omni Group that lists files from largest to smallest

## Build from source

You only need this if you want to work on MacDirStat; most people should use the [download](#how-to-install-macdirstat) instead. Building requires macOS 15 or later and Swift 6 (Xcode 16 or later).

```bash
git clone https://github.com/phalladar/MacDirStat.git
cd MacDirStat
swift build -c release
swift run MacDirStat
```

To install it as a regular app in `/Applications`:

```bash
./scripts/build-app.sh
cp -R .build/MacDirStat.app /Applications/
```

The comments at the top of `scripts/build-app.sh` cover universal builds and Developer ID signing. If your keychain has an **Apple Development** identity, the script signs the app with it automatically; otherwise it falls back to ad-hoc signing.

To include protected folders (Mail, Messages, other apps' data) in scans, add MacDirStat under **System Settings → Privacy & Security → Full Disk Access**. A Full Disk Access grant is tied to the app's code signature: with an Apple Development identity the identity stays the same across rebuilds, so the grant keeps working. Ad-hoc signing produces a new identity on every build, so after rebuilding, remove MacDirStat from that list and add it again.

Or open in Xcode:

```bash
open Package.swift
```

Zero external dependencies. Pure Swift Package Manager project.

## Architecture

MacDirStat is a SwiftUI app written in Swift 6 with strict concurrency checking. A single `@Observable` `AppState` drives all views.

**Scan pipeline:** the user picks a drive or folder → `ScanCoordinator` starts `FileScanner` → `FileScanner` reads metadata with `getattrlistbulk`, using `fstatat` for directory/mount identities and missing attributes, and `readdir`/`fstatat` on unsupported filesystems. At most four directories run in parallel, symlinks are skipped, nested mount points are listed but not descended into (identified by mount table, not `st_dev`, because a sealed system snapshot reports a different device for files inside its own mount), and device+inode deduplication counts hard links and firmlinks once → it builds the `FileNode` tree, optionally marks linked git worktree roots (directories whose `.git` file points into `.git/worktrees/`), and streams progress as `ScanEvent`s over an `AsyncStream` → `ScanCoordinator` throttles UI updates to every 50 ms → `TreemapLayoutEngine` lays out the tree with the squarify algorithm on a background task → a SwiftUI `Canvas` renders it.

### Project structure

```
Sources/MacDirStat/
├── App/              # Entry point, AppState
├── Scanning/         # FileScanner (parallel POSIX traversal), ScanCoordinator, FileNode tree model
├── Categorization/   # FileCategory definitions, ~190 file extension mappings
├── Worktrees/        # Worktree detection, git cross-check/analysis, shared color constants
├── Treemap/          # Squarify layout engine, hit testing, Canvas renderer, zoom and pan
├── Views/            # ContentView, WelcomeView, Settings, Worktree Report, diagnostics banners
└── Utilities/        # ByteFormatter, FilePath, FullDiskAccess, FolderPicker, AppLog (unified logging)
```

### Diagnostics logging

Logging is **off by default**. Enable it in **MacDirStat › Settings…** (⌘,) under **Diagnostics**. The switch applies immediately, but it does not backfill anything: a session that started with logging off has no record of its own launch or the scans that already ran. When it is on, every scan logs its start parameters, the normalized root with device/inode/flags, each folder that failed or changed mid-scan, the final file/folder counts, logical and allocated totals, and cloud/incomplete counts. Layout runs log item counts, canvas size, duration, and the worktree item count, and UI/state events log navigation and worktree mutations. Folder paths are logged as public so they are readable.

Test runs write to the `io.github.phalladar.MacDirStat.tests` subsystem, so `log show` for the app stays free of fixture paths.

```bash
# Live stream while reproducing a problem
log stream --level debug --style compact \
  --predicate 'subsystem == "io.github.phalladar.MacDirStat"'

# Recent history, including info and debug messages
log show --last 10m --info --debug --style compact \
  --predicate 'subsystem == "io.github.phalladar.MacDirStat"'

# Narrow to one area
log stream --level debug --predicate 'subsystem == "io.github.phalladar.MacDirStat" AND category == "scan"'
```

Categories are `scan`, `worktree`, `layout`, `ui`, and `state`. When running from Xcode, messages also appear in the debug console. With `swift run`, prefix the command with `log stream ...` in a second terminal, because the unified log does not echo to stdout.

### Worktree analysis

`WorktreeAnalyzer` combines three sources of truth:

1. **The scan.** Each directory already open for enumeration reads its `.git` file, so worktree roots are known before the tree is published. The newest modification date in the subtree supplies "last changed".
2. **`git worktree list --porcelain`** for every repository found, giving branch names, `prunable` entries, and registrations the scan could not see.
3. **`git status --porcelain=v1 --branch`** for each worktree, giving the live branch and whether anything is uncommitted (including untracked files).

A worktree is an **unused candidate** when it is clean and either detached or untouched for longer than the threshold (14 days by default, configurable in **Settings › Git Worktrees**). Delete is refused unless the worktree is clean, or unless you explicitly choose **Delete Immediately**. All git calls are local: prompts are disabled, optional locks are off, and each call has a timeout.

Paths are canonicalized once at the scanner with `realpath`, so a scan started at `/tmp/project` reports `/private/tmp/project`, matching what `git` returns.

A folder can also be scanned from Finder with **Open With › MacDirStat**, by dropping it on the Dock icon, or with `MacDirStat --scan <folder>`.

## Contributing

Contributions are welcome. [Open an issue](https://github.com/phalladar/MacDirStat/issues) to report a bug or suggest a feature, or submit a pull request. CI builds and tests every pull request with `swift build` and `swift test`.

Run the regression suite with `swift test`. To also verify a real cloud-only directory without downloading it, set `MACDIRSTAT_CLOUD_TEST_PATH` to a File Provider placeholder directory when running `swift test`. Set `MACDIRSTAT_SCAN_TEST_PATH` to a folder to run a metadata-only integration scan and print a size/count summary.

For a controlled enumeration comparison, run `MACDIRSTAT_BENCHMARK_PATH=/path/to/stable/folder swift test -c release --filter compareDirectoryEnumerationPerformance --no-parallel`. It alternates POSIX and bulk reads and checks that file/folder counts, sizes, cloud-only files and incomplete folders agree. Use a stable tree and report each timing; changing files and filesystem cache warmth affect results. This benchmark does not open file contents.

## License

MacDirStat is released under the [MIT License](LICENSE).
