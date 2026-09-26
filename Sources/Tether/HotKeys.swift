import AppKit
import Carbon.HIToolbox
import TetherCore

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility
/// or Input Monitoring permission (unlike an event tap).
@MainActor
final class HotKeys {
    enum Action: String, CaseIterable, Codable {
        case sleepNow, toggle, blank

        fileprivate var id: UInt32 {
            switch self {
            case .sleepNow: 1
            case .toggle: 2
            case .blank: 3
            }
        }

        /// ⌃⌥⌘ plus a letter: free in macOS and in common apps.
        var defaultCombo: KeyCombo {
            let modifiers = KeyCombo.control | KeyCombo.option | KeyCombo.command
            switch self {
            case .sleepNow: return KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: modifiers)
            case .toggle: return KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: modifiers)
            case .blank: return KeyCombo(keyCode: UInt32(kVK_ANSI_B), modifiers: modifiers)
            }
        }

        var title: String {
            switch self {
            case .sleepNow: L("Sleep now", "지금 잠자기")
            case .toggle: L("Turn Tether on/off", "Tether 켜기/끄기")
            case .blank: L("Screen off", "화면 끄기")
            }
        }
    }

    private nonisolated static let signature: OSType = 0x5454_4852  // 'TTHR'

    private let perform: (Action) -> Void
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    /// Shortcuts another app already owns.
    private(set) var unavailable: [Action] = []

    init(perform: @escaping (Action) -> Void) {
        self.perform = perform
    }

    /// Registers `combos` (defaults for missing actions), replacing whatever was registered.
    func apply(_ combos: [Action: KeyCombo], enabled: Bool) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        unavailable = []
        guard enabled else { return }
        installHandler()
        for action in Action.allCases {
            let combo = combos[action] ?? action.defaultCombo
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.id)
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                unavailable.append(action)
            }
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeys.signature,
                  let action = Action.allCases.first(where: { $0.id == id.id }) else {
                return OSStatus(eventNotHandledErr)
            }
            let me = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.perform(action) }
            return noErr
        }, 1, &type, context, &handler)
    }
}

extension KeyCombo {
    /// The combination pressed in `event`, labelled from the US layout.
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyCombo.command }
        if flags.contains(.option) { modifiers |= KeyCombo.option }
        if flags.contains(.control) { modifiers |= KeyCombo.control }
        if flags.contains(.shift) { modifiers |= KeyCombo.shift }
        let code = UInt32(event.keyCode)
        self.init(keyCode: code, modifiers: modifiers,
                  key: KeyCombo.keyName(code) ?? event.charactersIgnoringModifiers?.uppercased())
    }
}
