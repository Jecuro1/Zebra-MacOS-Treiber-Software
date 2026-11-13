import AppKit
import Foundation
import UserNotifications
import LabelWerkKit

/// Systembenachrichtigungen bei Druckerfehlern (z. B. „Etiketten leer“, „Druckkopf offen“) und angehaltenen
/// Druckaufträgen.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Wird beim Klick auf eine Benachrichtigung mit der Drucker-ID aufgerufen.
    var onOpenPrinter: ((UUID) -> Void)?

    private var isAuthorized = false
    private var lastSent: [String: Date] = [:]

    /// UNUserNotificationCenter benötigt ein echtes App-Bundle (nicht bei `swift run`).
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func setUp() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in NotificationService.shared.isAuthorized = granted }
        }
    }

    func notify(printerName: String, alert: PrinterAlert, printerID: UUID) {
        guard isAvailable, isAuthorized else { return }
        // Gleiche Meldung höchstens alle 5 Minuten.
        let key = "\(printerID.uuidString)-\(alert.kind.rawValue)"
        if let last = lastSent[key], Date().timeIntervalSince(last) < 300 { return }
        lastSent[key] = Date()

        let content = UNMutableNotificationContent()
        content.title = tr("%@: %@", printerName, tr(alert.title))
        content.body = tr(alert.recovery)
        content.sound = alert.severity == .error ? .defaultCritical : .default
        content.userInfo = ["printerID": printerID.uuidString]
        content.threadIdentifier = printerID.uuidString
        let request = UNNotificationRequest(identifier: key + "-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Mitteilung zu einem laufenden Druckauftrag (z. B. „Druck angehalten – Papier leer …“, wenn
    /// LabelWerk im Hintergrund ist). Gleiche Meldung desselben Druckers höchstens jede Minute.
    func notifyPrintJob(title: String, body: String, printerID: UUID, key: String) {
        guard isAvailable, isAuthorized else { return }
        let fullKey = "\(printerID.uuidString)-\(key)"
        if let last = lastSent[fullKey], Date().timeIntervalSince(last) < 60 { return }
        lastSent[fullKey] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        content.userInfo = ["printerID": printerID.uuidString]
        content.threadIdentifier = printerID.uuidString
        let request = UNNotificationRequest(identifier: fullKey + "-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo["printerID"] as? String
        Task { @MainActor in
            if let idString, let id = UUID(uuidString: idString) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationService.shared.onOpenPrinter?(id)
            }
            completionHandler()
        }
    }
}

/// Dezente Systemklänge für Rückmeldungen.
enum SoundService {
    enum Sound { case printed, alert, success }

    @MainActor
    static func play(_ sound: Sound) {
        let name: String
        switch sound {
        case .printed: name = "Pop"
        case .alert: name = "Basso"
        case .success: name = "Glass"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
