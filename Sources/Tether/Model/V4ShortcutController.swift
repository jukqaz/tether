import TetherCore
import Carbon
import Combine
import Foundation

/// These actions have the same scope from menus, hotkeys and App Intents.
enum V4AutomationAction: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case startManual, endManual, pauseAll, automaticOn, automaticOff, status
    var id: Self { self }
    var title: String {
        switch self {
        case .startManual: L("Start manual work", "수동 시작")
        case .endManual: L("End manual only", "수동만 종료")
        case .pauseAll: L("Pause all", "모두 일시중지")
        case .automaticOn: L("AC automatic on", "AC 자동 켬")
        case .automaticOff: L("AC automatic off", "AC 자동 끔")
        case .status: L("Check status", "상태 확인")
        }
    }
}

struct V4ShortcutChord: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.modifierMask == 0
            && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }
    var title: String {
        let prefix = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
                      (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return prefix + (Self.keys.first { $0.code == keyCode }?.label ?? "[\(keyCode)]")
    }
    // Physical key codes are stable; no keyboard monitoring or input content is retained.
    static let keys: [(code: UInt32, label: String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),
        (38,"J"),(40,"K"),(37,"L"),(46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),
        (15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z")
    ]
}

@MainActor
protocol V4ShortcutRegistering: AnyObject {
    func register(_ chord: V4ShortcutChord, handler: @escaping @MainActor () -> Void) throws -> UUID
    func unregister(_ token: UUID) -> Bool
}

enum V4ShortcutFailure: LocalizedError {
    case invalid, conflict, unavailable, unregisterFailed
    var errorDescription: String? {
        switch self {
        case .invalid: L("Choose Command, Control or Option together with a key.", "키와 함께 Command·Control·Option 중 하나 이상을 선택하세요.")
        case .conflict: L("This shortcut is already assigned. The previous shortcut was kept.", "이미 사용 중인 단축키입니다. 기존 단축키를 보존했습니다.")
        case .unavailable: L("Could not register the shortcut. The previous shortcut was kept.", "단축키를 등록하지 못했습니다. 기존 단축키를 보존했습니다.")
        case .unregisterFailed: L("Could not replace the existing shortcut. It was kept.", "기존 단축키를 바꾸지 못해 그대로 보존했습니다.")
        }
    }
}

/// Replacement registers first, then releases the old key. Failure never overwrites the old choice.
@MainActor
final class V4ShortcutController: ObservableObject {
    static let defaultsKey = "v4GlobalShortcuts"
    @Published private(set) var assignments: [V4AutomationAction: V4ShortcutChord] = [:]
    @Published private(set) var activeActions = Set<V4AutomationAction>()
    @Published private(set) var lastError: String?
    private let registrar: V4ShortcutRegistering
    private let defaults: UserDefaults
    private let perform: @MainActor (V4AutomationAction) -> Void
    private var registrations: [V4AutomationAction: UUID] = [:]
    private var dispatchGenerations: [V4AutomationAction: UUID] = [:]
    private var loaded = false

    private struct Saved: Codable {
        var version = 1
        var entries: [Entry]
        struct Entry: Codable { var action: V4AutomationAction; var chord: V4ShortcutChord }
    }

    init(defaults: UserDefaults, registrar: V4ShortcutRegistering,
         perform: @escaping @MainActor (V4AutomationAction) -> Void) {
        self.defaults = defaults; self.registrar = registrar; self.perform = perform
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        guard data.count <= 16_384, let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == 1, saved.entries.count <= V4AutomationAction.allCases.count,
              Set(saved.entries.map(\.action)).count == saved.entries.count,
              Set(saved.entries.map(\.chord)).count == saved.entries.count,
              saved.entries.allSatisfy({ $0.chord.isValid }) else {
            lastError = L("Saved shortcuts need review. No new key was registered.", "저장된 단축키를 확인해야 합니다. 새 키는 등록하지 않았습니다."); return
        }
        assignments = Dictionary(uniqueKeysWithValues: saved.entries.map { ($0.action, $0.chord) })
    }

    func activateSavedAssignments() {
        guard !loaded else { return }
        loaded = true
        for action in V4AutomationAction.allCases {
            guard registrations[action] == nil, let chord = assignments[action] else { continue }
            do {
                let generation = UUID()
                registrations[action] = try registrar.register(chord) { [weak self] in
                    guard let self, self.dispatchGenerations[action] == generation else { return }
                    self.perform(action)
                }
                dispatchGenerations[action] = generation
                activeActions.insert(action)
            } catch { lastError = error.localizedDescription }
        }
    }

    @discardableResult
    func assign(_ chord: V4ShortcutChord?, to action: V4AutomationAction) -> Bool {
        lastError = nil
        if chord == assignments[action], registrations[action] != nil || chord == nil { return true }
        if let chord, !chord.isValid { lastError = V4ShortcutFailure.invalid.localizedDescription; return false }
        if let chord, assignments.contains(where: { $0.key != action && $0.value == chord }) {
            lastError = V4ShortcutFailure.conflict.localizedDescription; return false
        }
        var replacement: UUID?
        let replacementGeneration = UUID()
        if let chord {
            do {
                replacement = try registrar.register(chord) { [weak self] in
                    guard let self, self.dispatchGenerations[action] == replacementGeneration else { return }
                    self.perform(action)
                }
            } catch { lastError = error.localizedDescription; return false }
        }
        if let old = registrations[action], !registrar.unregister(old) {
            if let replacement { _ = registrar.unregister(replacement) }
            lastError = V4ShortcutFailure.unregisterFailed.localizedDescription; return false
        }
        registrations[action] = replacement
        dispatchGenerations[action] = replacement == nil ? nil : replacementGeneration
        assignments[action] = chord
        if replacement != nil { activeActions.insert(action) } else { activeActions.remove(action) }
        let saved = Saved(entries: V4AutomationAction.allCases.compactMap { action in
            assignments[action].map { Saved.Entry(action: action, chord: $0) }
        })
        guard let data = try? JSONEncoder().encode(saved) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }

    func deactivate() {
        for token in registrations.values { _ = registrar.unregister(token) }
        registrations.removeAll(); dispatchGenerations.removeAll(); activeActions.removeAll(); loaded = false
    }
}

/// Carbon's exclusive registration reports OS conflicts; no event tap or accessibility permission is used.
@MainActor
final class V4CarbonShortcutRegistrar: V4ShortcutRegistering {
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var references: [UUID: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var nativeIDs: [UUID: UInt32] = [:]
    private static let signature: UInt32 = 0x54657434 // Tet4

    func register(_ chord: V4ShortcutChord, handler: @escaping @MainActor () -> Void) throws -> UUID {
        guard chord.isValid else { throw V4ShortcutFailure.invalid }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKey = EventHotKeyID()
                let code = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                             nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                guard code == noErr, hotKey.signature == V4CarbonShortcutRegistrar.signature else { return OSStatus(eventNotHandledErr) }
                // Carbon invokes the application event handler on the main event loop.
                MainActor.assumeIsolated {
                    let registrar = Unmanaged<V4CarbonShortcutRegistrar>.fromOpaque(context).takeUnretainedValue()
                    registrar.handlers[hotKey.id]?()
                }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard result == noErr else { throw V4ShortcutFailure.unavailable }
        }
        let id = nextID; nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.keyCode, chord.modifiers,
            EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            throw status == eventHotKeyExistsErr ? V4ShortcutFailure.conflict : V4ShortcutFailure.unavailable
        }
        let token = UUID()
        references[token] = reference; nativeIDs[token] = id; handlers[id] = handler
        return token
    }

    func unregister(_ token: UUID) -> Bool {
        guard let reference = references[token] else { return true }
        guard UnregisterEventHotKey(reference) == noErr else { return false }
        references.removeValue(forKey: token)
        if let id = nativeIDs.removeValue(forKey: token) { handlers.removeValue(forKey: id) }
        return true
    }

    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Rendering and unit tests cannot register a real global shortcut.
@MainActor
final class V4UnavailableShortcutRegistrar: V4ShortcutRegistering {
    func register(_ chord: V4ShortcutChord, handler: @escaping @MainActor () -> Void) throws -> UUID { throw V4ShortcutFailure.unavailable }
    func unregister(_ token: UUID) -> Bool { true }
}
