# Native macOS (Swift) UI for Libation — assessment

Fork: https://github.com/alexisskeates/Libation (upstream `rmcrackan/Libation`, branch `master`).

## What Libation actually is

Libation is ~130k lines of C# across 22 projects. Only a thin slice of that is UI:

| Layer | Projects | Lines | Swift-replaceable? |
|---|---|---|---|
| **UI (Avalonia, cross-platform)** | `LibationAvalonia` | 15.6k (51 `.axaml` views + code-behind/VMs) | **Yes — this is the target** |
| **UI (WinForms, Windows only)** | `LibationWinForms`, `HangoverWinForms` | 20k | Irrelevant on macOS |
| **Shared UI logic** | `LibationUiBase` | 6.8k (grid entries, process-queue VMs, status icons, walkthrough text) | Partly — port the view-models, reuse the rest via the bridge |
| **Core** | `ApplicationServices`, `FileLiberator`, `DtoImporterService`, `AaxDecrypter`, `FileManager`, `LibationFileManager`, `LibationSearchEngine`, `DataLayer*` | ~40k | **No** |
| **Audible client** | `AudibleUtilities` + NuGet `AudibleApi` | 17.7k + external | **No** |
| **CLI** | `LibationCli` | 3.1k | Keep — it is already a headless front end to the core |

The core depends on things with no Swift equivalent: `AudibleApi` (Audible's private API — device
registration, token refresh, licence requests, Widevine), `AAXClean` (decrypt + remux without
ffmpeg), EF Core + SQLite (`LibationContext.db`, with migrations), Lucene.NET for the search
syntax, Serilog, Polly. Rewriting those in Swift is a multi-month reverse-engineering project and
would permanently fork away from upstream fixes to Audible's API changes. **Rule out a full rewrite.**

The realistic goal is: **native SwiftUI shell, .NET core underneath, same `~/Library/…/Libation`
config and database so the CLI, the Avalonia app and the Swift app are interchangeable.**

## Three ways to bridge Swift ↔ .NET

### A. Drive `LibationCli` as a subprocess
The CLI already exposes: `scan`, `liberate`, `convert`, `search`, `set-status`, `export`,
`list-accounts`, `import-account`, `login-external`, `get-license`, `get-setting`, `upload`.
Swift reads the library grid straight from the SQLite DB and shells out for actions.

- ✅ Zero changes to upstream code → trivial to keep the fork in sync.
- ❌ Progress (download %, decrypt %) only via stdout parsing; no per-book cancel; every call
  pays .NET startup + DB open (~1 s); search is a separate Lucene index the CLI owns.
- Good for a proof of concept, not for the finished app.

### B. A small .NET host process with a local API  ← **recommended**
Add one new project, `Source/LibationHost` (~1–2k lines), that references the same core
assemblies the CLI does and exposes them over a Unix-domain socket (JSON-RPC or plain HTTP
+ SSE for progress). The Swift app bundles the published host inside `Libation.app/Contents/
MacOS/`, launches it on start, and talks to it with `URLSession`/`Network.framework`.

Endpoints map directly onto what `LibationUiBase` already does:
`library/list`, `library/search`, `accounts/*`, `login/external/{start,complete}`, `scan`,
`queue/{add,cancel,status}` (events from `ProcessQueueViewModel` → SSE), `settings/{get,set}`,
`book/{details,records,tags,status}`.

- ✅ Real progress events, cancellation, one warm process, full feature parity possible.
- ✅ Upstream core untouched — only an additive project, so upstream merges stay clean.
- ✅ The host is reusable for other front ends (a menu-bar agent, Shortcuts, etc.).
- ❌ Two runtimes in one bundle (~70 MB for a self-contained .NET publish); need to manage the
  child-process lifecycle and codesign/notarize both.

### C. NativeAOT static library + C interop
Compile the core to a `.dylib` with `UnmanagedCallersOnly` exports and call it from Swift.
EF Core, Lucene.NET and `AudibleApi` are reflection-heavy and not AOT-clean; expect a long
tail of trimming failures. Not worth it for a desktop app.

## What the Swift app has to cover

From the Avalonia project, grouped by priority:

**Must-have (v1)**
- Main window: library grid (`ProductsDisplay`, ~1.1k lines incl. VM) with sort, column choice,
  the "liberate status" button per row, series grouping (`SeriesViewGrid`), cover thumbnails,
  context menu (`GridContextMenu`), quick-filter chips, search box with Lucene syntax.
- Process queue side panel (`ProcessQueueControl` / `ProcessBookControl`) with per-book progress.
- Accounts + login (`AccountsDialog`, `LoginExternalDialog`) — Audible's flow is browser-based;
  `ASWebAuthenticationSession` fits it well and is nicer than the current WebView.
- Settings (`SettingsDialog` + 5 tabbed panels; `Audio.axaml` alone is 444 lines — it is a big surface).
- Book details / tags / records dialogs, trash bin, first-run setup (`SetupDialog`, walkthrough).

**Can wait**
- Theme picker (native app follows system appearance), replacement-chars editor, template
  editor (`EditTemplateDialog` needs the naming-template engine — do it via the host),
  Audiobookshelf upload, find-better-quality, locate-audiobooks, upgrade notifier (Sparkle instead).

Ballpark: ~8–10k lines of Swift/SwiftUI plus ~1.5k of C# for the host. `LibationUiBase`'s
view-models (`GridEntry`, `ProcessBookViewModel`, status icon generator) are the spec for the
Swift view-models — port their behaviour, not their code.

## Environment notes

- Repo pins **.NET 10 SDK** (`global.json`). This Mac has .NET 8 in `~/.dotnet`; install 10 first.
- Build the existing Mac app to have a reference: `dotnet build Source/LibationAvalonia`.
- `dotnet run Scripts/seed-demo-library.cs` fills the DB with fake books — use it to develop the
  grid without an Audible account.
- Xcode / Swift target: macOS 14+, SwiftUI with `NSViewRepresentable` only where needed
  (`NSTableView` is still the better choice for a 1000+ row sortable grid with inline icons).

## Suggested first milestone

1. Install .NET 10, build and run `LibationAvalonia` and `LibationCli`, seed the demo library.
2. `Source/LibationHost`: list library + SSE queue events + scan + liberate. Prove it against the CLI.
3. `Source/LibationMac` (Swift package, Xcode project): main window with the grid, search,
   queue panel, and liberate. Nothing else.
4. Then accounts/login, then settings, then the dialogs.
