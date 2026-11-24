import SwiftUI

/// What the category sheet is for: a new category, optionally in a group, or
/// an existing one.
enum CategoryEditor: Identifiable {
    case add(defaultGroup: CategoryGroup.ID?)
    case edit(Category)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let category): category.id
        }
    }
}

/// Adds a category to a group, or edits its name, note and group (SPEC 7.5,
/// 7.6). A new group can be created in either case.
struct CategorySheet: View {
    let plan: PlanModel
    let editor: CategoryEditor

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note: String
    /// `nil` means a new group, named in `newGroupName`.
    @State private var groupID: CategoryGroup.ID?
    @State private var newGroupName = ""
    @State private var saving = false
    @State private var error: String?

    init(plan: PlanModel, editor: CategoryEditor) {
        self.plan = plan
        self.editor = editor
        switch editor {
        case .add(let defaultGroup):
            _name = State(initialValue: "")
            _note = State(initialValue: "")
            _groupID = State(initialValue: defaultGroup ?? plan.userCategoryGroups.first?.id)
        case .edit(let category):
            _name = State(initialValue: category.name)
            _note = State(initialValue: category.note ?? "")
            _groupID = State(initialValue: category.groupId)
        }
    }

    private var editing: Category? {
        if case .edit(let category) = editor { category } else { nil }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedGroupName: String { newGroupName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !trimmedName.isEmpty && (groupID != nil || !trimmedGroupName.isEmpty) && !saving
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Note", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text(editing == nil ? "New Category" : "Edit Category").font(.headline)
            }

            Section {
                Picker("Group", selection: $groupID) {
                    ForEach(plan.userCategoryGroups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                    Divider()
                    Text("New Group…").tag(CategoryGroup.ID?.none)
                }
                if groupID == nil {
                    TextField("New Group Name", text: $newGroupName)
                }
            } footer: {
                Text(editing == nil
                     ? "The category goes at the end of its group."
                     : "Moving a category puts it at the end of its new group.")
                    .foregroundStyle(.secondary)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
    }

    private func save() {
        let group: CategoryGroupChoice = groupID.map { .existing($0) } ?? .new(trimmedGroupName)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        error = nil
        Task {
            do {
                try await plan.saveCategory(
                    editing,
                    name: trimmedName,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    group: group
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

/// Removes a category. A category in use needs a category to move its
/// transactions to; the assigned money of every month moves there too
/// (SPEC 13.2, 13.3). An unused one can also drop its money into Ready to
/// Assign.
struct DeleteCategorySheet: View {
    let plan: PlanModel
    let category: Category

    @Environment(\.dismiss) private var dismiss
    @State private var replacement: Category.ID?
    @State private var deleting = false
    @State private var error: String?

    init(plan: PlanModel, category: Category) {
        self.plan = plan
        self.category = category
        let others = Self.otherCategories(plan: plan, excluding: category)
        _replacement = State(initialValue: plan.isInUse(category.id) ? others.first?.id : nil)
    }

    private static func otherCategories(plan: PlanModel, excluding category: Category) -> [Category] {
        plan.userCategoryGroups.flatMap(\.categories).filter { $0.id != category.id }
    }

    private var inUse: Bool { plan.isInUse(category.id) }
    private var others: [Category] { Self.otherCategories(plan: plan, excluding: category) }

    /// A category in use must move to another; an unused one may drop its money.
    private var canDelete: Bool {
        !deleting && (!inUse || replacement != nil)
    }

    private var replacementName: String {
        replacement.flatMap { plan.categoriesByID[$0]?.name } ?? ""
    }

    var body: some View {
        Form {
            Section {
                if others.isEmpty && inUse {
                    Text("Transactions use this category, and there's no other category to move them to. Create another category first.")
                        .foregroundStyle(.red)
                } else {
                    Picker("Move to", selection: $replacement) {
                        if !inUse {
                            Text("No Category (money returns to Ready to Assign)").tag(Category.ID?.none)
                        }
                        ForEach(others) { other in
                            Text(other.name).tag(Optional(other.id))
                        }
                    }
                }
            } header: {
                Text("Delete \(category.name)").font(.headline)
            } footer: {
                Text(footer).foregroundStyle(.secondary)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(deleting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Delete", role: .destructive, action: delete)
                    .disabled(!canDelete)
            }
        }
    }

    private var footer: String {
        if replacement != nil, !replacementName.isEmpty {
            return "Its transactions and its assigned money in every month move to \(replacementName)."
        }
        if inUse {
            return "Choose a category to move the transactions to."
        }
        return "Its assigned money in every month returns to Ready to Assign."
    }

    private func delete() {
        deleting = true
        error = nil
        Task {
            do {
                try await plan.deleteCategory(category, replacement: replacement)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                deleting = false
            }
        }
    }
}
