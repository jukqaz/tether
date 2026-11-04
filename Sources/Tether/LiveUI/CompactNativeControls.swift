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

/// Standard AppKit popup: compact neutral bezel, with SwiftUI owning the value.
struct CompactPopUp<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let choices: [PopupChoice<Value>]
    var identifier = ""
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
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
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? nsView.intrinsicContentSize.width
        return CGSize(width: width, height: 22)
    }
    final class Coordinator: NSObject {
        var parent: CompactPopUp
        var renderedChoices: [PopupChoice<Value>] = []
        init(_ parent: CompactPopUp) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.isEnabled, parent.choices.indices.contains(index), parent.choices[index].enabled else { return }
            parent.selection = parent.choices[index].value
        }
    }
}

/// A real macOS push button. Only a prominent enabled button gets the Return role.
struct CompactPushButton: NSViewRepresentable {
    let title: String
    var prominent = false
    var identifier = ""
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, prominent: Bool = false, identifier: String = "", action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.identifier = identifier; self.action = action
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        if button.title != title { button.title = title }
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        let shortcut = prominent && isEnabled ? "\r" : ""
        if button.keyEquivalent != shortcut {
            button.keyEquivalent = shortcut
            button.keyEquivalentModifierMask = []
        }
        button.setAccessibilityLabel(title)
        if !identifier.isEmpty { button.setAccessibilityIdentifier(identifier) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        return CGSize(width: nsView.intrinsicContentSize.width, height: 22)
    }
    final class Coordinator: NSObject {
        var parent: CompactPushButton
        init(_ parent: CompactPushButton) { self.parent = parent }
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
    let title: String
    let actions: [CompactMenuAction]
    var identifier = ""
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? { CGSize(width: 26, height: 22) }
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
