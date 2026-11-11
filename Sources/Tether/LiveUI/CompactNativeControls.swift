import AppKit
import SwiftUI

struct PopupChoice<Value: Hashable>: Equatable {
    let value: Value
    let title: String
    var enabled = true
    init(_ value: Value, _ title: String, enabled: Bool = true) {
        self.value = value; self.title = title; self.enabled = enabled
    }
}

/// Standard AppKit popup; SwiftUI owns the value and native AppKit owns the bezel.
struct CompactPopUp<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [PopupChoice<Value>]
    var identifier = ""
    @State private var textBaseline: CGFloat?

    init(title: String, selection: Binding<Value>, choices: [PopupChoice<Value>], identifier: String = "") {
        self.title = title; self._selection = selection; self.choices = choices; self.identifier = identifier
    }

    var body: some View {
        NativePopUp(title: title, selection: $selection, choices: choices, identifier: identifier,
                    textBaseline: $textBaseline)
            .alignmentGuide(.firstTextBaseline) { textBaseline ?? $0[.firstTextBaseline] }
            .alignmentGuide(.lastTextBaseline) { textBaseline ?? $0[.lastTextBaseline] }
    }
}

private struct NativePopUp<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let choices: [PopupChoice<Value>]
    let identifier: String
    @Binding var textBaseline: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tetherSettingsStyle) private var settingsStyle

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: settingsStyle ? TetherTypography.settingsBodySize : TetherTypography.bodySize)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let fontSize = settingsStyle ? TetherTypography.settingsBodySize : TetherTypography.bodySize
        if button.font?.pointSize != fontSize { button.font = .systemFont(ofSize: fontSize) }
        if context.coordinator.renderedChoices != choices {
            button.removeAllItems()
            for (index, choice) in choices.enumerated() {
                button.addItem(withTitle: choice.title)
                button.item(at: index)?.isEnabled = choice.enabled
            }
            button.menu?.autoenablesItems = false
            context.coordinator.renderedChoices = choices
        }
        let selectedIndex = choices.firstIndex { $0.value == selection } ?? -1
        if button.indexOfSelectedItem != selectedIndex { button.selectItem(at: selectedIndex) }
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        button.setAccessibilityLabel(title)
        if !identifier.isEmpty { button.setAccessibilityIdentifier(identifier) }
        // NSViewRepresentable does not expose the cell's text baseline to its
        // SwiftUI parent. Read AppKit's laid-out baseline after this update,
        // rather than aligning the label with the wrapper's frame edge.
        DispatchQueue.main.async { [weak button, weak coordinator = context.coordinator] in
            guard let button, let coordinator, button.bounds.height > 0 else { return }
            // AppKit expresses this offset from its alignment rect, which can
            // exclude bezel ornamentation; SwiftUI needs the frame coordinate.
            let baseline = button.alignmentRectInsets.top + button.firstBaselineOffsetFromTop
            if coordinator.parent.textBaseline != baseline { coordinator.parent.textBaseline = baseline }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let nativeWidth = nsView.intrinsicContentSize.width
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? nativeWidth
        // Preserve the same readable minimum in the menu and settings.
        // ViewThatFits can then stack the row when its controls do not fit.
        return CGSize(width: max(width, nativeWidth), height: nsView.intrinsicContentSize.height)
    }
    final class Coordinator: NSObject {
        var parent: NativePopUp
        var renderedChoices: [PopupChoice<Value>] = []
        init(_ parent: NativePopUp) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.isEnabled, parent.choices.indices.contains(index), parent.choices[index].enabled else { return }
            parent.selection = parent.choices[index].value
        }
    }
}

/// A real macOS push button. Only a prominent enabled button gets the Return role.
struct CompactPushButton: View {
    let title: String
    var prominent = false
    var identifier = ""
    let action: () -> Void
    @State private var textBaseline: CGFloat?

    init(_ title: String, prominent: Bool = false, identifier: String = "", action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.identifier = identifier; self.action = action
    }

    var body: some View {
        NativePushButton(title: title, prominent: prominent, identifier: identifier,
                         action: action, textBaseline: $textBaseline)
            .alignmentGuide(.firstTextBaseline) { textBaseline ?? $0[.firstTextBaseline] }
            .alignmentGuide(.lastTextBaseline) { textBaseline ?? $0[.lastTextBaseline] }
    }
}

private struct NativePushButton: NSViewRepresentable {
    let title: String
    let prominent: Bool
    let identifier: String
    let action: () -> Void
    @Binding var textBaseline: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tetherSettingsStyle) private var settingsStyle

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.controlSize = .regular
        button.font = .systemFont(ofSize: settingsStyle ? TetherTypography.settingsBodySize : TetherTypography.bodySize)
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        let fontSize = settingsStyle ? TetherTypography.settingsBodySize : TetherTypography.bodySize
        if button.font?.pointSize != fontSize { button.font = .systemFont(ofSize: fontSize) }
        if button.title != title { button.title = title }
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        let shortcut = prominent && isEnabled ? "\r" : ""
        if button.keyEquivalent != shortcut {
            button.keyEquivalent = shortcut
            button.keyEquivalentModifierMask = []
        }
        button.setAccessibilityLabel(title)
        if !identifier.isEmpty { button.setAccessibilityIdentifier(identifier) }
        DispatchQueue.main.async { [weak button, weak coordinator = context.coordinator] in
            guard let button, let coordinator, button.bounds.height > 0 else { return }
            let baseline = button.alignmentRectInsets.top + button.firstBaselineOffsetFromTop
            if coordinator.parent.textBaseline != baseline { coordinator.parent.textBaseline = baseline }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    final class Coordinator: NSObject {
        var parent: NativePushButton
        init(_ parent: NativePushButton) { self.parent = parent }
        @objc func clicked(_ sender: NSButton) { if parent.isEnabled { parent.action() } }
    }
}

struct CompactMenuAction {
    let title: String
    let separatorBefore: Bool
    let enabled: Bool
    let action: () -> Void
    init(_ title: String, separatorBefore: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.separatorBefore = separatorBefore; self.enabled = enabled; self.action = action
    }
}

/// A compact standard action menu; SwiftUI owns every action and model value.
struct CompactActionMenu: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tetherSettingsStyle) private var settingsStyle
    let title: String
    let actions: [CompactMenuAction]
    var identifier = ""
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: settingsStyle ? TetherTypography.settingsBodySize : TetherTypography.bodySize)
        button.bezelStyle = .rounded
        button.isBordered = false
        button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.preferredEdge = .maxY
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.enabled = isEnabled
        let fontSize = settingsStyle ? TetherTypography.settingsBodySize : TetherTypography.bodySize
        if button.font?.pointSize != fontSize { button.font = .systemFont(ofSize: fontSize) }
        button.isEnabled = isEnabled
        let titles = actions.map(\.title)
        if context.coordinator.titles != titles {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let face = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            face.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: title)
            menu.addItem(face)
            for (index, entry) in actions.enumerated() {
                if entry.separatorBefore { menu.addItem(.separator()) }
                let item = NSMenuItem(title: entry.title, action: #selector(Coordinator.performMenuAction(_:)), keyEquivalent: "")
                item.target = context.coordinator; item.tag = index
                menu.addItem(item)
            }
            button.menu = menu
            context.coordinator.titles = titles
        }
        for item in button.menu?.items ?? [] where item.action != nil {
            if actions.indices.contains(item.tag) { item.isEnabled = actions[item.tag].enabled }
        }
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: 28, height: max(24, nsView.intrinsicContentSize.height))
    }
    final class Coordinator: NSObject {
        var actions: [CompactMenuAction] = []
        var enabled = true
        var titles: [String] = []
        @objc func performMenuAction(_ sender: NSMenuItem) {
            guard enabled, actions.indices.contains(sender.tag), actions[sender.tag].enabled else { return }
            actions[sender.tag].action()
        }
    }
}
