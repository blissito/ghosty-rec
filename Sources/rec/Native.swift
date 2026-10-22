// `--aspect native`: el video sale del tamaño real de la ventana grabada (o de su --crop),
// sin fondo, sin margen, sin esquinas redondas ni sombra. Recortes, zooms, cursor y pastillas siguen.
import Foundation
import CoreGraphics

/// Lienzo nativo en píxeles: la región recortada a la escala del video, en dimensiones pares (h264).
func nativeCanvas(videoPixels: CGSize, windowPoints: CGSize, crop: [Double]) -> CGSize {
    let ps = videoPixels.width / windowPoints.width
    func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }
    return CGSize(width: even((CGFloat(crop[2]) * ps).rounded()), height: even((CGFloat(crop[3]) * ps).rounded()))
}

/// Zooms automáticos (los de grupos de clics: sin recuadro, etiqueta «clic»). `--no-auto-zoom`
/// los quita también de un project.json ya escrito, sin borrarlos del archivo.
func withoutAutoZooms(_ zooms: [Zoom]) -> [Zoom] {
    zooms.filter { !($0.rect == nil && $0.label == "clic") }
}
