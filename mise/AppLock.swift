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
    @ObservationIgnored private var authenticating = false

    /// Whether the device has any owner authentication (passcode / Mac
    /// password) set up. Without one, `.deviceOwnerAuthentication` can never
    /// succeed, so the lock would otherwise trap the user forever.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let mode = defaults.string(forKey: Self.modeKey).flatMap(LockMode.init) ?? .off
        self.mode = mode
        graceSeconds = defaults.double(forKey: Self.graceKey)
        isUnlocked = mode == .off  // launch starts locked
    }

    /// Re-read settings after a backup restore; keeps `isUnlocked` so a
    /// restore never locks the user out mid-session.
    func reload() {
        mode = defaults.string(forKey: Self.modeKey).flatMap(LockMode.init) ?? .off
        graceSeconds = defaults.double(forKey: Self.graceKey)
    }

    /// nil = never backgrounded (fresh launch), which always locks.
    static func shouldRelock(backgroundedAt: Date?, now: Date, grace: TimeInterval) -> Bool {
        guard let backgroundedAt else { return true }
        return now.timeIntervalSince(backgroundedAt) >= grace
    }

    struct Cover: Equatable {
        let locked: Bool
        let privacy: Bool
    }

    /// `returning`: back from background but the relock check hasn't run yet.
    static func cover(mode: LockMode, isUnlocked: Bool, phase: ScenePhase, returning: Bool) -> Cover {
        #if os(macOS)
        let privacy = false  // no app-switcher snapshot to hide
        #else
        let privacy = mode != .off && (phase != .active || returning)
        #endif
        return Cover(locked: mode == .wholeApp && !isUnlocked, privacy: privacy)
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
        // Two LockViews (macOS overlay + lock sheet) both auto-unlock; one prompt at a time.
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if error?.code == LAError.passcodeNotSet.rawValue {
                // No device passcode means nothing can protect the lock anyway.
                isUnlocked = true
                errorMessage = nil
            } else {
                errorMessage = error?.localizedDescription ?? "Authentication is unavailable."
            }
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

/// Applied at the app root (inside `ThemeRoot`): whole-app lock, app-switcher
/// privacy cover, and relock on return from background. Sheets present above
/// in-view overlays, so on iOS the cover lives in its own window above every
/// presentation; on macOS the main window keeps an overlay, sheet windows hide
/// their content, and the lock is also presented as a sheet on the deepest one
/// (an attached sheet blocks clicks on the main window's Unlock button).
struct AppLockRoot: ViewModifier {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var phase
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let cover = AppLock.cover(mode: lock.mode, isUnlocked: lock.isUnlocked, phase: phase,
                                  returning: lock.backgroundedAt != nil)
        content
            .accessibilityHidden(cover.locked || cover.privacy)
            #if os(macOS)
            .overlay {
                if cover.locked { LockView() }
            }
            #endif
            // Synchronous so the cover is up before iOS snapshots for the app switcher.
            .onChange(of: cover, initial: true) { _, cover in LockWindow.update(cover, lock: lock, theme: theme) }
            #if !os(macOS)
            .onChange(of: theme) { _, theme in LockWindow.update(cover, lock: lock, theme: theme) }
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

enum LockWindow {
    #if os(macOS)
    private static var sheet: NSWindow?

    static func update(_ cover: AppLock.Cover, lock: AppLock, theme: Palette.Variant) {
        for window in NSApp.windows where window.sheetParent != nil && window !== sheet {
            window.contentView?.isHidden = cover.locked
        }
        if cover.locked {
            guard sheet == nil,
                  let deepest = NSApp.windows.first(where: { $0.sheetParent != nil && $0.attachedSheet == nil })
            else { return }
            let window = NSWindow(contentViewController: NSHostingController(rootView: LockCover(cover: cover, lock: lock, theme: theme)))
            sheet = window
            deepest.beginSheet(window)
        } else if let sheet {
            sheet.sheetParent?.endSheet(sheet)
            self.sheet = nil
        }
    }
    #else
    // ponytail: one window on the first connected scene (app is iPhone-only, single scene); per-scene windows if multi-window ever ships.
    private static var window: UIWindow?
    private static var host: UIHostingController<LockCover>?

    static func update(_ cover: AppLock.Cover, lock: AppLock, theme: Palette.Variant) {
        let root = LockCover(cover: cover, lock: lock, theme: theme)
        if let host, window?.windowScene != nil {
            host.rootView = root  // keep LockView identity so its unlock task doesn't re-run
        } else if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            // First use, or the old window's scene disconnected: rebuild.
            window?.isHidden = true
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            host.view.accessibilityViewIsModal = true
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = host
            self.host = host
            self.window = window
        }
        let covering = cover.locked || cover.privacy
        if covering {
            // A sheet's keyboard would otherwise stay above the lock.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            window?.makeKeyAndVisible()
        } else if let window, !window.isHidden {
            window.isHidden = true
            // Hand key back to the app's own window (normal level skips keyboard/system windows).
            window.windowScene?.windows.first { $0 !== window && !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
        }
    }
    #endif
}

private struct LockCover: View {
    let cover: AppLock.Cover
    let lock: AppLock
    let theme: Palette.Variant

    var body: some View {
        ZStack {
            if cover.locked { LockView() }
            if cover.privacy {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(theme.background).ignoresSafeArea())
            }
        }
        .environment(lock)
        .environment(\.theme, theme)
        .tint(Color(theme.accent))
        .foregroundStyle(Color(theme.text))
    }
}
