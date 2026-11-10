import Foundation
import Testing
@testable import LabelWerkCore
@testable import LabelWerkImaging

@Suite("GrayImage")
struct GrayImageTests {
    /// 1 2 3
    /// 4 5 6
    let sample = GrayImage(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])

    @Test("Initialisierung und Pixelzugriff")
    func basics() {
        var image = GrayImage(width: 4, height: 3)
        #expect(image.pixels.count == 12)
        #expect(image.pixels.allSatisfy { $0 == 255 })
        image[2, 1] = 7
        #expect(image[2, 1] == 7)
        #expect(image.pixels[1 * 4 + 2] == 7)
        #expect(GrayImage(width: 2, height: 2, fill: 0).pixels == [0, 0, 0, 0])
        #expect(sample[0, 1] == 4)
        #expect(!sample.isEmpty)
        #expect(GrayImage(width: 0, height: 5).isEmpty)
    }

    @Test("Drehungen im Uhrzeigersinn")
    func rotations() {
        let r90 = sample.rotated(.r90)
        #expect(r90.width == 2 && r90.height == 3)
        #expect(r90.pixels == [4, 1, 5, 2, 6, 3])
        #expect(sample.rotated(.r180).pixels == [6, 5, 4, 3, 2, 1])
        let r270 = sample.rotated(.r270)
        #expect(r270.width == 2 && r270.height == 3)
        #expect(r270.pixels == [3, 6, 2, 5, 1, 4])
        #expect(sample.rotated(.r0) == sample)
        // Viermal 90° = Ausgangsbild; 90° + 270° = Ausgangsbild
        #expect(sample.rotated(.r90).rotated(.r90).rotated(.r90).rotated(.r90) == sample)
        #expect(sample.rotated(.r90).rotated(.r270) == sample)
        #expect(sample.rotated(.r90).rotated(.r90) == sample.rotated(.r180))
    }

    @Test("QuarterTurn-Hilfen")
    func quarterTurn() {
        #expect(QuarterTurn(degrees: 450) == .r90)
        #expect(QuarterTurn(degrees: -90) == .r270)
        #expect(QuarterTurn(degrees: 180) == .r180)
        #expect(QuarterTurn.r90.inverse == .r270)
        #expect(QuarterTurn.r0.inverse == .r0)
        #expect(QuarterTurn.r270.followed(by: .r180) == .r90)
        #expect(QuarterTurn.r90.swapsDimensions && !QuarterTurn.r180.swapsDimensions)
        #expect(QuarterTurn.allCases.map(\.rawValue) == [0, 90, 180, 270])
    }

    @Test("Spiegeln, vertikal spiegeln, invertieren")
    func mirrorInvert() {
        #expect(sample.mirrored().pixels == [3, 2, 1, 6, 5, 4])
        #expect(sample.flippedVertically().pixels == [4, 5, 6, 1, 2, 3])
        #expect(sample.inverted().pixels == [254, 253, 252, 251, 250, 249])
        #expect(sample.mirrored().mirrored() == sample)
        // gerade Breite
        let even = GrayImage(width: 4, height: 1, pixels: [1, 2, 3, 4])
        #expect(even.mirrored().pixels == [4, 3, 2, 1])
    }

    @Test("Verkleinern mit Flächenmittel")
    func scaleDownBox() {
        let image = GrayImage(width: 4, height: 2, pixels: [10, 20, 30, 40, 50, 60, 70, 80])
        let half = image.scaled(width: 2, height: 1)
        #expect(half.pixels == [35, 55])
        // Nicht-ganzzahliger Faktor 1,5: [0,1.5) → (0·1 + 90·0,5)/1,5 = 30; [1.5,3) → (90·0,5 + 180)/1,5 = 150
        let odd = GrayImage(width: 3, height: 1, pixels: [0, 90, 180]).scaled(width: 2, height: 1)
        #expect(odd.pixels == [30, 150])
        // Gleichförmige Fläche bleibt gleich
        let flat = GrayImage(width: 37, height: 23, fill: 77).scaled(width: 5, height: 3)
        #expect(flat.pixels.allSatisfy { $0 == 77 })
    }

    @Test("Vergrößern bilinear (pixelzentriert)")
    func scaleUpBilinear() {
        // Positionen: −0,25 → 0; 0,25; 0,75; 1,25 → 1 ⇒ 0, 25, 75, 100
        let image = GrayImage(width: 2, height: 1, pixels: [0, 100])
        #expect(image.scaled(width: 4, height: 1).pixels == [0, 25, 75, 100])
        // Gemischt: horizontal verkleinern, vertikal vergrößern
        let mixed = GrayImage(width: 4, height: 1, pixels: [0, 100, 200, 40]).scaled(width: 2, height: 3)
        #expect(mixed.pixels == [50, 120, 50, 120, 50, 120])
        // Identität und Grenzfälle
        #expect(sample.scaled(width: 3, height: 2) == sample)
        #expect(sample.scaled(width: 0, height: 4).isEmpty)
        #expect(GrayImage(width: 0, height: 0).scaled(width: 2, height: 2).pixels == [255, 255, 255, 255])
    }

    @Test("Seitenverhältnistreu einpassen")
    func scaleToFit() {
        let image = GrayImage(width: 4, height: 2, pixels: [10, 20, 30, 40, 50, 60, 70, 80])
        let fitted = image.scaledToFit(width: 2, height: 2, alignment: .top)
        #expect(fitted.width == 2 && fitted.height == 2)
        #expect(fitted.pixels == [35, 55, 255, 255])
        let centered = image.scaledToFit(width: 2, height: 3, alignment: .center)
        #expect(centered.pixels == [255, 255, 35, 55, 255, 255])
        let tall = GrayImage(width: 1, height: 4, fill: 0).scaledToFit(width: 6, height: 8, alignment: .leading)
        #expect(tall.width == 6 && tall.height == 8)
        #expect(tall[0, 0] == 0 && tall[1, 7] == 0 && tall[2, 0] == 255)
    }

    @Test("Ausschneiden (außerhalb weiß)")
    func crop() {
        #expect(sample.cropped(x: 1, y: 1, width: 2, height: 1).pixels == [5, 6])
        #expect(sample.cropped(x: -1, y: 0, width: 3, height: 1).pixels == [255, 1, 2])
        let beyond = sample.cropped(x: 2, y: 1, width: 3, height: 2)
        #expect(beyond.pixels == [6, 255, 255, 255, 255, 255])
        #expect(sample.cropped(x: 10, y: 10, width: 2, height: 2).pixels == [255, 255, 255, 255])
        #expect(sample.cropped(x: 0, y: 0, width: 0, height: 0).isEmpty)
    }

    @Test("Auffüllen mit Ausrichtung")
    func pad() {
        let centered = sample.padded(toWidth: 5, height: 4, alignment: .center, fill: 0)
        #expect(centered.pixels == [
            0, 0, 0, 0, 0,
            0, 1, 2, 3, 0,
            0, 4, 5, 6, 0,
            0, 0, 0, 0, 0,
        ])
        let corner = sample.padded(toWidth: 4, height: 3, alignment: .bottomTrailing)
        #expect(corner.pixels == [
            255, 255, 255, 255,
            255, 1, 2, 3,
            255, 4, 5, 6,
        ])
        #expect(sample.padded(toWidth: 3, height: 2) == sample)
        // Kleinere Fläche → mittiger Ausschnitt
        #expect(sample.padded(toWidth: 1, height: 1, alignment: .center).pixels == [5])
        #expect(sample.padded(toWidth: 2, height: 1, alignment: .topLeading).pixels == [1, 2])
    }

    @Test("Helligkeit, Kontrast, Gamma")
    func adjust() {
        let ramp = GrayImage(width: 256, height: 1, pixels: (0...255).map { UInt8($0) })
        #expect(ramp.adjusted() == ramp)
        #expect(ramp.adjusted(brightness: 1).pixels.allSatisfy { $0 == 255 })
        #expect(ramp.adjusted(brightness: -1).pixels.allSatisfy { $0 == 0 })
        // +0,2 Helligkeit = +51
        #expect(ramp.adjusted(brightness: 0.2)[100, 0] == 151)
        // Maximaler Kontrast = harte Schwelle in der Mitte
        let hard = ramp.adjusted(contrast: 1)
        #expect(hard[127, 0] == 0 && hard[128, 0] == 255)
        // Minimaler Kontrast = Mittelgrau
        #expect(ramp.adjusted(contrast: -1).pixels.allSatisfy { $0 == 128 })
        // Kontrast 0,25 → Faktor 4/3: (64 − 127,5)·4/3 + 127,5 = 42,83 → 43
        #expect(ramp.adjusted(contrast: 0.25)[64, 0] == 43)
        // Gamma 2: 64/255 = 0,25098 → √ = 0,50098 → 127,75 → 128
        #expect(ramp.adjusted(gamma: 2)[64, 0] == 128)
        // Monotonie bleibt erhalten
        let curve = ramp.adjusted(brightness: 0.1, contrast: 0.3, gamma: 1.4).pixels
        #expect(zip(curve, curve.dropFirst()).allSatisfy { $0 <= $1 })
        // Ungültige Werte werden ignoriert bzw. begrenzt
        #expect(ramp.adjusted(gamma: 0) == ramp.adjusted(gamma: 1))
        #expect(ramp.adjusted(brightness: .nan) == ramp)
    }

    @Test("Mittlere Helligkeit")
    func mean() {
        #expect(sample.meanLuminance == 3.5)
        #expect(GrayImage(width: 0, height: 0).meanLuminance == 255)
    }
}
