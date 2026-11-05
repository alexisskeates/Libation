# LibationMac — native macOS front end

A SwiftUI shell over Libation's .NET core. The core runs as a child process, `LibationHost`
(`Source/LibationHost`), a small local HTTP + server-sent-events API over the same
`ApplicationServices` / `FileLiberator` / `LibationUiBase` code the Avalonia and CLI front ends use.
It reads and writes the same LibationFiles folder (`Settings.json`, `LibationContext.db`), so the
three front ends are interchangeable. See `docs/development/native-macos-ui-plan.md` for the why.

## Status (milestone 1)

- Library table with sorting, Lucene search (Libation's own syntax), cover art, liberate-status icons
- Process queue inspector with live progress over SSE; cancel one / cancel all
- Scan, Liberate selected / all pending, core alerts surfaced as native alerts
- Accounts window (⌘⇧A): add / rename / toggle scan / delete; Audible sign-in in a private WKWebView
  (device user-agent, seeded cookies, `/ap/maplanding` capture) with a paste-the-URL fallback
- Not yet: settings editing, book details, series grouping, tags/ratings editing

## Develop

Requires Xcode 15+ and the .NET SDK pinned by `global.json` (install with
`curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0`).

```bash
# 1. build the host once (debug build; the app finds it at Source/bin/Host/Debug)
dotnet build Source/LibationHost/LibationHost.csproj

# 2. run the app against a throwaway copy of your library so nothing real is touched
LIBATION_FILES_DIR=/path/to/dev/LibationFiles swift run --package-path Source/LibationMac
```

The launcher honours `LIBATION_FILES_DIR` like the CLI does. To attach to a host you started
yourself (handy for curl-ing the API while the app runs):

```bash
LIBATION_FILES_DIR=... Source/bin/Host/Debug/LibationHost --port 5231 --token dev
LIBATION_HOST_URL=http://127.0.0.1:5231 LIBATION_HOST_TOKEN=dev swift run --package-path Source/LibationMac
```

Host stderr goes to `~/Library/Logs/Libation/LibationHost.log`; Libation's own log goes wherever
`Settings.json` says.

## API (all under `/api`, bearer token when the host was started with `--token`)

| Method | Path | Notes |
|---|---|---|
| GET | `status` | version, LibationFiles, Books dir, counts |
| GET | `library` · `library/{asin}` | flattened `LibraryBook` rows |
| GET | `search?q=` | Lucene query → ASINs |
| GET | `covers/{pictureId}?size=80\|300\|500` | JPEG, downloads on demand |
| GET / POST | `accounts` | list; add `{accountId, locale, accountName?, libraryScan}` |
| PUT / DELETE | `accounts/{id}/{locale}` | rename / toggle scan; remove |
| POST | `accounts/{id}/{locale}/signin` | tries stored tokens, else asks the UI to sign in; result as `signin` event |
| GET | `locales` | Audible marketplaces |
| GET | `login` · POST `login/{id}/complete` `{responseUrl}` · POST `login/{id}/cancel` | browser sign-in handshake; session arrives as a `login` event |
| POST / GET | `scan` | `{accounts:[...]}` optional; progress via `scan` events |
| GET | `queue` | snapshot |
| POST | `queue/liberate` | `{asins:[...]}` |
| POST | `queue/cancel` · `queue/{asin}/cancel` | |
| GET | `events` | SSE: `hello`, `queue`, `scan`, `library`, `alert`, `log`, `login`, `signin` |
| POST | `shutdown` | |

## Ship

```bash
Source/LibationMac/build.sh           # publishes the host self-contained and bundles it into dist/Libation.app
Source/LibationMac/build.sh install   # ...and copies to /Applications
```
