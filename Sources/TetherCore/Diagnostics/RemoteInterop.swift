import Foundation

public enum RemoteProvider: String, Codable, Sendable {
    case splashtop, rustDesk, appleScreenSharing

    public var title: String {
        switch self {
        case .splashtop: "Splashtop"
        case .rustDesk: "RustDesk"
        case .appleScreenSharing: L("macOS Screen Sharing", "macOS 화면 공유")
        }
    }
}

public enum RemoteProviderRole: String, Codable, Sendable {
    case host, viewer, hostAndViewer

    public var canHost: Bool { self != .viewer }
    public var title: String {
        switch self {
        case .host: L("Host", "접속받는 쪽")
        case .viewer: L("Viewer", "접속하는 쪽")
        case .hostAndViewer: L("Host and viewer", "양쪽 역할")
        }
    }
    public var detail: String {
        switch self {
        case .host: L("Receives remote connections on this Mac.", "이 Mac에서 원격 접속을 받습니다.")
        case .viewer: L("Connects to another computer. Its presence does not confirm this Mac's sharing service.", "다른 컴퓨터에 접속하는 앱입니다. 이 Mac의 공유 서비스 활성 여부를 뜻하지 않습니다.")
        case .hostAndViewer: L("Can receive or initiate connections; installation alone does not identify an active role.", "접속을 받거나 시작할 수 있습니다. 설치만으로 현재 역할을 확인할 수 없습니다.")
        }
    }
}

public enum RemoteObservationAvailability: String, Codable, Sendable {
    case known, unavailable, notApplicable

    public var title: String {
        switch self {
        case .known: L("Observed", "관측됨")
        case .unavailable: L("Not verified", "미확인")
        case .notApplicable: L("Not applicable", "해당 없음")
        }
    }
}

public enum RemoteObservationReason: String, Codable, Sendable {
    case observed, bundleNotObserved, bundleMetadataUnavailable, bundleIdentityMismatch
    case runtimeVersionUnavailable, clientVersionUnavailable, viewerIsNotHost
    case automaticConnectionUnsupported, frameDeliveryUnmeasured, inputRoundTripUnmeasured
    case authenticationUnavailable, hostServiceUnavailable, currentScopeUnavailable, sampleOnly

    public var title: String {
        switch self {
        case .observed: L("Observed", "관측됨")
        case .bundleNotObserved: L("App not observed", "앱 미관측")
        case .bundleMetadataUnavailable: L("Bundle version unavailable", "설치 버전 미확인")
        case .bundleIdentityMismatch: L("Bundle identity not verified", "앱 식별값 미확인")
        case .runtimeVersionUnavailable: L("Running version not verified", "실행 중 버전 미확인")
        case .clientVersionUnavailable: L("Remote client version not verified", "상대 클라이언트 버전 미확인")
        case .viewerIsNotHost: L("Viewer app", "접속하는 쪽 앱")
        case .automaticConnectionUnsupported: L("Automatic connection lookup unsupported", "접속 자동 조회 미지원")
        case .frameDeliveryUnmeasured: L("Remote frames not measured", "원격 화면 전달 미실측")
        case .inputRoundTripUnmeasured: L("Remote input not measured", "원격 입력 미실측")
        case .authenticationUnavailable: L("Authentication not verified", "원격 인증 미확인")
        case .hostServiceUnavailable: L("Sharing service not verified", "공유 서비스 미확인")
        case .currentScopeUnavailable: L("Current session not verified", "현재 사용자 세션 미확인")
        case .sampleOnly: L("Example observation", "예시 관측")
        }
    }
    public var detail: String {
        switch self {
        case .observed: L("The stated source returned this observation for its stated scope.", "표시된 출처가 해당 범위의 값을 반환했습니다.")
        case .bundleNotObserved: L("No verified bundle was found through the supported lookup paths. This does not confirm the app is uninstalled.", "지원하는 조회 경로에서 검증된 앱 번들을 찾지 못했습니다. 미설치가 확정된 것은 아닙니다.")
        case .bundleMetadataUnavailable: L("A bundle identifier or version could not be read and verified.", "앱 번들의 식별값 또는 버전을 읽고 검증하지 못했습니다.")
        case .bundleIdentityMismatch: L("The discovered bundle did not match the expected product identifier.", "발견한 번들이 해당 제품의 식별값과 일치하지 않습니다.")
        case .runtimeVersionUnavailable: L("An installed bundle version does not prove which version is loaded by a running process.", "설치 번들 버전은 실행 중 프로세스가 사용하는 버전의 증거가 아닙니다.")
        case .clientVersionUnavailable: L("This Mac's bundle metadata does not reveal the remote computer's client version.", "이 Mac의 앱 번들 정보로 상대 컴퓨터의 클라이언트 버전을 확인할 수 없습니다.")
        case .viewerIsNotHost: L("This viewer bundle is not the local host service; its installed version is shown separately.", "이 앱은 접속하는 쪽 도구입니다. 로컬 호스트 서비스와 설치 버전을 구별합니다.")
        case .automaticConnectionUnsupported: L("Tether has no supported public connection lookup for this product in the current configuration. App, assertion and virtual-display hints do not prove a connection.", "Tether의 현재 구성에서는 이 제품의 접속 상태를 자동 조회하지 않습니다. 앱·절전 요청·가상 화면 힌트는 접속 성공의 증거가 아닙니다.")
        case .frameDeliveryUnmeasured: L("A connection or awake Mac does not confirm remote frames are being received.", "접속 상태나 Mac의 작업 유지만으로 원격 화면 수신을 확인할 수 없습니다.")
        case .inputRoundTripUnmeasured: L("No remote input round trip was measured. Local input activity is not a substitute.", "원격 입력의 왕복 성공을 실측하지 않았습니다. 로컬 입력 활동으로 대신하지 않습니다.")
        case .authenticationUnavailable: L("Remote login, lock-screen authentication and provider permissions have not been verified.", "원격 로그인·잠금 화면 인증·공급자 권한을 확인하지 않았습니다.")
        case .hostServiceUnavailable: L("The Screen Sharing viewer does not reveal whether this Mac's sharing service is enabled or connected.", "화면 공유 뷰어 앱으로 이 Mac의 공유 서비스 활성 또는 접속 여부를 확인할 수 없습니다.")
        case .currentScopeUnavailable: L("A current user session and display revision are required before publishing current remote success.", "현재 원격 성공을 표시하려면 사용자 세션과 화면 구성 범위를 확인해야 합니다.")
        case .sampleOnly: L("This is a preview example, not an observation of an installed app or a remote connection.", "미리보기 예시입니다. 실제 설치 앱이나 원격 접속의 관측이 아닙니다.")
        }
    }
}

public enum RemoteEvidenceSource: String, Codable, Sendable {
    case bundleMetadata, publicAPI, providerReported, physicalVerification, hint, unsupported

    public var title: String {
        switch self {
        case .bundleMetadata: L("Installed bundle metadata", "설치 번들 정보")
        case .publicAPI: L("Public API observation", "공개 API 관측")
        case .providerReported: L("Verified provider report", "검증된 공급자 보고")
        case .physicalVerification: L("Previous physical test", "이전 실제 시험")
        case .hint: L("Hint only", "참고 힌트")
        case .unsupported: L("No supported observation", "지원 관측 경로 없음")
        }
    }
    var supportsCurrentSuccess: Bool { self == .publicAPI || self == .providerReported }
}

/// Scope contains no address, account, screen content or input text. Version fields identify
/// the tested configuration; installed metadata is never silently substituted for runtime.
public struct RemoteEvidenceScope: Codable, Equatable, Sendable {
    public var providerID: String
    public var productName: String
    public var role: RemoteProviderRole
    public var bundleID: String?
    public var osVersion: String
    public var sessionKey: String
    public var generation: UInt64
    public var displayRevision: UInt64
    public var hostInstalledVersion: String?
    public var hostRuntimeVersion: String?
    public var clientVersion: String?

    public init(providerID: String, productName: String, role: RemoteProviderRole, bundleID: String?,
                osVersion: String, sessionKey: String, generation: UInt64, displayRevision: UInt64,
                hostInstalledVersion: String? = nil, hostRuntimeVersion: String? = nil, clientVersion: String? = nil) {
        self.providerID = providerID; self.productName = productName; self.role = role; self.bundleID = bundleID
        self.osVersion = osVersion; self.sessionKey = sessionKey; self.generation = generation
        self.displayRevision = displayRevision; self.hostInstalledVersion = hostInstalledVersion
        self.hostRuntimeVersion = hostRuntimeVersion; self.clientVersion = clientVersion
    }

    public var canVerifyCurrentSuccess: Bool {
        role.canHost && [providerID, productName, osVersion, sessionKey,
                        hostInstalledVersion ?? "", hostRuntimeVersion ?? "", clientVersion ?? ""]
            .allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                && !["unavailable", "unknown"].contains($0.lowercased())
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }
}

public enum RemoteEvidenceValidity: String, Codable, Sendable {
    case current, unavailable, missingValue, unsupportedSource, invalidTime, future, stale
    case invalidFreshnessLimit, scopeMismatch, unverifiedScope
}

public struct RemoteObservation<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value?
    public var availability: RemoteObservationAvailability
    public var reason: RemoteObservationReason
    public var source: RemoteEvidenceSource
    public var observedAt: Double
    public var scope: RemoteEvidenceScope

    public init(value: Value?, availability: RemoteObservationAvailability, reason: RemoteObservationReason,
                source: RemoteEvidenceSource, observedAt: Double, scope: RemoteEvidenceScope) {
        self.value = value; self.availability = availability; self.reason = reason; self.source = source
        self.observedAt = observedAt; self.scope = scope
    }
    public var summary: String {
        availability == .known ? value.map { String(describing: $0) } ?? reason.title : reason.title
    }

    /// The caller chooses a freshness limit for each metric. A connection heartbeat must
    /// not refresh frames, input or authentication. No external-message ingestion exists here.
    public func validity(currentScope: RemoteEvidenceScope, now: Date, maximumAge: TimeInterval) -> RemoteEvidenceValidity {
        guard availability == .known else { return .unavailable }
        guard value != nil else { return .missingValue }
        guard source.supportsCurrentSuccess else { return .unsupportedSource }
        guard maximumAge.isFinite, maximumAge >= 0 else { return .invalidFreshnessLimit }
        let current = now.timeIntervalSince1970
        guard observedAt.isFinite, current.isFinite else { return .invalidTime }
        guard observedAt <= current else { return .future }
        guard current - observedAt <= maximumAge else { return .stale }
        guard scope == currentScope else { return .scopeMismatch }
        guard currentScope.canVerifyCurrentSuccess else { return .unverifiedScope }
        return .current
    }
}

public struct RemoteHint: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case installedBundle, runningApp, virtualDisplay, displayAssertion, previewExample
    }
    public var id: String { kind.rawValue }
    public let kind: Kind
    public let observedAt: Double
    public var title: String {
        switch kind {
        case .installedBundle: L("Installed bundle observed", "설치 번들 확인")
        case .runningApp: L("App running", "앱 실행 관측")
        case .virtualDisplay: L("Virtual-display hint", "가상 화면 힌트")
        case .displayAssertion: L("Display-request hint", "화면 유지 요청 힌트")
        case .previewExample: L("Preview example", "미리보기 예시")
        }
    }
    public var detail: String {
        L("This is a hint, not proof of a remote connection, frame delivery or input.", "원격 접속·화면 전달·입력 성공의 증거가 아닌 참고 정보입니다.")
    }
    public init(kind: Kind, observedAt: Double) { self.kind = kind; self.observedAt = observedAt }
}

public struct RemoteProviderCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: RemoteProvider
    public let role: RemoteProviderRole
    public let productName: String
    public let bundleID: String?
    public let hints: [RemoteHint]

    public init(id: String, provider: RemoteProvider, role: RemoteProviderRole, productName: String,
                bundleID: String?, hints: [RemoteHint] = []) {
        self.id = id; self.provider = provider; self.role = role; self.productName = productName
        self.bundleID = bundleID; self.hints = hints
    }
}

/// Historical proof is retained separately. It never becomes a current Observation.
public struct RemotePhysicalVerification: Codable, Equatable, Sendable {
    public let scope: RemoteEvidenceScope
    public let observedAt: Double
    public let connection: Bool
    public let frameDelivery: Bool
    public let inputRoundTrip: Bool
    public let authentication: Bool

    public init(scope: RemoteEvidenceScope, observedAt: Double, connection: Bool, frameDelivery: Bool,
                inputRoundTrip: Bool, authentication: Bool) {
        self.scope = scope; self.observedAt = observedAt; self.connection = connection
        self.frameDelivery = frameDelivery; self.inputRoundTrip = inputRoundTrip; self.authentication = authentication
    }
    public var summary: String { L("Last physical test; current connection is not verified", "마지막 실제 시험 근거 · 현재 접속 확인과 별개") }
    public func matchesConfiguration(_ currentScope: RemoteEvidenceScope, now: Date) -> Bool {
        observedAt.isFinite && now.timeIntervalSince1970.isFinite && observedAt <= now.timeIntervalSince1970
            && scope == currentScope && currentScope.canVerifyCurrentSuccess
    }
}

public struct RemoteFreshnessLimits: Equatable, Sendable {
    public let connection: TimeInterval
    public let frameDelivery: TimeInterval
    public let inputRoundTrip: TimeInterval
    public let authentication: TimeInterval
    public init(connection: TimeInterval, frameDelivery: TimeInterval, inputRoundTrip: TimeInterval, authentication: TimeInterval) {
        self.connection = connection; self.frameDelivery = frameDelivery
        self.inputRoundTrip = inputRoundTrip; self.authentication = authentication
    }
}

public struct RemoteProviderState: Codable, Equatable, Sendable, Identifiable {
    public var id: String { candidate.id }
    public let candidate: RemoteProviderCandidate
    public let scope: RemoteEvidenceScope
    public let localInstalledVersion: RemoteObservation<String>
    public let hostInstalledVersion: RemoteObservation<String>
    public let runtimeVersion: RemoteObservation<String>
    public let clientVersion: RemoteObservation<String>
    public var connection: RemoteObservation<Bool>
    public var frameDelivery: RemoteObservation<Bool>
    public var inputRoundTrip: RemoteObservation<Bool>
    public var authentication: RemoteObservation<Bool>
    public var lastPhysicalVerification: RemotePhysicalVerification?
    public var guides: [RemoteSupportGuide] { RemoteSupportCatalog.guides.filter { $0.provider == candidate.provider } }

    public init(candidate: RemoteProviderCandidate, scope: RemoteEvidenceScope,
                localInstalledVersion: RemoteObservation<String>, hostInstalledVersion: RemoteObservation<String>,
                runtimeVersion: RemoteObservation<String>, clientVersion: RemoteObservation<String>,
                connection: RemoteObservation<Bool>, frameDelivery: RemoteObservation<Bool>,
                inputRoundTrip: RemoteObservation<Bool>, authentication: RemoteObservation<Bool>,
                lastPhysicalVerification: RemotePhysicalVerification? = nil) {
        self.candidate = candidate; self.scope = scope; self.localInstalledVersion = localInstalledVersion
        self.hostInstalledVersion = hostInstalledVersion; self.runtimeVersion = runtimeVersion; self.clientVersion = clientVersion
        self.connection = connection; self.frameDelivery = frameDelivery; self.inputRoundTrip = inputRoundTrip
        self.authentication = authentication; self.lastPhysicalVerification = lastPhysicalVerification
    }

    /// A complete current remote observation requires independent current evidence for every
    /// metric. Historical tests and installation/runtime/display hints are never substitutes.
    public func liveReady(currentScope: RemoteEvidenceScope, now: Date, freshness: RemoteFreshnessLimits) -> Bool {
        guard candidate.role.canHost, scope == currentScope,
              candidate.id == currentScope.providerID, candidate.productName == currentScope.productName,
              candidate.role == currentScope.role, candidate.bundleID == currentScope.bundleID,
              hostInstalledVersion.availability == .known, hostInstalledVersion.scope == currentScope,
              hostInstalledVersion.value == currentScope.hostInstalledVersion,
              hostInstalledVersion.source == .bundleMetadata || hostInstalledVersion.source.supportsCurrentSuccess,
              hostInstalledVersion.observedAt.isFinite, hostInstalledVersion.observedAt <= now.timeIntervalSince1970,
              runtimeVersion.value == currentScope.hostRuntimeVersion, clientVersion.value == currentScope.clientVersion,
              runtimeVersion.validity(currentScope: currentScope, now: now, maximumAge: freshness.authentication) == .current,
              clientVersion.validity(currentScope: currentScope, now: now, maximumAge: freshness.authentication) == .current else { return false }
        return [(connection, freshness.connection), (frameDelivery, freshness.frameDelivery),
                (inputRoundTrip, freshness.inputRoundTrip), (authentication, freshness.authentication)]
            .allSatisfy { $0.0.value == true && $0.0.validity(currentScope: currentScope, now: now, maximumAge: $0.1) == .current }
    }
}

public struct RemoteSupportGuide: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: RemoteProvider
    public let role: RemoteProviderRole
    public let url: String
    public let englishTitle: String
    public let koreanTitle: String
    public let englishDetail: String
    public let koreanDetail: String
    public var title: String { L(englishTitle, koreanTitle) }
    public var detail: String { L(englishDetail, koreanDetail) }
}

public enum RemoteSupportCatalog {
    // Streamer ID: Splashtop's official Jamf deployment guide. Business viewer ID:
    // the actual macOS bundle, independently distinguished from its st-business URI scheme.
    // RustDesk ID: release/debug/profile PRODUCT_BUNDLE_IDENTIFIER in its official Runner project.
    public static let candidates: [RemoteProviderCandidate] = [
        .init(id: "splashtop-host", provider: .splashtop, role: .host, productName: "Splashtop Streamer", bundleID: "com.splashtop.Splashtop-Streamer"),
        .init(id: "splashtop-viewer", provider: .splashtop, role: .viewer, productName: "Splashtop Business", bundleID: "com.splashtop.stb.macosx"),
        .init(id: "rustdesk", provider: .rustDesk, role: .hostAndViewer, productName: "RustDesk", bundleID: "com.carriez.rustdesk"),
        .init(id: "apple-sharing-host", provider: .appleScreenSharing, role: .host, productName: "macOS Screen Sharing service", bundleID: nil),
        .init(id: "apple-sharing-viewer", provider: .appleScreenSharing, role: .viewer, productName: "Screen Sharing", bundleID: "com.apple.ScreenSharing")
    ]
    public static let guides: [RemoteSupportGuide] = [
        .init(id: "splashtop-settings", provider: .splashtop, role: .host,
              url: "https://support-splashtopbusiness.splashtop.com/hc/en-us/articles/360041097071-Streamer-Settings-Overview",
              englishTitle: "Splashtop Streamer settings", koreanTitle: "Splashtop Streamer 설정",
              englishDetail: "Review session-end locking, idle timeout and screen options in Streamer. Tether has not read their current values.",
              koreanDetail: "Streamer에서 세션 종료 후 잠금·유휴 종료·화면 옵션을 확인하세요. Tether가 현재 설정값을 읽은 것은 아닙니다."),
        .init(id: "rustdesk-permissions", provider: .rustDesk, role: .hostAndViewer,
              url: "https://rustdesk.com/docs/en/client/mac/",
              englishTitle: "RustDesk macOS permissions", koreanTitle: "RustDesk macOS 권한",
              englishDetail: "Check RustDesk's Screen Recording and Accessibility approvals, and Input Monitoring where required. Tether's approvals do not cover RustDesk.",
              koreanDetail: "RustDesk의 화면 기록·접근성 승인과 필요한 입력 모니터링을 확인하세요. Tether 승인으로 대신할 수 없습니다."),
        .init(id: "apple-sharing", provider: .appleScreenSharing, role: .host,
              url: "https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac",
              englishTitle: "macOS Screen Sharing", koreanTitle: "macOS 화면 공유 설정",
              englishDetail: "Review Sharing and allowed users. The Screen Sharing viewer does not establish local service activation; Remote Management is a separate service.",
              koreanDetail: "공유 설정과 허용 사용자를 확인하세요. 뷰어 앱 실행은 로컬 서비스 활성의 증거가 아니며 원격 관리는 별도 서비스입니다."),
        .init(id: "apple-lock", provider: .appleScreenSharing, role: .hostAndViewer,
              url: "https://support.apple.com/en-sg/guide/mac-help/mh11784/15.0/mac/15.0",
              englishTitle: "macOS password requirement", koreanTitle: "macOS 암호 요구 설정",
              englishDetail: "Screen-off password requirements and system sleep are separate. Review the policy without assuming it caused a remote failure.",
              koreanDetail: "화면이 꺼진 뒤 암호 요구와 시스템 잠자기는 별개입니다. 원격 실패의 원인으로 단정하지 않고 해당 정책을 확인하세요.")
    ]
}

public struct RemoteInteropContext: Codable, Equatable, Sendable {
    public let providers: [RemoteProviderState]
    public let checkedAt: Double
    public let osVersion: String
    public let generation: UInt64
    public let displayRevision: UInt64
    public let sessionKey: String
    public let simulated: Bool
    public var guides: [RemoteSupportGuide] { RemoteSupportCatalog.guides }

    public init(providers: [RemoteProviderState], checkedAt: Double, osVersion: String, generation: UInt64,
                displayRevision: UInt64, sessionKey: String, simulated: Bool = false) {
        self.providers = providers; self.checkedAt = checkedAt; self.osVersion = osVersion
        self.generation = generation; self.displayRevision = displayRevision; self.sessionKey = sessionKey
        self.simulated = simulated
    }

    /// Safe diagnostic projection: no account, endpoint, PID, assertion payload or session key.
    /// Each metric keeps its own observation time; this output does not declare live readiness.
    public func reportLines() -> [String] {
        var lines = ["Remote observations: \(simulated ? "preview example" : "read-only capture"); macOS \(osVersion); generation \(generation); display revision \(displayRevision)"]
        for provider in providers {
            lines.append("\(provider.candidate.productName) [\(provider.candidate.role.rawValue)]; hints=\(provider.candidate.hints.map { $0.kind.rawValue }.joined(separator: ","))")
            func row<T: Codable & Equatable & Sendable>(_ title: String, _ observation: RemoteObservation<T>) -> String {
                "  \(title): \(observation.summary); availability=\(observation.availability.rawValue); source=\(observation.source.rawValue); reason=\(observation.reason.rawValue); observedAt=\(observation.observedAt)"
            }
            lines.append(row("local installed bundle", provider.localInstalledVersion))
            lines.append(row("host installed bundle", provider.hostInstalledVersion))
            lines.append(row("host runtime version", provider.runtimeVersion))
            lines.append(row("remote client version", provider.clientVersion))
            lines.append(row("connection", provider.connection))
            lines.append(row("frames", provider.frameDelivery))
            lines.append(row("input round trip", provider.inputRoundTrip))
            lines.append(row("authentication", provider.authentication))
            if let previous = provider.lastPhysicalVerification {
                lines.append("  historical physical test: observedAt=\(previous.observedAt); current readiness not implied")
            }
        }
        return lines
    }
}
