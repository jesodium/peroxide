import SwiftUI

@main struct PeroxideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var bulb = Bulb.shared

    var body: some Scene {
        MenuBarExtra("Peroxide", systemImage: bulb.on ? "lightbulb.led.fill" : "lightbulb.led") {
            Panel().environmentObject(bulb)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var window: NSWindow = {
        let w = NSWindow(contentViewController: NSHostingController(rootView: Panel().environmentObject(Bulb.shared)))
        w.title = "Peroxide"
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }()

    func applicationWillFinishLaunching(_ n: Notification) {
        guard let id = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current })
        else { return }
        if let url = other.bundleURL { NSWorkspace.shared.open(url) }
        exit(0)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Hotkeys.start()
        // stay quiet in the menu bar when macOS opens us at login
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = ev?.eventID == kAEOpenApplication
            && ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { show() }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show()
        return false
    }

    private func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct Panel: View {
    @EnvironmentObject var bulb: Bulb
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if bulb.calibration != nil { ClapSetup() } else if adding || bulb.devices.isEmpty { Setup { adding = false } } else { Controls { adding = true } }
            Divider()
            HStack {
                if let e = bulb.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Settings…") { SettingsWindow.show() }.keyboardShortcut(",")
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { Task { await bulb.refresh() } }
    }
}

struct Controls: View {
    @EnvironmentObject var bulb: Bulb
    var picker = true
    let onAdd: () -> Void
    @State private var renaming = false
    @State private var renameText = ""

    static let swatches: [(String, Double, Double)] = [
        ("Red", 0, 1), ("Orange", 25, 1), ("Yellow", 50, 1), ("Green", 120, 1),
        ("Cyan", 180, 1), ("Blue", 240, 1), ("Purple", 280, 1), ("Pink", 330, 0.75),
    ]

    var body: some View {
        if picker { HStack {
            if renaming {
                TextField("Name", text: $renameText)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    if let d = bulb.device { bulb.rename(d.id, to: renameText) }
                    renaming = false
                }
                .buttonStyle(.borderless)
            } else {
                Picker("Light", selection: .init(get: { bulb.device?.id ?? "" }, set: { $0 == "+" ? onAdd() : bulb.select($0) })) {
                    ForEach(bulb.devices, id: \.id) { Text($0.name).tag($0.id) }
                    Divider()
                    Text("Add light…").tag("+")
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Button(action: {
                renameText = bulb.device?.name ?? ""
                renaming.toggle()
            }) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .disabled(bulb.devices.isEmpty)
            Toggle("On", isOn: .init(get: { bulb.on }, set: bulb.setOn))
                .toggleStyle(.switch)
                .labelsHidden()
        } }

        row("sun.max", "Brightness") {
            Slider(value: .init(get: { bulb.brightness }, set: bulb.setBrightness))
        }
        Picker("Mode", selection: .init(get: { bulb.colour }, set: {
            $0 ? bulb.setColour(hue: bulb.hue, sat: bulb.sat) : bulb.setTemp(bulb.temp)
        })) {
            Text("White").tag(false)
            Text("Color").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!bulb.on)

        if bulb.colour {
            row("paintpalette", "Hue") {
                Slider(value: .init(get: { bulb.hue }, set: { bulb.setColour(hue: $0, sat: bulb.sat) }))
                    .background(gradient(stride(from: 0.0, through: 1, by: 1 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) }))
            }
            swatches(Self.swatches.map { name, h, s in
                (name, Color(hue: h / 360, saturation: s, brightness: 1), { bulb.setColour(hue: h / 360, sat: s) })
            })
        } else {
            row("thermometer.medium", "Warmth") {
                Slider(value: .init(get: { bulb.temp }, set: bulb.setTemp))
                    .background(gradient(Self.whites.map(\.1)))
            }
            swatches(Self.whites.map { name, c, t in (name, c, { bulb.setTemp(t) }) })
        }

        Divider()
        HStack {
            Image(systemName: "waveform").frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Listen", selection: .init(get: { bulb.micMode }, set: {
                bulb.setMicMode($0)
                if $0 == .clap, !bulb.clapCalibrated { bulb.startCalibration() }
            })) {
                Text("Off").tag(Mic.Mode.off)
                Text("Clap").tag(Mic.Mode.clap)
                Text("Music").tag(Mic.Mode.music)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .help("Clap: double snap or clap at the mic toggles the light. Music: the light pulses to what your Mac is playing.")

        if bulb.micMode == .clap {
            HStack {
                Image(systemName: "dial.medium").frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $bulb.clapSensitivity).accessibilityLabel("Clap sensitivity")
                Button(action: bulb.startCalibration) { Image(systemName: "wand.and.stars") }
                    .buttonStyle(.borderless)
                    .help("Clap assisted setup")
                    .accessibilityLabel("Clap assisted setup")
            }
            .help("Clap sensitivity: higher picks up quieter claps, but also more false triggers")
        }

        if bulb.micMode == .music {
            HStack {
                Image(systemName: "slider.vertical.3").frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
                Picker("Follow", selection: $bulb.musicBand) {
                    ForEach(Mic.Band.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .help("Which part of the song drives the brightness")
            HStack {
                Image(systemName: "dial.medium").frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $bulb.musicSensitivity).accessibilityLabel("Sensitivity")
            }
            .help("Sensitivity")
            Text("Pulses in the color picked above. Brightness sets the peak.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static let whites: [(String, Color, Double)] = [
        ("Warm", Color(red: 1, green: 0.7, blue: 0.35), 0),
        ("Neutral", .white, 0.5),
        ("Cool", Color(red: 0.75, green: 0.85, blue: 1), 1),
    ]

    private func swatches(_ items: [(String, Color, () -> Void)]) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.0) { name, color, action in
                Button(action: action) {
                    Circle().fill(color).overlay(Circle().strokeBorder(.secondary.opacity(0.3))).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
            }
        }
        .disabled(!bulb.on)
    }

    private func row(_ icon: String, _ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            content().accessibilityLabel(label)
        }
        .disabled(!bulb.on)
    }

    private func gradient(_ c: [Color]) -> some View {
        Capsule().fill(LinearGradient(colors: c, startPoint: .leading, endPoint: .trailing)).frame(height: 4).opacity(0.8)
    }
}

struct ClapSetup: View {
    @EnvironmentObject var bulb: Bulb

    var body: some View {
        let c = bulb.calibration ?? ClapCalibrator()
        VStack(spacing: 12) {
            Group {
                switch c.phase {
                case .room: Image(systemName: "ear").symbolEffect(.pulse)
                case .clap: Image(systemName: "hands.clap.fill").symbolEffect(.bounce, value: c.claps.count)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 34))
            .frame(height: 40)
            .transition(.scale.combined(with: .opacity))

            Text(title(c)).font(.headline)
            Text(subtitle(c)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Waveform(levels: bulb.levels)
            Text("\(db(bulb.levels.last ?? 0)) dB").font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            if c.phase == .clap {
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { i in
                        Circle().fill(i < c.claps.count ? Color.accentColor : .secondary.opacity(0.3))
                            .frame(width: 10, height: 10)
                            .scaleEffect(i < c.claps.count ? 1.3 : 1)
                    }
                }
                .animation(.spring(duration: 0.3), value: c.claps.count)
            }

            HStack {
                if case .failed = c.phase { Button("Try Again", action: bulb.startCalibration) }
                Spacer()
                if case .done = c.phase {
                    Button("Done", action: bulb.endCalibration).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: bulb.endCalibration).keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.4), value: c.phase)
    }

    private func title(_ c: ClapCalibrator) -> String {
        switch c.phase {
        case .room: "Listening to your room"
        case .clap: "Now clap twice"
        case .done: "All set"
        case .failed: "Let's try that again"
        }
    }

    private func subtitle(_ c: ClapCalibrator) -> String {
        switch c.phase {
        case .room: "Keep things as they normally are for a few seconds, music, talking, whatever."
        case .clap: "Clap the way you would to toggle the light."
        case .done: "Sensitivity set to \(Int(bulb.clapSensitivity * 100))%. Room \(db(c.noise)) dB, claps \(db(c.claps.min() ?? 0)) dB."
        case .failed(let why): why
        }
    }

    private func db(_ p: Float) -> Int { Int(20 * log10(max(p, 1e-5))) }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor.opacity(0.3 + 0.7 * Double(i) / Double(levels.count)))
                    .frame(width: 3, height: 4 + 52 * Self.height(levels[i]))
            }
        }
        .frame(height: 60)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }

    static func height(_ p: Float) -> CGFloat { CGFloat(max(0, min(1, (20 * log10(max(p, 1e-5)) + 60) / 60))) }
}

struct Setup: View {
    @EnvironmentObject var bulb: Bulb
    let done: () -> Void
    @State private var name = ""
    @State private var id = ""
    @State private var ip = ""
    @State private var key = ""
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var useCloud = false

    var body: some View {
        Text("Add a light").font(.headline)
        if bulb.scanning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking at your network for smart devices…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if useCloud {
            Text("Enter Tuya cloud API credentials from tuya.com developer account.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("API Key", text: $apiKey)
            SecureField("API Secret", text: $apiSecret)
            HStack {
                if !bulb.devices.isEmpty { Button("Cancel", action: done).keyboardShortcut(.cancelAction) }
                Spacer()
                if bulb.scanning {
                    Button("Scanning…") {}.disabled(true).keyboardShortcut(.defaultAction)
                } else {
                    Button("Auto-setup from cloud") {
                        bulb.cloudApiKey = apiKey
                        bulb.cloudApiSecret = apiSecret
                        Task { await bulb.cloudScan() }
                    }
                    .disabled(apiKey.isEmpty || apiSecret.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            Text("Get the device ID and local key with `python3 -m tinytuya wizard`.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $name)
            TextField("Device ID", text: $id)
            TextField("IP address", text: $ip)
            SecureField("Local key (16 chars)", text: $key)
            HStack {
                if !bulb.devices.isEmpty { Button("Cancel", action: done).keyboardShortcut(.cancelAction) }
                Spacer()
                if bulb.scanning {
                    Button("Scanning…") {}.disabled(true).keyboardShortcut(.defaultAction)
                } else {
                    Button("Save") {
                        do {
                            try bulb.add(Device(name: name.trimmed.isEmpty ? "Light" : name.trimmed, id: id.trimmed, ip: ip.trimmed, key: key))
                            done()
                        } catch { bulb.error = error.localizedDescription }
                    }
                    .disabled(id.trimmed.isEmpty || ip.trimmed.isEmpty || key.utf8.count != 16)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        HStack {
            Button(useCloud ? "Manual setup" : "Auto-setup with Tuya cloud") {
                useCloud.toggle()
            }
            Spacer()
            Button("Scan network for devices") {
                Task { await bulb.scanNetwork() }
            }
            .disabled(bulb.scanning)
        }
    }
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespaces) } }
