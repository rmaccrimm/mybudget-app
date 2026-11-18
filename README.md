# MyBudget macOS app

The native macOS client for the MyBudget server. It talks to the server over HTTP, using the same API a future web client will use (`../spec/SPEC.md`).

The app is outside the adversarial loop: neither agent can write here.

## Stack

The priorities are fast startup and first-class macOS support.

| Layer | Choice |
| --- | --- |
| Language | Swift 6 (language mode 6, strict concurrency) |
| UI | SwiftUI; AppKit through `NSViewRepresentable` only where SwiftUI falls short |
| Minimum macOS | 15.0 (built with the Xcode 26 SDK) |
| State | Observation (`@Observable`) |
| Networking | `URLSession` + `Codable`, async/await |
| Local storage | None: the server owns the data |
| Project | Plain Xcode project; `MyBudget/` is a folder-synced group, so new files need no `project.pbxproj` edits |
| Dependencies | None |

Ruled out: Tauri and Electron (web view startup, not native), Flutter, Compose Multiplatform and Catalyst (not native AppKit/SwiftUI), and pure AppKit (no faster to launch, much slower to write).

Keep launch cheap: at launch the app starts the server and shows the window, nothing else. Avoid third-party packages, since each framework loaded adds launch time. Check launch time with Instruments' App Launch template.

## How the app runs the server

The server ships inside the app, at `MyBudget.app/Contents/MacOS/mybudget-server`.

- **Build:** the "Build and Embed Server" build phase runs `scripts/embed-server.sh`. It builds `../server` with cargo for each architecture in `ARCHS`, debug or release to match the Xcode configuration. It joins them with `lipo` and signs the result with `Config/Server.entitlements`, so the server inherits the app's sandbox. Cargo's output goes in Xcode's build folder, never in `server/target`.
- **Launch:** `ServerProcess` starts the server with `MYBUDGET_ADDR=127.0.0.1:0` (SPEC 1.2). It reads the `listening on <ip>:<port>` line (SPEC 1.3) for the base URL, then checks `GET /health`. The window opens immediately and shows "Starting server…" until then.
- **Data:** `MYBUDGET_DATA` points at `Application Support/MyBudget` in the app's container. The server only uses it once SPEC section 15 (persistence) is built; until then each launch starts empty.
- **Quit:** the server is stopped when the app quits. The app also sets `MYBUDGET_EXIT_ON_STDIN_EOF=1` and holds the only write end of the server's stdin. Once the server implements SPEC 1.4, it exits whenever the app dies, even in a crash.
- **Reading stdout:** `ServerProcess` reads the server's stdout with `FileHandle.readabilityHandler` and keeps discarding it after the first line. Don't change this to `FileHandle.bytes`: its blocking `read` holds a Swift concurrency thread for the whole life of the server, and it hung the hosted tests.

The app is sandboxed (`Config/MyBudget.entitlements`), with network client access to reach the server and network server access so the server can listen. It's signed to run locally; set a team in Xcode to distribute it.

## Building and running

Requires Xcode 26 and a Rust toolchain in `~/.cargo/bin`. A Release build for both architectures also needs `rustup target add x86_64-apple-darwin`.

Open `MyBudget.xcodeproj` in Xcode and run the `MyBudget` scheme, or from the command line:

```sh
xcodebuild -project MyBudget.xcodeproj -scheme MyBudget -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/MyBudget.app
```

Run the tests with ⌘U in Xcode, or:

```sh
xcodebuild test -project MyBudget.xcodeproj -scheme MyBudget -derivedDataPath build
```

`MyBudgetTests` uses Swift Testing and runs inside the app. The tests start the bundled server, so they cover the build phase, signing and sandbox as well as the client. When the app only hosts the tests, it doesn't start a server of its own.

The app logs to the unified log under subsystem `local.mybudget.MyBudget`:

```sh
log show --last 5m --info --predicate 'subsystem == "local.mybudget.MyBudget"'
```

## The window

- **Plan chooser:** at launch the window lists the plans. Double-click one or press Open; New Plan… names a plan and picks its currency. The app reopens the last plan at the next launch. File ▸ Switch Plan changes plans, and File ▸ All Plans… (⇧⌘O) goes back to the chooser.
- **Sidebar:** All Accounts, then the accounts in collapsible groups (Cash, Credit, Tracking, Closed), each with its total. Empty groups are hidden, and a group's expanded state is remembered. Accounts are in the server's order, oldest first.
- **Add Account** (at the bottom of the sidebar, or File ▸ New Account…, ⇧⌘N) asks for a name, type, balance, date and note. For credit cards, lines of credit and liabilities it asks for the amount owed and sends it negated.
- **Right-click an account** to edit its name and note, close or reopen it, or delete it. The server only closes an account with a zero balance (SPEC 5.8), so Close Account is disabled until then, and only deletes one with no transactions (SPEC 5.9).
- **Detail:** a placeholder until the transaction register is built.

Until the server keeps its data (SPEC section 15), every launch starts empty. To look at the UI with data, launch a Debug build with `MYBUDGET_SAMPLE_DATA=1`, which adds and opens a sample plan:

```sh
open --env MYBUDGET_SAMPLE_DATA=1 build/Build/Products/Debug/MyBudget.app
```

## Layout

| Path | What |
| --- | --- |
| `MyBudget/MyBudgetApp.swift` | App entry point; the app delegate owns the server's lifetime |
| `MyBudget/ServerProcess.swift` | Starts the bundled server and reads its address |
| `MyBudget/APIClient.swift` | Typed client for the HTTP API |
| `MyBudget/AppModel.swift` | Observable app state: the server, the plans and the open plan |
| `MyBudget/PlanModel.swift` | The open plan's accounts; changes go to the server first |
| `MyBudget/Account.swift` | Account types, sidebar groups and request bodies (SPEC section 5) |
| `MyBudget/Money.swift` | Formats and parses amounts in milliunits (SPEC 3.7) |
| `MyBudget/ContentView.swift` | The window: server state, then the plan chooser or the open plan |
| `MyBudget/PlanChooser.swift` | Lists plans to open, and the New Plan sheet |
| `MyBudget/PlanView.swift` | The open plan's split view, and the File menu commands |
| `MyBudget/AccountSidebar.swift` | Accounts in collapsible Cash, Credit, Tracking and Closed groups |
| `MyBudget/AccountSheets.swift` | The Add Account and Edit Account sheets |
| `MyBudgetTests/` | Unit and integration tests (Swift Testing) |
| `Config/` | Entitlements for the app and the bundled server |
| `scripts/embed-server.sh` | The build phase that builds and embeds the server |

## Known gaps

- An account with a non-zero balance can't be closed. YNAB offers to add a balancing transaction first; that waits for the transaction register.
- Accounts can't be reordered; the sidebar follows the server's order.
