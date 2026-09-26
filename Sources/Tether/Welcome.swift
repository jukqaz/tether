import AppKit
import SwiftUI
import TetherCore

/// The first-run window: what Tether does, and the one-time helper install.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingView(rootView: WelcomeView(model: model) { close(model: model) }
            .background(SettingsWindowBridge()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = L("Welcome to Tether", "Tether 시작하기")
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    private static func close(model: AppModel) {
        model.finishOnboarding()
        window?.close()
        window = nil
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 28)
            VStack(spacing: 4) {
                Text("Tether")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(L("Clamshell mode that follows your power cord", "전원에 따라 움직이는 클램쉘 모드"))
                    .foregroundStyle(.secondary)
            }

            if model.supportedMac {
                VStack(alignment: .leading, spacing: 12) {
                    point("powerplug.fill", .tetherMint,
                          L("On power, close the lid and keep working", "전원 연결: 덮개를 닫아도 계속 일해요"),
                          L("No sleep and no lock; the screen under the lid goes dark.", "잠들지도 잠기지도 않고, 덮개 아래 화면은 어둡게 꺼 둬요."))
                    point("battery.75percent", .blue,
                          L("Unplugged, it sleeps like normal", "전원을 뽑으면 평소처럼 잠들어요"),
                          L("A Mac already closed goes to sleep right away, even in a bag.", "이미 덮개가 닫혀 있으면 가방 안에서도 바로 잠들어요."))
                    point("shield.lefthalf.filled", .orange,
                          L("Safe when it has to stay awake", "깨어 있어야 할 때도 안전하게"),
                          L("Battery holds end when hot or low; a hot closed Mac is cooled with Low Power Mode.",
                            "배터리 유지는 뜨겁거나 배터리가 적으면 끝나고, 덮개를 닫은 채 뜨거우면 저전력 모드로 식혀요."))
                }
                .padding(.horizontal, 36)

                VStack(spacing: 8) {
                    if model.helperInstalled {
                        Label(L("Helper installed", "도우미 설치됨"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.tetherMint)
                    } else {
                        Button(L("Install Helper…", "도우미 설치…")) { model.installHelper() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    Text(L("It asks for your administrator password once and only switches the sleep setting (pmset). Settings › System shows everything it changes.",
                           "관리자 암호를 한 번 묻고, 잠자기 설정(pmset)만 바꿔요. 바꾸는 것은 설정 › 시스템에서 모두 볼 수 있어요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 40)
                }
                Toggle(L("Open at login", "로그인하면 자동으로 열기"),
                       isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
            } else {
                Text(L("This Mac has no built-in battery or lid, so Tether has nothing to do here and leaves its sleep settings alone.",
                       "이 Mac에는 내장 배터리나 덮개가 없어서 Tether가 할 일이 없어요. 잠자기 설정은 건드리지 않아요."))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer(minLength: 0)
            HStack {
                if !model.supportedMac {
                    Button(L("Quit Tether", "Tether 종료")) { NSApp.terminate(nil) }
                }
                Spacer()
                Button(model.helperInstalled || !model.supportedMac ? L("Done", "완료") : L("Later", "나중에"), action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
    }

    private func point(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SidebarIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The welcome content without its window, for `--render-welcome`.
struct WelcomePreview: View {
    @ObservedObject var model: AppModel

    var body: some View {
        WelcomeView(model: model) {}
    }
}
