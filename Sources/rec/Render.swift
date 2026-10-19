// rec render — post-producción estilo Screen Studio, pero dirigida por las marcas del agente.
// La matemática (cámara y cursor) se calcula offline en tiempo de contenido y queda en
// x.project.json; el export sólo la aplica cuadro por cuadro con Core Image.
// Valores tomados de OpenScreen (MIT): escala 1.8, entrada 1.5 s con bezier(0.16,1,0.3,1),
// salida 1 s, paneo de 1 s con bezier(0.1,0,0.2,1) si dos zooms quedan a < 1.5 s, resorte de
// cámara k=320 c=40 m=0.92 y de cursor k=340 c=58 m=1 a 240 Hz.
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct Zoom: Codable {
    var t: Double          // momento de la marca (segundos del archivo)
    var hold: Double       // cuánto se queda ampliado después de la marca
    var scale: Double
    var focus: [Double]    // centro normalizado 0–1 de la ventana
    var rect: [Double]?    // recuadro normalizado de la ventana que debe quedar entero a cuadro
    var label: String
    var say: String?       // frase que se escribe palabra por palabra junto al recuadro
    var enabled: Bool
}

struct Project: Codable {
    var video: String
    var aspect: String
    var background: [String]
    var padding: Double
    var radius: Double
    var shadow: Double
    var cursor: Bool
    var cursorSize: Double
    var crop: [Double]?    // región de la ventana en puntos (x,y,w,h) que entra al video
    var fill: Double?      // en vertical: fracción del alto que ocupa la ventana sin zoom
    var zooms: [Zoom]
}

struct CursorSample { var t: Double; var x: Double; var y: Double; var down: Bool }

func readJSONLines(_ path: String) -> [[String: Any]] {
    guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return txt.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

// Bezier cúbica con P0=(0,0) y P3=(1,1), resuelta por Newton sobre x.
func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> (Double) -> Double {
    func b(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }
    func db(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }
    return { x in
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let d = db(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t -= (b(t, x1, x2) - x) / d
            t = min(1, max(0, t))
        }
        return b(t, y1, y2)
    }
}

let easeZoom = cubicBezier(0.16, 1, 0.3, 1)
let easePan = cubicBezier(0.1, 0, 0.2, 1)

struct Key { var t: Double; var s: Double; var fx: Double; var fy: Double; var rw = 0.0; var rh = 0.0; var ease: (Double) -> Double }

// Línea de tiempo de la cámara: entrada 1 s antes de la marca hasta 0.5 s después,
// se sostiene `hold`, sale en 1 s; dos zooms a menos de 1.5 s se unen en un paneo.
func cameraKeys(_ zooms: [Zoom], duration: Double) -> [Key] {
    let zs = zooms.filter { $0.enabled && $0.scale > 1.01 }.sorted { $0.t < $1.t }
    // Sin zoom la cámara descansa en el último recuadro (o en el primero, antes de empezar):
    // en vertical así no se regresa al centro vacío de la ventana.
    let first = zs.first
    var keys = [Key(t: 0, s: 1, fx: first?.focus[0] ?? 0.5, fy: first?.focus[1] ?? 0.5,
                    rw: first?.rect?[2] ?? 0, rh: first?.rect?[3] ?? 0, ease: easeZoom)]
    var i = 0
    while i < zs.count {
        let z = zs[i]
        let inStart = max(keys.last!.t, z.t - 1.0)
        // Hasta que arranca la entrada la cámara se queda donde estaba; foco y escala se mueven juntos.
        keys.append(Key(t: inStart, s: 1, fx: keys.last!.fx, fy: keys.last!.fy, rw: keys.last!.rw, rh: keys.last!.rh, ease: easeZoom))
        keys.append(Key(t: max(inStart + 0.3, z.t + 0.5), s: z.scale, fx: z.focus[0], fy: z.focus[1], rw: z.rect?[2] ?? 0, rh: z.rect?[3] ?? 0, ease: easeZoom))
        var cur = z
        var end = max(keys.last!.t, z.t + z.hold)
        while i + 1 < zs.count, zs[i + 1].t - 1.0 - (end + 1.0) < 1.5 {
            let n = zs[i + 1]
            let panStart = max(end, n.t - 1.0)
            keys.append(Key(t: panStart, s: cur.scale, fx: cur.focus[0], fy: cur.focus[1], rw: cur.rect?[2] ?? 0, rh: cur.rect?[3] ?? 0, ease: easePan))
            keys.append(Key(t: panStart + 1.0, s: n.scale, fx: n.focus[0], fy: n.focus[1], rw: n.rect?[2] ?? 0, rh: n.rect?[3] ?? 0, ease: easePan))
            cur = n
            end = max(panStart + 1.0, n.t + n.hold)
            i += 1
        }
        keys.append(Key(t: end, s: cur.scale, fx: cur.focus[0], fy: cur.focus[1], rw: cur.rect?[2] ?? 0, rh: cur.rect?[3] ?? 0, ease: easeZoom))
        keys.append(Key(t: min(duration, end + 1.0), s: 1, fx: cur.focus[0], fy: cur.focus[1], rw: cur.rect?[2] ?? 0, rh: cur.rect?[3] ?? 0, ease: easeZoom))
        i += 1
    }
    return keys
}

func sampleKeys(_ keys: [Key], _ t: Double) -> [Double] {
    guard let j = keys.firstIndex(where: { $0.t > t }) else {
        let k = keys.last!
        return [k.s, k.fx, k.fy, k.rw, k.rh]
    }
    if j == 0 { return [keys[0].s, keys[0].fx, keys[0].fy, keys[0].rw, keys[0].rh] }
    let a = keys[j - 1], b = keys[j]
    let p = b.ease((t - a.t) / max(1e-6, b.t - a.t))
    let fx = a.fx + (b.fx - a.fx) * p
    let fy = a.fy + (b.fy - a.fy) * p
    return [a.s + (b.s - a.s) * p, fx, fy, a.rw + (b.rw - a.rw) * p, a.rh + (b.rh - a.rh) * p]
}

// Resorte con Euler semi-implícito a 240 Hz; si cruza el objetivo se clava ahí (sin rebote).
struct Spring {
    var x: Double, v: Double = 0
    let k: Double, c: Double, m: Double
    mutating func step(to target: Double, dt: Double) {
        let before = x - target
        v += (-k * before - c * v) / m * dt
        x += v * dt
        if before * (x - target) < 0 { x = target; v = 0 }
    }
}

func smoothTrack(duration: Double, fps: Int, sample: (Double) -> [Double], k: Double, c: Double, m: Double) -> [[Double]] {
    let sub = 240
    let dt = 1.0 / Double(sub)
    var springs = sample(0).map { Spring(x: $0, k: k, c: c, m: m) }
    var out: [[Double]] = []
    let frames = Int((duration * Double(fps)).rounded(.up))
    var t = 0.0
    for f in 0..<frames {
        let ft = Double(f) / Double(fps)
        while t < ft {
            let target = sample(t)
            for i in springs.indices { springs[i].step(to: target[i], dt: dt) }
            t += dt
        }
        out.append(springs.map(\.x))
    }
    return out
}

func parseColor(_ hex: String) -> CIColor {
    var h = hex.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0x0E1317
    return CIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255)
}

// Flecha de cursor vectorial (relleno negro, contorno blanco) dibujada a 4× para que sea nítida.
func cursorImage(height: CGFloat) -> CIImage {
    let s: CGFloat = 4
    let w = Int(height * 0.72 * s), h = Int(height * s)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.78), (0.2, 0.62), (0.34, 0.92), (0.46, 0.87), (0.33, 0.58), (0.58, 0.58)]
    let path = CGMutablePath()
    let pad = 0.08 * CGFloat(h)
    for (i, p) in pts.enumerated() {
        let pt = CGPoint(x: pad + p.0 * CGFloat(h) * 0.85, y: CGFloat(h) - pad - p.1 * CGFloat(h) * 0.85)
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(0.06 * CGFloat(h))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.drawPath(using: .fillStroke)
    let img = CIImage(cgImage: ctx.makeImage()!)
    return img.transformed(by: CGAffineTransform(scaleX: 1 / s, y: 1 / s))
}

// Encoge un recuadro (normalizado) a lo que de verdad tiene contenido: toma el cuadro al final
// del zoom, adivina el color de fondo por la esquina del recuadro y se queda con la caja de los
// píxeles distintos, con un margen. Así «toda la línea» se vuelve «lo que se escribió».
func tightenRect(_ r: [Double], asset: AVURLAsset, at t: Double) async -> [Double] {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { return r }
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = ctx.data else { return r }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    let x0 = Int(r[0] * Double(w)), y0 = Int(r[1] * Double(h))
    let x1 = min(w, Int((r[0] + r[2]) * Double(w))), y1 = min(h, Int((r[1] + r[3]) * Double(h)))
    guard x1 - x0 > 8, y1 - y0 > 8 else { return r }
    // El buffer está con la fila 0 arriba (CGContext dibuja invertido respecto a CI, pero aquí no importa: misma convención que y0).
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
    }
    // Fondo = el color más común del recuadro (muestreado).
    var counts: [Int: Int] = [:]
    for y in stride(from: y0, to: y1, by: 3) {
        for x in stride(from: x0, to: x1, by: 3) {
            let p = pixel(x, y)
            counts[(p.0 >> 3) << 10 | (p.1 >> 3) << 5 | (p.2 >> 3), default: 0] += 1
        }
    }
    let key = counts.max { $0.value < $1.value }?.key ?? 0
    let bg = (((key >> 10) & 31) << 3 + 4, ((key >> 5) & 31) << 3 + 4, (key & 31) << 3 + 4)
    func differs(_ x: Int, _ y: Int) -> Bool {
        let p = pixel(x, y)
        return abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 60
    }
    // Columnas casi llenas son barras (scroll, bordes), no texto: no cuentan.
    let rows = y1 - y0
    var minX = x1, minY = y1, maxX = x0, maxY = y0
    for x in x0..<x1 {
        var hits: [Int] = []
        for y in y0..<y1 where differs(x, y) { hits.append(y) }
        if hits.isEmpty || hits.count > rows * 9 / 10 { continue }
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, hits.first!); maxY = max(maxY, hits.last!)
    }
    guard maxX > minX, maxY > minY else { return r }
    let m = Int(0.02 * Double(w))
    minX = max(x0, minX - m); minY = max(y0, minY - m); maxX = min(x1, maxX + m); maxY = min(y1, maxY + m)
    return [Double(minX) / Double(w), Double(minY) / Double(h), Double(maxX - minX) / Double(w), Double(maxY - minY) / Double(h)]
}

// Pastilla plana con sombra dura (sin blur): las primeras `words` palabras de `text`.
// El ancho se fija con la frase completa para que no brinque mientras se escribe.
func pillImage(_ text: String, words: Int, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage {
    let all = text.split(separator: " ").map(String.init)
    let shown = all.prefix(words).joined(separator: " ")
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.09, alpha: 1), .paragraphStyle: para]
    let padX = fontSize * 0.7, padY = fontSize * 0.45, shadow = max(4, fontSize * 0.22)
    let full = NSAttributedString(string: text, attributes: attrs)
    let box = full.boundingRect(with: CGSize(width: maxWidth - 2 * padX, height: 10_000), options: [.usesLineFragmentOrigin])
    let w = ceil(box.width + 2 * padX), h = ceil(box.height + 2 * padY)
    let scale: CGFloat = 2
    let ctx = CGContext(data: nil, width: Int((w + shadow) * scale), height: Int((h + shadow) * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    let r = min(h / 2, fontSize)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.9))
    ctx.addPath(CGPath(roundedRect: CGRect(x: shadow, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()
    let pill = CGRect(x: 0, y: shadow, width: w, height: h)
    ctx.setFillColor(CGColor(srgbRed: 0.52, green: 0.87, blue: 0.80, alpha: 1))
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
    ctx.setLineWidth(max(2, fontSize * 0.1))
    ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 1, dy: 1), cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.strokePath()
    let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    NSAttributedString(string: shown, attributes: attrs)
        .draw(with: CGRect(x: padX, y: shadow + padY, width: box.width + 1, height: box.height), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
    return CIImage(cgImage: ctx.makeImage()!).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
}

func renderCommand(input: String, args: [String]) async {
    let inPath = URL(fileURLWithPath: input).standardizedFileURL.path
    let base = (inPath as NSString).deletingPathExtension
    let projPath = base + ".project.json"
    guard let metaData = try? Data(contentsOf: URL(fileURLWithPath: base + ".rec.json")),
          let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
          let wp = meta["windowPoints"] as? [Double], wp.count == 2 else {
        fail("falta \(base).rec.json: graba con rec 0.2 o posterior", code: 2)
    }
    let winW = wp[0], winH = wp[1]
    let cursor = readJSONLines(base + ".cursor.jsonl").compactMap { d -> CursorSample? in
        guard let t = num(d["t"]), let x = num(d["x"]), let y = num(d["y"]) else { return nil }
        return CursorSample(t: t, x: x / winW, y: y / winH, down: (d["down"] as? Bool) ?? false)
    }
    func cursorAt(_ t: Double) -> (x: Double, y: Double, down: Bool) {
        guard !cursor.isEmpty else { return (0.5, 0.5, false) }
        guard let j = cursor.firstIndex(where: { $0.t > t }) else { let c = cursor.last!; return (c.x, c.y, c.down) }
        if j == 0 { return (cursor[0].x, cursor[0].y, cursor[0].down) }
        let a = cursor[j - 1], b = cursor[j]
        let p = (t - a.t) / max(1e-6, b.t - a.t)
        return (a.x + (b.x - a.x) * p, a.y + (b.y - a.y) * p, a.down)
    }

    // El proyecto se arma una vez desde las marcas; después manda el JSON (ahí se editan o apagan zooms).
    var project: Project
    if !args.contains("--reset"), let d = try? Data(contentsOf: URL(fileURLWithPath: projPath)),
       let p = try? JSONDecoder().decode(Project.self, from: d) {
        project = p
    } else {
        let defaultZoom = arg("--zoom", args).flatMap(Double.init) ?? 1.8
        var zooms = readJSONLines(base + ".marks.jsonl").compactMap { m -> Zoom? in
            guard let t = num(m["t"]) else { return nil }
            var focus = [cursorAt(t).x, cursorAt(t).y]
            var scale = num(m["zoom"]) ?? defaultZoom
            var rectN: [Double]?
            if let r = m["rect"] as? [NSNumber], r.count == 4 {
                let rx = r[0].doubleValue, ry = r[1].doubleValue, rw = r[2].doubleValue, rh = r[3].doubleValue
                focus = [(rx + rw / 2) / winW, (ry + rh / 2) / winH]
                rectN = [rx / winW, ry / winH, rw / winW, rh / winH]
                // Que el recuadro quepa con aire: nunca más que lo pedido, ni menos de 1.25.
                if num(m["zoom"]) == nil { scale = max(1.25, min(defaultZoom, 0.8 * min(winW / max(rw, 1), winH / max(rh, 1)))) }
            }
            return Zoom(t: t, hold: num(m["hold"]) ?? 2.0, scale: scale,
                        focus: focus.map { min(1, max(0, $0)) }, rect: rectN, label: m["label"] as? String ?? "",
                        say: m["say"] as? String, enabled: true)
        }
        // Ajusta cada recuadro a lo que se ve al final de su zoom (--no-tighten lo deja tal cual).
        if !args.contains("--no-tighten") {
            let probe = AVURLAsset(url: URL(fileURLWithPath: inPath))
            for i in zooms.indices {
                guard let r = zooms[i].rect else { continue }
                let tight = await tightenRect(r, asset: probe, at: zooms[i].t + zooms[i].hold)
                zooms[i].rect = tight
                zooms[i].focus = [tight[0] + tight[2] / 2, tight[1] + tight[3] / 2]
            }
        }
        project = Project(video: inPath, aspect: "16:9", background: ["#1B2A4A", "#0E1317"], padding: 0.08, radius: 12,
                          shadow: 0.45, cursor: true, cursorSize: 22, crop: nil, fill: nil, zooms: zooms)
    }
    if let a = arg("--aspect", args) { project.aspect = a }
    if let b = arg("--bg", args) { project.background = b.split(separator: ",").map(String.init) }
    if let p = arg("--padding", args).flatMap(Double.init) { project.padding = p }
    if let r = arg("--radius", args).flatMap(Double.init) { project.radius = r }
    if args.contains("--no-cursor") { project.cursor = false }
    if let c = arg("--crop", args) { project.crop = c.split(separator: ",").compactMap { Double($0) } }
    // La barra de título de macOS mide 28 pt; su título suele traer el proceso («sleep ◂ …»).
    if args.contains("--no-titlebar") { project.crop = [0, 28, winW, winH - 28] }
    if let f = arg("--fill", args).flatMap(Double.init) { project.fill = f }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(project).write(to: URL(fileURLWithPath: projPath))

    let canvas: CGSize = switch project.aspect {
    case "9:16": CGSize(width: 1080, height: 1920)
    case "1:1": CGSize(width: 1080, height: 1080)
    default: CGSize(width: 1920, height: 1080)
    }
    let outPath = arg("--out", args).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        ?? base + ".\(project.aspect.replacingOccurrences(of: ":", with: "x")).mp4"

    let asset = AVURLAsset(url: URL(fileURLWithPath: inPath))
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let duration = try? await asset.load(.duration).seconds,
          let fpsF = try? await track.load(.nominalFrameRate) else { fail("no pude leer \(inPath)") }
    let fps = max(1, Int(fpsF.rounded()))

    // Región que entra al video (por defecto la ventana entera); todo lo normalizado se pasa a ella.
    let crop = (project.crop?.count == 4 ? project.crop! : [0, 0, winW, winH])
    let nx = { (v: Double) in (v * winW - crop[0]) / crop[2] }
    let ny = { (v: Double) in (v * winH - crop[1]) / crop[3] }
    let zooms = project.zooms.map { z -> Zoom in
        var z = z
        z.focus = [nx(z.focus[0]), ny(z.focus[1])]
        if let r = z.rect { z.rect = [nx(r[0]), ny(r[1]), r[2] * winW / crop[2], r[3] * winH / crop[3]] }
        return z
    }
    // Pistas suavizadas, una entrada por cuadro.
    let keys = cameraKeys(zooms, duration: duration)
    let cam = smoothTrack(duration: duration, fps: fps, sample: { t in sampleKeys(keys, t) }, k: 320, c: 40, m: 0.92)
    let cur = smoothTrack(duration: duration, fps: fps, sample: { t in let c = cursorAt(t); return [nx(c.x), ny(c.y)] },
                          k: 340, c: 58, m: 1)

    // Acomodo: la ventana cabe dentro del lienzo con padding, centrada.
    let W = canvas.width, H = canvas.height
    let pad = CGFloat(project.padding) * min(W, H)
    let fit = min((W - 2 * pad) / crop[2], (H - 2 * pad) / crop[3])
    let cw = crop[2] * fit, ch = crop[3] * fit
    let content = CGRect(x: (W - cw) / 2, y: (H - ch) / 2, width: cw, height: ch) // coordenadas CI (origen abajo)
    let radius = CGFloat(project.radius) * fit
    // En vertical una ventana horizontal queda chica: zoom base para que ocupe ~45 % del alto,
    // y la cámara recorre la ventana siguiendo el foco (el recorte 9:16 sale de la misma pista).
    let baseZoom = H > W ? max(1, CGFloat(project.fill ?? 0.6) * H / ch) : 1

    let colors = project.background.map(parseColor)
    let bg: CIImage = {
        if colors.count >= 2 {
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: 0, y: H)
            g.point1 = CGPoint(x: W, y: 0)
            g.color0 = colors[0]
            g.color1 = colors[1]
            return g.outputImage!.cropped(to: CGRect(origin: .zero, size: canvas))
        }
        return CIImage(color: colors.first ?? CIColor(red: 0.05, green: 0.07, blue: 0.09)).cropped(to: CGRect(origin: .zero, size: canvas))
    }()
    let mask: CIImage = {
        let r = CIFilter.roundedRectangleGenerator()
        r.extent = content
        r.radius = Float(radius)
        r.color = .white
        return r.outputImage!
    }()
    let shadow: CIImage = {
        let r = CIFilter.roundedRectangleGenerator()
        r.extent = content.offsetBy(dx: 0, dy: -0.02 * H)
        r.radius = Float(radius)
        r.color = CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(project.shadow))
        return r.outputImage!.applyingGaussianBlur(sigma: 0.025 * H).cropped(to: CGRect(origin: .zero, size: canvas))
    }()
    let staticBack = shadow.composited(over: bg)
    let arrow = cursorImage(height: CGFloat(project.cursorSize) * fit)
    // Etiquetas: una palabra cada 0.32 s desde la marca, visibles hasta que sale su zoom.
    struct Label { let z: Zoom; let words: Int; var cache: [Int: CIImage] = [:] }
    var labels = zooms.filter { $0.enabled && !($0.say ?? "").isEmpty }.map { Label(z: $0, words: $0.say!.split(separator: " ").count) }
    let pillFont = (H > W ? 0.034 : 0.036) * min(W, H) * 1.0

    // Lectura y escritura.
    guard let reader = try? AVAssetReader(asset: asset) else { fail("no pude abrir el lector") }
    let rout = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(rout)
    try? FileManager.default.removeItem(atPath: outPath)
    guard let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: outPath), fileType: .mp4) else { fail("no pude crear \(outPath)") }
    let winput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000, AVVideoMaxKeyFrameIntervalKey: fps * 2],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: winput, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
    ])
    writer.add(winput)
    reader.startReading()
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    var f = 0
    var maxMag: CGFloat = 0
    let pxPerPoint = CGFloat(num(meta["scale"]) ?? 1)
    while let sb = rout.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        let i = min(f, cam.count - 1)
        var s = CGFloat(cam[i][0]) * baseZoom
        // Foco en coordenadas del lienzo (CI: y hacia arriba).
        var cx = content.minX + CGFloat(cam[i][1]) * cw
        var cy = content.maxY - CGFloat(cam[i][2]) * ch
        let rw = CGFloat(cam[i][3]) * cw, rh = CGFloat(cam[i][4]) * ch
        if rw > 1, rh > 1 {
            // El recuadro marcado entra completo: si no cabe al zoom pedido, se baja el zoom.
            // Con la cámara centrada en él y el recuadro dentro del lienzo, el clamp de abajo
            // puede correrla pero nunca lo corta.
            s = max(1, min(s, 0.92 * W / rw, 0.92 * H / rh))
        }
        // Y nunca se sale del lienzo.
        cx = min(W - W / (2 * s), max(W / (2 * s), cx))
        cy = min(H - H / (2 * s), max(H / (2 * s), cy))
        maxMag = max(maxMag, s * fit / pxPerPoint)
        let camT = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))

        let full = CIImage(cvPixelBuffer: pb)
        let ps = full.extent.width / winW
        let frame = full.cropped(to: CGRect(x: crop[0] * ps, y: (winH - crop[1] - crop[3]) * ps, width: crop[2] * ps, height: crop[3] * ps))
            .transformed(by: CGAffineTransform(translationX: -crop[0] * ps, y: -(winH - crop[1] - crop[3]) * ps))
        let k = cw / frame.extent.width
        let placed = frame.transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: content.minX, y: content.minY))
        let win = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        var img = win.composited(over: staticBack)

        if project.cursor, f < cur.count {
            let px = Double(cur[f][0]), py = Double(cur[f][1])
            if (-0.02...1.02).contains(px), (-0.02...1.02).contains(py) {
                let down = cursorAt(Double(f) / Double(fps)).down
                let a = down ? arrow.transformed(by: CGAffineTransform(scaleX: 0.85, y: 0.85)) : arrow
                let tip = CGPoint(x: content.minX + CGFloat(px) * cw, y: content.maxY - CGFloat(py) * ch)
                img = a.transformed(by: CGAffineTransform(translationX: tip.x - 0.08 * a.extent.height * 0.85, y: tip.y - a.extent.maxY + 0.08 * a.extent.height * 0.85))
                    .composited(over: img)
            }
        }
        var out = img.transformed(by: camT).cropped(to: CGRect(origin: .zero, size: canvas))

        // La pastilla va en el espacio de la pantalla (tamaño fijo), anclada bajo el recuadro ya con la cámara.
        let ft = Double(f) / Double(fps)
        for li in labels.indices {
            let z = labels[li].z
            guard ft >= z.t, ft < z.t + z.hold + 0.6 else { continue }
            let n = min(labels[li].words, 1 + Int((ft - z.t) / 0.32))
            let pill = labels[li].cache[n] ?? pillImage(z.say!, words: n, fontSize: pillFont, maxWidth: W * 0.86)
            labels[li].cache[n] = pill
            let r = z.rect ?? [z.focus[0] - 0.05, z.focus[1] - 0.05, 0.1, 0.1]
            let anchor = CGPoint(x: content.minX + CGFloat(r[0]) * cw, y: content.maxY - CGFloat(r[1] + r[3]) * ch).applying(camT)
            var x = min(max(anchor.x, 0.07 * W), W - pill.extent.width - 0.07 * W)
            var y = anchor.y - pill.extent.height - 0.015 * H
            if y < 0.08 * H { y = 0.08 * H }
            x = x.rounded(); y = y.rounded()
            // Entrada: sube 12 px en los primeros 0.25 s.
            let rise = CGFloat(max(0, 1 - (ft - z.t) / 0.25)) * 12
            out = pill.transformed(by: CGAffineTransform(translationX: x, y: y - rise)).composited(over: out)
        }

        while !winput.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
        var opb: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &opb) == kCVReturnSuccess, let opb else {
            fail("sin buffer de salida")
        }
        ctx.render(out, to: opb, bounds: CGRect(origin: .zero, size: canvas), colorSpace: sRGB)
        adaptor.append(opb, withPresentationTime: CMTime(value: Int64(f), timescale: CMTimeScale(fps)))
        f += 1
    }
    winput.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { fail("falló el export: \(writer.error?.localizedDescription ?? "")") }
    var res: [String: Any] = ["out": outPath, "project": projPath, "frames": f, "zooms": project.zooms.filter(\.enabled).count,
                              "size": [Int(W), Int(H)], "maxUpscale": Double(String(format: "%.2f", maxMag))!]
    if maxMag > 1.5 {
        res["warning"] = String(format: "el texto se estira %.1f× y saldrá borroso: graba en pantalla Retina, con fuente más grande o ventana más angosta, o usa --crop", maxMag)
    }
    printJSON(res)
}
