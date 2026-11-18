import SwiftUI

struct ContentView: View {
    let model: AppModel
    @State private var newPlanName = ""

    var body: some View {
        VStack(spacing: 0) {
            List(model.plans) { plan in
                LabeledContent(plan.name, value: plan.currencyCode)
            }
            .overlay {
                if model.isConnected && model.plans.isEmpty {
                    ContentUnavailableView(
                        "No Plans",
                        systemImage: "tray",
                        description: Text("Add a plan below to create it on the server.")
                    )
                }
            }

            Divider()

            HStack {
                TextField("New plan name", text: $newPlanName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPlan)
                Button("Add Plan", action: addPlan)
                    .disabled(!canAdd)
            }
            .padding()

            Divider()

            StatusBar(connection: model.connection, lastError: model.lastError)
        }
        .frame(minWidth: 420, minHeight: 320)
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") {
                Task { await model.reload() }
            }
            .keyboardShortcut("r")
            .disabled(!model.isConnected)
        }
    }

    private var canAdd: Bool {
        model.isConnected && !newPlanName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addPlan() {
        guard canAdd else { return }
        let name = newPlanName
        newPlanName = ""
        Task { await model.addPlan(named: name) }
    }
}

private struct StatusBar: View {
    let connection: AppModel.Connection
    let lastError: String?

    var body: some View {
        HStack(spacing: 6) {
            switch connection {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting server…")
            case .connected(let url):
                Image(systemName: "circle.fill").foregroundStyle(.green)
                Text("Connected to \(url.host() ?? "?"):\(url.port.map(String.init) ?? "?")")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Server failed: \(message)")
            }
            Spacer()
            if let lastError {
                Text(lastError).foregroundStyle(.red).lineLimit(1)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

#Preview {
    ContentView(model: AppModel())
}
