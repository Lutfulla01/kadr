// Kadr — welcome tour: 8 pages with animated illustrations. Shown once to new installs only.
// Re-open from the status menu ("Welcome Tour…") or Settings → General.
// Test flags: --onboarding (always show), --onboarding-page <n> (1-based). KADR_NO_ONBOARDING=1 skips the
// automatic show (scripted test runs). Test profile only: KADR_REDUCE_MOTION=1|0, KADR_ONBOARDING_FALLBACK=1
// (pre-macOS 26 background), KADR_TOUR_PERMS=none (permission rows as not granted), KADR_TOUR_DEMO=<seconds>
// (pages turn by themselves, then the tour finishes).
// Memory: the window, its views and every illustration loop are torn down on close. Loops run inside SwiftUI
// tasks that are cancelled as soon as their page is no longer current.
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Install detection and launch

enum Onboarding {
    static let version = 1
    private(set) static var isNewInstall = false
    private static var captured = false

    /// Called first thing in main.swift, before anything writes settings or data: a new install has an empty
    /// settings domain and no data folder.
    static func captureInstallState() {
        guard !captured else { return }
        captured = true
        let env = ProcessInfo.processInfo.environment
        let domain = Profile.suiteName ?? env["KADR_DEFAULTS_SUITE"] ?? Bundle.main.bundleIdentifier ?? "uz.lutfulla.kadr"
        let prefs = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Profile.dataDir.path)) ?? []
        isNewInstall = prefs.isEmpty && !files.contains { !$0.hasPrefix(".") }
    }

    /// End of a normal launch: test flags first, then the one automatic show for new installs.
    static func launchIfNeeded() {
        let args = CommandLine.arguments
        var page: Int?
        if let i = args.firstIndex(of: "--onboarding-page"), i + 1 < args.count, let n = Int(args[i + 1]) { page = n - 1 }
        if args.contains("--onboarding") || page != nil {
            DispatchQueue.main.async { OnboardingController.show(page: page ?? 0) }
            return
        }
        if Prefs.onboardingVersion >= version { return }
        if !isNewInstall {
            // Existing user (settings or data were already there): never show it on its own.
            Prefs.onboardingVersion = version
            KadrLog.write("знакомство: прежняя установка, отмечено без показа")
            return
        }
        if ProcessInfo.processInfo.environment["KADR_NO_ONBOARDING"] == "1" { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OnboardingController.show(page: 0) }
    }

    static var reduceMotion: Bool {
        if Profile.name != nil, let v = ProcessInfo.processInfo.environment["KADR_REDUCE_MOTION"] { return v == "1" }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static let forceFallback = Profile.name != nil && ProcessInfo.processInfo.environment["KADR_ONBOARDING_FALLBACK"] == "1"

    // Permission buttons: the system prompt once, after that System Settings (same flags as the rest of Kadr).
    static func grantScreenRecording() {
        if CGPreflightScreenCaptureAccess() { return }
        if !Prefs.d.bool(forKey: "askedScreenCapture") {
            Prefs.d.set(true, forKey: "askedScreenCapture")
            _ = CGRequestScreenCaptureAccess()
        } else {
            AppActions.openScreenRecordingSettings()
        }
    }

    static func grantAccessibility() {
        if AXIsProcessTrusted() { return }
        if !Prefs.d.bool(forKey: "askedAccessibility") {
            _ = SequentialPaster.ensureAccess()
        } else {
            SequentialPaster.openAccessibilitySettings()
        }
    }
}

// MARK: - Window

final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OnboardingController: NSObject, NSWindowDelegate {
    private(set) static var shared: OnboardingController?
    static let size = NSSize(width: 760, height: 540)
    static let cornerRadius: CGFloat = 26

    private var window: OnboardingWindow?
    private var monitor: Any?
    private let model: TourModel
    private var closing = false

    static func show(page: Int = 0) {
        if let s = shared {
            s.model.go(page)
            NSApp.activate(ignoringOtherApps: true)
            s.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = OnboardingController(page: page)
        shared = c
        c.present()
    }

    private init(page: Int) {
        model = TourModel(page: page)
        super.init()
        model.onFinish = { [weak self] in self?.finish() }
    }

    private func present() {
        let rect = NSRect(origin: .zero, size: Self.size)
        let w = OnboardingWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.title = L("Welcome to Kadr")
        w.identifier = NSUserInterfaceItemIdentifier("kadr.onboarding")
        w.setAccessibilityIdentifier("kadr.onboarding")
        w.setAccessibilityTitle(w.title)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        let host = NSHostingView(rootView: TourView(model: model))
        host.sizingOptions = []
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        w.contentView = Self.background(content: host, size: Self.size)
        w.delegate = self
        w.center()
        w.alphaValue = 0
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak w] in w?.invalidateShadow() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let win = self.window, e.window === win else { return e }
            return self.handleKey(e) ? nil : e
        }
        KadrLog.write("знакомство: показано, страница \(model.page + 1)")
        // Test profile only: KADR_TOUR_DEMO=<seconds> turns pages by itself (transition checks, screen recordings).
        if Profile.name != nil, let v = ProcessInfo.processInfo.environment["KADR_TOUR_DEMO"], let t = Double(v), t > 0 {
            scheduleDemo(after: t)
        }
    }

    private func scheduleDemo(after t: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
            guard let self, !self.closing else { return }
            if self.model.isLast { self.model.finish(); return }   // runs the real finish path: persist + release
            self.model.next()
            self.scheduleDemo(after: t)
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, e.charactersIgnoringModifiers == "w" { model.finish(); return true }
        guard mods.isEmpty || mods == .shift else { return false }
        switch e.keyCode {
        case 123: model.back(); return true           // ←
        case 124: model.next(); return true           // →
        case 53: model.finish(); return true          // Esc
        case 36, 76: model.primary(); return true     // Return, Enter
        default: return false
        }
    }

    /// Liquid Glass on macOS 26+, a behind-window material before that.
    private static func background(content: NSView, size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26, *), !Onboarding.forceFallback {
            let g = NSGlassEffectView(frame: frame)
            g.cornerRadius = cornerRadius
            g.style = .regular
            // Lean toward the window colour so text stays readable over any wallpaper.
            g.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72)
            g.contentView = content
            return g
        }
        let v = NSVisualEffectView(frame: frame)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        let r = cornerRadius
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        v.maskImage = mask
        content.frame = frame
        v.addSubview(content)
        return v
    }

    /// Finish, Skip, Esc and ⌘W all end up here: remember it, fade out, release everything.
    private func finish() {
        guard !closing else { return }
        closing = true
        Prefs.onboardingVersion = Onboarding.version
        KadrLog.write("знакомство: закрыто на странице \(model.page + 1)")
        removeMonitor()
        guard let w = window else { teardown(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.teardown() })
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func teardown() {
        removeMonitor()
        if let w = window {
            w.delegate = nil
            w.orderOut(nil)
            w.contentView = nil
            w.close()
        }
        window = nil
        model.onFinish = nil
        Self.shared = nil
        MemoryRelief.soon()
    }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        Prefs.onboardingVersion = Onboarding.version
        DispatchQueue.main.async { [weak self] in self?.teardown() }
    }
}

// MARK: - Model and pages

final class TourModel: ObservableObject {
    static let count = TourPage.allCases.count
    @Published private(set) var page: Int
    let reduceMotion = Onboarding.reduceMotion
    var onFinish: (() -> Void)?

    init(page: Int) { self.page = max(0, min(TourModel.count - 1, page)) }

    var isLast: Bool { page == Self.count - 1 }

    func go(_ p: Int) {
        guard p >= 0, p < Self.count, p != page else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.86)) { page = p }
    }

    func next() { go(page + 1) }
    func back() { go(page - 1) }
    func primary() { isLast ? finish() : next() }
    func finish() { onFinish?() }
}

enum TourPage: Int, CaseIterable {
    case welcome, press, shake, capture, markup, history, permissions, done

    var title: String {
        switch self {
        case .welcome: return L("Welcome to Kadr")
        case .press: return L("Three fingers, one press")
        case .shake: return L("Shake for a shelf")
        case .capture: return L("Capture any part of the screen")
        case .markup: return L("Mark up, pin, copy text")
        case .history: return L("Everything you copy, at hand")
        case .permissions: return L("Give Kadr access")
        case .done: return L("You’re all set")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return L("Screenshots and clipboard history in your menu bar. Nothing leaves your Mac.")
        case .press: return L("Press the trackpad with three fingers and your clipboard history slides in. With text selected, the same press copies it.")
        case .shake: return L("Drag a file and shake the pointer, and a shelf pops up under it. Shake with nothing in hand to open the text shelf.")
        case .capture: return L("Drag over an area, or press Space to pick a window. The shot is copied and saved to your Screenshots folder.")
        case .markup: return L("Add arrows, numbers and blur in the editor. Pin a shot above your windows, or copy the text right off it.")
        case .history: return L("Start typing to search, then press ⌘1 to paste. History is encrypted, and passwords are masked.")
        case .permissions: return L("Kadr asks only when you click Grant. You can change this later in System Settings.")
        case .done: return L("Kadr lives in the menu bar. Click its icon to capture, open history or change settings.")
        }
    }
}

// MARK: - Root view

// This toolchain (Command Line Tools) ships no SwiftUIMacros plugin, and the macOS 27 SDK resolves the `@State`
// attribute to a macro. A type alias picks the plain property wrapper instead.
private typealias TourState = SwiftUI.State

private let SW: CGFloat = 740   // stage
private let SH: CGFloat = 300

struct TourView: View {
    @ObservedObject var model: TourModel

    var body: some View {
        VStack(spacing: 0) {
            stage.padding(.top, 10)
            textArea.padding(.top, 20)
            Spacer(minLength: 0)
            controls.padding(.horizontal, 20).padding(.bottom, 18)
        }
        .frame(width: OnboardingController.size.width, height: OnboardingController.size.height)
        .overlay(alignment: .topTrailing) { skip }
    }

    private var stage: some View {
        ZStack {
            StageBackdrop(page: model.page)
            ForEach(TourPage.allCases, id: \.self) { p in
                sceneView(p).modifier(PageSlide(index: p.rawValue, current: model.page, distance: model.reduceMotion ? 0 : 130))
            }
        }
        .frame(width: SW, height: SH)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder private func sceneView(_ p: TourPage) -> some View {
        let a = model.page == p.rawValue
        let r = model.reduceMotion
        switch p {
        case .welcome: WelcomeScene(active: a, reduce: r)
        case .press: PressScene(active: a, reduce: r)
        case .shake: ShakeScene(active: a, reduce: r)
        case .capture: CaptureScene(active: a, reduce: r)
        case .markup: MarkupScene(active: a, reduce: r)
        case .history: HistoryScene(active: a, reduce: r)
        case .permissions: PermissionsScene(active: a, reduce: r)
        case .done: DoneScene(active: a, reduce: r)
        }
    }

    private var textArea: some View {
        ZStack(alignment: .top) {
            ForEach(TourPage.allCases, id: \.self) { p in
                PageText(page: p, model: model)
                    .modifier(PageSlide(index: p.rawValue, current: model.page, distance: model.reduceMotion ? 0 : 44))
            }
        }
        .frame(width: 720, height: 148, alignment: .top)
    }

    private var controls: some View {
        ZStack {
            PageDots(count: TourModel.count, current: model.page) { model.go($0) }
            HStack {
                if model.page > 0 {
                    Button { model.back() } label: {
                        Label(L("Back"), systemImage: "chevron.left").padding(.horizontal, 2)
                    }
                    .tourSecondary()
                    .transition(.opacity)
                }
                Spacer()
                Button { model.primary() } label: {
                    Text(model.isLast ? L("Start using Kadr") : L("Continue"))
                        .frame(minWidth: 96)
                        .padding(.horizontal, 4)
                }
                .keyboardShortcut(.defaultAction)
                .tourPrimary()
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var skip: some View {
        if !model.isLast {
            Button(L("Skip")) { model.finish() }
                .tourSecondary()
                .padding(.top, 22)
                .padding(.trailing, 22)
                .transition(.opacity)
        }
    }
}

private struct PageSlide: ViewModifier {
    let index: Int
    let current: Int
    let distance: CGFloat

    func body(content: Content) -> some View {
        let d = max(-1, min(1, index - current))
        // The outgoing page fades fast, the incoming one a beat later, so the two never read on top of each other.
        content
            .opacity(d == 0 ? 1 : 0)
            .animation(d == 0 ? .easeOut(duration: 0.32).delay(0.07) : .easeOut(duration: 0.13), value: current)
            .offset(x: CGFloat(d) * distance)
            .allowsHitTesting(d == 0)
            .accessibilityHidden(d != 0)
    }
}

private extension View {
    @ViewBuilder func tourPrimary() -> some View {
        if #available(macOS 26, *), !Onboarding.forceFallback {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder func tourSecondary() -> some View {
        if #available(macOS 26, *), !Onboarding.forceFallback {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// An illustration: fixed stage size, script restarts every time the page becomes current.
    func tourScene(active: Bool, run: @escaping () async throws -> Void) -> some View {
        frame(width: SW, height: SH)
            .task(id: active) {
                guard active else { return }
                try? await run()
            }
    }

    /// Place a cursor so that its tip is at `p`.
    func tip(_ p: CGPoint) -> some View { position(x: p.x + 6, y: p.y + 9.5) }
}

private func pause(_ s: Double) async throws { try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

private func instant(_ body: () -> Void) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t, body)
}

// MARK: - Text, accessories, controls

private struct PageText: View {
    let page: TourPage
    @ObservedObject var model: TourModel

    var body: some View {
        VStack(spacing: 7) {
            Text(page.title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
            Text(page.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .frame(width: 548)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 40, alignment: .top)
            accessory.padding(.top, 8)
        }
    }

    @ViewBuilder private var accessory: some View {
        switch page {
        case .welcome:
            HStack(spacing: 18) {
                Label(L("No network access"), systemImage: "wifi.slash")
                Label(L("History encrypted on disk"), systemImage: "lock.fill")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
        case .press: PressToggles(model: model)
        case .shake: ShakeToggles()
        case .capture:
            HStack(spacing: 22) {
                ShortcutItem(keys: ShortcutItem.keys(.area), label: L("Area"))
                ShortcutItem(keys: ShortcutItem.keys(.window), label: L("Window"))
                ShortcutItem(keys: ShortcutItem.keys(.screen), label: L("Screen"))
            }
        case .markup:
            ShortcutItem(keys: ShortcutItem.keys(.ocr), label: L("Copy text from screen"))
        case .history:
            HStack(spacing: 22) {
                ShortcutItem(keys: ShortcutItem.keys(.clipboard), label: L("Open history"))
                ShortcutItem(keys: ["⌘", "1"], label: L("Paste the first item"))
            }
        case .permissions, .done:
            EmptyView()
        }
    }
}

private struct PressToggles: View {
    @ObservedObject var model: TourModel
    @AppStorage("clipGesture", store: Prefs.d) private var clipGesture = false
    @AppStorage("clipEdge", store: Prefs.d) private var clipEdge = false
    @TourState private var dragOn = GestureTrigger.systemThreeFingerDrag()

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 28) {
                Toggle(L("Three-finger press"), isOn: $clipGesture).disabled(dragOn)
                Toggle(L("Screen edge"), isOn: $clipEdge)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 13, weight: .medium))
            HStack(spacing: 5) {
                if dragOn { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                Text(dragOn ? L("Three-finger drag is on in System Settings, so Kadr leaves the press alone.")
                            : L("Both are off by default. The press stays off while three-finger drag is on in System Settings."))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .onChange(of: model.page) { _, p in
            if p == TourPage.press.rawValue { dragOn = GestureTrigger.systemThreeFingerDrag() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dragOn = GestureTrigger.systemThreeFingerDrag()
        }
    }
}

private struct ShakeToggles: View {
    @AppStorage("shakeEnabled", store: Prefs.d) private var shakeEnabled = true
    @AppStorage("idleShakeEnabled", store: Prefs.d) private var idleShakeEnabled = false

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 28) {
                Toggle(L("Shake while dragging"), isOn: $shakeEnabled)
                Toggle(L("Shake without dragging"), isOn: $idleShakeEnabled)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 13, weight: .medium))
            HStack(spacing: 18) {
                ShortcutItem(keys: ShortcutItem.keys(.shelf), label: L("New shelf"), small: true)
                ShortcutItem(keys: ShortcutItem.keys(.textShelf), label: L("Text shelf"), small: true)
            }
        }
    }
}

private struct ShortcutItem: View {
    let keys: [String]?
    let label: String
    var small = false

    /// Current shortcut of the action, split into keys (the user may have changed it in Settings).
    static func keys(_ a: HotkeyAction) -> [String]? {
        Prefs.hotkey(a).map { s in s.modifierSymbols.map { String($0) } + [KeyNames.name(s.keyCode)] }
    }

    var body: some View {
        HStack(spacing: small ? 6 : 8) {
            if let keys {
                HStack(spacing: small ? 2 : 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(label: $0.element, small: small) }
                }
            } else {
                Text(L("Not Set")).foregroundStyle(.tertiary)
            }
            Text(label).foregroundStyle(.secondary)
        }
        .font(.system(size: small ? 12 : 13))
    }
}

/// A real-looking keycap: face with a light gradient, a darker lower edge and a soft shadow.
private struct Keycap: View {
    let label: String
    var small = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let h: CGFloat = small ? 19 : 24
        let r: CGFloat = small ? 4.5 : 6
        let fs: CGFloat = small ? 10.5 : 12.5
        return Text(label)
            .font(Font.system(size: fs, weight: .medium))
            .foregroundStyle(dark ? Color.white.opacity(0.92) : Color.black.opacity(0.75))
            .frame(minWidth: h - 10)
            .padding(.horizontal, small ? 4.5 : 6)
            .frame(height: h)
            .background {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(LinearGradient(colors: dark ? [Color(white: 0.34), Color(white: 0.27)] : [.white, Color(white: 0.95)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                        .strokeBorder(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10), lineWidth: 0.5))
            }
            .padding(.bottom, small ? 1.5 : 2)
            .background {
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(dark ? Color(white: 0.13) : Color(white: 0.77))
            }
            .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 1.5, y: 1)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    let go: (Int) -> Void
    @TourState private var hover: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Button { go(i) } label: {
                    Capsule()
                        .fill(i == current ? Color.accentColor : Color.primary.opacity(hover == i ? 0.4 : 0.2))
                        .frame(width: i == current ? 22 : 7, height: 7)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.12)) { hover = inside ? i : (hover == i ? nil : hover) }
                }
                .accessibilityLabel(Lf("Page %d of %d", i + 1, count))
            }
        }
    }
}

// MARK: - Shared illustration pieces

private enum TC {
    static func window(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.17) : .white }
    static func line(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.09) }
    static func strongLine(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.32) : Color.black.opacity(0.22) }
}

/// The stage: soft wallpaper whose colour spots drift from page to page, over a faint dot grid.
private struct StageBackdrop: View {
    let page: Int
    @Environment(\.colorScheme) private var scheme
    private static let hues: [Color] = [.purple, .pink, .orange, .teal, .indigo, .mint, .blue, .pink]
    private static let spots: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 230, y: 40), CGPoint(x: 560, y: 260)),
        (CGPoint(x: 170, y: 250), CGPoint(x: 600, y: 60)),
        (CGPoint(x: 560, y: 260), CGPoint(x: 160, y: 50)),
        (CGPoint(x: 320, y: 30), CGPoint(x: 660, y: 240)),
        (CGPoint(x: 120, y: 120), CGPoint(x: 560, y: 40)),
        (CGPoint(x: 600, y: 230), CGPoint(x: 160, y: 60)),
        (CGPoint(x: 370, y: 270), CGPoint(x: 120, y: 30)),
        (CGPoint(x: 220, y: 160), CGPoint(x: 620, y: 220)),
    ]

    var body: some View {
        let dark = scheme == .dark
        let s = Self.spots[max(0, min(Self.spots.count - 1, page))]
        let hue = Self.hues[max(0, min(Self.hues.count - 1, page))]
        ZStack {
            dark ? Color(white: 0.105) : Color(white: 0.972)
            Circle()
                .fill(RadialGradient(colors: [Color.accentColor.opacity(dark ? 0.42 : 0.30), Color.accentColor.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 280))
                .frame(width: 560, height: 560)
                .position(s.0)
            Circle()
                .fill(RadialGradient(colors: [hue.opacity(dark ? 0.30 : 0.24), hue.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 250))
                .frame(width: 500, height: 500)
                .position(s.1)
            DotGrid().foregroundStyle(Color.primary.opacity(dark ? 0.08 : 0.07))
        }
        .frame(width: SW, height: SH)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for x in stride(from: CGFloat(10), to: size.width, by: 20) {
                for y in stride(from: CGFloat(10), to: size.height, by: 20) {
                    p.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                }
            }
            ctx.fill(p, with: .foreground)
        }
        .allowsHitTesting(false)
    }
}

private struct Bar: View {
    var w: CGFloat
    var h: CGFloat = 6
    var strong = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Capsule().fill(strong ? TC.strongLine(scheme) : TC.line(scheme)).frame(width: w, height: h)
    }
}

private struct MockWindow<Content: View>: View {
    var width: CGFloat
    var height: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 7, height: 7)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 7, height: 7)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 7, height: 7)
            }
            .padding(.leading, 9)
            .frame(height: 20)
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(TC.window(scheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.primary.opacity(dark ? 0.16 : 0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.13), radius: 12, y: 6)
    }
}

/// Panel surface like Kadr's own panels (history, shelves).
private struct PanelSurface: ViewModifier {
    var radius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background(dark ? Color(white: 0.19) : Color(white: 0.995), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(dark ? 0.16 : 0.09), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.15), radius: 14, y: 7)
    }
}

private struct TourPill: View {
    let symbol: String
    let text: String
    var small = false
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: small ? 4 : 6) {
            Image(systemName: symbol)
                .font(.system(size: small ? 9 : 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: small ? 10 : 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .padding(.horizontal, small ? 8 : 11)
        .frame(height: small ? 20 : 28)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}

private struct ArrowCursorShape: SwiftUI.Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 16.6), (3.9, 12.9), (6.5, 18.9), (9.1, 17.8), (6.6, 11.9), (11.8, 11.9)]
        let sx = r.width / 12, sy = r.height / 19
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: r.minX + q.0 * sx, y: r.minY + q.1 * sy)) }
        p.closeSubpath()
        return p
    }
}

private struct Cursor: View {
    var body: some View {
        ZStack {
            ArrowCursorShape().stroke(Color.white, style: StrokeStyle(lineWidth: 2.6, lineJoin: .round))
            ArrowCursorShape().fill(Color.black)
        }
        .frame(width: 12, height: 19)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

private struct Crosshair: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.white).frame(width: 19, height: 3)
            Rectangle().fill(Color.white).frame(width: 3, height: 19)
            Rectangle().fill(Color.black).frame(width: 17, height: 1)
            Rectangle().fill(Color.black).frame(width: 1, height: 17)
        }
        .shadow(color: .black.opacity(0.25), radius: 1)
    }
}

/// Four viewfinder corners: Kadr's own motif.
private struct Brackets: SwiftUI.Shape {
    var len: CGFloat = 22
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(len, r.width / 2, r.height / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

private struct Ridge: SwiftUI.Shape {
    let pts: [CGPoint]   // normalised 0…1
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        for q in pts { p.addLine(to: CGPoint(x: r.minX + q.x * r.width, y: r.minY + q.y * r.height)) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A tiny landscape photo used as "the screenshot".
private struct PhotoBlock: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: dark ? [Color(red: 0.17, green: 0.25, blue: 0.50), Color(red: 0.50, green: 0.33, blue: 0.52)]
                                            : [Color(red: 0.50, green: 0.72, blue: 1.0), Color(red: 1.0, green: 0.82, blue: 0.72)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1, green: 0.85, blue: 0.45))
                    .frame(width: g.size.height * 0.24, height: g.size.height * 0.24)
                    .position(x: g.size.width * 0.72, y: g.size.height * 0.33)
                Ridge(pts: [CGPoint(x: 0, y: 0.70), CGPoint(x: 0.18, y: 0.50), CGPoint(x: 0.33, y: 0.62), CGPoint(x: 0.50, y: 0.40),
                            CGPoint(x: 0.68, y: 0.60), CGPoint(x: 0.85, y: 0.48), CGPoint(x: 1, y: 0.62)])
                    .fill(dark ? Color(red: 0.22, green: 0.27, blue: 0.45) : Color(red: 0.45, green: 0.58, blue: 0.84))
                Ridge(pts: [CGPoint(x: 0, y: 0.86), CGPoint(x: 0.22, y: 0.68), CGPoint(x: 0.42, y: 0.82), CGPoint(x: 0.62, y: 0.64),
                            CGPoint(x: 0.82, y: 0.80), CGPoint(x: 1, y: 0.72)])
                    .fill(dark ? Color(red: 0.12, green: 0.16, blue: 0.29) : Color(red: 0.24, green: 0.40, blue: 0.56))
            }
        }
    }
}

private struct DocShape: SwiftUI.Shape {
    var fold: CGFloat = 9
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct FileIcon: View {
    var badge = "PDF"
    var color: Color = Color(red: 0.92, green: 0.26, blue: 0.24)
    var name: String?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                DocShape().fill(Color.white)
                DocShape().stroke(Color.black.opacity(0.16), lineWidth: 0.6)
                Path { p in
                    p.move(to: CGPoint(x: 25, y: 0)); p.addLine(to: CGPoint(x: 25, y: 9)); p.addLine(to: CGPoint(x: 34, y: 9)); p.closeSubpath()
                }
                .fill(Color(white: 0.86))
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(Color.black.opacity(0.12)).frame(width: i == 2 ? 14 : 20, height: 2)
                    }
                }
                .padding(.bottom, 19)
                Text(verbatim: badge)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(color, in: RoundedRectangle(cornerRadius: 2))
                    .padding(.bottom, 6)
            }
            .frame(width: 34, height: 42)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            if let name {
                Text(name).font(.system(size: 9, weight: .medium)).foregroundStyle(.primary).lineLimit(1).fixedSize()
            }
        }
    }
}

// MARK: - 1. Welcome

private struct WelcomeScene: View {
    let active: Bool
    let reduce: Bool
    @TourState private var box = CGSize(width: 340, height: 250)
    @TourState private var boxOpacity = 0.0
    @TourState private var iconScale = 0.6
    @TourState private var iconOpacity = 0.0
    @TourState private var iconBlur = 14.0
    @TourState private var flash = 0.0
    @TourState private var glow = 0.0
    private let c = CGPoint(x: SW / 2, y: 146)

    var body: some View {
        ZStack {
            Ellipse().fill(Color.accentColor)
                .frame(width: 220, height: 60).blur(radius: 30)
                .opacity(0.5 * glow)
                .position(x: c.x, y: c.y + 74)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 136, height: 136)
                .scaleEffect(iconScale)
                .blur(radius: iconBlur)
                .opacity(iconOpacity)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
                .position(c)
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.white)
                .frame(width: 150, height: 150)
                .blur(radius: 8)
                .opacity(flash)
                .position(c)
            Brackets(len: 26)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .frame(width: box.width, height: box.height)
                .opacity(boxOpacity)
                .position(c)
        }
        .tourScene(active: active) { try await play() }
    }

    private func reset() {
        instant {
            box = CGSize(width: 340, height: 250); boxOpacity = 0
            iconScale = 0.6; iconOpacity = 0; iconBlur = 14; flash = 0; glow = 0
        }
    }

    private func play() async throws {
        reset()
        if reduce {
            instant { box = CGSize(width: 200, height: 200); boxOpacity = 0.45; iconScale = 1; iconOpacity = 1; iconBlur = 0; glow = 1 }
            return
        }
        try await pause(0.25)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { box = CGSize(width: 172, height: 172); boxOpacity = 1 }
        try await pause(0.5)
        withAnimation(.easeOut(duration: 0.09)) { flash = 0.85 }
        try await pause(0.09)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.62)) { iconScale = 1; iconOpacity = 1; iconBlur = 0 }
        withAnimation(.easeOut(duration: 0.7)) { flash = 0 }
        withAnimation(.easeOut(duration: 1.4)) { glow = 1 }
        try await pause(0.7)
        withAnimation(.spring(response: 1.0, dampingFraction: 0.85)) { box = CGSize(width: 200, height: 200); boxOpacity = 0.45 }
    }
}

// MARK: - 2. Three-finger press (and screen edge)

private struct PressScene: View {
    let active: Bool
    let reduce: Bool
    @Environment(\.colorScheme) private var scheme

    @TourState private var beat = 0
    @TourState private var on = [false, false, false]
    @TourState private var ripS: [CGFloat] = [1, 1, 1]
    @TourState private var ripO: [Double] = [0, 0, 0]
    @TourState private var pressed = false
    @TourState private var clickS: CGFloat = 1
    @TourState private var clickO = 0.0
    @TourState private var panel = false
    @TourState private var cursor = CGPoint(x: 150, y: 120)
    @TourState private var nudge: CGFloat = 0
    @TourState private var selW: CGFloat = 0
    @TourState private var selO = 0.0
    @TourState private var copied = false
    @TourState private var edge = 0.0

    private let tp = CGPoint(x: 182, y: 180)          // trackpad centre
    private let dc = CGPoint(x: 492, y: 150)          // display centre (top clears the Skip button)
    private let fingers = [CGPoint(x: -54, y: 14), CGPoint(x: 0, y: -12), CGPoint(x: 54, y: 14)]
    private let home = CGPoint(x: 150, y: 120)        // cursor, screen coordinates

    private static let beats: [(String, String)] = [
        ("hand.tap", "Three-finger press"), ("text.cursor", "Press on selected text"), ("sidebar.right", "Screen edge"),
    ]

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Ellipse().fill(Color.black.opacity(dark ? 0.45 : 0.16))
                .frame(width: 250, height: 34).blur(radius: 14)
                .position(x: tp.x, y: tp.y + 52)
            trackpad.position(tp)
            stand.position(x: dc.x, y: dc.y + 118)
            display.position(dc)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                TourPill(symbol: Self.beats[beat].0, text: L(Self.beats[beat].1))
                    .id(beat)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity))
            }
            .padding(18)
        }
        .tourScene(active: active) { try await play() }
    }

    // Trackpad lying on the desk, seen in perspective.
    private var trackpad: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return ZStack {
            shape.fill(dark ? Color(white: 0.10) : Color(white: 0.70)).offset(y: 8)
            shape.fill(LinearGradient(colors: dark ? [Color(white: 0.31), Color(white: 0.21)] : [Color(white: 0.995), Color(white: 0.87)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(LinearGradient(colors: [Color.white.opacity(dark ? 0.10 : 0.55), .clear], startPoint: .topLeading, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.28 : 1), Color.black.opacity(dark ? 0.35 : 0.12)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            shape.stroke(Color.accentColor, lineWidth: 3).scaleEffect(clickS).opacity(clickO)
            ForEach(0..<3, id: \.self) { i in finger(i).offset(x: fingers[i].x, y: fingers[i].y) }
        }
        .frame(width: 236, height: 158)
        .scaleEffect(pressed ? 0.965 : 1)
        .rotation3DEffect(.degrees(50), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45)
    }

    private func finger(_ i: Int) -> some View {
        ZStack {
            Circle().stroke(Color.accentColor, lineWidth: 2.5)
                .frame(width: 44, height: 44)
                .scaleEffect(ripS[i])
                .opacity(ripO[i])
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.95), Color.accentColor.opacity(0.92)],
                                     center: UnitPoint(x: 0.42, y: 0.36), startRadius: 1, endRadius: 26))
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                .shadow(color: Color.accentColor.opacity(0.6), radius: pressed ? 14 : 7)
                .scaleEffect(on[i] ? (pressed ? 0.84 : 1) : 1.45)
                .opacity(on[i] ? 1 : 0)
        }
    }

    private var stand: some View {
        let dark = scheme == .dark
        let metal = LinearGradient(colors: dark ? [Color(white: 0.34), Color(white: 0.20)] : [Color(white: 0.86), Color(white: 0.70)],
                                   startPoint: .top, endPoint: .bottom)
        return VStack(spacing: 0) {
            Rectangle().fill(metal).frame(width: 54, height: 18)
            Capsule().fill(metal).frame(width: 132, height: 8)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var display: some View {
        let dark = scheme == .dark
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Color(white: 0.05) : Color(white: 0.12))
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(dark ? 0.14 : 0.08), lineWidth: 1)
            screen.frame(width: 324, height: 198).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(width: 336, height: 210)
        .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 16, y: 10)
    }

    private var screen: some View {
        let dark = scheme == .dark
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: dark ? [Color(red: 0.13, green: 0.20, blue: 0.42), Color(red: 0.32, green: 0.17, blue: 0.42)]
                                        : [Color(red: 0.55, green: 0.71, blue: 1.0), Color(red: 0.83, green: 0.66, blue: 0.98)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Capsule().fill(Color.primary.opacity(0.55)).frame(width: 14, height: 3)
                    Capsule().fill(Color.primary.opacity(0.3)).frame(width: 18, height: 3)
                    Capsule().fill(Color.primary.opacity(0.3)).frame(width: 14, height: 3)
                    Spacer()
                    Circle().fill(Color.primary.opacity(0.4)).frame(width: 4, height: 4)
                    Capsule().fill(Color.primary.opacity(0.4)).frame(width: 16, height: 3)
                }
                .padding(.horizontal, 8)
                .frame(height: 12)
                .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
                Spacer(minLength: 0)
            }
            MockWindow(width: 200, height: 130) { windowContent }
                .position(x: 124, y: 95)
            Capsule().fill(Color.accentColor)
                .frame(width: 4, height: 130).blur(radius: 2)
                .opacity(edge)
                .position(x: 322, y: 105)
            historyPanel
                .position(x: 266, y: 105)
                .offset(x: panel ? 0 : 124)
            TourPill(symbol: "checkmark.circle.fill", text: L("Copied"), small: true)
                .scaleEffect(copied ? 1 : 0.6)
                .opacity(copied ? 1 : 0)
                .position(x: min(cursor.x + 26, 280), y: cursor.y - 18)
            Cursor().tip(CGPoint(x: cursor.x + nudge, y: cursor.y))
        }
        .frame(width: 324, height: 198)
    }

    private var windowContent: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2.5).fill(Color.accentColor.opacity(0.38))
                .frame(width: selW, height: 12)
                .offset(x: 10, y: 33)
                .opacity(selO)
            Bar(w: 90, h: 7, strong: true).offset(x: 12, y: 8)
            Bar(w: 160).offset(x: 12, y: 22)
            Bar(w: 150).offset(x: 12, y: 36)
            Bar(w: 170).offset(x: 12, y: 50)
            Bar(w: 120).offset(x: 12, y: 64)
            Bar(w: 140).offset(x: 12, y: 78)
        }
    }

    private var historyPanel: some View {
        let colors: [Color] = [.blue, .orange, .green, .purple, .gray]
        let widths: [CGFloat] = [52, 40, 58, 36, 46]
        return VStack(spacing: 5) {
            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 14)
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(colors[i].gradient).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Bar(w: widths[i], h: 4, strong: true)
                        Bar(w: 28, h: 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(7)
        .frame(width: 104, height: 174, alignment: .top)
        .modifier(PanelSurface(radius: 11))
    }

    private func setBeat(_ b: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { beat = b }
    }

    private func reset() {
        instant {
            beat = 0; on = [false, false, false]; ripS = [1, 1, 1]; ripO = [0, 0, 0]
            pressed = false; clickS = 1; clickO = 0; panel = false; cursor = home; nudge = 0
            selW = 0; selO = 0; copied = false; edge = 0
        }
    }

    /// Three contacts land one after another with a ripple, then the pad clicks.
    private func landAndPress() async throws {
        for i in 0..<3 {
            instant { ripS[i] = 1; ripO[i] = 0.85 }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { on[i] = true }
            withAnimation(.easeOut(duration: 0.75)) { ripS[i] = 2.4; ripO[i] = 0 }
            try await pause(0.07)
        }
        try await pause(0.32)
        instant { clickS = 1; clickO = 0.9 }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) { pressed = true }
        withAnimation(.easeOut(duration: 0.6)) { clickS = 1.12; clickO = 0 }
        try await pause(0.15)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.6)) { pressed = false }
    }

    private func lift() {
        withAnimation(.easeOut(duration: 0.3)) { on = [false, false, false] }
    }

    private func play() async throws {
        reset()
        if reduce {
            instant { on = [true, true, true]; panel = true }
            return
        }
        while true {
            // Beat 1: three-finger press opens history from the side.
            setBeat(0)
            try await pause(0.6)
            try await landAndPress()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { panel = true }
            try await pause(0.4)
            lift()
            try await pause(1.7)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.95)) { panel = false }
            try await pause(0.55)

            // Beat 2: select a line, press, it's copied.
            setBeat(1)
            withAnimation(.easeInOut(duration: 0.55)) { cursor = CGPoint(x: 36, y: 86) }
            try await pause(0.6)
            instant { selO = 1 }
            withAnimation(.easeInOut(duration: 0.7)) { cursor = CGPoint(x: 188, y: 86); selW = 154 }
            try await pause(0.8)
            try await landAndPress()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { copied = true }
            try await pause(0.4)
            lift()
            try await pause(1.3)
            withAnimation(.easeOut(duration: 0.3)) { copied = false; selO = 0 }
            try await pause(0.4)
            instant { selW = 0 }

            // Beat 3: push the pointer into the screen edge.
            setBeat(2)
            withAnimation(.easeIn(duration: 0.7)) { cursor = CGPoint(x: 319, y: 112) }
            try await pause(0.72)
            withAnimation(.easeOut(duration: 0.2)) { edge = 1 }
            for dx: CGFloat in [3, 0, 3, 0] {
                withAnimation(.easeInOut(duration: 0.08)) { nudge = dx }
                try await pause(0.08)
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { panel = true }
            withAnimation(.easeOut(duration: 0.5)) { edge = 0 }
            try await pause(1.8)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.95)) { panel = false }
            withAnimation(.easeInOut(duration: 0.8)) { cursor = home }
            try await pause(1.0)
        }
    }
}

// MARK: - 3. Shake for a shelf

private struct ShakeScene: View {
    let active: Bool
    let reduce: Bool
    @Environment(\.colorScheme) private var scheme

    @TourState private var beat = 0
    @TourState private var cursor = CGPoint(x: 136, y: 136)
    @TourState private var cursorO = 1.0
    @TourState private var shakeX: CGFloat = 0
    @TourState private var trail = 0.0
    @TourState private var carrying = false
    @TourState private var dropped = false
    @TourState private var shelf = false
    @TourState private var shelfFilled = false
    @TourState private var shelfO = 1.0
    @TourState private var textShelf = false
    @TourState private var snip = [false, false, false]
    @TourState private var picked = -1

    private let fileHome = CGPoint(x: 136, y: 140)
    private let grab = CGPoint(x: 4, y: 14)            // file centre relative to the pointer tip
    private let target = CGPoint(x: 440, y: 112)
    private var shelfCenter: CGPoint { CGPoint(x: target.x, y: target.y + 90) }
    private var slot: CGPoint { CGPoint(x: target.x - 46, y: target.y + 90) }
    private let tsCenter = CGPoint(x: 590, y: 186)

    private static let beats: [(String, String)] = [
        ("hand.draw", "Shake while dragging"), ("cursorarrow.motionlines", "Shake without dragging"),
    ]

    var body: some View {
        ZStack {
            finder.position(x: 155, y: 166)
            FileIcon().opacity(dropped ? 1 : (carrying ? 0.35 : 0)).position(fileHome)   // stays in Finder; dimmed while dragged
            fileShelf.scaleEffect(shelf ? 1 : 0.4, anchor: .top).opacity(shelf ? shelfO : 0).position(shelfCenter)
            textShelfPanel.scaleEffect(textShelf ? 1 : 0.4, anchor: .top).opacity(textShelf ? 1 : 0).position(tsCenter)
            if !shelfFilled {
                FileIcon()
                    .scaleEffect(carrying ? 1.1 : 1)
                    .position(dropped ? slot : (carrying ? CGPoint(x: cursor.x + shakeX + grab.x, y: cursor.y + grab.y) : fileHome))
                    .shadow(color: .black.opacity(carrying ? 0.25 : 0), radius: 8, y: 6)
            }
            ForEach(0..<3, id: \.self) { k in
                ghost(k)
                    .animation(.easeOut(duration: 0.08 * Double(k + 1)), value: shakeX)
            }
            Cursor().tip(CGPoint(x: cursor.x + shakeX, y: cursor.y)).opacity(cursorO)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                TourPill(symbol: Self.beats[beat].0, text: L(Self.beats[beat].1))
                    .id(beat)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity))
            }
            .padding(18)
        }
        .tourScene(active: active) { try await play() }
    }

    /// Motion trail: copies of the pointer (and file) that lag behind the shake.
    private func ghost(_ k: Int) -> some View {
        let alpha = [0.42, 0.26, 0.13][k] * trail
        return ZStack {
            if carrying && !dropped {
                FileIcon().position(x: cursor.x + shakeX + grab.x, y: cursor.y + grab.y)
            }
            Cursor().tip(CGPoint(x: cursor.x + shakeX, y: cursor.y))
        }
        .opacity(alpha)
    }

    private var finder: some View {
        MockWindow(width: 230, height: 176) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    Bar(w: 34, h: 5, strong: true)
                    Bar(w: 30, h: 5)
                    Bar(w: 38, h: 5)
                    Bar(w: 26, h: 5)
                }
                .padding(.top, 12)
                .padding(.leading, 10)
                .frame(width: 58, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.primary.opacity(0.04))
                Spacer(minLength: 0)
            }
        }
        .overlay {
            ZStack {
                FileIcon(badge: "TXT", color: Color(white: 0.45)).position(x: 158, y: 62)
                FileIcon(badge: "JPG", color: Color(red: 0.2, green: 0.62, blue: 0.36)).position(x: 96, y: 132)
                Text(L("Report.pdf")).position(x: 96, y: 92)
                Text(verbatim: "notes.txt").position(x: 158, y: 92)
                Text(verbatim: "IMG_2048.jpg").position(x: 96, y: 162)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.primary)
        }
    }

    private var fileShelf: some View {
        ZStack {
            if shelfFilled {
                HStack(spacing: 10) {
                    FileIcon()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Report.pdf")).font(.system(size: 11, weight: .semibold))
                        Text(L("1 file")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 23)
                .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    Text(L("Drop here")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(width: 148, height: 80)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
            }
        }
        .frame(width: 172, height: 104)
        .modifier(PanelSurface(radius: 16))
    }

    private var textShelfPanel: some View {
        let snippets = [L("Thanks, got it!"), L("See you at 10"), L("Invoice attached")]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "text.badge.plus").foregroundStyle(Color.accentColor)
                Text(L("Text shelf")).foregroundStyle(.primary)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.leading, 4)
            .padding(.bottom, 2)
            ForEach(0..<3, id: \.self) { i in
                HStack {
                    Text(snippets[i]).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 4)
                    if picked == i {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(picked == i ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .offset(y: snip[i] ? 0 : -8)
                .opacity(snip[i] ? 1 : 0)
            }
        }
        .padding(10)
        .frame(width: 196, height: 152, alignment: .top)
        .modifier(PanelSurface(radius: 14))
    }

    private func setBeat(_ b: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { beat = b }
    }

    private func reset() {
        instant {
            beat = 0; cursor = CGPoint(x: fileHome.x - grab.x, y: fileHome.y - grab.y); cursorO = 1; shakeX = 0; trail = 0
            carrying = false; dropped = false; shelf = false; shelfFilled = false; shelfO = 1
            textShelf = false; snip = [false, false, false]; picked = -1
        }
    }

    private func shake(_ amp: CGFloat) async throws {
        withAnimation(.easeOut(duration: 0.1)) { trail = 1 }
        for dx in [-amp, amp, -amp, amp, -amp * 0.8, amp * 0.55, 0] {
            withAnimation(.easeInOut(duration: 0.075)) { shakeX = dx }
            try await pause(0.075)
        }
        withAnimation(.easeOut(duration: 0.3)) { trail = 0 }
    }

    private func play() async throws {
        reset()
        if reduce {
            instant { shelf = true; shelfFilled = true; dropped = true; cursorO = 0 }
            return
        }
        while true {
            setBeat(0)
            try await pause(0.5)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { carrying = true }
            try await pause(0.25)
            withAnimation(.easeInOut(duration: 0.9)) { cursor = target }
            try await pause(0.95)
            try await shake(22)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) { shelf = true }
            try await pause(0.6)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { dropped = true }
            withAnimation(.easeInOut(duration: 0.7)) { cursor = CGPoint(x: target.x + 70, y: target.y - 36) }
            try await pause(0.42)
            withAnimation(.easeOut(duration: 0.12)) { shelfFilled = true; carrying = false }
            try await pause(1.5)
            withAnimation(.easeOut(duration: 0.35)) { shelfO = 0; cursorO = 0 }
            try await pause(0.4)
            instant { shelf = false; shelfFilled = false; dropped = false; shelfO = 1; cursor = CGPoint(x: 660, y: 60) }

            // Beat 2: shake with nothing in hand opens the text shelf.
            setBeat(1)
            withAnimation(.easeOut(duration: 0.25)) { cursorO = 1 }
            withAnimation(.easeInOut(duration: 0.6)) { cursor = CGPoint(x: tsCenter.x, y: tsCenter.y - 92) }
            try await pause(0.7)
            try await shake(20)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { textShelf = true }
            for i in 0..<3 {
                try await pause(0.07)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { snip[i] = true }
            }
            try await pause(0.6)
            withAnimation(.easeInOut(duration: 0.5)) { cursor = CGPoint(x: tsCenter.x + 44, y: tsCenter.y + 2) }
            try await pause(0.6)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { picked = 1 }
            try await pause(1.6)
            withAnimation(.easeOut(duration: 0.35)) { textShelf = false; cursorO = 0 }
            try await pause(0.45)
            reset()
            instant { cursorO = 0 }
            withAnimation(.easeOut(duration: 0.3)) { cursorO = 1 }
            try await pause(0.3)
        }
    }
}

// MARK: - 4. Capture

private struct CaptureScene: View {
    let active: Bool
    let reduce: Bool
    @Environment(\.colorScheme) private var scheme

    @TourState private var dim = 0.0
    @TourState private var selEnd = CGPoint(x: 150, y: 80)
    @TourState private var selO = 0.0
    @TourState private var cross = 0.0
    @TourState private var sizeLabel = false
    @TourState private var flash = 0.0
    @TourState private var thumb = CGRect.zero
    @TourState private var thumbO = 0.0
    @TourState private var copied = false

    private let p0 = CGPoint(x: 150, y: 80)
    private let p1 = CGPoint(x: 340, y: 212)
    private var selRect: CGRect { CGRect(x: p0.x, y: p0.y, width: max(0, selEnd.x - p0.x), height: max(0, selEnd.y - p0.y)) }
    private let corner = CGRect(x: 588, y: 190, width: 124, height: 86)

    var body: some View {
        let r = selRect
        ZStack {
            MockWindow(width: 380, height: 214) { windowContent }.position(x: 330, y: 162)
            DimShape(hole: r).fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true)).opacity(dim)
            ZStack {
                Rectangle().strokeBorder(Color.white.opacity(0.95), lineWidth: 1)
                Brackets(len: 11).stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .opacity(selO)
            Text(verbatim: "\(Int(p1.x - p0.x) * 2) × \(Int(p1.y - p0.y) * 2)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: Capsule())
                .scaleEffect(sizeLabel ? 1 : 0.7)
                .opacity(sizeLabel ? 1 : 0)
                .position(x: p1.x + 2, y: p1.y + 16)
            Crosshair().position(selEnd).opacity(cross)
            Rectangle().fill(Color.white).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY).opacity(flash)
            thumbnail
                .frame(width: thumb.width, height: thumb.height)
                .position(x: thumb.midX, y: thumb.midY)
                .opacity(thumbO)
            TourPill(symbol: "checkmark.circle.fill", text: L("Copied"))
                .scaleEffect(copied ? 1 : 0.6)
                .opacity(copied ? 1 : 0)
                .position(x: corner.midX, y: corner.minY - 24)
        }
        .tourScene(active: active) { try await play() }
    }

    private var windowContent: some View {
        ZStack(alignment: .topLeading) {
            PhotoBlock()
                .frame(width: 170, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .offset(x: 18, y: 14)
            VStack(alignment: .leading, spacing: 8) {
                Bar(w: 110, h: 8, strong: true)
                Bar(w: 140)
                Bar(w: 120)
                Bar(w: 150)
                Bar(w: 96)
            }
            .offset(x: 204, y: 18)
            VStack(alignment: .leading, spacing: 8) {
                Bar(w: 330)
                Bar(w: 300)
                Bar(w: 200)
            }
            .offset(x: 18, y: 142)
        }
    }

    private var thumbnail: some View {
        GeometryReader { g in
            ZStack {
                TC.window(scheme)
                PhotoBlock()
                    .frame(width: g.size.width * 0.86, height: g.size.height * 0.80)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        }
    }

    private func reset() {
        instant {
            dim = 0; selEnd = p0; selO = 0; cross = 0; sizeLabel = false; flash = 0
            thumb = CGRect(x: p0.x, y: p0.y, width: p1.x - p0.x, height: p1.y - p0.y); thumbO = 0; copied = false
        }
    }

    private func play() async throws {
        reset()
        if reduce {
            instant { thumb = corner; thumbO = 1; copied = true }
            return
        }
        while true {
            try await pause(0.45)
            withAnimation(.easeOut(duration: 0.25)) { dim = 1; cross = 1 }
            try await pause(0.35)
            instant { selO = 1 }
            withAnimation(.spring(response: 0.95, dampingFraction: 1)) { selEnd = p1 }
            try await pause(1.0)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { sizeLabel = true }
            try await pause(0.5)
            withAnimation(.easeOut(duration: 0.07)) { flash = 0.95 }
            try await pause(0.07)
            instant { thumbO = 1 }
            withAnimation(.easeOut(duration: 0.45)) { flash = 0; dim = 0; selO = 0; cross = 0; sizeLabel = false }
            withAnimation(.spring(response: 0.62, dampingFraction: 0.78)) { thumb = corner }
            try await pause(0.55)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { copied = true }
            try await pause(2.2)
            withAnimation(.easeOut(duration: 0.35)) { thumbO = 0; copied = false }
            try await pause(0.5)
            reset()
        }
    }
}

/// Everything except the selection: the dimmed screen during an area capture.
private struct DimShape: SwiftUI.Shape {
    var hole: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.origin.x, hole.origin.y), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in r: CGRect) -> Path {
        var p = Path(r)
        p.addRect(hole)
        return p
    }
}

// MARK: - 5. Markup, pin, OCR

private struct MarkupScene: View {
    let active: Bool
    let reduce: Bool
    @Environment(\.colorScheme) private var scheme

    @TourState private var tool = -1
    @TourState private var arrow: CGFloat = 0
    @TourState private var head = false
    @TourState private var badge = false
    @TourState private var mosaic = false
    @TourState private var lifted = false
    @TourState private var pinned = false
    @TourState private var ocr = [CGFloat](repeating: 0, count: 4)
    @TourState private var textCopied = false

    private let card = CGSize(width: 320, height: 200)
    private let cardCenter = CGPoint(x: 290, y: 156)
    private let lines: [CGFloat] = [250, 214, 268, 160]
    private let from = CGPoint(x: 52, y: 100)
    private let to = CGPoint(x: 150, y: 52)

    var body: some View {
        ZStack {
            screenshot
                .scaleEffect(lifted ? 1.04 : 1)
                .rotationEffect(.degrees(lifted ? -2 : 0))
                .offset(y: lifted ? -6 : 0)
                .shadow(color: .black.opacity(lifted ? 0.32 : 0.14), radius: lifted ? 26 : 10, y: lifted ? 16 : 5)
                .position(cardCenter)
            toolbar.position(x: 506, y: 156)
            VStack(alignment: .leading, spacing: 12) {
                TourPill(symbol: "pin.fill", text: L("Pinned on top"))
                    .scaleEffect(pinned ? 1 : 0.6, anchor: .leading)
                    .opacity(pinned ? 1 : 0)
                TourPill(symbol: "checkmark.circle.fill", text: L("Text copied"))
                    .scaleEffect(textCopied ? 1 : 0.6, anchor: .leading)
                    .opacity(textCopied ? 1 : 0)
            }
            .frame(width: 180, alignment: .leading)
            .position(x: 640, y: 156)
        }
        .tourScene(active: active) { try await play() }
    }

    private var screenshot: some View {
        let dark = scheme == .dark
        let red = Color(red: 0.95, green: 0.23, blue: 0.21)
        return ZStack(alignment: .topLeading) {
            TC.window(scheme)
            PhotoBlock().frame(width: card.width, height: 118)
            // Name tag that gets blurred.
            HStack(spacing: 4) {
                Image(systemName: "person.fill").font(.system(size: 8))
                Capsule().fill(Color.black.opacity(0.35)).frame(width: 42, height: 4)
            }
            .foregroundStyle(Color.black.opacity(0.55))
            .padding(.horizontal, 7)
            .frame(width: 78, height: 18)
            .background(Color.white.opacity(0.85), in: Capsule())
            .offset(x: 230, y: 90)
            MosaicGrid(columns: 8, rows: 2, cell: CGSize(width: 10, height: 10), on: mosaic)
                .offset(x: 229, y: 89)
            ForEach(0..<4, id: \.self) { i in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(dark ? 0.45 : 0.30))
                        .frame(width: (lines[i] + 6) * ocr[i], height: 12)
                        .offset(x: -3)
                    Bar(w: lines[i], h: 6, strong: i == 0)
                }
                .offset(x: 20, y: 132 + CGFloat(i) * 16)
            }
            ArrowPath(from: from, to: to)
                .trim(from: 0, to: arrow)
                .stroke(red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            ArrowHead()
                .fill(red)
                .frame(width: 18, height: 16)
                .rotationEffect(.radians(Double(atan2(to.y - 70, to.x - 115))) + .degrees(90))
                .scaleEffect(head ? 1 : 0.2)
                .opacity(head ? 1 : 0)
                .position(to)
            ZStack {
                Circle().fill(red)
                Circle().strokeBorder(Color.white, lineWidth: 2)
                Text(verbatim: "1").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            .scaleEffect(badge ? 1 : 0.1)
            .opacity(badge ? 1 : 0)
            .position(x: 254, y: 30)
        }
        .frame(width: card.width, height: card.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if pinned {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: "pin.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .offset(x: 10, y: -10)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
    }

    private var toolbar: some View {
        let symbols = ["arrow.up.right", "1.circle", "checkerboard.rectangle", "pin", "text.viewfinder"]
        return VStack(spacing: 4) {
            ForEach(0..<symbols.count, id: \.self) { i in
                Image(systemName: symbols[i])
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tool == i ? Color.white : Color.primary.opacity(0.75))
                    .frame(width: 30, height: 30)
                    .background(tool == i ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(5)
        .modifier(PanelSurface(radius: 12))
    }

    private func reset() {
        instant {
            tool = -1; arrow = 0; head = false; badge = false; mosaic = false
            lifted = false; pinned = false; ocr = [0, 0, 0, 0]; textCopied = false
        }
    }

    private func setTool(_ t: Int) { withAnimation(.easeOut(duration: 0.15)) { tool = t } }

    private func play() async throws {
        reset()
        if reduce {
            instant { arrow = 1; head = true; badge = true; mosaic = true; lifted = true; pinned = true; ocr = [1, 1, 1, 1]; textCopied = true }
            return
        }
        while true {
            try await pause(0.4)
            setTool(0)
            try await pause(0.25)
            withAnimation(.easeInOut(duration: 0.55)) { arrow = 1 }
            try await pause(0.45)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { head = true }
            try await pause(0.4)
            setTool(1)
            try await pause(0.25)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { badge = true }
            try await pause(0.55)
            setTool(2)
            try await pause(0.25)
            withAnimation(.easeOut(duration: 0.1)) { mosaic = true }
            try await pause(0.75)
            setTool(3)
            try await pause(0.2)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { lifted = true }
            try await pause(0.2)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { pinned = true }
            try await pause(0.8)
            setTool(4)
            for i in 0..<4 {
                withAnimation(.easeInOut(duration: 0.28)) { ocr[i] = 1 }
                try await pause(0.16)
            }
            try await pause(0.2)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { textCopied = true }
            try await pause(2.2)
            withAnimation(.easeOut(duration: 0.4)) {
                tool = -1; arrow = 0; head = false; badge = false; mosaic = false
                lifted = false; pinned = false; ocr = [0, 0, 0, 0]; textCopied = false
            }
            try await pause(0.6)
        }
    }
}

private struct ArrowPath: SwiftUI.Shape {
    let from: CGPoint
    let to: CGPoint
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: CGPoint(x: 115, y: 70))
        return p
    }
}

private struct ArrowHead: SwiftUI.Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.28))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Pixelation: square tiles fade in one after another over the hidden part.
private struct MosaicGrid: View {
    let columns: Int
    let rows: Int
    let cell: CGSize
    let on: Bool

    private func shade(_ i: Int) -> Color {
        let v = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let tones: [Color] = [Color(red: 0.62, green: 0.70, blue: 0.82), Color(red: 0.86, green: 0.86, blue: 0.88),
                              Color(red: 0.42, green: 0.52, blue: 0.66), Color(red: 0.95, green: 0.93, blue: 0.92)]
        return tones[Int(v * Double(tones.count)) % tones.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { c in
                        let i = r * columns + c
                        Rectangle().fill(shade(i))
                            .frame(width: cell.width, height: cell.height)
                            .opacity(on ? 1 : 0)
                            .animation(.easeOut(duration: 0.18).delay(on ? Double(i) * 0.025 : 0), value: on)
                    }
                }
            }
        }
    }
}

// MARK: - 6. Clipboard history

private struct HistoryScene: View {
    let active: Bool
    let reduce: Bool
    @Environment(\.colorScheme) private var scheme

    @TourState private var shown = [false, false, false, false]
    @TourState private var typed = ""
    @TourState private var searching = false
    @TourState private var others = true      // non-matching rows visible
    @TourState private var filtered = false
    @TourState private var highlight = false
    @TourState private var keyDown = false
    @TourState private var pasted = false

    private let panelCenter = CGPoint(x: 360, y: 152)
    private let match = 1

    private struct Item {
        let symbol: String
        let color: Color
        let title: String
        let source: String
    }

    private var items: [Item] {
        [Item(symbol: "link", color: .blue, title: "example.com/pricing", source: "Safari"),
         Item(symbol: "doc.text", color: .orange, title: L("Meeting at 3 pm"), source: L("Notes")),
         Item(symbol: "photo", color: .green, title: "IMG_2048.png", source: "Finder"),
         Item(symbol: "key.fill", color: .gray, title: "••••••••••", source: L("Passwords"))]
    }

    var body: some View {
        ZStack {
            panel.position(panelCenter)
            TourPill(symbol: "arrow.down.doc", text: L("Pasted"))
                .scaleEffect(pasted ? 1 : 0.6, anchor: .leading)
                .opacity(pasted ? 1 : 0)
                .position(x: 600, y: 128)
        }
        .tourScene(active: active) { try await play() }
    }

    // The list collapses around the match (others fade first), so the panel never sits half empty.
    private var panel: some View {
        VStack(spacing: 20) {
            ZStack(alignment: .top) {
                ForEach(0..<items.count, id: \.self) { i in
                    card(i)
                        .offset(y: CGFloat(slot(i)) * 52 + (shown[i] ? 0 : -14))
                        .opacity(shown[i] && (others || i == match) ? 1 : 0)
                        .scaleEffect(!others && i != match ? 0.96 : 1)
                }
            }
            .frame(width: 296, height: filtered ? 46 : 46 + 3 * 52, alignment: .top)
            searchField
        }
        .padding(12)
        .modifier(PanelSurface(radius: 16))
    }

    private func slot(_ i: Int) -> Int { filtered ? (i == match ? 0 : i) : i }

    private func card(_ i: Int) -> some View {
        let it = items[i]
        let hi = highlight && i == match
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(it.color.gradient)
                Image(systemName: it.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .foregroundStyle(hi ? Color.white : Color.primary)
                Text(it.source).font(.system(size: 10))
                    .foregroundStyle(hi ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 4)
            Text(verbatim: "⌘\(slot(i) + 1)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(hi ? Color.white : Color.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(hi ? Color.white.opacity(keyDown ? 0.45 : 0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .scaleEffect(keyDown ? 0.88 : 1)
        }
        .padding(.horizontal, 9)
        .frame(width: 296, height: 46)
        .background(hi ? Color.accentColor : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if typed.isEmpty {
                Text(L("Search")).font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                Text(typed).font(.system(size: 12)).foregroundStyle(.primary)
            }
            if searching {
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 13).padding(.leading, -4)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 296, height: 28)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(searching ? 0.6 : 0), lineWidth: 1.5))
    }

    private func reset() {
        instant {
            shown = [false, false, false, false]; typed = ""; searching = false
            others = true; filtered = false; highlight = false; keyDown = false; pasted = false
        }
    }

    private func play() async throws {
        reset()
        let word = L("mee")
        if reduce {
            instant { shown = [true, true, true, true]; typed = word; others = false; filtered = true; highlight = true; pasted = true }
            return
        }
        while true {
            try await pause(0.3)
            for i in 0..<4 {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { shown[i] = true }
                try await pause(0.09)
            }
            try await pause(0.7)
            withAnimation(.easeOut(duration: 0.2)) { searching = true }
            for n in 1...word.count {
                try await pause(0.17)
                instant { typed = String(word.prefix(n)) }
            }
            try await pause(0.25)
            withAnimation(.easeOut(duration: 0.16)) { others = false }
            try await pause(0.12)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { filtered = true }
            try await pause(0.55)
            withAnimation(.easeOut(duration: 0.2)) { highlight = true }
            try await pause(0.5)
            withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { keyDown = true }
            try await pause(0.14)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { keyDown = false }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { pasted = true }
            try await pause(2.0)
            withAnimation(.easeOut(duration: 0.35)) {
                shown = [false, false, false, false]; pasted = false; searching = false
            }
            try await pause(0.45)
            reset()
        }
    }
}

// MARK: - 7. Permissions

private struct PermissionsScene: View {
    let active: Bool
    let reduce: Bool
    @TourState private var screen = PermissionsScene.screenGranted()
    @TourState private var ax = PermissionsScene.axGranted()
    @TourState private var rows = [false, false, false]
    @StateObject private var login = LoginItemModel()

    var body: some View {
        VStack(spacing: 0) {
            row(0, symbol: "record.circle", tint: .red, title: L("Screen Recording"),
                detail: L("For screenshots and text recognition")) { status(screen) { Onboarding.grantScreenRecording() } }
            Divider().padding(.leading, 58)
            row(1, symbol: "accessibility", tint: .blue, title: L("Accessibility"),
                detail: L("For pasting from history, gestures and selected text")) { status(ax) { Onboarding.grantAccessibility() } }
            Divider().padding(.leading, 58)
            row(2, symbol: "power", tint: .green, title: L("Launch at login"),
                detail: L("Kadr starts with your Mac and waits in the menu bar")) {
                Toggle("", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(Profile.name != nil)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 500)
        .modifier(PanelSurface(radius: 16))
        .position(x: SW / 2, y: SH / 2)
        .tourScene(active: active) { try await play() }
    }

    private func row<Trailing: View>(_ i: Int, symbol: String, tint: Color, title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient)
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .offset(y: rows[i] ? 0 : 10)
        .opacity(rows[i] ? 1 : 0)
    }

    @ViewBuilder private func status(_ granted: Bool, grant: @escaping () -> Void) -> some View {
        if granted {
            Label(L("Granted"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        } else {
            Button(L("Grant"), action: grant)
                .controlSize(.regular)
                .tourSecondary()
        }
    }

    /// KADR_TOUR_PERMS=none (test profile only) shows both as not granted, to check the Grant buttons.
    private static let fakeNone = Profile.name != nil && ProcessInfo.processInfo.environment["KADR_TOUR_PERMS"] == "none"
    static func screenGranted() -> Bool { fakeNone ? false : CGPreflightScreenCaptureAccess() }
    static func axGranted() -> Bool { fakeNone ? false : AXIsProcessTrusted() }

    private func refresh() {
        let s = Self.screenGranted(), a = Self.axGranted()
        if s != screen || a != ax { withAnimation(.easeOut(duration: 0.2)) { screen = s; ax = a } }
        login.refresh()
    }

    private func play() async throws {
        refresh()
        if reduce {
            instant { rows = [true, true, true] }
        } else {
            instant { rows = [false, false, false] }
            try await pause(0.12)
            for i in 0..<3 {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { rows[i] = true }
                try await pause(0.08)
            }
        }
        // Live status while the page is open (the task ends with the page).
        while true {
            try await pause(1.0)
            refresh()
        }
    }
}

// MARK: - 8. Done

private struct DoneScene: View {
    let active: Bool
    let reduce: Bool
    @Environment(\.colorScheme) private var scheme

    @TourState private var bar = false
    @TourState private var iconHi = false
    @TourState private var menu = false
    @TourState private var itemsOn = 0
    @TourState private var hover = -1
    @TourState private var check = false
    @TourState private var ringS: CGFloat = 1
    @TourState private var ringO = 0.0

    private let iconX: CGFloat = 520
    private struct Row { let symbol: String; let title: String; let keys: String }

    private var rows: [Row?] {
        func keys(_ a: HotkeyAction) -> String { Prefs.hotkey(a)?.display ?? "" }
        return [Row(symbol: HotkeyAction.area.symbol, title: HotkeyAction.area.title, keys: keys(.area)),
                Row(symbol: HotkeyAction.window.symbol, title: HotkeyAction.window.title, keys: keys(.window)),
                Row(symbol: HotkeyAction.screen.symbol, title: HotkeyAction.screen.title, keys: keys(.screen)),
                Row(symbol: HotkeyAction.ocr.symbol, title: HotkeyAction.ocr.title, keys: keys(.ocr)),
                nil,
                Row(symbol: HotkeyAction.clipboard.symbol, title: HotkeyAction.clipboard.title, keys: keys(.clipboard)),
                nil,
                Row(symbol: "gearshape", title: L("Settings…"), keys: "⌘,")]
    }

    var body: some View {
        ZStack {
            ZStack {
                Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 104, height: 104).scaleEffect(ringS).opacity(ringO)
                Circle().fill(Color.accentColor.gradient).frame(width: 96, height: 96)
                    .shadow(color: Color.accentColor.opacity(0.45), radius: 18, y: 8)
                Image(systemName: "checkmark").font(.system(size: 42, weight: .bold)).foregroundStyle(.white)
            }
            .scaleEffect(check ? 1 : 0.5)
            .opacity(check ? 1 : 0)
            .position(x: 220, y: 164)
            menuBar.offset(y: bar ? 0 : -30)
            menuPanel
                .scaleEffect(menu ? 1 : 0.94, anchor: .top)
                .opacity(menu ? 1 : 0)
                .position(x: iconX + 94, y: 30 + 86)
        }
        .tourScene(active: active) { try await play() }
    }

    private var menuBar: some View {
        let dark = scheme == .dark
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Capsule().fill(Color.primary.opacity(0.55)).frame(width: 34, height: 5)
                Capsule().fill(Color.primary.opacity(0.28)).frame(width: 22, height: 5)
                Capsule().fill(Color.primary.opacity(0.28)).frame(width: 26, height: 5)
                Capsule().fill(Color.primary.opacity(0.28)).frame(width: 20, height: 5)
                Spacer()
            }
            .padding(.leading, 22)
            .frame(width: SW, height: 26)
            .overlay(alignment: .leading) {
                HStack(spacing: 15) {
                    ZStack {
                        Capsule().fill(Color.primary.opacity(iconHi ? 0.16 : 0)).frame(width: 30, height: 20)
                        Image(systemName: "camera.viewfinder").font(.system(size: 13, weight: .medium))
                    }
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Image(systemName: "switch.2")
                    Image(systemName: "magnifyingglass")
                    Text(verbatim: "9:41").font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .offset(x: iconX - 15)
            }
            .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
            Spacer(minLength: 0)
        }
        .frame(width: SW, height: SH)
    }

    private var menuPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                Group {
                    if let row {
                        HStack(spacing: 8) {
                            Image(systemName: row.symbol).font(.system(size: 11.5)).frame(width: 16)
                            Text(row.title).font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.85).layoutPriority(1)
                            Spacer(minLength: 8)
                            Text(row.keys).font(.system(size: 12)).fixedSize()
                                .foregroundStyle(hover == i ? Color.white.opacity(0.85) : Color.secondary)
                        }
                        .foregroundStyle(hover == i ? Color.white : Color.primary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(hover == i ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Divider().padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
                .opacity(i < itemsOn ? 1 : 0)
                .offset(y: i < itemsOn ? 0 : -4)
            }
        }
        .padding(5)
        .frame(width: 244)
        .modifier(PanelSurface(radius: 10))
    }

    private func reset() {
        instant { bar = false; iconHi = false; menu = false; itemsOn = 0; hover = -1; check = false; ringS = 1; ringO = 0 }
    }

    private func play() async throws {
        reset()
        if reduce {
            instant { bar = true; iconHi = true; menu = true; itemsOn = rows.count; check = true }
            return
        }
        try await pause(0.15)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { bar = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { check = true }
        instant { ringS = 1; ringO = 0.8 }
        withAnimation(.easeOut(duration: 1.1)) { ringS = 1.7; ringO = 0 }
        try await pause(0.5)
        withAnimation(.easeOut(duration: 0.15)) { iconHi = true }
        try await pause(0.15)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { menu = true }
        for n in 1...rows.count {
            withAnimation(.easeOut(duration: 0.22)) { itemsOn = n }
            try await pause(0.035)
        }
        try await pause(0.5)
        withAnimation(.easeOut(duration: 0.12)) { hover = 0 }
    }
}
