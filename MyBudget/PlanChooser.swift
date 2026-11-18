import SwiftUI

/// Lists the plans to open one, like a document app's open panel.
struct PlanChooser: View {
    let model: AppModel
    @State private var selection: Plan.ID?
    @State private var creatingPlan = false
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.plans.isEmpty {
                ContentUnavailableView {
                    Label("No Plans", systemImage: "book.closed")
                } description: {
                    Text("A plan holds one budget: its accounts, categories and transactions.")
                } actions: {
                    Button("New Plan…") { creatingPlan = true }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Choose a Plan")
                    .font(.title2.bold())

                List(model.plans, selection: $selection) { plan in
                    HStack {
                        Label(plan.name, systemImage: "book.closed")
                        Spacer()
                        Text(plan.currencyCode).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .contextMenu(forSelectionType: Plan.ID.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()

                HStack {
                    Button("New Plan…") { creatingPlan = true }
                    Spacer()
                    Button("Open") { selection.map(open) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 520, maxHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("MyBudget")
        .onAppear { selection = selection ?? model.plans.first?.id }
        .sheet(isPresented: $creatingPlan) {
            NewPlanSheet(model: model) { plan in open(plan.id) }
        }
        .alert(
            "Couldn't Open the Plan",
            isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })
        ) {
        } message: {
            Text(openError ?? "")
        }
    }

    private func open(_ id: Plan.ID) {
        guard let plan = model.plans.first(where: { $0.id == id }) else { return }
        Task {
            do {
                try await model.open(plan)
            } catch {
                openError = error.localizedDescription
            }
        }
    }
}

/// Names a new plan and picks its currency (SPEC 4.1).
struct NewPlanSheet: View {
    let model: AppModel
    var onCreated: (Plan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var currencyCode = Locale.current.currency?.identifier ?? "USD"
    @State private var saving = false
    @State private var error: String?

    private static let currencies: [(code: String, name: String)] =
        Locale.commonISOCurrencyCodes
            .map { ($0, Locale.current.localizedString(forCurrencyCode: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Household"))
                Picker("Currency", selection: $currencyCode) {
                    ForEach(Self.currencies, id: \.code) { currency in
                        Text("\(currency.name) (\(currency.code))").tag(currency.code)
                    }
                }
            } header: {
                Text("New Plan").font(.headline)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: create)
                    .disabled(!NameRule.isValid(name) || saving)
            }
        }
    }

    private func create() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let plan = try await model.createPlan(name: name, currencyCode: currencyCode)
                dismiss()
                onCreated(plan)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
