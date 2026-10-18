import Foundation
import UserNotifications
import StreamProtocol

/// A macOS notification for a device that joins or leaves the Mac's trust list: the moment it
/// happens, rather than a row someone finds in Settings weeks later. This is the detection half of
/// pairing hardening — the crypto makes pairing expensive, this makes it visible.
///
/// Authorization is asked for once at launch. If it is denied (or notifications are off for Sill),
/// nothing is lost: the host still prints an `AUDIT:` line for every pairing and removal, and the
/// app's log window shows it. A device paired over the USB cable is skipped here because the app
/// already raises its own cable notice window for that one.
@MainActor
final class PairingNotifier {
    static let shared = PairingNotifier()
    private var asked = false

    /// Ask once, at launch, where the prompt belongs; `post` then needs no callback.
    func requestPermission() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func paired(name: String, method: String) {
        guard method != PairResult.cable else { return }
        post(title: "New device paired", body: "\(name) paired \(Self.words(for: method)).")
    }

    func removed(name: String) {
        post(title: "Device removed", body: "\(name) can no longer connect to this Mac.")
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func words(for method: String) -> String {
        switch method {
        case PairRequest.qr: return "with the QR code"
        case PairResult.cable: return "over the USB cable"
        default: return "with the 12-digit code"
        }
    }
}
