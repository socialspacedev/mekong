import SwiftUI
import UniformTypeIdentifiers

/// The single console window: live preview and signal readout on the left,
/// every control in one column on the right.
struct ConsoleView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var input: AudioInput
    @EnvironmentObject private var stage: StageController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var library = SceneLibrary.shared
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                PreviewSurface(engine: app.engine)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
                SignalStrip(engine: app.engine)
                Spacer(minLength: 0)
                keyHints
            }
            .padding(26)
            .frame(maxWidth: .infinity)

            Rectangle().fill(Theme.hairline).frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    outputSection
                    sceneSection
                    lookSection
                    inputSection
                }
                .padding(24)
            }
            .frame(width: 360)
            .background(Theme.surface.opacity(0.4))
        }
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
        .onChange(of: settings.prefs.displayID) { _, id in
            if stage.isPresenting { stage.present(on: id) }
        }
    }

    // MARK: - Left column

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MEKONG")
                .font(.system(size: 13, weight: .semibold))
                .tracking(4)
            Spacer()
            if app.blackout {
                Text("BLACKOUT").font(Theme.label()).tracking(1.6).foregroundStyle(Theme.textSecondary)
            }
            if stage.isPresenting {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("ON \(stage.presentingOn?.name.uppercased() ?? "STAGE")")
                        .font(Theme.label()).tracking(1.6)
                }
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private var keyHints: some View {
        HStack(spacing: 18) {
            hint("P", "present")
            hint("Esc", "stop")
            hint("Space", "blackout")
            hint("1–9", "scene")
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(Theme.mono(10, .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .cardSurface(Theme.surfaceHi, radius: 4)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Output")
            Picker("Display", selection: $settings.prefs.displayID) {
                Text("Automatic").tag(UInt32(0))
                ForEach(stage.displays) { d in
                    Text(d.isMain ? "\(d.name) (this screen)" : d.name).tag(d.id)
                }
            }
            .labelsHidden()

            HStack(spacing: 8) {
                Button(action: app.togglePresent) {
                    Text(stage.isPresenting ? "Stop presenting" : "Present")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(stage.isPresenting ? Theme.background : Theme.textPrimary)
                        .background(stage.isPresenting ? Theme.accent : Theme.surfaceHi,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { app.blackout.toggle() } label: {
                    Text("Blackout")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(app.blackout ? Theme.textPrimary : Theme.textSecondary)
                        .cardSurface(app.blackout ? Theme.surfaceHi : Theme.surface, radius: 8)
                }
                .buttonStyle(.plain)
            }
            if stage.isPresenting {
                caption("The screensaver and display sleep are held off while presenting.")
            }
        }
    }

    // MARK: - Scene

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Scene")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(Array(library.entries.enumerated()), id: \.element.id) { i, scene in
                    sceneTile(scene, index: i)
                }
            }
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .opacity(dropTargeted ? 1 : 0))
            .padding(-4)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
            if let current = library.entry(settings.prefs.sceneKey) {
                caption(current.blurb)
            }
            HStack {
                Text("Change scene").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: $settings.prefs.autoSceneMinutes) {
                    Text("Manually").tag(0)
                    Text("Every 2 min").tag(2)
                    Text("Every 5 min").tag(5)
                    Text("Every 10 min").tag(10)
                }
                .labelsHidden()
                .fixedSize()
            }
            yourScenes
        }
    }

    /// Adding, tuning and removing your own scenes — no Finder needed.
    private var yourScenes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                smallButton("Add scene…", "plus") { addScenes() }
                smallButton("Folder", "folder") { library.openFolder() }
                if library.isReloading { ProgressView().controlSize(.small) }
            }
            caption("Add a picture to play it as a scene, or a .metal file for a fully custom one. You can also drag files onto the scene list.")

            if let entry = library.entry(settings.prefs.sceneKey), entry.source != .builtin {
                CustomSceneEditor(entry: entry, library: library)
            }

            ForEach(library.issues.keys.sorted(), id: \.self) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file).font(.system(size: 11, weight: .medium))
                    Text(library.issues[file] ?? "")
                        .font(Theme.mono(10))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .foregroundStyle(Theme.alert)
            }
        }
        .padding(.top, 4)
    }

    private func smallButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .cardSurface(Theme.surface, radius: 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
    }

    private func addScenes() {
        let panel = NSOpenPanel()
        panel.title = "Add scenes"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SceneLibrary.addableTypes.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        if let first = library.add(urls).first { settings.prefs.sceneKey = first }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in add([url]) }
            }
        }
        return true
    }

    private func sceneTile(_ scene: SceneEntry, index: Int) -> some View {
        let selected = settings.prefs.sceneKey == scene.id
        return Button { app.selectScene(index) } label: {
            HStack(spacing: 8) {
                Text(index < 9 ? "\(index + 1)" : "·")
                    .font(Theme.mono(10))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                Text(scene.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if scene.source != .builtin {
                    Image(systemName: scene.source == .image ? "photo" : "curlybraces")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(selected ? Theme.accentSoft : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Look

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Look")
            slider("Density", $settings.prefs.density, "sparse", "dense")
            slider("Motion", $settings.prefs.motion, "still", "restless")
            slider("Brightness", $settings.prefs.brightness, "dim", "full")
            slider("Response", $settings.prefs.response, "tight", "slow")

            Picker("", selection: $settings.prefs.palette) {
                Text("White").tag(0)
                Text("Tint").tag(1)
                Text("Inverted").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle(isOn: $settings.prefs.flashes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flash on strong attacks").font(.system(size: 12))
                    caption("Inverts the whole image. Limited to 3 per second for audience safety.")
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Input")
            Picker("", selection: $settings.prefs.deviceUID) {
                Text("System default input").tag("")
                ForEach(input.devices) { d in
                    Text(d.name).tag(d.uid)
                }
                Divider()
                Text("Test signal").tag(AudioInput.testSignalUID)
            }
            .labelsHidden()

            if input.channelCount > 1 {
                HStack {
                    Text("Listen to").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Picker("", selection: $settings.prefs.channel) {
                        Text("All channels").tag(-1)
                        ForEach(0..<input.channelCount, id: \.self) { c in
                            Text("Channel \(c + 1)").tag(c)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            InputMeter(engine: app.engine, gateDb: $settings.prefs.gateDb)

            Toggle("Auto level", isOn: $settings.prefs.autoLevel)
                .toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12))
            if settings.prefs.autoLevel {
                caption("Follows how loud you're playing, so quiet passages still move the image.")
            } else {
                slider("Gain", $settings.prefs.gainDb, "−24 dB", "+24 dB", range: -24...24)
            }
            slider("Attack sensitivity", $settings.prefs.attackSensitivity, "only hard", "every note")

            if !input.status.isEmpty {
                Text(input.status)
                    .font(Theme.mono(10))
                    .foregroundStyle(input.isRunning ? Theme.textTertiary : Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Pieces

    private func slider(_ label: String, _ value: Binding<Double>, _ low: String, _ high: String,
                        range: ClosedRange<Double> = 0...1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The live preview — the same engine and shader as the stage, at 30 fps.
struct PreviewSurface: NSViewRepresentable {
    let engine: VisualEngine
    func makeNSView(context: Context) -> VisualView {
        VisualView(engine: engine, fps: 30, hidesCursor: false)
    }
    func updateNSView(_ nsView: VisualView, context: Context) {}
}

/// Raw input level against the silence threshold. Drag the marker to just
/// above the room/interface noise: below it the picture collapses to a dot.
struct InputMeter: View {
    let engine: VisualEngine
    @Binding var gateDb: Double

    private static let floor: Double = -80, ceiling: Double = 0
    private func x(_ db: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((min(max(db, Self.floor), Self.ceiling) - Self.floor) / (Self.ceiling - Self.floor)) * w
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Silence threshold").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(gateDb.rounded())) dB").font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
            }
            TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                let db = Double(engine.inputDb)
                let open = engine.gateOpen
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.surfaceHi).frame(height: 4)
                        Rectangle().fill(open ? Theme.accent : Theme.textTertiary)
                            .frame(width: x(db, w), height: 4)
                        Rectangle().fill(Theme.textPrimary)
                            .frame(width: 2, height: 14)
                            .offset(x: x(gateDb, w) - 1)
                    }
                    .frame(height: 14)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let v = Self.floor + Double(max(0, min(1, g.location.x / w))) * (Self.ceiling - Self.floor)
                        gateDb = min(-20, v.rounded())
                    })
                }
                .frame(height: 14)
            }
            Text("Input level, live. Drag the marker just above the hiss you get with nothing played — below it, the picture shrinks to a dot.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What Mekong is hearing, in the console only (never on the wall).
struct SignalStrip: View {
    let engine: VisualEngine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let u = engine.u
            let attackAge = CACurrentMediaTime() - engine.lastOnsetTime
            HStack(spacing: 22) {
                meter("Level", u.level)
                meter("Drone", engine.drone)
                meter("Brightness", u.centroid)
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Attack")
                    Circle()
                        .fill(attackAge < 0.12 ? Theme.accent : Theme.surfaceHi)
                        .frame(width: 8, height: 8)
                        .padding(.vertical, 1)
                }
            }
            .id(context.date)
        }
    }

    private func meter(_ label: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.surfaceHi)
                    Rectangle().fill(Theme.textSecondary)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                }
            }
            .frame(height: 2)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Settings for the selected custom scene: name, style and monochrome for a
/// picture; reveal or remove for either kind.
struct CustomSceneEditor: View {
    let entry: SceneEntry
    @ObservedObject var library: SceneLibrary
    @State private var name = ""
    @State private var confirmRemove = false
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: entry.source == .image ? "photo" : "curlybraces")
                    .font(.system(size: 10))
                Text(entry.file ?? entry.name).font(Theme.mono(10)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(Theme.textTertiary)

            if entry.source == .image {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .cardSurface(Theme.surfaceHi, radius: 6)
                    .focused($editingName)
                    .onSubmit { library.update(entry, name: name) }
                    .onChange(of: editingName) { _, editing in
                        if !editing, name != entry.name { library.update(entry, name: name) }
                    }

                Picker("", selection: Binding(get: { entry.style },
                                              set: { library.update(entry, style: $0) })) {
                    ForEach(Array(SceneLibrary.styleNames.enumerated()), id: \.offset) { i, style in
                        Text(style.capitalized).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Toggle("Black and white (follows the palette)",
                       isOn: Binding(get: { entry.mono }, set: { library.update(entry, mono: $0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .font(.system(size: 12))
            }

            HStack(spacing: 14) {
                Button("Show in Finder") { library.reveal(entry) }
                Button("Remove scene…") { confirmRemove = true }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(Theme.surface, radius: 8)
        .onAppear { name = entry.name }
        .onChange(of: entry.id) { _, _ in name = entry.name }
        .confirmationDialog("Remove “\(entry.name)”?", isPresented: $confirmRemove) {
            Button("Move to Trash", role: .destructive) { library.remove(entry) }
        } message: {
            Text("The file goes to the Trash, so you can get it back from there.")
        }
    }
}
