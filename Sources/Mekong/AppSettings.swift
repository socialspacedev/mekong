import Foundation
import Combine

/// The visual scenes. All abstract — nothing draws the waveform or a
/// spectrum; the audio only decides density, timing, colour and change.
enum SceneKind: Int, CaseIterable, Identifiable {
    case barcode, grid, horizon, interference, scratch, ribbons

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .barcode:      "Barcode"
        case .grid:         "Grid"
        case .horizon:      "Horizon"
        case .interference: "Interference"
        case .scratch:      "Scratch"
        case .ribbons:      "Ribbons"
        }
    }

    var blurb: String {
        switch self {
        case .barcode:      "Strata of data lines. Attacks re-scramble the code."
        case .grid:         "Rows of cells drift like a data feed, each row tied to one region of the sound."
        case .horizon:      "One line holds the drone; playing harder splits it into many."
        case .interference: "Stripe fields at shifting frequencies; attacks break them into static."
        case .scratch:      "Hand-scratched film after Len Lye: wobbling lines and painted colour that jitter at film speed."
        case .ribbons:      "Vertical ribbons of coloured light streaming outward; attacks send a surge through."
        }
    }

    /// Scenes drawn in colour ignore the White / Tint / Inverted palette.
    var isColour: Bool { self == .scratch || self == .ribbons }
}

/// Everything you set on the console, saved between launches.
struct Prefs: Codable, Equatable {
    // Input
    var deviceUID = ""            // "" = system default input
    var channel = -1              // -1 = mix all channels
    var autoLevel = true
    var gateDb: Double = -55      // quieter than this counts as silence
    var gainDb: Double = 0        // used when auto level is off
    var attackSensitivity: Double = 0.5

    // Scene
    var scene = 0
    var autoSceneMinutes = 0      // 0 = stay on the chosen scene

    // Look
    var density: Double = 0.5
    var motion: Double = 0.5
    var brightness: Double = 0.8
    var response: Double = 0.35   // 0 = tight, 1 = slow and smooth
    var palette = 0               // 0 white, 1 tint, 2 inverted
    var flashes = false

    // Output
    var displayID: UInt32 = 0     // 0 = automatic (external display if present)
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let key = "prefs"

    @Published var prefs: Prefs {
        didSet {
            guard prefs != oldValue, let data = try? JSONEncoder().encode(prefs) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private init() {
        // Lay saved values over the defaults, so settings saved by an older
        // version (missing newer keys) still load instead of resetting.
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Prefs())) as? [String: Any],
           let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(saved) { _, new in new }),
           let prefs = try? JSONDecoder().decode(Prefs.self, from: merged) {
            self.prefs = prefs
        } else {
            prefs = Prefs()
        }
    }
}
