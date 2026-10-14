import AVFoundation
import CoreAudio

struct ClapDetector {
    var thresh: Float = 0.07
    var ratio: Float = 8
    var gap = 0.08..<0.7
    private var noise: Float = 0.01, last = 0.0, cooldown = 0.0

    mutating func feed(peak: Float, rms: Float, now: Double) -> Bool {
        guard peak > thresh, peak > noise * ratio, now > cooldown else {
            noise = noise * 0.98 + rms * 0.02
            return false
        }
        cooldown = now + 0.1
        if gap.contains(now - last) {
            last = 0
            // tweak if it double fires
            cooldown = now + 1.25
            return true
        }
        last = now
        return false
    }
}

struct ClapCalibrator {
    enum Phase: Equatable { case room, clap, done(thresh: Float), failed(String) }
    private(set) var phase = Phase.room
    private(set) var claps: [Float] = []
    private var roomSum: Float = 0, roomBlocks = 0
    private var start: Double?, lastClap = -1.0
    var noise: Float { roomSum / Float(max(roomBlocks, 1)) }
    var clapLevel: Float { max(noise * 4, 0.02) }

    mutating func feed(peak: Float, now: Double) {
        let t0 = start ?? now
        start = t0
        switch phase {
        case .room:
            roomSum += peak
            roomBlocks += 1
            if now - t0 > 2.5 { phase = .clap; start = now }
        case .clap:
            if peak > clapLevel {
                if now - lastClap > 0.15 { claps.append(peak); lastClap = now }
                else { claps[claps.count - 1] = max(claps[claps.count - 1], peak) }
            }
            if claps.count >= 2, now - lastClap > 0.3 { phase = .done(thresh: max(clapLevel, claps.min()! * 0.3)) }
            else if now - t0 > 10 { phase = .failed("Didn't hear two claps over the noise. Clap louder or closer to your Mac.") }
        case .done, .failed: break
        }
    }
}

struct MusicFollower {
    private var loudest: Float = 0.003

    mutating func feed(rms: Float) -> Float {
        loudest = max(rms, loudest * 0.999, 0.003)
        return rms / loudest
    }
}

struct Biquad {
    private var b0, b1, b2, a1, a2: Float
    private var z1: Float = 0, z2: Float = 0

    enum Kind { case lowpass, bandpass, highpass }

    init(_ kind: Kind, freq: Double, sampleRate: Double, q: Double = 0.707) {
        let w = 2 * Double.pi * freq / sampleRate, cw = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        let b: (Double, Double, Double) = switch kind {
        case .lowpass: ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
        case .highpass: ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
        case .bandpass: (alpha, 0, -alpha)
        }
        (b0, b1, b2) = (Float(b.0 / a0), Float(b.1 / a0), Float(b.2 / a0))
        (a1, a2) = (Float(-2 * cw / a0), Float((1 - alpha) / a0))
    }

    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

let debug = ProcessInfo.processInfo.environment["PEROXIDE_DEBUG"] != nil
func log(_ s: String) { if debug { FileHandle.standardError.write(Data((s + "\n").utf8)) } }

final class Mic {
    enum Mode: String, CaseIterable { case off, clap, music }

    enum Band: String, CaseIterable {
        case all, bass, mids, highs
        func filter(sampleRate sr: Double) -> Biquad? {
            switch self {
            case .all: nil
            case .bass: Biquad(.lowpass, freq: 150, sampleRate: sr)
            case .mids: Biquad(.bandpass, freq: 1000, sampleRate: sr, q: 0.5)
            case .highs: Biquad(.highpass, freq: 4000, sampleRate: sr)
            }
        }
    }

    var onClap: () -> Void = {}
    var onMusic: (_ level: Double) -> Void = { _ in }
    var band = Band.all
    var gain: Float = 1
    var clapThresh: Float = 0.07
    var onLevel: (_ peak: Float, _ now: Double) -> Void = { _, _ in }
    var reportLevels = false

    private let engine = AVAudioEngine()
    private var mode = Mode.off
    private var pinned = false
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var clap = ClapDetector()
    private var music = MusicFollower()
    private var filter: Biquad?
    private var appliedBand: Band?
    private var armedAt = 0.0
    private var window: (level: Float, until: Double) = (0, 0)

    init() {
        _ = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, mode == .clap else { return }
            log("audio config changed, restarting mic")
            do { try set(.clap) } catch { log("mic restart failed: \(error)") }
        }
    }

    func set(_ m: Mode) throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        stopSystemAudio()
        mode = m
        switch m {
        case .off: break
        case .clap:
            appliedBand = nil
            clap = ClapDetector()
            armedAt = ProcessInfo.processInfo.systemUptime + 0.5
        if !pinned { pinBuiltInMic(); pinned = true }
            engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buf, _ in
                guard let x = buf.floatChannelData?[0] else { return }
                self?.process(UnsafeBufferPointer(start: x, count: Int(buf.frameLength)), rate: buf.format.sampleRate)
            }
            try engine.start()
            log("mic on, format \(engine.inputNode.outputFormat(forBus: 0))")
        case .music:
            guard #available(macOS 14.2, *) else { throw CAError("Mac audio capture needs macOS 14.2+") }
            try startSystemAudio()
        }
    }

    private func process(_ x: UnsafeBufferPointer<Float>, rate: Double) {
        let n = x.count, block = 512
        let t0 = ProcessInfo.processInfo.systemUptime - Double(n) / rate
        for start in stride(from: 0, to: n, by: block) {
            let chunk = UnsafeBufferPointer(rebasing: x[start..<min(start + block, n)])
            let now = t0 + Double(start) / rate

            switch mode {
            case .off: return
            case .clap:
                var peak: Float = 0, sum: Float = 0
                for v in chunk { peak = max(peak, abs(v)); sum += v * v }
                let rms = (sum / Float(chunk.count)).squareRoot()
                if peak > 0.03 { log(String(format: "%7.2f  peak %.3f  rms %.4f", now.truncatingRemainder(dividingBy: 100), peak, rms)) }
                clap.thresh = clapThresh
                guard now > armedAt else { continue }
                if reportLevels { DispatchQueue.main.async { self.onLevel(peak, now) }; continue }
                if clap.feed(peak: peak, rms: rms, now: now) { log("clap clap -> toggle"); DispatchQueue.main.async(execute: onClap) }
            case .music:
                if appliedBand != band {
                    (filter, music, appliedBand) = (band.filter(sampleRate: rate), MusicFollower(), band)
                }
                var sum: Float = 0
                for v in chunk { let y = filter?.run(v) ?? v; sum += y * y }
                window.level = max(window.level, min(1, music.feed(rms: (sum / Float(chunk.count)).squareRoot()) * gain))
                if now >= window.until {
                    let l = Double(window.level)
                    log(String(format: "music %@ %.2f", band.rawValue, l))
                    DispatchQueue.main.async { self.onMusic(l) }
                    // dont go lower, bulb chokes
                    window = (0, now + 0.1)
                }
            }
        }
    }

    @available(macOS 14.2, *)
    private func startSystemAudio() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create audio tap")

        var out: [AudioDeviceID] = []
        prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &out)
        guard let outUID = out.first.flatMap(deviceUID) else { throw CAError("No audio output device") }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Peroxide Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "create aggregate device")

        var fmt: [AudioStreamBasicDescription] = []
        prop(tap, kAudioTapPropertyFormat, &fmt)
        // dont forget to test w headphones
        let sr = fmt.first?.mSampleRate ?? 48000, channels = Double(fmt.first?.mChannelsPerFrame ?? 2)
        log("system audio tap on, \(sr) Hz × \(channels)")
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { [weak self] _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = list.count == 1 ? Int(channels) : 1, frames = Int(b.mDataByteSize) / 4 / ch
            let mono = (0..<frames).map { i in (0..<ch).reduce(Float(0)) { $0 + p[i * ch + $1] } / Float(ch) }
            mono.withUnsafeBufferPointer { self?.process($0, rate: sr) }
        }, "create IO proc")
        try check(AudioDeviceStart(aggregate, ioProc), "start capture")
    }

    private func stopSystemAudio() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
    }

    private func pinBuiltInMic() {
        var ids: [AudioDeviceID] = []
        prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, &ids)
        let mic = ids.first { id in
            var transport: [UInt32] = [], streams: [AudioStreamID] = []
            prop(id, kAudioDevicePropertyTransportType, &transport)
            prop(id, kAudioDevicePropertyStreams, &streams, scope: kAudioDevicePropertyScopeInput)
            return transport.first == kAudioDeviceTransportTypeBuiltIn && !streams.isEmpty
        }
        log("built-in mic: \(mic.map(String.init) ?? "not found")")
        guard var mic, let au = engine.inputNode.audioUnit else { return }
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mic, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}

struct CAError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CAError("Couldn't \(what) (\(status))") }
}

private func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: inout [T], scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { v = []; return }
    v = [T](unsafeUninitializedCapacity: Int(size) / MemoryLayout<T>.stride) { p, n in
        n = AudioObjectGetPropertyData(id, &a, 0, nil, &size, p.baseAddress!) == noErr ? Int(size) / MemoryLayout<T>.stride : 0
    }
}

private func deviceUID(_ id: AudioObjectID) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &uid) == noErr else { return nil }
    return uid?.takeRetainedValue() as String?
}
