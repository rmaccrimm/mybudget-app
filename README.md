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
| Local storage | None in the app: the server keeps each plan in a SQLite file (SPEC section 15) |
| Project | Plain Xcode project; `MyBudget/` is a folder-synced group, so new files need no `project.pbxproj` edits |
| Dependencies | None |

Ruled out: Tauri and Electron (web view startup, not native), Flutter, Compose Multiplatform and Catalyst (not native AppKit/SwiftUI), and pure AppKit (no faster to launch, much slower to write).

Keep launch cheap: at launch the app starts the server and shows the window, nothing else. Avoid third-party packages, since each framework loaded adds launch time. Check launch time with Instruments' App Launch template.

## How the app runs the server

The server ships inside the app, at `MyBudget.app/Contents/MacOS/mybudget-server`.

- **Build:** the "Build and Embed Server" build phase runs `scripts/embed-server.sh`. It builds `../server` with cargo for each architecture in `ARCHS`, debug or release to match the Xcode configuration. It joins them with `lipo` and signs the result with `Config/Server.entitlements`, so the server inherits the app's sandbox. Cargo's output goes in Xcode's build folder, never in `server/target`.
- **Launch:** `ServerProcess` starts the server with `MYBUDGET_ADDR=127.0.0.1:0` (SPEC 1.2). It reads the `listening on <ip>:<port>` line (SPEC 1.3) for the base URL, then checks `GET /health`. The window opens immediately and shows "Starting server…" until then.
- **Data:** `MYBUDGET_DATA` points at `Application Support/MyBudget` in the app's container, `~/Library/Containers/local.mybudget.MyBudget/Data/Library/Application Support/MyBudget/`. The server creates it and keeps one file per plan there, named after the plan, such as `Household.sqlite` (SPEC 15.2). It saves each change before it answers (SPEC 15.5), so the app has nothing to save and nothing to lose in a crash. The server reads the folder only at startup (SPEC 15.11), so quit the app before adding, copying or removing plan files.
- **Stderr:** `ServerProcess` logs each line the server writes to stderr, such as a plan file it skipped at startup (SPEC 15.7). If the server exits before listening, for example because it can't use its data folder (SPEC 15.1), the window shows its message.
- **Quit:** the app sets `MYBUDGET_EXIT_ON_STDIN_EOF=1` and holds the only write end of the server's stdin. On quit it closes stdin, so the server finishes any save in progress and exits (SPEC 1.4), and it sends `SIGTERM` only if the server is still running a second later. The kernel closes the pipe if the app crashes, so the server never outlives it.
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

`MyBudgetTests` uses Swift Testing and runs inside the app. The tests start the bundled server, so they cover the build phase, signing and sandbox as well as the client. When the app only hosts the tests, it doesn't start a server of its own. The tests share the app's container, so each server they start keeps its data in memory or in its own temporary folder, never in the app's saved plans.

The app logs to the unified log under subsystem `local.mybudget.MyBudget`:

```sh
log show --last 5m --info --predicate 'subsystem == "local.mybudget.MyBudget"'
```

## The window

- **Plan chooser:** at launch the window lists the plans. Double-click one or press Open; New Plan… names a plan and picks its currency. The app reopens the last plan at the next launch. File ▸ Switch Plan changes plans, and File ▸ All Plans… (⇧⌘O) goes back to the chooser.
- **Sidebar:** All Accounts, then the accounts in collapsible groups (Cash, Credit, Tracking, Closed), each with its total. Empty groups are hidden, and a group's expanded state is remembered. Accounts are in the server's order, oldest first.
- **Add Account** (at the bottom of the sidebar, or File ▸ New Account…, ⇧⌘N) asks for a name, type, balance, date and note. For credit cards, lines of credit and liabilities it asks for the amount owed and sends it negated.
- **Right-click an account** to edit its name and note, close or reopen it, or delete it. The server only closes an account with a zero balance (SPEC 5.8), so Close Account is disabled until then, and only deletes one with no transactions (SPEC 5.9).
- **Register:** the selected account's transactions, newest first (the server's order, SPEC 8.5, reversed), with Date, Payee, Category, Memo, Outflow, Inflow and a cleared column. Above it are the account's cleared, uncleared and working balances, as the server reports them (SPEC 5.4). All Accounts shows every account's transactions with an Account column. There's no running balance.
- **Add Transaction** (the toolbar's +, or File ▸ New Transaction…, ⌘N) asks for the account, date, payee, category, outflow or inflow, memo, cleared and flag. The payee field completes from the plan's payees. A name it doesn't know creates a payee (SPEC 6.5), and `Transfer : <account>` makes a transfer (SPEC 9.1). A known payee brings the category of its last transaction. Save and Add Another (⌘↩) saves and empties the sheet for the next transaction, keeping the account and date, with the cursor back in Payee. The category is required in budget accounts (SPEC 8.2), not needed in tracking accounts or for a transfer between two budget accounts (SPEC 9.3), and the + beside it creates a category, in a new group if need be.
- **Editing:** double-click a transaction, or press Return, to edit it in the same sheet. The sheet sends only the fields that changed (SPEC 8.6), so an unchanged transfer keeps its other half. Click the cleared column to clear or unclear a transaction. Right-click for Mark as Cleared/Uncleared, Flag and Delete, which act on every selected transaction; the Delete key deletes too, after asking. Deleting a transfer deletes both halves (SPEC 9.6).
- **After a change** the app reloads the accounts, transactions and payees, since a transfer also edits its other half and a payee name may create a payee.

To look at the UI with data without touching your saved plans, launch a Debug build with `MYBUDGET_SAMPLE_DATA=1`. The server then keeps everything in memory, and the app adds and opens a sample plan, which is gone at the next launch:

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
| `MyBudget/PlanModel.swift` | The open plan's accounts, transactions, payees and categories; changes go to the server first |
| `MyBudget/Account.swift` | Account types, sidebar groups and request bodies (SPEC section 5) |
| `MyBudget/Transaction.swift` | Transactions, payees, categories, their request bodies, the category rule and the register's order (SPEC sections 6 to 10) |
| `MyBudget/Money.swift` | Formats and parses amounts in milliunits (SPEC 3.7) |
| `MyBudget/ContentView.swift` | The window: server state, then the plan chooser or the open plan |
| `MyBudget/PlanChooser.swift` | Lists plans to open, and the New Plan sheet |
| `MyBudget/PlanView.swift` | The open plan's split view, and the File menu commands |
| `MyBudget/AccountSidebar.swift` | Accounts in collapsible Cash, Credit, Tracking and Closed groups |
| `MyBudget/AccountSheets.swift` | The Add Account and Edit Account sheets |
| `MyBudget/RegisterView.swift` | An account's transactions, with the balances above them |
| `MyBudget/TransactionSheet.swift` | The Add and Edit Transaction sheet, and New Category |
| `MyBudget/ComboBox.swift` | `NSComboBox` for SwiftUI, for the payee field |
| `MyBudgetTests/` | Unit and integration tests (Swift Testing) |
| `Config/` | Entitlements for the app and the bundled server |
| `scripts/embed-server.sh` | The build phase that builds and embeds the server |

## Known gaps

- An account with a non-zero balance can't be closed. YNAB offers to add a balancing transaction first; that waits for the transaction register.
- Accounts can't be reordered; the sidebar follows the server's order.
- Transactions are entered in a sheet, not in the register row itself as in YNAB.
- Split transactions (SPEC section 10) are shown, as "Split (n)" with the parts in a tooltip, but can't be created, and an existing split's amount and categories can't be changed.
- There's no reconciling yet: a reconciled transaction shows a lock, and the app never sets one.
- The app loads every transaction of the plan at once. The server has no paging, which is fine for years of manual entries but may need it once files are imported.
- Categories can only be created from the transaction sheet, until there's a budget view.
