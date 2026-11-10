import Foundation
import LabelWerkKit

/// Geräteoperationen des Dialogs „Druckeinstellungen“ (Wartung, „Vom Drucker lesen“, Testseite).
/// Nutzt ausschließlich die interne Schnittstelle von `PrinterSession` (`withClient`), damit Fehler
/// wie bei allen anderen Operationen abgefangen und als Hinweis angezeigt werden.
extension PrinterSession {
    /// Liest die Druckeinstellungen des Druckers (SGD, `PrinterClient.readPrintSettings`) und trägt
    /// die gemeldeten Werte in `base` ein. `nil` ohne Rückkanal, ohne Verbindung oder bei einem Fehler
    /// (der Hinweis wird – außer mit `quiet` – angezeigt).
    func readPrintSettings(into base: PrintSettings, quiet: Bool = false) async -> PrintSettings? {
        guard supportsStatus else {
            if !quiet {
                app?.toast(tr("Werte können nicht gelesen werden"),
                           message: tr("Diese Verbindung kann keine Werte lesen (nur Senden)."), style: .warning)
            }
            return nil
        }
        return await withClient(tr("Druckeinstellungen werden gelesen …"), quiet: quiet) { client in
            try await client.readPrintSettings(into: base)
        }
    }

    /// „Echtzeituhr (RTC) synchronisieren“: stellt die Uhr des Druckers auf die Ortszeit des Mac
    /// (ZPL `^ST`, EPL/CPCL SGD `rtc.date`/`rtc.time`).
    @discardableResult
    func syncClock() async -> Bool {
        let now = Date()
        let ok = await withClient(tr("Echtzeituhr wird synchronisiert …")) { client in
            try await client.syncClock(now: now, timeZone: .current)
        } != nil
        app?.record(JobRecord(printerID: id, printerName: displayName, title: tr("Echtzeituhr synchronisiert"),
                              kind: .action, labels: 0, bytes: 0, success: ok, message: ok ? nil : lastError))
        if ok {
            app?.toast(tr("Echtzeituhr synchronisiert"),
                       message: now.formatted(date: .abbreviated, time: .standard), style: .success)
        }
        return ok
    }

    /// „Testseite drucken“: rastert das LabelWerk-Testetikett in der Größe `widthMM` × `heightMM` und
    /// druckt es mit `settings` wie ein Programm über den Treiber – also mit Drehung, Spiegeln, Invers,
    /// Rasterung, eigenen Befehlen und „Aufträge vor dem Drucken abbrechen“ (inklusive Wartezeit).
    @discardableResult
    func printTestPage(settings: PrintSettings, widthMM: Double, heightMM: Double) async -> Bool {
        let resolution = self.resolution
        var width = max(64, resolution.dots(fromMM: widthMM))
        var height = max(64, resolution.dots(fromMM: heightMM))
        if let maxWidth = model?.printWidthDots(resolution), maxWidth > 0 { width = min(width, maxWidth) }
        // Bei 90°/270° liegt die Seite quer im Etikett; der Treiber dreht sie beim Kodieren zurück.
        if settings.clamped().effectiveRotation.isQuarterTurn { swap(&width, &height) }
        let pageWidth = width
        let pageHeight = height
        let subtitle = tr("Testseite – Druckeinstellungen")
        let image = await Task.detached(priority: .userInitiated) { () -> GrayImage? in
            let zpl = TestLabel.zpl(widthDots: pageWidth, heightDots: pageHeight, resolution: resolution,
                                    title: "LabelWerk", subtitle: subtitle)
            let interpreter = ZPLInterpreter(dotsPerMM: resolution.dotsPerMM, defaultWidthDots: pageWidth,
                                             defaultHeightDots: pageHeight)
            guard let label = interpreter.render(zpl).labels.first else { return nil }
            return SoftwareRasterizer.rasterize(label).toGrayImage()
        }.value
        guard let image, image.width > 0, image.height > 0 else {
            app?.toast(tr("Testseite konnte nicht erzeugt werden"), style: .error)
            return false
        }
        let title = tr("Testseite")
        let stock = self.stock
        let ok = await withClient(tr("Testseite wird gedruckt …")) { client in
            try await client.printImages([image], settings: settings, resolution: resolution, stock: stock, copies: 1)
        } != nil
        let preview = ok ? await Self.previewPNG(image: image) : nil
        app?.record(JobRecord(printerID: id, printerName: displayName, title: title, kind: .testLabel,
                              labels: ok ? 1 : 0, bytes: 0, success: ok, message: ok ? nil : lastError,
                              previewPNG: preview))
        if ok { app?.toast(tr("Testseite gedruckt"), message: displayName, style: .success) }
        return ok
    }
}
