import AppKit
import Combine

/// The fullscreen projection: a borderless window covering one display
/// (menu bar included), with the pointer hidden over it.
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

    /// 0 means "automatic": the first non-main display, else the main one.
    func resolve(_ id: CGDirectDisplayID) -> Display? {
        displays.first(where: { $0.id == id })
            ?? displays.first(where: { !$0.isMain })
            ?? displays.first
    }

    func present(on id: CGDirectDisplayID) {
        guard let display = resolve(id),
              let screen = NSScreen.screens.first(where: { Self.id(of: $0) == display.id }) else { return }
        stop()

        let window = StageWindow(contentRect: screen.frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        let view = VisualView(engine: engine, fps: 60, hidesCursor: true)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        self.window = window
        self.view = view
        presentingOn = display
        isPresenting = true
    }

    func stop() {
        view?.setCursorHidden(false)
        window?.orderOut(nil)
        window = nil
        view = nil
        presentingOn = nil
        isPresenting = false
    }

    private func refresh() {
        let main = NSScreen.main.flatMap(Self.id(of:))
        displays = NSScreen.screens.compactMap { s in
            guard let id = Self.id(of: s) else { return nil }
            return Display(id: id, name: s.localizedName, isMain: id == main)
        }
        // Projector unplugged mid-set: drop the stage rather than leave a
        // window stranded on a screen that no longer exists.
        if let on = presentingOn, !displays.contains(where: { $0.id == on.id }) {
            stop()
        }
    }

    private static func id(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
