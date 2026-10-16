import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = AppSettings.shared
    let input: AudioInput
    let engine: VisualEngine
    let stage: StageController
    let power = PowerManager()

    @Published var blackout = false {
        didSet { engine.blackout = blackout }
    }

    private var bag = Set<AnyCancellable>()
    private var keyMonitor: Any?

    private init() {
        input = AudioInput()
        engine = VisualEngine(analyzer: input.analyzer, settings: settings)
        stage = StageController(engine: engine)

        settings.$prefs.map(\.deviceUID).removeDuplicates()
            .sink { [weak self] uid in self?.input.start(uid: uid) }
            .store(in: &bag)

        // The screensaver is held off for exactly as long as we're projecting.
        stage.$isPresenting.removeDuplicates()
            .sink { [weak self] on in self?.power.setKeepAwake(on) }
            .store(in: &bag)

        installKeys()
    }

    func togglePresent() {
        stage.isPresenting ? stage.stop() : stage.present(on: settings.prefs.displayID)
    }

    func selectScene(_ index: Int) {
        guard SceneKind(rawValue: index) != nil else { return }
        settings.prefs.scene = index
    }

    /// Single keys, no modifiers — hands are on the guitar, so these need to
    /// be one reachable press. Esc always gets you off the wall.
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                else { return event }
                switch event.keyCode {
                case 53:  // Esc
                    if self.stage.isPresenting { self.stage.stop(); return nil }
                    return event
                case 49:  // Space
                    self.blackout.toggle()
                    return nil
                default:
                    break
                }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "1", "2", "3", "4":
                    self.selectScene(Int(event.charactersIgnoringModifiers!)! - 1)
                    return nil
                case "p":
                    self.togglePresent()
                    return nil
                default:
                    return event
                }
            }
        }
    }
}
