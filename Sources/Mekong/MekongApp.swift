import SwiftUI

@main
enum Entry {
    static func main() {
        // `Mekong --snapshot <dir>` renders each scene from the test signal
        // to PNGs and exits — a way to check the visuals without a display.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : "."
            MainActor.assumeIsolated { Snapshot.run(to: dir) }
            exit(0)
        }
        MekongApp.main()
    }
}

struct MekongApp: App {
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("Mekong", id: "console") {
            ConsoleView()
                .environmentObject(app)
                .environmentObject(app.input)
                .environmentObject(app.stage)
                .frame(minWidth: 1020, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Clickable mirrors of the single-key controls; the key monitor
            // owns the keys themselves.
            CommandMenu("Visuals") {
                Button(app.stage.isPresenting ? "Stop Presenting (P / Esc)" : "Present (P)") {
                    app.togglePresent()
                }
                Button(app.blackout ? "Lift Blackout (Space)" : "Blackout (Space)") {
                    app.blackout.toggle()
                }
                Divider()
                ForEach(SceneKind.allCases) { scene in
                    Button("\(scene.name) (\(scene.rawValue + 1))") { app.selectScene(scene.rawValue) }
                }
            }
        }
    }
}
