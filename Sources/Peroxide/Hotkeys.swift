import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// Carbon hotkeys: system-wide, no Accessibility permission, get press + release.
@MainActor enum Hotkeys {
    private static var handlers: [UInt32: (Bool) -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false
    private static let d = UserDefaults.standard
    static let mods: [(flag: NSEvent.ModifierFlags, carbon: Int, symbol: String)] =
        [(.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")]

    static func carbon(_ f: NSEvent.ModifierFlags) -> Int { mods.filter { f.contains($0.flag) }.reduce(0) { $0 | $1.carbon } }
    static func symbols(_ m: Int) -> String { mods.filter { m & $0.carbon != 0 }.map(\.symbol).joined() }
    static var label: String { symbols(d.integer(forKey: "hotkeyMods")) + (d.string(forKey: "hotkeyLabel") ?? "") }
    /// "⌃⌥" when number shortcuts are live, else nil
    static var digitMods: String? {
        d.bool(forKey: "hotkeyOn") && d.bool(forKey: "hotkeyDigits") ? symbols(d.integer(forKey: "hotkeyMods")) : nil
    }

    static func register(_ key: Int, _ mods: Int, _ handler: @escaping (_ down: Bool) -> Void) {
        if !installed { install() }
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        // fails if another app owns the combo
        let err = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: 0x5058_4944, id: id), GetApplicationEventTarget(), 0, &ref)
        if let ref, err == noErr { refs.append(ref) } else { log("hotkey \(key) taken (\(err))") }
    }

    private static func install() {
        installed = true
        let specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { Hotkeys.handlers[hk.id]?(down) }
            return noErr
        }, 2, specs, nil, nil)
    }

    static func start() {
        d.register(defaults: ["hotkeyOn": true, "hotkeyDigits": true, "hotkeyKey": kVK_ANSI_L,
                              "hotkeyMods": controlKey | optionKey, "hotkeyLabel": "L"])
        reload()
    }

    static func stop() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
    }

    // main shortcut: tap = toggle, hold = quick panel. Same modifiers + 1-9 = toggle light N.
    static func reload() {
        stop()
        guard d.bool(forKey: "hotkeyOn") else { return }
        let mods = d.integer(forKey: "hotkeyMods")
        var held: DispatchWorkItem?, opened = false
        register(d.integer(forKey: "hotkeyKey"), mods) { down in
            if down {
                guard held == nil else { return }
                opened = false
                held = DispatchWorkItem { opened = true; QuickPanel.show() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: held!)
            } else if let h = held {
                h.cancel()
                held = nil
                if !opened { Bulb.shared.toggle() }
            }
        }
        guard d.bool(forKey: "hotkeyDigits") else { return }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, key) in digits.enumerated() {
            register(key, mods) { down in
                let b = Bulb.shared
                if down, b.devices.indices.contains(i) { b.toggle(b.devices[i]) }
            }
        }
    }
}

struct ShortcutRecorder: View {
    @AppStorage("hotkeyKey") private var key = kVK_ANSI_L
    @AppStorage("hotkeyMods") private var mods = controlKey | optionKey
    @AppStorage("hotkeyLabel") private var label = "L"
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? Hotkeys.symbols(mods) + label : "Type shortcut…") { monitor == nil ? record() : finish() }
            .frame(minWidth: 110)
            .onDisappear(perform: finish)
    }

    private func record() {
        Hotkeys.stop() // else Carbon swallows the current combo before we see it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { finish(); return nil }
            let m = Hotkeys.carbon(e.modifierFlags)
            // need ⌃, ⌥ or ⌘ so a plain letter never gets stolen from typing
            guard m & (controlKey | optionKey | cmdKey) != 0 else { NSSound.beep(); return nil }
            // IMPORTANT NOTE: label is the typed char, so F-keys/arrows show odd glyphs. Map keycodes if that bugs anyone.
            let ch = e.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces) ?? ""
            (key, mods, label) = (Int(e.keyCode), m, ch.isEmpty ? "Space" : ch)
            finish()
            return nil
        }
    }

    private func finish() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        Hotkeys.reload()
    }
}

struct SettingsView: View {
    @AppStorage("hotkeyOn") private var on = true
    @AppStorage("hotkeyDigits") private var digits = true
    @AppStorage("hotkeyMods") private var mods = controlKey | optionKey
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $login)
                    .onChange(of: login) { _, v in
                        guard v != (SMAppService.mainApp.status == .enabled) else { return }
                        do { try v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); error = nil }
                        catch { self.error = error.localizedDescription }
                        login = SMAppService.mainApp.status == .enabled
                    }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Keyboard shortcuts") {
                Toggle("Enable shortcuts", isOn: $on)
                Group {
                    LabeledContent("Toggle light") { ShortcutRecorder() }
                    Toggle("\(Hotkeys.symbols(mods))1–9 toggles light 1–9", isOn: $digits)
                }
                .disabled(!on)
                Text("Tap the shortcut to toggle, hold it for all lights. Esc cancels recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: on) { Hotkeys.reload() }
        .onChange(of: digits) { Hotkeys.reload() }
    }
}

@MainActor enum SettingsWindow {
    private static let window: NSWindow = {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        w.title = "Peroxide Settings"
        w.styleMask.remove([.resizable, .miniaturizable])
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }()

    static func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

final class QuickPanel: NSPanel, NSWindowDelegate {
    private static let shared = QuickPanel()

    private init() {
        super.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        level = .floating
        isReleasedWhenClosed = false
        delegate = self
        contentViewController = NSHostingController(rootView: QuickView().environmentObject(Bulb.shared))
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    func windowDidResignKey(_ n: Notification) { orderOut(nil) }

    @MainActor static func show() {
        let p = shared
        Bulb.shared.refreshAll()
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let f = s.visibleFrame, size = p.frame.size
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height / 6))
        }
        p.makeKeyAndOrderFront(nil)
    }
}

struct QuickView: View {
    @EnvironmentObject var bulb: Bulb

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(bulb.devices.enumerated()), id: \.1.id) { i, d in
                HStack {
                    Button { bulb.select(d.id) } label: {
                        HStack {
                            Image(systemName: bulb.power[d.id] == true ? "lightbulb.led.fill" : "lightbulb.led")
                                .foregroundStyle(bulb.power[d.id] == true ? Color.yellow : .secondary)
                                .frame(width: 18)
                            Text(d.name).fontWeight(d == bulb.device ? .semibold : .regular)
                            if i < 9, let m = Hotkeys.digitMods { Text("\(m)\(i + 1)").font(.caption).foregroundStyle(.tertiary) }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Toggle(d.name, isOn: .init(get: { bulb.power[d.id] ?? false }, set: { bulb.setOn($0, d) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Divider()
            Controls(picker: false) {}
        }
        .padding(14)
        .frame(width: 280)
    }
}
