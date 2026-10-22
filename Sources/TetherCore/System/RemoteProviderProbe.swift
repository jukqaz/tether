import Foundation
import AppKit

/// Read-only metadata probe. It does not query private preferences, TCC databases, services,
/// network endpoints or provider accounts, and cannot modify a power/display/lock policy.
public enum RemoteProviderProbe {
    struct BundleMetadata: Equatable, Sendable {
        let bundleID: String
        let version: String
    }
    struct BundleObservation: Equatable, Sendable {
        let metadata: BundleMetadata?
        let running: Bool
        let reason: RemoteObservationReason
    }

    @MainActor public static func capture(displays: DisplayReport? = nil, assertionHints: [SleepBlocker] = [],
                                         generation: UInt64, displayRevision: UInt64, sessionKey: String,
                                         forceUnavailable: Bool = false, now: Date = Date()) -> RemoteInteropContext {
        var bundles: [String: BundleObservation] = [:]
        if !forceUnavailable {
            let workspace = NSWorkspace.shared
            let running = workspace.runningApplications
            for candidate in RemoteSupportCatalog.candidates {
                guard let bundleID = candidate.bundleID else { continue }
                let matching = running.filter { !$0.isTerminated && $0.bundleIdentifier == bundleID }
                var urls = [workspace.urlForApplication(withBundleIdentifier: bundleID), fallbackURL(for: candidate.id)]
                    .compactMap { $0 }
                urls.append(contentsOf: matching.compactMap(\.bundleURL))
                var metadata: BundleMetadata?
                var reason: RemoteObservationReason = .bundleNotObserved
                for url in Array(Set(urls)).sorted(by: { $0.path < $1.path }) {
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    let result = readMetadata(url, expectedBundleID: bundleID)
                    if let found = result.metadata { metadata = found; reason = .observed; break }
                    reason = result.reason
                }
                // A matching running app is only a presence hint. Validate its bundle identity
                // too; do not label an arbitrary process name as an active provider.
                let runningHint = matching.contains { app in
                    !app.isTerminated && app.bundleURL.flatMap { readMetadata($0, expectedBundleID: bundleID).metadata } != nil
                }
                bundles[candidate.id] = .init(metadata: metadata, running: runningHint, reason: reason)
            }
        }
        return resolve(bundles: bundles, displays: displays, assertionHints: assertionHints,
                       generation: generation, displayRevision: displayRevision, sessionKey: sessionKey,
                       osVersion: operatingSystemVersion, forceUnavailable: forceUnavailable, now: now)
    }

    /// Pure preview seam. It never enumerates applications and never assumes a remote connection.
    public static func sample(generation: UInt64, displayRevision: UInt64, sessionKey: String,
                              now: Date = Date()) -> RemoteInteropContext {
        resolve(bundles: ["splashtop-host": .init(metadata: .init(bundleID: "com.splashtop.Splashtop-Streamer", version: "3.8.6.0"),
                                                  running: true, reason: .sampleOnly)],
                generation: generation, displayRevision: displayRevision, sessionKey: sessionKey,
                osVersion: "15.0", simulated: true, now: now)
    }

    static func resolve(bundles: [String: BundleObservation], displays: DisplayReport? = nil,
                        assertionHints: [SleepBlocker] = [], generation: UInt64, displayRevision: UInt64,
                        sessionKey: String, osVersion: String, forceUnavailable: Bool = false,
                        simulated: Bool = false, now: Date) -> RemoteInteropContext {
        let time = now.timeIntervalSince1970
        let providers = RemoteSupportCatalog.candidates.map { catalog -> RemoteProviderState in
            let observation = forceUnavailable ? nil : bundles[catalog.id]
            let metadata = observation?.metadata.flatMap { $0.bundleID == catalog.bundleID ? $0 : nil }
            var hints: [RemoteHint] = []
            if metadata != nil { hints.append(.init(kind: .installedBundle, observedAt: time)) }
            if metadata != nil, observation?.running == true { hints.append(.init(kind: .runningApp, observedAt: time)) }
            if !forceUnavailable, let displays, displays.graphicsAvailable,
               displays.checkedAt.isFinite, displays.checkedAt <= time,
               catalog.id == "splashtop-host", displays.displays.contains(where: { $0.provider == "Splashtop" && $0.kind == .virtual }) {
                hints.append(.init(kind: .virtualDisplay, observedAt: displays.checkedAt))
            }
            // Name attribution is explicitly a hint. Never retain assertion payloads or PID.
            if !forceUnavailable, assertionHints.contains(where: { $0.kind == .display && $0.process == catalog.productName }) {
                hints.append(.init(kind: .displayAssertion, observedAt: time))
            }
            if simulated { hints.append(.init(kind: .previewExample, observedAt: time)) }
            let candidate = RemoteProviderCandidate(id: catalog.id, provider: catalog.provider, role: catalog.role,
                                                    productName: catalog.productName, bundleID: catalog.bundleID, hints: hints)
            let scope = RemoteEvidenceScope(providerID: candidate.id, productName: candidate.productName,
                                            role: candidate.role, bundleID: candidate.bundleID, osVersion: osVersion,
                                            sessionKey: sessionKey, generation: generation, displayRevision: displayRevision,
                                            hostInstalledVersion: candidate.role.canHost ? metadata?.version : nil)
            func unavailable<T: Codable & Equatable & Sendable>(_ reason: RemoteObservationReason, availability: RemoteObservationAvailability = .unavailable) -> RemoteObservation<T> {
                .init(value: nil, availability: availability, reason: reason, source: .unsupported, observedAt: time, scope: scope)
            }
            let metadataReason: RemoteObservationReason = forceUnavailable ? .currentScopeUnavailable
                : observation?.metadata != nil && metadata == nil ? .bundleIdentityMismatch
                : observation?.reason ?? (candidate.bundleID == nil ? .hostServiceUnavailable : .bundleNotObserved)
            let installed: RemoteObservation<String> = metadata.map {
                .init(value: $0.version, availability: .known, reason: simulated ? .sampleOnly : .observed,
                      source: simulated ? .hint : .bundleMetadata, observedAt: time, scope: scope)
            } ?? unavailable(metadataReason)
            return RemoteProviderState(candidate: candidate, scope: scope, localInstalledVersion: installed,
                hostInstalledVersion: candidate.role.canHost ? installed : unavailable(.viewerIsNotHost, availability: .notApplicable),
                runtimeVersion: unavailable(.runtimeVersionUnavailable), clientVersion: unavailable(.clientVersionUnavailable),
                connection: unavailable(forceUnavailable ? .currentScopeUnavailable : candidate.bundleID == nil ? .hostServiceUnavailable : .automaticConnectionUnsupported),
                frameDelivery: unavailable(.frameDeliveryUnmeasured), inputRoundTrip: unavailable(.inputRoundTripUnmeasured),
                authentication: unavailable(.authenticationUnavailable))
        }
        return .init(providers: providers, checkedAt: time, osVersion: osVersion, generation: generation,
                     displayRevision: displayRevision, sessionKey: sessionKey, simulated: simulated)
    }

    static func validatedMetadata(_ dictionary: [String: Any], expectedBundleID: String) -> BundleMetadata? {
        guard let identifier = dictionary["CFBundleIdentifier"] as? String, identifier == expectedBundleID,
              let version = dictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty, version.utf8.count <= 80,
              version == version.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return .init(bundleID: identifier, version: version)
    }

    private static var operatingSystemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    private static func fallbackURL(for id: String) -> URL? {
        let paths = ["splashtop-host": "/Applications/Splashtop Streamer.app", "splashtop-viewer": "/Applications/Splashtop Business.app",
                     "rustdesk": "/Applications/RustDesk.app", "apple-sharing-viewer": "/System/Applications/Utilities/Screen Sharing.app"]
        return paths[id].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    private static func readMetadata(_ bundle: URL, expectedBundleID: String) -> (metadata: BundleMetadata?, reason: RemoteObservationReason) {
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        guard let size = try? info.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262_144,
              let data = try? Data(contentsOf: info), data.count <= 262_144,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return (nil, .bundleMetadataUnavailable) }
        guard dictionary["CFBundleIdentifier"] as? String == expectedBundleID else { return (nil, .bundleIdentityMismatch) }
        guard let metadata = validatedMetadata(dictionary, expectedBundleID: expectedBundleID) else { return (nil, .bundleMetadataUnavailable) }
        return (metadata, .observed)
    }
}
