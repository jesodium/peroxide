import SwiftUI

@main struct PeroxideApp: App {
    @StateObject private var bulb = Bulb()

    var body: some Scene {
        MenuBarExtra("Peroxide", systemImage: bulb.on ? "lightbulb.led.fill" : "lightbulb.led") {
            Panel().environmentObject(bulb)
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @EnvironmentObject var bulb: Bulb
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if adding || bulb.devices.isEmpty { Setup { adding = false } } else { Controls { adding = true } }
            Divider()
            HStack {
                if let e = bulb.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
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
    let onAdd: () -> Void

    static let swatches: [(String, Double, Double)] = [
        ("Red", 0, 1), ("Orange", 25, 1), ("Yellow", 50, 1), ("Green", 120, 1),
        ("Cyan", 180, 1), ("Blue", 240, 1), ("Purple", 280, 1), ("Pink", 330, 0.75),
    ]

    var body: some View {
        HStack {
            // kinda hacky but works
            Picker("Light", selection: .init(get: { bulb.device?.id ?? "" }, set: { $0 == "+" ? onAdd() : bulb.select($0) })) {
                ForEach(bulb.devices, id: \.id) { Text($0.name).tag($0.id) }
                Divider()
                Text("Add light…").tag("+")
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Toggle("On", isOn: .init(get: { bulb.on }, set: bulb.setOn))
                .toggleStyle(.switch)
                .labelsHidden()
        }

        row("sun.max", "Brightness") {
            Slider(value: .init(get: { bulb.brightness }, set: bulb.setBrightness))
        }
        if bulb.micMode != .music {
            Picker("Mode", selection: .init(get: { bulb.colour }, set: {
                $0 ? bulb.setColour(hue: bulb.hue, sat: bulb.sat) : bulb.setTemp(bulb.temp)
            })) {
                Text("White").tag(false)
                Text("Color").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!bulb.on)
        }

        if bulb.colour || bulb.micMode == .music {
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
            Picker("Listen", selection: .init(get: { bulb.micMode }, set: bulb.setMicMode)) {
                Text("Off").tag(Mic.Mode.off)
                Text("Clap").tag(Mic.Mode.clap)
                Text("Music").tag(Mic.Mode.music)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .help("Clap: double snap or clap at the mic toggles the light. Music: the light pulses to what your Mac is playing.")

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

struct Setup: View {
    @EnvironmentObject var bulb: Bulb
    let done: () -> Void
    @State private var name = ""
    @State private var id = ""
    @State private var ip = ""
    @State private var key = ""

    var body: some View {
        Text("Add a light").font(.headline)
        Text("Get the device ID and local key with `python3 -m tinytuya wizard`.")
            .font(.caption).foregroundStyle(.secondary)
        TextField("Name", text: $name)
        TextField("Device ID", text: $id)
        TextField("IP address", text: $ip)
        SecureField("Local key (16 chars)", text: $key)
        HStack {
            if !bulb.devices.isEmpty { Button("Cancel", action: done).keyboardShortcut(.cancelAction) }
            Spacer()
            Button("Save") {
                do {
                    // validate ip later
                    try bulb.add(Device(name: name.trimmed.isEmpty ? "Light" : name.trimmed, id: id.trimmed, ip: ip.trimmed, key: key))
                    done()
                } catch { bulb.error = error.localizedDescription }
            }
            .disabled(id.trimmed.isEmpty || ip.trimmed.isEmpty || key.utf8.count != 16)
            .keyboardShortcut(.defaultAction)
        }
    }
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespaces) } }
