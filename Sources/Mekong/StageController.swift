import AppKit
import Combine

/// The fullscreen projection: a borderless window covering one display
/// (menu bar included), with the pointer hidden over it.
///
/// It sits at the shielding level (the one macOS uses for captured
/// displays), above the menu bar, its status items such as the battery,
/// notifications and other HUDs. When it's on the screen that owns the menu
/// bar and Dock, those are hidden outright as well.
@MainActor
final class StageController: ObservableObject {
    struct Display: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let isMain: Bool
    }

    @Published private(set) var displays: [Display] = []
    @Published private(set) var isPresenting = false
    @Published private(set) var presentingOn: Display?
    /// The display the stage was on when it dropped out mid-set (a knocked
    /// cable, HDMI renegotiating). The stage goes back up when it returns.
    @Published private(set) var waitingFor: Display?

    /// Presenting, or waiting to present again.
    var isActive: Bool { isPresenting || waitingFor != nil }

    private let engine: VisualEngine
    private var window: NSWindow?
    private var view: VisualView?

    init(engine: VisualEngine) {
        self.engine = engine
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// 0 means "automatic": the first display without the menu bar, else the main one.
    func resolve(_ id: CGDirectDisplayID) -> Display? {
        displays.first(where: { $0.id == id })
            ?? displays.first(where: { !$0.isMain })
            ?? displays.first
    }

    func present(on id: CGDirectDisplayID) {
        guard let display = resolve(id),
              let screen = Self.screen(display.id) else { return }
        stop()

        let window = StageWindow(contentRect: screen.frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        let view = VisualView(engine: engine, fps: 60, hidesCursor: true)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        if screen == NSScreen.screens.first {
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        }

        self.window = window
        self.view = view
        presentingOn = display
        isPresenting = true
    }

    func stop() {
        takeDown()
        waitingFor = nil
    }

    private func takeDown() {
        if window != nil { NSApp.presentationOptions = [] }
        view?.setCursorHidden(false)
        window?.orderOut(nil)
        window = nil
        view = nil
        presentingOn = nil
        isPresenting = false
    }

    private func refresh() {
        // The menu-bar screen. NSScreen.main is whichever has the key window,
        // which is the projector whenever the console happens to sit there.
        let main = NSScreen.screens.first.flatMap(Self.id(of:))
        displays = NSScreen.screens.compactMap { s in
            guard let id = Self.id(of: s) else { return nil }
            return Display(id: id, name: s.localizedName, isMain: id == main)
        }
        if let on = presentingOn {
            if let screen = Self.screen(on.id) {
                // Resolution or arrangement changed: keep covering all of it.
                if let window, window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            } else {
                // Projector gone: take the stage down rather than strand a
                // window on a screen that no longer exists, and wait for it.
                takeDown()
                waitingFor = on
            }
        } else if let waiting = waitingFor, Self.screen(waiting.id) != nil {
            present(on: waiting.id)
        }
    }

    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: { Self.id(of: $0) == id })
    }

    private static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    // Never let AppKit nudge the window clear of the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
