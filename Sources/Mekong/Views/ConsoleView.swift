import SwiftUI

/// The single console window: live preview and signal readout on the left,
/// every control in one column on the right.
struct ConsoleView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var input: AudioInput
    @EnvironmentObject private var stage: StageController
    @ObservedObject private var settings = AppSettings.shared

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
            hint("1–4", "scene")
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
                ForEach(SceneKind.allCases) { scene in
                    sceneTile(scene)
                }
            }
            if let current = SceneKind(rawValue: settings.prefs.scene) {
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
        }
    }

    private func sceneTile(_ scene: SceneKind) -> some View {
        let selected = settings.prefs.scene == scene.rawValue
        return Button { app.selectScene(scene.rawValue) } label: {
            HStack(spacing: 8) {
                Text("\(scene.rawValue + 1)")
                    .font(Theme.mono(10))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                Text(scene.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
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
