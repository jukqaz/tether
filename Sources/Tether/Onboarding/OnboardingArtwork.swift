import AppKit
import AVFoundation
import AVKit
import SwiftUI
import TetherCore

/// A concept illustration, never a live power-state indicator. Motion is opt-in and silent.
struct OnboardingArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = OnboardingMotionPlayback()

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                poster
                if playback.isPlaying, let player = playback.player, !reduceMotion {
                    OnboardingMotionView(player: player)
                }
            }
            .frame(width: 250, height: 141)
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                Text(L("Power connection concept", "전원 연결·분리 개념 안내"))
                    .font(TetherTypography.secondary)
                    .foregroundStyle(Color.tetherSecondary)
                if !reduceMotion && playback.motionAvailable {
                    Button {
                        if playback.isPlaying { playback.stop() }
                        else { playback.playOnce() }
                    } label: {
                        Label(motionTitle, systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                    }
                    .actionButton()
                    .accessibilityIdentifier("welcome-motion-preview")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { playback.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            playback.stop()
        }
        .onDisappear { playback.stop() }
    }

    @ViewBuilder private var poster: some View {
        if let image = (!reduceMotion && playback.showDisconnected)
            ? OnboardingResources.disconnected ?? OnboardingResources.connected
            : OnboardingResources.connected {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            // A raw SwiftPM executable or incomplete bundle still has a usable static guide.
            Image(systemName: "macbook").font(.system(size: 72, weight: .light))
                .foregroundStyle(Color.tetherSecondary)
        }
    }

    private var motionTitle: String {
        if playback.isPlaying { return L("Stop", "정지") }
        return playback.hasPlayed ? L("Replay", "다시 보기") : L("See motion", "동작 보기")
    }
}

private enum OnboardingResources {
    static let connected = image("connected")
    static let disconnected = image("disconnected")
    static let motionURL = Bundle.main.url(forResource: "motion-preview", withExtension: "mp4", subdirectory: "Onboarding")

    private static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Onboarding") else { return nil }
        return NSImage(contentsOf: url)
    }
}

@MainActor
private final class OnboardingMotionPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var showDisconnected = false
    @Published private(set) var hasPlayed = false
    @Published private(set) var motionAvailable = OnboardingResources.motionURL != nil
    private(set) var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    func playOnce() {
        guard motionAvailable, let url = OnboardingResources.motionURL else { return }
        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
        // An optional onboarding animation must not create a screen keep-awake request.
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        showDisconnected = false
        hasPlayed = true
        isPlaying = true
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in self?.fail(item: item) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.player?.currentItem === item else { return }
                    self.stop()
                    self.showDisconnected = true
                }
            }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fail(item: item) }
            }
        player.play()
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        itemObservation?.invalidate()
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        isPlaying = false
        showDisconnected = false
    }

    private func fail(item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        stop()
        motionAvailable = false
    }

    deinit {
        itemObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }
}

/// AVKit's smallest bridge removes transport/fullscreen chrome from the compact illustration.
private struct OnboardingMotionView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player?.pause()
        view.player = nil
    }
}
