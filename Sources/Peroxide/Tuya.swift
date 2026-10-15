import CommonCrypto
import Foundation
import Network

struct TuyaCloud {
    let apiKey: String
    let apiSecret: String
    let region: String

    private var baseURL: String {
        switch region {
        case "eu": return "https://openapi.tuyaeu.com"
        case "cn": return "https://openapi.tuyacn.com"
        case "in": return "https://openapi.tuyain.com"
        default: return "https://openapi.tuyaus.com"
        }
    }

    private func sign(_ path: String, _ method: String, _ body: String = "") -> [String: String] {
        let t = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.prefix(8)
        let contentHash = sha256(body)
        let stringToSign = "\(method)\n\(contentHash)\n\n\(path)"
        let signStr = apiKey + t + String(nonce) + stringToSign
        let signature = hmac(signStr, key: apiSecret).uppercased()
        return ["client_id": apiKey, "t": t, "sign_method": "HMAC-SHA256", "nonce": String(nonce), "sign": signature]
    }

    private func sha256(_ s: String) -> String {
        let d = Data(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        d.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(d.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hmac(_ s: String, key: String) -> String {
        var code = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let k = Array(key.utf8), m = Array(s.utf8)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k, k.count, m, m.count, &code)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    func token() async throws -> String {
        let path = "/v1.0/token?grant_type=1"
        let headers = sign(path, "GET")
        var req = URLRequest(url: URL(string: baseURL + path)!)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let token = result["access_token"] as? String
        else { throw TuyaError.badReply("Token failed") }
        return token
    }

    func devices() async throws -> [Device] {
        let token = try await token()
        let path = "/v1.0/users/\(apiKey)/devices"
        let headers = sign(path, "GET")
        var req = URLRequest(url: URL(string: baseURL + path)!)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(token, forHTTPHeaderField: "access_token")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [[String: Any]]
        else { throw TuyaError.badReply("Device list failed") }
        return result.compactMap { d in
            guard let id = d["id"] as? String, let key = d["local_key"] as? String,
                  let ip = d["ip"] as? String, let name = d["name"] as? String
            else { return nil }
            return Device(name: name, id: id, ip: ip, key: key)
        }
    }
}

struct Device: Codable, Hashable { var name, id, ip, key: String }

enum TuyaError: LocalizedError {
    case crypto, closed, badReply(String)
    var errorDescription: String? {
        switch self {
        case .crypto: "Bad local key"
        case .closed: "Bulb closed the connection"
        case .badReply(let s): "Bulb said: \(s)"
        }
    }
}

struct Tuya {
    let device: Device

    func status() async throws -> [String: Any] {
        let body = try json(["gwId": device.id, "devId": device.id, "uid": device.id, "t": now()])
        let reply = try await request(cmd: 10, payload: aes(body, key: device.key, encrypt: true))
        guard let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let dps = obj["dps"] as? [String: Any]
        else { throw TuyaError.badReply(String(decoding: reply, as: UTF8.self)) }
        return dps
    }

    func set(_ dps: [String: Any]) async throws {
        let body = try json(["devId": device.id, "uid": device.id, "t": now(), "dps": dps])
        _ = try await request(cmd: 7, payload: Data("3.3".utf8) + Data(count: 12) + aes(body, key: device.key, encrypt: true))
    }

    private func request(cmd: UInt32, payload: Data) async throws -> Data {
        let conn = NWConnection(host: .init(device.ip), port: 6668, using: .tcp)
        conn.start(queue: .global())
        defer { conn.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { conn.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: frame(cmd: cmd, payload: payload), completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
        var buf = Data()
        while true {
            buf += try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, e in
                    if let e { c.resume(throwing: e) } else if let data, !data.isEmpty { c.resume(returning: data) } else { c.resume(throwing: TuyaError.closed) }
                }
            }
            while let f = parse(&buf) {
                if f.cmd == cmd { return try decode(f.payload, key: device.key) }
            }
        }
    }

    private func now() -> String { String(Int(Date().timeIntervalSince1970)) }
    private func json(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
}

func frame(cmd: UInt32, payload: Data, seq: UInt32 = 1) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    u32(0x55AA); u32(seq); u32(cmd); u32(UInt32(payload.count + 8))
    d += payload
    u32(crc32(d)); u32(0xAA55)
    return d
}

func parse(_ buf: inout Data) -> (cmd: UInt32, payload: Data)? {
    let b = [UInt8](buf)
    guard b.count >= 16 else { return nil }
    func u32(_ i: Int) -> UInt32 { b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    guard u32(0) == 0x55AA else { buf.removeAll(); return nil }
    let end = 16 + Int(u32(12))
    guard b.count >= end, end >= 24 else { return nil }
    buf = Data(b[end...])
    return (u32(8), Data(b[16..<end - 8]))
}

func decode(_ p: Data, key: String) throws -> Data {
    var p = [UInt8](p)
    if p.count >= 4, p[0] == 0, p[1] == 0, p[2] == 0 { p.removeFirst(4) }
    if p.starts(with: Array("3.3".utf8)) { p.removeFirst(min(15, p.count)) }
    return p.isEmpty ? Data() : try aes(Data(p), key: key, encrypt: false)
}

func aes(_ data: Data, key: String, encrypt: Bool) throws -> Data {
    let k = Array(key.utf8)
    guard k.count == 16 else { throw TuyaError.crypto }
    var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
    var n = 0
    let st = data.withUnsafeBytes { d in
        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), k, k.count, nil,
                d.baseAddress, data.count, &out, out.count, &n)
    }
    guard st == kCCSuccess else { throw TuyaError.crypto }
    return Data(out.prefix(n))
}

func crc32(_ d: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in d {
        c ^= UInt32(b)
        for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
    }
    return ~c
}
