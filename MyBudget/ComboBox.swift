import AppKit
import SwiftUI

/// A text field with a list of suggestions that completes what's typed, as
/// `NSComboBox` does. SwiftUI has no control for this on macOS.
struct ComboBox: NSViewRepresentable {
    @Binding var text: String
    var items: [String]
    var placeholder: String = ""
    /// Changing this puts the cursor in the box. SwiftUI's focus state
    /// doesn't reach an AppKit view.
    var focusRequest = 0

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true
        box.numberOfVisibleItems = 12
        box.placeholderString = placeholder
        box.delegate = context.coordinator
        box.addItems(withObjectValues: items)
        box.stringValue = text
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            box.stringValue = text
            box.window?.makeFirstResponder(box)
        }
        if box.objectValues as? [String] != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text, box.currentEditor() == nil {
            box.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusRequest: focusRequest)
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>
        var focusRequest: Int

        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.focusRequest = focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        /// The box's text changes only after this, so read the item itself.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox,
                  box.indexOfSelectedItem >= 0,
                  let item = box.objectValueOfSelectedItem as? String
            else { return }
            text.wrappedValue = item
        }
    }
}
