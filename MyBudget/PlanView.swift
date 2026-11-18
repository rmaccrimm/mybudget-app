import SwiftUI

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case allAccounts
    case account(Account.ID)
}

/// An open plan: accounts in the sidebar, transactions in the detail.
struct PlanView: View {
    let plan: PlanModel

    @State private var selection: SidebarItem? = .allAccounts
    @State private var addingAccount = false

    var body: some View {
        NavigationSplitView {
            AccountSidebar(plan: plan, selection: $selection, addingAccount: $addingAccount)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            TransactionsPlaceholder(plan: plan, selection: selection)
        }
        .navigationTitle(plan.plan.name)
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $addingAccount) {
            AddAccountSheet(plan: plan) { account in
                selection = .account(account.id)
            }
        }
        .focusedSceneValue(\.newAccount, NewAccountAction { addingAccount = true })
        .onChange(of: plan.accounts) {
            // The selected account was deleted.
            if case .account(let id) = selection, plan.account(id: id) == nil {
                selection = .allAccounts
            }
        }
    }

    private var subtitle: String {
        switch selection {
        case .account(let id): plan.account(id: id)?.name ?? ""
        case .allAccounts, nil: "All Accounts"
        }
    }
}

/// Stands in for the transaction register, which isn't built yet.
private struct TransactionsPlaceholder: View {
    let plan: PlanModel
    let selection: SidebarItem?

    var body: some View {
        switch selection {
        case .account(let id):
            if let account = plan.account(id: id) {
                ContentUnavailableView {
                    Label(account.name, systemImage: account.type.systemImage)
                } description: {
                    Text("\(account.type.title) · \(Money.format(account.balance, currencyCode: plan.currencyCode))")
                    Text("Its transactions will appear here.")
                }
            }
        case .allAccounts, nil:
            if plan.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "building.columns")
                } description: {
                    Text("Add the accounts you spend from, save in and owe on.")
                }
            } else {
                ContentUnavailableView(
                    "All Accounts",
                    systemImage: "tray.full",
                    description: Text("Transactions from every account will appear here.")
                )
            }
        }
    }
}

/// Lets the menu bar's New Account command reach the focused window.
struct NewAccountAction {
    let perform: @MainActor () -> Void
    @MainActor func callAsFunction() { perform() }
}

extension FocusedValues {
    @Entry var newAccount: NewAccountAction?
}

/// File menu commands: add an account, switch plans, or go back to the
/// plan chooser.
struct PlanCommands: Commands {
    let app: AppModel
    @FocusedValue(\.newAccount) private var newAccount

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Account…") { newAccount?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(newAccount == nil)

            Divider()

            Menu("Switch Plan") {
                ForEach(app.plans) { plan in
                    Toggle(plan.name, isOn: Binding(
                        get: { app.openPlan?.plan.id == plan.id },
                        set: { _ in Task { try? await app.open(plan) } }
                    ))
                }
            }
            .disabled(app.plans.isEmpty)

            Button("All Plans…") { app.closePlan() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(app.openPlan == nil)
        }
    }
}
