import SwiftUI

/// The plan's accounts in collapsible groups, with an Add Account button at
/// the bottom, like Reminders' Add List.
struct AccountSidebar: View {
    let plan: PlanModel
    @Binding var selection: SidebarItem?
    @Binding var addingAccount: Bool

    @AppStorage("Sidebar.CashExpanded") private var cashExpanded = true
    @AppStorage("Sidebar.CreditExpanded") private var creditExpanded = true
    @AppStorage("Sidebar.TrackingExpanded") private var trackingExpanded = true
    @AppStorage("Sidebar.ClosedExpanded") private var closedExpanded = false

    @State private var editing: Account?
    @State private var deleting: Account?
    @State private var actionError: ActionError?

    var body: some View {
        List(selection: $selection) {
            Label("All Accounts", systemImage: "tray.full")
                .tag(SidebarItem.allAccounts)

            ForEach(AccountGroup.grouped(plan.accounts), id: \.group) { group, accounts in
                Section(isExpanded: isExpanded(group)) {
                    ForEach(accounts) { account in
                        AccountRow(account: account, currencyCode: plan.currencyCode)
                            .tag(SidebarItem.account(account.id))
                            .contextMenu { menu(for: account) }
                    }
                } header: {
                    GroupHeader(group: group, accounts: accounts, currencyCode: plan.currencyCode)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                addingAccount = true
            } label: {
                Label("Add Account", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { account in
            EditAccountSheet(plan: plan, account: account)
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { account in
            Button("Delete", role: .destructive) {
                run("Couldn't Delete “\(account.name)”") { try await plan.delete(account) }
            }
        } message: { _ in
            Text("Only an account with no transactions, including a starting balance, can be deleted. To keep an account's history, close it instead.")
        }
        .alert(
            actionError?.title ?? "",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
        } message: { error in
            Text(error.message)
        }
    }

    @ViewBuilder
    private func menu(for account: Account) -> some View {
        Button("Edit Account…") { editing = account }
        Divider()
        if account.closed {
            Button("Reopen Account") {
                run("Couldn't Reopen “\(account.name)”") {
                    try await plan.update(account, AccountPatch(closed: false))
                }
            }
        } else {
            // SPEC 5.8: only an account with a zero balance can be closed.
            Button("Close Account") {
                run("Couldn't Close “\(account.name)”") {
                    try await plan.update(account, AccountPatch(closed: true))
                }
            }
            .disabled(account.balance != 0)
        }
        Button("Delete Account…", role: .destructive) { deleting = account }
    }

    private func run(_ failureTitle: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                actionError = ActionError(title: failureTitle, message: error.localizedDescription)
            }
        }
    }

    private func isExpanded(_ group: AccountGroup) -> Binding<Bool> {
        switch group {
        case .cash: $cashExpanded
        case .credit: $creditExpanded
        case .tracking: $trackingExpanded
        case .closed: $closedExpanded
        }
    }
}

private struct ActionError {
    let title: String
    let message: String
}

private struct GroupHeader: View {
    let group: AccountGroup
    let accounts: [Account]
    let currencyCode: String

    /// The sidebar shows a collapse chevron at the trailing edge of a hovered
    /// header and narrows the header to fit it. Keeping that space free when
    /// it isn't hovered stops the total from jumping.
    @State private var hovering = false
    private static let chevronWidth: CGFloat = 23

    var body: some View {
        HStack {
            Text(group.title)
            Spacer()
            Text(summary)
                .monospacedDigit()
                .padding(.trailing, hovering ? 0 : Self.chevronWidth)
        }
        .onHover { hovering = $0 }
    }

    /// A closed account's balance is 0 when it's closed, so the Closed group
    /// counts its accounts instead.
    private var summary: String {
        group == .closed
            ? "\(accounts.count)"
            : Money.format(accounts.reduce(0) { $0 + $1.balance }, currencyCode: currencyCode)
    }
}

private struct AccountRow: View {
    let account: Account
    let currencyCode: String

    var body: some View {
        HStack {
            Label(account.name, systemImage: account.type.systemImage)
                .lineLimit(1)
            Spacer()
            Text(Money.format(account.balance, currencyCode: currencyCode))
                .monospacedDigit()
                .foregroundStyle(account.balance < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(account.closed ? .secondary : .primary)
        .help(account.note ?? "")
    }
}
