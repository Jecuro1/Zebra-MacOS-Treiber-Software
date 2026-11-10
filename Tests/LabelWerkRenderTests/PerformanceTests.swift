import Foundation
import Testing
@testable import LabelWerkRender

@Suite("Leistung")
struct PerformanceTests {
    @Test("Interpretation und Rasterung eines 4×6-Zoll-Versandetiketts bleiben interaktiv schnell")
    func parcelLabelSpeed() {
        let start = Date()
        var black = 0
        for _ in 0..<10 {
            let document = ZPLInterpreter().render(ShippingLabelTests.parcelLabel)
            for label in document.labels { black += SoftwareRasterizer.rasterize(label).blackPixelCount }
        }
        let perLabel = Date().timeIntervalSince(start) / 10
        print("Versandetikett: \(Int(perLabel * 1000)) ms je Durchlauf")
        #expect(black > 0)
        // Großzügige Grenze (Debug-Build, geteilte CI-Maschinen); typisch deutlich darunter.
        #expect(perLabel < 2.0)
    }
}
