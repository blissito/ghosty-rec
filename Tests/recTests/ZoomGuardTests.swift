import Testing
@testable import rec

// Regresión de take2 (gads-verificacion, 22-oct): clics reales fuera de la ventana
// (x=-895 pt en una ventana de 1301) acababan en un zoom pegado al borde izquierdo.
@Suite struct ZoomGuardTests {
    func s(_ t: Double, _ x: Double, _ y: Double, _ down: Bool) -> CursorSample { CursorSample(t: t, x: x, y: y, down: down) }

    @Test func clicksOutsideWindowDoNotMakeGroups() {
        let cursor = [s(40.4, 0.64, 0.27, true), s(40.5, 0.64, 0.27, false),
                      s(45.4, -0.13, 0.52, true), s(45.5, -0.13, 0.52, false),
                      s(97.8, -0.69, 0.93, true), s(97.9, -0.69, 0.93, false)]
        let g = clickGroups(cursor)
        #expect(g.count == 1)
        #expect(g[0][0].t == 40.4)
    }

    @Test func zoomWithPointerOutsideIsDisabled() {
        let z = Zoom(t: 97.833, hold: 1.5, scale: 1.8, focus: [0, 0.93], rect: nil, label: "clic", say: nil, enabled: true)
        let r = guardZoomsToPointer([z], pointerAt: { _ in (-0.69, 0.93) })
        #expect(r.zooms[0].enabled == false)
        #expect(r.dropped == [97.833])
    }

    @Test func zoomFarFromPointerIsRefocused() {
        let z = Zoom(t: 10, hold: 1.5, scale: 1.8, focus: [0.1, 0.1], rect: nil, label: "clic", say: nil, enabled: true)
        let r = guardZoomsToPointer([z], pointerAt: { _ in (0.7, 0.5) })
        #expect(r.zooms[0].enabled)
        #expect(r.zooms[0].focus == [0.7, 0.5])
    }

    @Test func zoomWithRectIsUntouched() {
        let z = Zoom(t: 10, hold: 2, scale: 1.5, focus: [0.2, 0.2], rect: [0.1, 0.1, 0.2, 0.2], label: "m", say: nil, enabled: true)
        let r = guardZoomsToPointer([z], pointerAt: { _ in (-2, -2) })
        #expect(r.zooms[0].enabled)
        #expect(r.zooms[0].focus == [0.2, 0.2])
    }
}
