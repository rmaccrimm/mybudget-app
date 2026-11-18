import SwiftUI

/// The window: the server's state until it's running, then the plan chooser
/// or the open plan.
struct ContentView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.connection {
            case .starting:
                ProgressView("Starting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "The Server Didn't Start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .connected:
                if let plan = model.openPlan {
                    PlanView(plan: plan)
                        .id(plan.plan.id)
                } else {
                    PlanChooser(model: model)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

#Preview {
    ContentView(model: AppModel())
}
