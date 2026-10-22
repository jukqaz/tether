import Foundation
import CoreGraphics

/// Only identifiers needed to join two local observations; no serials, EDID or UUIDs.
public struct DisplayObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UInt32
    public let builtIn: Bool
    public let vendor: UInt32
    public let model: UInt32
    public let width: Int
    public let height: Int
    public let active: Bool
    public let asleep: Bool

    public init(id: UInt32, builtIn: Bool, vendor: UInt32, model: UInt32, width: Int, height: Int, active: Bool, asleep: Bool) {
        self.id = id; self.builtIn = builtIn; self.vendor = vendor; self.model = model
        self.width = width; self.height = height; self.active = active; self.asleep = asleep
    }

    /// Observed on this Mac and confirmed against its system profile. Kept narrow: unrelated
    /// virtual vendors and USB/DisplayLink displays must not inherit this classification.
    public var providerHint: String? {
        !builtIn && vendor == 0xeee0 && [0xeee1, 0xeee2].contains(model) ? "Splashtop" : nil
    }
}

public struct DisplayFinding: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case builtIn, wired, usb, wireless, virtual, connected
        public var title: String {
            switch self {
            case .builtIn: L("Built-in display", "내장 화면")
            case .wired: L("Wired display", "유선 외장 화면")
            case .usb: L("USB display", "USB 연결 화면")
            case .wireless: L("Wireless display", "무선 연결 화면")
            case .virtual: L("Virtual display", "가상 화면")
            case .connected: L("Additional display", "추가 화면")
            }
        }
    }
    public var id: UInt32 { observation.id }
    public let observation: DisplayObservation
    public let name: String
    public let kind: Kind
    public let connection: String?
    public let provider: String?
    public let profileMatched: Bool
    public let evidence: String
    public var detail: String {
        [kind.title, connection, "\(observation.width) × \(observation.height)",
         observation.asleep ? L("Sleep observed", "꺼짐으로 보고됨") : L("Awake observed", "켜짐으로 보고됨")]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

public struct DisplayReport: Codable, Equatable, Sendable {
    public let checkedAt: Double
    public let displays: [DisplayFinding]
    public let issue: String?
    public let graphicsAvailable: Bool
    public var virtualCount: Int { displays.filter { $0.kind == .virtual }.count }
    public var additionalCount: Int { displays.filter { !$0.observation.builtIn }.count }
    public var summary: String {
        guard graphicsAvailable else { return L("macOS did not return its current display list", "macOS가 현재 화면 목록을 반환하지 않았습니다") }
        guard !displays.isEmpty else { return L("No online displays were reported in this login session", "현재 로그인 세션에서 온라인 화면이 확인되지 않았습니다") }
        if virtualCount > 0 {
            let providers = Array(Set(displays.compactMap(\.provider))).sorted().joined(separator: ", ")
            return L("\(providers.isEmpty ? "Remote" : providers) virtual displays: \(virtualCount)", "\(providers.isEmpty ? "원격용" : providers) 가상 화면 \(virtualCount)개 감지")
        }
        return additionalCount == 0 ? L("Only the built-in display is connected", "내장 화면만 연결되어 있습니다")
            : L("\(additionalCount) additional displays connected", "추가 화면 \(additionalCount)개가 연결되어 있습니다")
    }
    public var guidance: String {
        if !graphicsAvailable { return L("Display observation is unavailable. General work sessions remain independent; display commands and native closed-lid handoff need a current display observation.", "화면 상태를 읽지 못했습니다. 일반 작업 유지는 별도로 동작하며, 화면 끄기와 macOS 클램쉘 위임은 현재 화면 관측이 필요합니다.") }
        if displays.isEmpty { return L("There is no online display to inspect. General work sessions remain independent. This does not confirm a remote frame or that a physical panel is powered off.", "점검할 온라인 화면이 없습니다. 일반 작업 유지는 별도로 동작합니다. 원격 화면 수신이나 실제 패널 전원 차단이 확인된 것은 아닙니다.") }
        if virtualCount > 0 {
            return L("Virtual displays may be needed for remote rendering; they are not evidence of a physical closed-lid monitor setup. Tether withholds all-display sleep and checks the built-in display separately. This does not confirm remote frames, input or lock state.", "가상 화면은 원격 화면에 필요할 수 있으며, 물리 모니터를 연결한 macOS 클램쉘의 근거는 아닙니다. 전체 화면 절전 명령을 보류하고 내장 화면 상태를 별도로 확인합니다. 원격 화면·입력과 잠금 상태가 확인된 것은 아닙니다.")
        }
        if additionalCount > 0 { return L("macOS manages connected displays. Tether avoids an all-display sleep command that could turn these screens off.", "연결된 화면은 macOS가 관리합니다. 외장 화면까지 꺼질 수 있는 전체 화면 절전 명령은 보내지 않습니다.") }
        return L("No additional display was observed. Tether checks the lid and other apps' display requests before requesting display sleep.", "추가 화면이 관측되지 않았습니다. 덮개 상태와 다른 앱의 화면 유지 요청을 확인한 뒤 화면 절전을 요청합니다.")
    }
}

public enum DisplayProbe {
    /// Cheap public API path for the helper's regular policy evaluations.
    public static func observations() -> [DisplayObservation]? { capture().displays }

    private static func capture() -> (displays: [DisplayObservation]?, issue: String?) {
        var count: UInt32 = 0
        let counted = CGGetOnlineDisplayList(0, nil, &count)
        guard counted == .success else { return (nil, L("CoreGraphics display count failed (code \(counted.rawValue)).", "CoreGraphics 화면 개수 조회 실패(코드 \(counted.rawValue)).")) }
        // A successful zero count is an empty current list, not a failed query.
        // Do not invent a built-in panel or turn headless use into an app-wide error.
        guard count > 0 else { return ([], nil) }
        guard count <= 128 else { return (nil, L("The display count exceeds the supported query limit.", "화면 개수가 지원하는 조회 상한을 초과했습니다.")) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let capacity = count
        let fetched = CGGetOnlineDisplayList(capacity, &ids, &count)
        guard fetched == .success else { return (nil, L("CoreGraphics display list failed (code \(fetched.rawValue)).", "CoreGraphics 화면 목록 조회 실패(코드 \(fetched.rawValue)).")) }
        guard count > 0, count <= capacity else { return (nil, L("The display list changed during the query; check again.", "조회 중 화면 목록이 변경되었습니다. 다시 점검해 주세요.")) }
        let observations = ids.prefix(Int(count)).map {
            DisplayObservation(id: $0, builtIn: CGDisplayIsBuiltin($0) != 0,
                vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                width: CGDisplayPixelsWide($0), height: CGDisplayPixelsHigh($0),
                active: CGDisplayIsActive($0) != 0, asleep: CGDisplayIsAsleep($0) != 0)
        }
        return (observations, nil)
    }

    public static func topology(_ displays: [DisplayObservation]?) -> DisplayTopology {
        guard let displays else { return .unknown }
        let additional = displays.filter { !$0.builtIn }
        guard !additional.isEmpty else { return .none }
        let remote = additional.filter { $0.providerHint != nil }.count
        if remote == additional.count { return .virtualOnly }
        return remote > 0 ? .externalWithVirtual : .externalUnverified
    }

    /// On-demand only. The helper never shells out to system_profiler in its policy loop.
    /// Recheck after profiling so unplugged screens and reused IDs cannot become stale facts.
    public static func inspect() -> DisplayReport {
        let result = Shell.run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json", "-detailLevel", "mini"], timeout: 4, maxOutputBytes: 524_288)
        let issue: String? = result.status == 0 ? nil : result.status == 124
            ? L("System Information took too long; current CoreGraphics observations are shown.", "시스템 정보 응답이 지연되어 현재 CoreGraphics 관측을 표시합니다.")
            : L("System Information could not be read; current CoreGraphics observations are shown.", "시스템 정보를 읽지 못해 현재 CoreGraphics 관측을 표시합니다.")
        let current = capture()
        let issues = [current.issue, issue].compactMap { $0 }
        return resolve(observations: current.displays, profile: result.status == 0 ? Data(result.output.utf8) : nil,
                       issue: issues.isEmpty ? nil : issues.joined(separator: " "))
    }

    public static func resolve(observations: [DisplayObservation]?, profile: Data?, issue: String? = nil) -> DisplayReport {
        let parsed = profile.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let gpus = parsed?["SPDisplaysDataType"] as? [[String: Any]]
        let records = gpus?.flatMap { $0["spdisplays_ndrvs"] as? [[String: Any]] ?? [] } ?? []
        var issue = issue
        if profile != nil, gpus == nil { issue = L("The display detail format changed; current display observations are still available.", "화면 상세 정보 형식이 달라 현재 화면 관측만 사용합니다.") }
        var unmatched = 0
        let findings = (observations ?? []).map { observed -> DisplayFinding in
            let matches = records.filter { record in
                // IDs in SPDisplaysDataType are hexadecimal, including digit-only values.
                hex(record["_spdisplays_displayID"]) == observed.id
                    && hex(record["_spdisplays_display-vendor-id"]) == observed.vendor
                    && hex(record["_spdisplays_display-product-id"]) == observed.model
            }
            let record = matches.count == 1 ? matches[0] : nil
            if record == nil { unmatched += 1 }
            let rawName = (record?["_name"] as? String).map(safeName)
            let transport = record?["spdisplays_connection_type"] as? String
            let hint = observed.providerHint
            var kind: DisplayFinding.Kind = observed.builtIn ? .builtIn : .connected
            var connection: String?
            var provider: String?
            var evidence = observed.builtIn ? L("CoreGraphics identifies this display as built in.", "CoreGraphics가 내장 화면으로 보고했습니다.")
                : L("CoreGraphics confirms this additional display is online. macOS did not expose a supported connection path for it.", "CoreGraphics에서 추가 화면 연결을 확인했습니다. macOS가 해석 가능한 연결 경로를 제공하지 않았습니다.")
            if let hint, !observed.builtIn {
                kind = .virtual; provider = hint
                let named = rawName?.hasPrefix("Splashtop Display ") == true
                evidence = named
                    ? L("System Information's Splashtop name and the current CoreGraphics display/vendor/product IDs match.", "시스템 정보의 Splashtop 이름과 현재 CoreGraphics의 화면·제조사·제품 식별값이 일치합니다.")
                    : L("The current vendor/product IDs match an observed Splashtop virtual-display signature; the system name was not corroborated.", "현재 제조사·제품 식별값이 관측된 Splashtop 가상 화면 패턴과 일치합니다. 시스템 이름은 추가 확인되지 않았습니다.")
            } else if !observed.builtIn, let transport {
                switch transport.lowercased() {
                case "spdisplays_hdmi", "spdisplays_displayport", "spdisplays_dvi", "spdisplays_vga", "spdisplays_thunderbolt":
                    kind = .wired; connection = transport.replacingOccurrences(of: "spdisplays_", with: "").uppercased()
                case "spdisplays_usb": kind = .usb; connection = "USB"
                case "spdisplays_airplay": kind = .wireless; connection = "AirPlay"
                case "spdisplays_sidecar": kind = .wireless; connection = "Sidecar"
                default: break
                }
                if kind != .connected {
                    evidence = L("System Information reports \(connection ?? "") and matches the current display/vendor/product IDs.", "시스템 정보의 \(connection ?? "") 연결 정보가 현재 화면·제조사·제품 식별값과 일치합니다.")
                }
            }
            return DisplayFinding(observation: observed, name: rawName.flatMap { $0.isEmpty ? nil : $0 }
                ?? (observed.builtIn ? L("Built-in display", "내장 화면") : hint.map { "\($0) · \(observed.id)" } ?? L("Display \(observed.id)", "화면 \(observed.id)")),
                kind: kind, connection: connection, provider: provider, profileMatched: record != nil, evidence: evidence)
        }
        if issue == nil, gpus != nil, unmatched > 0 {
            issue = L("Some live screens did not match System Information. A display transition may have occurred; check again for their names and connection details.", "일부 현재 화면과 시스템 정보가 일치하지 않습니다. 화면 전환 중일 수 있으므로 이름·연결 정보는 다시 점검해 주세요.")
        }
        return DisplayReport(checkedAt: Date().timeIntervalSince1970, displays: findings, issue: issue, graphicsAvailable: observations != nil)
    }

    private static func hex(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        guard let text = value as? String else { return nil }
        return UInt32(text.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
    }
    private static func safeName(_ name: String) -> String {
        String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
    }
}
