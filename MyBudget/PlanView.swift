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
    @State private var editor: TransactionEditor?

    var body: some View {
        NavigationSplitView {
            AccountSidebar(plan: plan, selection: $selection, addingAccount: $addingAccount)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            RegisterView(plan: plan, accountID: selectedAccountID, editor: $editor)
        }
        .navigationTitle(plan.plan.name)
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $addingAccount) {
            AddAccountSheet(plan: plan) { account in
                selection = .account(account.id)
            }
        }
        .sheet(item: $editor) { editor in
            TransactionSheet(plan: plan, editor: editor)
        }
        .focusedSceneValue(\.newAccount, PlanAction { addingAccount = true })
        .focusedSceneValue(
            \.newTransaction,
            plan.accounts.isEmpty ? nil : PlanAction { editor = .add(selectedAccountID) }
        )
        .onChange(of: plan.accounts) {
            // The selected account was deleted.
            if case .account(let id) = selection, plan.account(id: id) == nil {
                selection = .allAccounts
            }
        }
    }

    private var selectedAccountID: Account.ID? {
        if case .account(let id) = selection { id } else { nil }
    }

    private var subtitle: String {
        switch selection {
        case .account(let id): plan.account(id: id)?.name ?? ""
        case .allAccounts, nil: "All Accounts"
        }
    }
}

/// Lets a menu bar command, such as New Account, reach the focused window.
struct PlanAction {
    let perform: @MainActor () -> Void
    @MainActor func callAsFunction() { perform() }
}

extension FocusedValues {
    @Entry var newAccount: PlanAction?
    @Entry var newTransaction: PlanAction?
}

/// File menu commands: add a transaction or an account, switch plans, or go
/// back to the plan chooser.
struct PlanCommands: Commands {
    let app: AppModel
    @FocusedValue(\.newAccount) private var newAccount
    @FocusedValue(\.newTransaction) private var newTransaction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Transaction…") { newTransaction?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newTransaction == nil)

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
