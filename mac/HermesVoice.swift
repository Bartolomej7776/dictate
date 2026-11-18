// Hold Right Option, talk, release: the speech is transcribed by an OpenAI-compatible Whisper server
// and sent to a Hermes Agent webhook route, which runs it and delivers the reply.
import AVFoundation
import AppKit
import CryptoKit
import Foundation

struct Config: Decodable {
    let whisper: String
    let model: String?
    let language: String?
    let hermes_url: String
    let hermes_secret: String
    // Tried when the primary URL can't be reached (e.g. Tailscale down at home).
    let whisper_fallback: String?
    let hermes_fallback: String?
    let source: String?
    let min_hold: Double?
    let tail: Double?
}

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/HermesVoice")
let logURL = supportDir.appendingPathComponent("hermesvoice.log")

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "\(f.string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

func sound(_ name: String) {
    NSSound(named: NSSound.Name(name))?.play()
}

final class Voice {
    let cfg: Config
    let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("hermesvoice.wav")
    var recorder: AVAudioRecorder?
    var held = false
    var pressedAt = Date()
    var busy = false
    let rightOption: Int64 = 61

    init(cfg: Config) { self.cfg = cfg }

    func start() {
        guard !busy else { return }
        held = true
        pressedAt = Date()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            recorder = try AVAudioRecorder(url: wavURL, settings: settings)
            recorder?.record()
        } catch {
            log("record failed: \(error)")
            held = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (cfg.min_hold ?? 0.3)) { [weak self] in
            if let s = self, s.held { sound("Tink") }
        }
    }

    func cancel() {
        held = false
        recorder?.stop()
        recorder = nil
    }

    func release() {
        held = false
        let heldFor = Date().timeIntervalSince(pressedAt)
        if heldFor < (cfg.min_hold ?? 0.3) { cancel(); return }
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (cfg.tail ?? 0.2)) { [self] in
            recorder?.stop()
            recorder = nil
            sound("Pop")
            guard let wav = try? Data(contentsOf: wavURL) else { busy = false; return }
            log(String(format: "released after %.2fs, %d bytes", heldFor, wav.count))
            Task {
                defer { DispatchQueue.main.async { self.busy = false } }
                do {
                    let text = try await transcribe(wav).trimmingCharacters(in: .whitespacesAndNewlines)
                    log("heard: \(text)")
                    guard !text.isEmpty else { return }
                    let code = try await sendToHermes(text)
                    log("sent to Hermes: HTTP \(code)")
                    sound(code == 202 ? "Glass" : "Basso")
                } catch {
                    log("failed: \(error)")
                    sound("Basso")
                }
            }
        }
    }

    func transcribe(_ wav: Data) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        var fields = ["model": cfg.model ?? "whisper-1", "response_format": "json"]
        if let l = cfg.language { fields["language"] = l }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        let (data, _) = try await post(
            [cfg.whisper, cfg.whisper_fallback].compactMap { $0.map { $0 + "/v1/audio/transcriptions" } }, body,
            ["Content-Type": "multipart/form-data; boundary=\(boundary)"])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["text"] as? String ?? ""
    }

    // Hermes webhook generic HMAC V2: hex HMAC-SHA256 of "<unix timestamp>.<body>".
    func sendToHermes(_ text: String) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "source": cfg.source ?? "Mac"])
        let ts = String(Int(Date().timeIntervalSince1970))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data((ts + ".").utf8) + body, using: SymmetricKey(data: Data(cfg.hermes_secret.utf8)))
        let (_, resp) = try await post([cfg.hermes_url, cfg.hermes_fallback].compactMap { $0 }, body, [
            "Content-Type": "application/json", "X-Webhook-Timestamp": ts,
            "X-Webhook-Signature-V2": mac.map { String(format: "%02x", $0) }.joined(),
        ])
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    // Only connection-level failures move on to the next URL; an HTTP error response is returned as is.
    func post(_ urls: [String], _ body: Data, _ headers: [String: String]) async throws -> (Data, URLResponse) {
        var lastError: Error = URLError(.badURL)
        for (i, u) in urls.enumerated() {
            var req = URLRequest(url: URL(string: u)!, timeoutInterval: i < urls.count - 1 ? 8 : 30)
            req.httpMethod = "POST"
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            do { return try await URLSession.shared.upload(for: req, from: body) } catch let e as URLError {
                log("\(u) unreachable: \(e.code.rawValue)")
                lastError = e
            }
        }
        throw lastError
    }

    func handle(type: CGEventType, event: CGEvent) {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged && key == rightOption {
            let down = event.flags.contains(.maskAlternate)
            if down && !held { start() } else if !down && held { release() }
        } else if held && (type == .keyDown || (type == .flagsChanged && key != rightOption)) {
            cancel()
        }
    }
}

try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
// Only the LaunchAgent's copy runs. A copy opened by Finder or System Settings' "Quit & Reopen" would
// record into the same file and send every request twice.
if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != Bundle.main.bundleIdentifier {
    log("not started by the LaunchAgent; exiting (pid \(getpid()))")
    exit(0)
}
let cfgURL = supportDir.appendingPathComponent("config.json")
guard let cfgData = try? Data(contentsOf: cfgURL), let cfg = try? JSONDecoder().decode(Config.self, from: cfgData) else {
    log("missing or invalid \(cfgURL.path)")
    exit(1)
}
let voice = Voice(cfg: cfg)

AVCaptureDevice.requestAccess(for: .audio) { ok in log("microphone access: \(ok)") }
// A listen-only tap is created even without Input Monitoring; it just never sees a key.
if !CGPreflightListenEventAccess() {
    log("no Input Monitoring permission yet; asking (System Settings > Privacy & Security > Input Monitoring)")
    CGRequestListenEventAccess()
}

var eventTap: CFMachPort?
var sawEvent = false
let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask(mask),
    callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("event tap was disabled by the system; re-enabling")
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        } else {
            if !sawEvent { sawEvent = true; log("first key event received; Input Monitoring works") }
            voice.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)
else {
    log("cannot create event tap: grant Input Monitoring to HermesVoice in System Settings > Privacy & Security")
    CGRequestListenEventAccess()
    exit(2)
}
eventTap = tap
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("ready; hold Right Option to talk to Hermes")
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
