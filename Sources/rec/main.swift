// rec — graba UNA ventana de macOS desde la terminal, pensado para agentes.
// POC: windows | start | stop | mark | status. El render con marcas viene después.
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

let version = "0.6.1"

let stateDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".rec")
let stateFile = stateDir.appendingPathComponent("session.json")
// t0 = momento del primer cuadro del archivo; lo escribe sólo el grabador, con su pid.
let clockFile = stateDir.appendingPathComponent("t0")

func readClock(pid: Int32) -> Double? {
    guard let txt = try? String(contentsOf: clockFile, encoding: .utf8) else { return nil }
    let parts = txt.split(separator: " ")
    guard parts.count == 2, Int32(parts[0]) == pid else { return nil }
    return Double(parts[1])
}

let usage = """
rec — graba UNA ventana de macOS (nunca la pantalla completa). Salida en JSON.

  rec windows [--json]                 lista ventanas: id, app, título, rect (puntos de pantalla)
  rec start (--id N | --window texto) --out x.mov [--fps 60] [--cursor]
                                       arranca en segundo plano → {pid, out, marks, window}
  rec mark "evento" [--rect x,y,w,h]   marca qué hace el agente → {t, label, rect}
                                       t = segundos desde el inicio del archivo
                                       rect en puntos, relativo a la esquina superior izquierda de la ventana
        [--say "frase"] [--zoom 1.8] [--hold 2] [--no-zoom] [--at +1.5]
  rec stop                             cierra el .mov → {out, marks, cursor, seconds}
  rec render x.mov [--aspect 16:9|9:16|1:1] [--out y.mp4] [--bg "#hex[,#hex]"]
        [--padding 0.08] [--radius 12] [--zoom 1.8] [--no-cursor] [--reset]
        [--crop x,y,w,h | --no-titlebar] [--fill 0.6] [--max-upscale 1.5]
        [--bg midnight|ocean|sunset|candy|mint|forest|grape|paper|ink|macos:Sonoma|foto.jpg|#hex,#hex]
        [--cursor-size 1.5] [--click ring] [--motion-blur] [--shadow 0.75] [--shadow-style hard] [--no-auto-zoom]
        [--trim-idle 1.5]                corta las esperas donde la ventana no cambia
                                       sin marcas, hace zoom solo en los grupos de clics   (fill: alto que ocupa la ventana en 9:16)
                                       arma x.project.json (zooms editables: "enabled": false lo quita)
                                       y exporta con zoom suave, cursor suavizado, fondo y sombra
  rec status                           ¿hay grabación? → {recording, …}

Las marcas quedan en x.marks.jsonl junto al video.
El video sale en la escala de la pantalla: 2× en Retina, 1× en un monitor normal.
Permiso: Grabación de pantalla para la terminal que corre rec (código de salida 3 si falta).
"""

struct Session: Codable {
    var pid: Int32
    var out: String
    var marks: String
    var windowId: UInt32
    var app: String
    var title: String
    var rect: [Double]
    var startedAt: Double?
}

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
}

func readSession() -> Session? {
    guard let data = try? Data(contentsOf: stateFile) else { return nil }
    return try? JSONDecoder().decode(Session.self, from: data)
}

func writeSession(_ s: Session) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try! JSONEncoder().encode(s).write(to: stateFile)
}

func log(_ msg: String) {
    FileHandle.standardError.write("[rec \(getpid())] \(msg)\n".data(using: .utf8)!)
}

func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

// El permiso se le da a la app que abrió la terminal (Ghostty, Terminal…), no a `rec`.
func ensurePermission() {
    if CGPreflightScreenCaptureAccess() { return }
    CGRequestScreenCaptureAccess()
    fail("""
    rec necesita permiso de Grabación de pantalla.
    Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema →
    prende tu terminal y vuelve a abrirla. Después repite el comando.
    """, code: 3)
}

// Sólo el proceso grabador habla con ScreenCaptureKit: si otro proceso de `rec` pide
// SCShareableContent mientras se graba, macOS corta el stream vivo («se interrumpió la
// conexión con la app»). Por eso listar y resolver ventanas va por CGWindowList.
struct Win {
    let id: UInt32
    let app: String
    let title: String
    let onScreen: Bool
    let rect: CGRect
}

func listWindows() -> [Win] {
    let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { d -> Win? in
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              let id = d[kCGWindowNumber as String] as? UInt32,
              let b = d[kCGWindowBounds as String] as? [String: Double] else { return nil }
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        let app = d[kCGWindowOwnerName as String] as? String ?? ""
        let title = d[kCGWindowName as String] as? String ?? ""
        let onScreen = (d[kCGWindowIsOnscreen as String] as? Bool) ?? false
        guard rect.width > 120, rect.height > 80, onScreen || !title.isEmpty else { return nil }
        return Win(id: id, app: app, title: title, onScreen: onScreen, rect: rect)
    }
}

func windowById(_ id: UInt32) -> Win? {
    let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]] ?? []
    guard let d = info.first, let b = d[kCGWindowBounds as String] as? [String: Double] else { return nil }
    return Win(id: id, app: d[kCGWindowOwnerName as String] as? String ?? "",
               title: d[kCGWindowName as String] as? String ?? "",
               onScreen: (d[kCGWindowIsOnscreen as String] as? Bool) ?? false,
               rect: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
}

func describe(_ w: Win) -> [String: Any] {
    ["id": w.id, "app": w.app, "title": w.title, "onScreen": w.onScreen,
     "rect": [w.rect.origin.x, w.rect.origin.y, w.rect.width, w.rect.height]]
}

// Acepta id numérico, o texto que coincide con app o título (gana la ventana en pantalla más grande).
func resolveWindow(_ query: String, in windows: [Win]) -> Win? {
    if let id = UInt32(query) { return windowById(id) }
    let q = query.lowercased()
    return windows.filter { $0.app.lowercased().contains(q) || $0.title.lowercased().contains(q) }
        .sorted { ($0.onScreen ? 1 : 0, $0.rect.width * $0.rect.height) > ($1.onScreen ? 1 : 0, $1.rect.width * $1.rect.height) }
        .first
}

func arg(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// Global para que ARC no suelte las fuentes de señal antes de tiempo.
var signalSources: [DispatchSourceSignal] = []

// Escribe el .mov con AVAssetWriter a cuadros constantes (CFR): ScreenCaptureKit sólo entrega
// cuadros cuando la ventana cambia, así que un reloj a `fps` repite el último cuadro recibido.
// Junto al video guarda la ruta del cursor (x.cursor.jsonl, puntos relativos a la ventana)
// para que el render lo redibuje suavizado.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let fps: Int
    let queue = DispatchQueue(label: "rec.writer")
    var latest: CVPixelBuffer?
    var frame: Int64 = 0
    var timer: DispatchSourceTimer?
    var cursorOut: FileHandle?
    var windowRect: CGRect
    let windowId: UInt32

    init(out: URL, width: Int, height: Int, fps: Int, windowId: UInt32, windowRect: CGRect, cursorPath: String) throws {
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, width * height * 12),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        self.fps = fps
        self.windowId = windowId
        self.windowRect = windowRect
        FileManager.default.createFile(atPath: cursorPath, contents: nil)
        cursorOut = FileHandle(forWritingAtPath: cursorPath)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb),
              let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        queue.async {
            let first = self.latest == nil
            self.latest = pb
            if first { self.begin() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("el stream se detuvo: \(error.localizedDescription)")
    }

    // Arranca el archivo con el primer cuadro real: así el cuadro 0 nunca sale vacío.
    private func begin() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? "\(getpid()) \(Date().timeIntervalSince1970)".write(to: clockFile, atomically: true, encoding: .utf8)
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(500))
        let start = DispatchTime.now().uptimeNanoseconds
        t.setEventHandler { [unowned self] in
            // El índice sale del reloj real: si un tick se atrasa, se rellena para no perder sincronía.
            let due = Int64((DispatchTime.now().uptimeNanoseconds - start) * UInt64(fps) / 1_000_000_000)
            while self.frame <= due { self.appendFrame() }
        }
        timer = t
        t.resume()
    }

    private func appendFrame() {
        guard let pb = latest, input.isReadyForMoreMediaData else { frame += 1; return }
        let pts = CMTime(value: frame, timescale: CMTimeScale(fps))
        adaptor.append(pb, withPresentationTime: pts)
        if frame % Int64(max(1, fps / 30)) == 0 { logCursor(at: Double(frame) / Double(fps)) }
        frame += 1
    }

    // Cursor a ~30 Hz en puntos relativos a la esquina superior izquierda de la ventana.
    private func logCursor(at t: Double) {
        let m = NSEvent.mouseLocation
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        if frame % Int64(fps) == 0, let w = windowById(windowId) { windowRect = w.rect }
        let x = m.x - windowRect.origin.x
        let y = (screenH - m.y) - windowRect.origin.y
        let down = NSEvent.pressedMouseButtons & 1 == 1
        let line = String(format: "{\"t\":%.3f,\"x\":%.1f,\"y\":%.1f,\"down\":%@}\n", t, x, y, down ? "true" : "false")
        cursorOut?.write(line.data(using: .utf8)!)
    }

    func finish() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.timer?.cancel()
                guard self.writer.status == .writing else { c.resume(); return }
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: CMTime(value: self.frame, timescale: CMTimeScale(self.fps)))
                self.writer.finishWriting { c.resume() }
            }
        }
        try? cursorOut?.close()
    }
}

final class CheckedContinuationBox: @unchecked Sendable {
    private var cont: CheckedContinuation<Void, Never>?
    private var done = false
    func wait() async {
        await withCheckedContinuation { c in
            if done { c.resume() } else { cont = c }
        }
    }
    func resume() {
        done = true
        cont?.resume()
        cont = nil
    }
}

// Proceso de fondo que de verdad graba; `start` lo lanza y `stop` le manda SIGINT.
func runRecorder(windowId: UInt32, out: String, fps: Int, cursor: Bool) async {
    let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    guard let win = content?.windows.first(where: { $0.windowID == windowId }) else { fail("la ventana \(windowId) ya no existe") }

    // desktopIndependentWindow: sólo esa ventana, aunque otra la tape o esté en otro escritorio.
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let cfg = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    cfg.width = Int(filter.contentRect.width * scale) & ~1
    cfg.height = Int(filter.contentRect.height * scale) & ~1
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.colorSpaceName = CGColorSpace.sRGB
    cfg.queueDepth = 6
    cfg.showsCursor = cursor
    cfg.ignoreShadowsSingleWindow = true
    cfg.capturesAudio = false

    let outURL = URL(fileURLWithPath: out)
    try? FileManager.default.removeItem(at: outURL)
    let cursorPath = (out as NSString).deletingPathExtension + ".cursor.jsonl"
    let rec: Recorder
    do {
        rec = try Recorder(out: outURL, width: cfg.width, height: cfg.height, fps: fps, windowId: windowId,
                           windowRect: win.frame, cursorPath: cursorPath)
    } catch {
        fail("no pude crear el archivo: \(error.localizedDescription)")
    }
    // Metadatos para el render: tamaño de la ventana en puntos y del video en píxeles.
    let meta: [String: Any] = ["windowPoints": [win.frame.width, win.frame.height], "pixels": [cfg.width, cfg.height],
                               "scale": scale, "fps": fps, "app": win.owningApplication?.applicationName ?? "", "title": win.title ?? ""]
    try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + ".rec.json"))
    let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
    do {
        try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec.frames"))
        try await stream.startCapture()
    } catch {
        fail("no pude arrancar la captura: \(error.localizedDescription)")
    }
    log("capturando ventana \(windowId) a \(cfg.width)×\(cfg.height) (\(Int(scale))×), \(fps) fps")

    // Espera SIGINT/SIGTERM y cierra el archivo limpio.
    let stop = CheckedContinuationBox()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { log("señal \(sig)"); stop.resume() }
        s.resume()
        return s
    }
    await stop.wait()
    log("stop recibido")
    Task { try? await Task.sleep(nanoseconds: 15_000_000_000); log("el archivo no cerró en 15 s"); exit(1) }
    try? await stream.stopCapture()
    await rec.finish()
    log("archivo cerrado")
    exit(0)
}

func run() async {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else { fail(usage, code: 2) }
    args.removeFirst()
    if ["version", "--version", "-v"].contains(cmd) {
        print("rec \(version)")
        return
    }
    if ["help", "--help", "-h"].contains(cmd) || args.contains("--help") || args.contains("-h") {
        print(usage)
        return
    }

    switch cmd {
    case "windows":
        ensurePermission()
        let ws = listWindows()
        if args.contains("--json") {
            printJSON(ws.map(describe))
        } else {
            for w in ws { print("\(w.id)\t\(w.app)\t\(w.title)") }
        }

    case "start":
        ensurePermission()
        if let s = readSession(), isAlive(s.pid) { fail("ya hay una grabación (pid \(s.pid)); corre `rec stop`", code: 2) }
        guard let q = arg("--id", args) ?? arg("--window", args) else {
            if args.contains("--display") { fail("--display todavía no está en el POC", code: 2) }
            fail("falta --id N o --window <texto>; rec nunca graba la pantalla completa", code: 2)
        }
        guard let out = arg("--out", args) else { fail("falta --out x.mov", code: 2) }
        let fps = Int(arg("--fps", args) ?? "60") ?? 60
        if arg("--id", args) != nil, UInt32(q) == nil { fail("--id espera un número de `rec windows`", code: 2) }
        guard let win = resolveWindow(q, in: listWindows()) else { fail("no encontré la ventana «\(q)»; mira `rec windows`", code: 2) }

        let outPath = URL(fileURLWithPath: out).standardizedFileURL.path
        let marksPath = (outPath as NSString).deletingPathExtension + ".marks.jsonl"
        try? FileManager.default.removeItem(atPath: marksPath)
        try? FileManager.default.removeItem(at: clockFile)
        let p = Process()
        // Doble fork por sh: el grabador queda huérfano y no comparte la sesión de captura de este proceso.
        // Ruta absoluta del binario: argv[0] puede ser relativo («rec» vía PATH) y el cwd cambia.
        let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let childArgs = ["_record", String(win.id), outPath, String(fps), args.contains("--cursor") ? "1" : "0"]
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "\"$0\" \"$@\" </dev/null >/dev/null 2>>\"$REC_LOG\" & echo $!", me] + childArgs
        let pidPipe = Pipe()
        p.standardOutput = pidPipe
        let logURL = stateDir.appendingPathComponent("recorder.log")
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.environment = ProcessInfo.processInfo.environment.merging(["REC_LOG": logURL.path]) { $1 }
        do { try p.run() } catch { fail("no pude lanzar el grabador: \(error)") }
        p.waitUntilExit()
        let pidText = String(data: pidPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let childPid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("no obtuve el pid del grabador") }
        let f = win.rect
        writeSession(Session(pid: childPid, out: outPath, marks: marksPath, windowId: win.id, app: win.app, title: win.title,
                             rect: [f.origin.x, f.origin.y, f.width, f.height], startedAt: nil))
        // Espera el primer cuadro para que `mark` tenga reloj.
        var t0: Double?
        for _ in 0..<50 {
            t0 = readClock(pid: childPid)
            if t0 != nil { break }
            if !isAlive(childPid) { fail("el grabador murió; mira \(logURL.path)") }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if var s = readSession(), let t0 { s.startedAt = t0; writeSession(s) }
        var res: [String: Any] = ["pid": childPid, "out": outPath, "marks": marksPath,
                                  "window": ["id": win.id, "title": win.title, "rect": [f.origin.x, f.origin.y, f.width, f.height]]]
        if !win.onScreen { res["warning"] = "la ventana está minimizada o en otro escritorio: no habrá cuadros hasta que se vea" }
        if t0 == nil { res["warning"] = "no llegó el primer cuadro en 5 s; ¿la ventana está quieta o minimizada?" }
        printJSON(res)

    case "_record":
        guard args.count >= 4, let id = UInt32(args[0]) else { fail("uso interno") }
        await runRecorder(windowId: id, out: args[1], fps: Int(args[2]) ?? 60, cursor: args[3] == "1")

    case "mark":
        guard let s = readSession(), isAlive(s.pid) else { fail("no hay grabación en curso", code: 2) }
        guard let t0 = readClock(pid: s.pid) else { fail("la grabación aún no recibe su primer cuadro", code: 2) }
        guard let label = args.first, !label.hasPrefix("--") else { fail("uso: rec mark \"evento\" [--rect x,y,w,h]", code: 2) }
        // --at corre la marca en el tiempo (+1.5 = cuando termine de escribirse lo que viene).
        let at = arg("--at", args).flatMap(Double.init) ?? 0
        var m: [String: Any] = ["t": Decimal(string: String(format: "%.3f", max(0, Date().timeIntervalSince1970 - t0 + at)))!, "label": label]
        if let r = arg("--rect", args) { m["rect"] = r.split(separator: ",").compactMap { Double($0) } }
        if let say = arg("--say", args) { m["say"] = say }
        if let z = arg("--zoom", args).flatMap(Double.init) { m["zoom"] = z }
        if let h = arg("--hold", args).flatMap(Double.init) { m["hold"] = h }
        if args.contains("--no-zoom") { m["zoom"] = 1 }
        let line = String(data: try! JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]), encoding: .utf8)! + "\n"
        if let h = FileHandle(forWritingAtPath: s.marks) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: s.marks, contents: line.data(using: .utf8))
        }
        print(line, terminator: "")

    case "render":
        guard let input = args.first, !input.hasPrefix("--") else { fail("uso: rec render x.mov [--aspect 16:9|9:16] [--out y.mp4]", code: 2) }
        await renderCommand(input: input, args: args)

    case "stop":
        guard let s = readSession(), isAlive(s.pid) else { fail("no hay grabación en curso", code: 2) }
        kill(s.pid, SIGINT)
        for _ in 0..<100 where isAlive(s.pid) { try? await Task.sleep(nanoseconds: 100_000_000) }
        if isAlive(s.pid) { fail("el grabador no cerró en 10 s (pid \(s.pid))") }
        try? FileManager.default.removeItem(at: stateFile)
        let dur = readClock(pid: s.pid).map { Date().timeIntervalSince1970 - $0 } ?? 0
        printJSON(["out": s.out, "marks": s.marks, "cursor": (s.out as NSString).deletingPathExtension + ".cursor.jsonl", "seconds": Decimal(string: String(format: "%.2f", dur))!])

    case "status":
        if let s = readSession(), isAlive(s.pid) {
            printJSON(["recording": true, "pid": s.pid, "out": s.out, "app": s.app, "title": s.title])
        } else {
            printJSON(["recording": false])
        }

    default:
        fail("comando desconocido: \(cmd)", code: 2)
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10.0, Double(p))
        return (self * m).rounded() / m
    }
}

// ScreenCaptureKit exige la conexión con el WindowServer inicializada (si no, CGS_REQUIRE_INIT).
// y el indicador de grabación de la barra de menú se crea en el hilo principal: corre el run loop de AppKit.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let task = Task { await run(); exit(0) }
app.run()
