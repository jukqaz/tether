import SwiftUI
import TetherCore

struct RemoteFindingsView: View {
    let context: RemoteInteropContext
    let canOpenSettings: Bool
    let openLockScreenSettings: () -> Void

    private var observedProviders: [RemoteProviderState] {
        context.providers.filter { provider in
            provider.candidate.hints.contains { [.installedBundle, .runningApp, .virtualDisplay].contains($0.kind) }
        }
    }

    var body: some View {
        SettingsCard(title: L("Remote use", "원격 사용 확인"), symbol: "display.2") {
            Note(L("Keeping your Mac awake, receiving remote frames and accepting remote input are separate checks. The display-awake option prevents idle display sleep during a valid work session. Closed-lid display and lock behavior, screen-saver locking and manual locking follow macOS. This option does not unlock a locked screen or change password requirements.",
                   "작업 유지, 원격 화면 수신, 원격 입력은 각각 별도로 확인합니다. 화면 유지 옵션은 유효한 작업 유지 동안 화면의 유휴 꺼짐을 막습니다. 덮개를 닫을 때의 화면·잠금, 화면 보호기와 수동 잠금은 macOS에 따릅니다. 잠긴 화면을 해제하거나 암호 요구 설정을 바꾸지 않습니다."))
            Button(L("Open Lock Screen settings…", "잠금 화면 설정 열기…"), action: openLockScreenSettings)
                .disabled(!canOpenSettings)
                .help(L("Opens System Settings without changing the password requirement.",
                        "시스템 설정을 엽니다. 암호 요구 설정은 변경하지 않습니다."))
                .accessibilityHint(L("Review the password requirement in System Settings", "시스템 설정에서 암호 요구를 확인합니다"))
            if observedProviders.isEmpty {
                Note(L("No supported app bundle was observed. macOS sharing can operate without a viewer app running.",
                       "지원 경로에서 원격 앱 번들을 찾지 못했습니다. macOS 공유는 뷰어 앱 실행과 별개입니다."))
            }
            ForEach(observedProviders) { provider in
                DisclosureGroup {
                    providerDetails(provider).padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.candidate.productName).font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(providerCaption(provider)).font(.caption).foregroundStyle(Color.tetherSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DisclosureGroup(L("Settings to check", "확인할 설정")) {
                VStack(alignment: .leading, spacing: 10) {
                    Note(L("These are official guidance links. Current settings and the cause of a failure have not been read.",
                           "공식 설정 안내입니다. 현재 설정값이나 문제 원인을 확인했다는 뜻은 아닙니다."))
                    Note(L("In Lock Screen, review ‘Require password after screen saver begins or display is turned off’. Your remote app may also lock the Mac when a connection ends. These settings apply beyond Tether; managed policies can restrict changes.",
                           "잠금 화면에서 ‘화면 보호기 시작 후 또는 디스플레이가 꺼진 후 암호 요구’를 확인하세요. 원격 앱에도 연결 종료 후 잠금 설정이 있을 수 있습니다. Tether 밖에서도 적용되는 설정이며 관리 정책에 따라 변경이 제한될 수 있습니다."))
                    ForEach(context.guides) { guide in
                        VStack(alignment: .leading, spacing: 4) {
                            if let url = URL(string: guide.url) { Link(guide.title, destination: url).font(.callout.weight(.medium)) }
                            Text(guide.detail).font(.caption).foregroundStyle(Color.tetherSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(.top, 10)
            }.font(.callout)
        }
    }

    private func providerCaption(_ provider: RemoteProviderState) -> String {
        var parts = [provider.candidate.role.title]
        if let version = provider.localInstalledVersion.value {
            parts.append(L("Installed \(version)", "설치 버전 \(version)"))
        }
        if provider.candidate.hints.contains(where: { $0.kind == .runningApp }) {
            parts.append(L("App running", "앱 실행 관측"))
        }
        return parts.joined(separator: " · ")
    }

    private func providerDetails(_ provider: RemoteProviderState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Note(provider.candidate.role.detail)
            metric(L("Connection", "접속"), provider.connection)
            metric(L("Remote frames", "원격 화면"), provider.frameDelivery)
            metric(L("Remote input", "원격 입력"), provider.inputRoundTrip)
            metric(L("Authentication", "인증"), provider.authentication)
            DisclosureGroup(L("Version & observation details", "버전·관측 상세")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Running version: \(provider.runtimeVersion.summary)", "실행 중 버전: \(provider.runtimeVersion.summary)"))
                    Text(L("Remote client version: \(provider.clientVersion.summary)", "상대 클라이언트 버전: \(provider.clientVersion.summary)"))
                    ForEach(provider.candidate.hints) { hint in Text(hint.title) }
                    Note(L("An installed version or running app does not prove an active remote connection.",
                           "설치 버전과 앱 실행 여부는 실제 원격 접속의 증거가 아닙니다."))
                }.font(.caption).foregroundStyle(Color.tetherSecondary).padding(.top, 8)
            }.font(.caption)
        }
    }

    private func metric(_ title: String, _ observation: RemoteObservation<Bool>) -> some View {
        WorkSessionRow(title: title, value: observation.availability == .known
            ? L("Requires current provider verification", "현재 공급자 관측 확인 필요") : observation.summary)
    }
}
