import AVFoundation

@MainActor final class Bulb: ObservableObject {
    static let shared = Bulb()
    static let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/peroxide/devices.json")

    @Published var devices = (try? JSONDecoder().decode([Device].self, from: Data(contentsOf: Bulb.configURL))) ?? []
    @Published private var selected = UserDefaults.standard.string(forKey: "selected")
    var device: Device? { devices.first { $0.id == selected } ?? devices.first }
    @Published var on = false
    @Published var colour = false
    @Published var brightness = 1.0
    @Published var temp = 0.5
    @Published var hue = 0.0
    @Published var sat = 1.0
    @Published var error: String?
    @Published private(set) var micMode = Mic.Mode.off
    @Published var musicBand = UserDefaults.standard.string(forKey: "musicBand").flatMap(Mic.Band.init) ?? .all {
        didSet { mic.band = musicBand; UserDefaults.standard.set(musicBand.rawValue, forKey: "musicBand") }
    }
    @Published var musicSensitivity = UserDefaults.standard.object(forKey: "musicSensitivity") as? Double ?? 0.5 {
        didSet { mic.gain = Self.gain(musicSensitivity); UserDefaults.standard.set(musicSensitivity, forKey: "musicSensitivity") }
    }
    @Published var clapSensitivity = UserDefaults.standard.object(forKey: "clapSensitivity") as? Double ?? 0.5 {
        didSet { mic.clapThresh = Self.thresh(clapSensitivity); UserDefaults.standard.set(clapSensitivity, forKey: "clapSensitivity") }
    }
    var clapCalibrated: Bool { UserDefaults.standard.object(forKey: "clapSensitivity") != nil }
    @Published private(set) var calibration: ClapCalibrator?
    @Published private(set) var levels = [Float](repeating: 0, count: 48)
    private var heardPeak: Float = 0, heardCount = 0
    private static func thresh(_ s: Double) -> Float { Float(0.2 * pow(0.1, s)) }
    private static func gain(_ s: Double) -> Float { Float(pow(4, s * 2 - 1)) }

    private let mic = Mic()

    private var pending: [String: Any]?
    private var busy = false

    init() {
        mic.onClap = { [weak self] in self?.toggle() }
        mic.onMusic = { [weak self] in self?.music(level: $0) }
        mic.onLevel = { [weak self] in self?.heard(peak: $0, now: $1) }
        mic.band = musicBand
        mic.gain = Self.gain(musicSensitivity)
        mic.clapThresh = Self.thresh(clapSensitivity)
        Task { await refresh() }
        if let m = UserDefaults.standard.string(forKey: "micMode").flatMap(Mic.Mode.init) { setMicMode(m) }
    }

    func setMicMode(_ m: Mic.Mode) {
        micMode = m
        UserDefaults.standard.set(m.rawValue, forKey: "micMode")
        log("mic mode \(m), access \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        Task {
            if m == .clap, await !AVCaptureDevice.requestAccess(for: .audio) {
                error = "Allow the microphone in System Settings → Privacy"
                micMode = .off
                return
            }
            do { try mic.set(m) } catch { self.error = error.localizedDescription; micMode = .off }
        }
    }

    func startCalibration() {
        calibration = ClapCalibrator()
        levels = levels.map { _ in 0 }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                error = "Allow the microphone in System Settings → Privacy"
                calibration = nil
                return
            }
            guard calibration != nil else { return }
            mic.reportLevels = true
            do { try mic.set(.clap) } catch { self.error = error.localizedDescription; endCalibration() }
        }
    }

    func endCalibration() {
        calibration = nil
        stopHearing()
    }

    private func stopHearing() {
        guard mic.reportLevels else { return }
        mic.reportLevels = false
        do { try mic.set(micMode) } catch { self.error = error.localizedDescription }
    }

    private func heard(peak: Float, now: Double) {
        guard var c = calibration, mic.reportLevels else { return }
        c.feed(peak: peak, now: now)
        calibration = c
        heardPeak = max(heardPeak, peak)
        heardCount += 1
        if heardCount == 3 {
            levels = Array(levels.dropFirst()) + [heardPeak]
            (heardPeak, heardCount) = (0, 0)
        }
        switch c.phase {
        case .done(let t): clapSensitivity = min(1, max(0, log10(0.2 / Double(t)))); stopHearing()
        case .failed: stopHearing()
        default: break
        }
    }

    func select(_ id: String) {
        selected = id
        UserDefaults.standard.set(id, forKey: "selected")
        pending = nil
        error = nil
        Task { await refresh() }
    }

    func add(_ d: Device) throws {
        let all = devices.filter { $0.id != d.id } + [d]
        let dir = Self.configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: Self.configURL.path, contents: try JSONEncoder().encode(all),
                                             attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        devices = all
        select(d.id)
    }

    func refresh() async {
        guard let d = device, !busy else { return }
        do {
            let dps = try await Tuya(device: d).status()
            if device == d { apply(dps); error = nil }
        } catch { if device == d { self.error = error.localizedDescription } }
    }

    func apply(_ dps: [String: Any]) {
        if let v = dps["20"] as? Bool { on = v }
        if let v = dps["21"] as? String { colour = v == "colour" }
        if let v = dps["23"] as? Int { temp = Double(v) / 1000 }
        if !colour, let v = dps["22"] as? Int { brightness = Double(v - 10) / 990 }
        if let s = dps["24"] as? String, s.count == 12, let n = UInt64(s, radix: 16) {
            hue = Double(n >> 32 & 0xFFFF) / 360
            sat = Double(n >> 16 & 0xFFFF) / 1000
            if colour { brightness = (Double(n & 0xFFFF) - 10) / 990 }
        }
    }

    func setOn(_ v: Bool) { on = v; send(["20": v]) }

    func toggle() { Task { await refresh(); setOn(!on) } }

    // fix later, still a bit choppy
    func music(level: Double) {
        colour = true; on = true
        send(["20": true, "21": "colour", "24": hsv(max(0.01, brightness * level))])
    }

    func setBrightness(_ v: Double) {
        brightness = v
        send(colour ? ["20": true, "24": hsv()] : ["20": true, "22": level(v)])
    }

    func setTemp(_ v: Double) {
        temp = v; colour = false; on = true
        send(["20": true, "21": "white", "22": level(brightness), "23": Int(v * 1000)])
    }

    func setColour(hue h: Double, sat s: Double = 1) {
        hue = h; sat = s; colour = true; on = true
        send(["20": true, "21": "colour", "24": hsv()])
    }

    private func level(_ v: Double) -> Int { 10 + Int(v * 990) }
    private func hsv(_ v: Double? = nil) -> String { String(format: "%04x%04x%04x", Int(hue * 360), Int(sat * 1000), level(v ?? brightness)) }

    private func send(_ dps: [String: Any]) {
        pending = (pending ?? [:]).merging(dps) { $1 }
        guard !busy else { return }
        busy = true
        Task {
            while let p = pending, let d = device {
                pending = nil
                do { try await Tuya(device: d).set(p); error = nil } catch { self.error = error.localizedDescription }
            }
            busy = false
        }
    }
}
