import SwiftUI
import LocalAuthentication

/// What the Face ID / Touch ID lock protects (SPEC §5).
enum LockMode: String, CaseIterable {
    case off, wholeApp, financeAndNotes

    var title: String {
        switch self {
        case .off: "Off"
        case .wholeApp: "Whole app"
        case .financeAndNotes: "Finance + locked notes"
        }
    }
}

/// Lock settings (persisted in UserDefaults) plus the in-memory unlocked state.
@Observable final class AppLock {
    private static let modeKey = "lock.mode", graceKey = "lock.grace"
    static let graceOptions: [(seconds: TimeInterval, title: String)] = [
        (0, "Immediately"), (60, "After 1 minute"), (300, "After 5 minutes"), (900, "After 15 minutes"),
    ]
    @ObservationIgnored private let defaults: UserDefaults

    var mode: LockMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }
    var graceSeconds: TimeInterval {
        didSet { defaults.set(graceSeconds, forKey: Self.graceKey) }
    }
    var isUnlocked: Bool
    var backgroundedAt: Date?
    var errorMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = defaults.string(forKey: Self.modeKey).flatMap(LockMode.init) ?? .off
        self.mode = mode
        graceSeconds = defaults.double(forKey: Self.graceKey)
        isUnlocked = mode == .off  // launch starts locked
    }

    /// nil = never backgrounded (fresh launch), which always locks.
    static func shouldRelock(backgroundedAt: Date?, now: Date, grace: TimeInterval) -> Bool {
        guard let backgroundedAt else { return true }
        return now.timeIntervalSince(backgroundedAt) >= grace
    }

    func sceneDidBecomeActive(now: Date = .now) {
        // Only re-check after a real trip to the background; inactive -> active
        // (e.g. the Face ID sheet closing) must not relock.
        guard backgroundedAt != nil else { return }
        if mode != .off, Self.shouldRelock(backgroundedAt: backgroundedAt, now: now, grace: graceSeconds) {
            isUnlocked = false
        }
        backgroundedAt = nil
    }

    /// Biometrics with passcode / Mac password fallback. Stays locked on failure.
    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = error?.localizedDescription ?? "Authentication is unavailable."
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock mise")
            isUnlocked = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LockView: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Button("Unlock") { Task { await lock.unlock() } }
                .buttonStyle(.borderedProminent)
            if let message = lock.errorMessage {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(theme.background).ignoresSafeArea())
        .task { await lock.unlock() }
    }
}

/// Applied at the app root (inside `ThemeRoot`): whole-app lock overlay,
/// app-switcher privacy cover, and relock on return from background.
struct AppLockRoot: ViewModifier {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var phase
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .overlay {
                if lock.mode == .wholeApp && !lock.isUnlocked { LockView() }
            }
            #if !os(macOS)
            .overlay {
                if lock.mode != .off && phase != .active {
                    Image(systemName: "lock.fill")
                        .font(.largeTitle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(theme.background).ignoresSafeArea())
                }
            }
            #endif
            .onChange(of: phase) { _, phase in
                switch phase {
                case .background: lock.backgroundedAt = .now
                case .active: lock.sceneDidBecomeActive()
                default: break
                }
            }
    }
}
