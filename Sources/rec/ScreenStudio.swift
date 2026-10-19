// Fondos de Screen Studio leídos del app.asar del Screen Studio instalado en esta Mac.
// No se copian ni se redistribuyen: si la app no está, la opción falla con un mensaje claro.
import Foundation

let screenStudioAsar = "/Applications/Screen Studio.app/Contents/Resources/app.asar"

// ASAR: [u32 4][u32 tamaño del pickle][u32 payload][u32 largo del JSON][JSON]…; los archivos empiezan
// en 8 + tamaño del pickle y cada entrada trae su offset (texto) y su size.
func screenStudioBackground(_ name: String) -> Data? {
    guard let fh = FileHandle(forReadingAtPath: screenStudioAsar) else { return nil }
    defer { try? fh.close() }
    let head = fh.readData(ofLength: 16)
    guard head.count == 16 else { return nil }
    let u32 = { (o: Int) -> Int in Int(head[o]) | Int(head[o + 1]) << 8 | Int(head[o + 2]) << 16 | Int(head[o + 3]) << 24 }
    let pickleSize = u32(4), jsonLen = u32(12)
    let json = fh.readData(ofLength: jsonLen)
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
    var node: [String: Any]? = root
    for part in ["assets", "backgrounds"] + name.split(separator: "/").map(String.init) {
        node = (node?["files"] as? [String: Any])?[part] as? [String: Any]
    }
    guard let entry = node, let off = Int(entry["offset"] as? String ?? ""), let size = entry["size"] as? Int else { return nil }
    try? fh.seek(toOffset: UInt64(8 + pickleSize + off))
    return fh.readData(ofLength: size)
}

// Lista «carpeta/nombre» de los fondos disponibles, para el mensaje de error.
func screenStudioBackgroundNames() -> [String] {
    guard let fh = FileHandle(forReadingAtPath: screenStudioAsar) else { return [] }
    defer { try? fh.close() }
    let head = fh.readData(ofLength: 16)
    let jsonLen = Int(head[12]) | Int(head[13]) << 8 | Int(head[14]) << 16 | Int(head[15]) << 24
    guard let root = try? JSONSerialization.jsonObject(with: fh.readData(ofLength: jsonLen)) as? [String: Any],
          let assets = (root["files"] as? [String: Any])?["assets"] as? [String: Any],
          let bgs = (assets["files"] as? [String: Any])?["backgrounds"] as? [String: Any],
          let dirs = bgs["files"] as? [String: Any] else { return [] }
    return dirs.flatMap { dir, v in
        ((v as? [String: Any])?["files"] as? [String: Any] ?? [:]).keys.map { "\(dir)/\(($0 as NSString).deletingPathExtension)" }
    }.sorted()
}
