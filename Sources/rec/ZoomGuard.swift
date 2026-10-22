// Guarda de zoom: un zoom sin recuadro sigue al puntero, así que nunca debe quedar centrado
// lejos de él. El cursor.jsonl registra el mouse REAL del sistema: si el clic cae fuera de la
// ventana grabada (otra app, otro monitor) o los clics son sintéticos (CDP) y el mouse real
// está en otro lado, el foco salía de la ventana, se recortaba a 0–1 y el zoom caía en un borde vacío.
import Foundation

/// ¿El punto (normalizado a la ventana) está dentro de ella, con un margen pequeño?
func pointerInWindow(_ x: Double, _ y: Double, margin: Double = 0.02) -> Bool {
    x >= -margin && x <= 1 + margin && y >= -margin && y <= 1 + margin
}

/// Grupos de clics para el zoom automático: sólo cuentan los que caen dentro de la ventana;
/// clics a menos de `gap` segundos se juntan.
func clickGroups(_ cursor: [CursorSample], gap: Double = 2.5) -> [[CursorSample]] {
    var groups: [[CursorSample]] = []
    var prevDown = false
    for c in cursor {
        if c.down && !prevDown && pointerInWindow(c.x, c.y) {
            if let last = groups.last?.last, c.t - last.t < gap { groups[groups.count - 1].append(c) } else { groups.append([c]) }
        }
        prevDown = c.down
    }
    return groups
}

/// Revisa los zooms sin recuadro contra el puntero en su momento: si el puntero está fuera de la
/// ventana se apagan; si está dentro pero lejos del foco (`maxDist`, normalizado por eje) el foco
/// se mueve al puntero. Los zooms con recuadro son intención explícita del agente y no se tocan.
func guardZoomsToPointer(_ zooms: [Zoom], pointerAt: (Double) -> (x: Double, y: Double),
                         maxDist: Double = 0.3) -> (zooms: [Zoom], dropped: [Double], refocused: [Double]) {
    var out = zooms, dropped: [Double] = [], refocused: [Double] = []
    for i in out.indices where out[i].enabled && out[i].rect == nil {
        let p = pointerAt(out[i].t)
        if !pointerInWindow(p.x, p.y) {
            out[i].enabled = false
            dropped.append(out[i].t)
        } else if abs(p.x - out[i].focus[0]) > maxDist || abs(p.y - out[i].focus[1]) > maxDist {
            out[i].focus = [min(1, max(0, p.x)), min(1, max(0, p.y))]
            refocused.append(out[i].t)
        }
    }
    return (out, dropped, refocused)
}
