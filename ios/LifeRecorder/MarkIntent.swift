import AppIntents
import Foundation

/// Adds a marker without unlocking or opening the app: from the Action Button, a Lock Screen or
/// Control Center shortcut, Back Tap, the Shortcuts app, or Siri.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark this moment"
    static var description = IntentDescription("Bookmarks the current moment of the recording and uploads it to your receiver.")
    static var openAppWhenRun = false
    // Marker files and the upload token stay readable after the first unlock, so a locked phone can mark.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let marker = UploadManager.shared.addMarker() else { throw MarkMomentError.saveFailed }
        let time = marker.at.formatted(date: .omitted, time: .standard)
        if UserDefaults.standard.bool(forKey: "recorderEnabled") {
            return .result(dialog: "Marked at \(time)")
        }
        return .result(dialog: "Marked at \(time). The recorder is off, so no audio covers this moment.")
    }
}

enum MarkMomentError: Error, CustomLocalizedStringResourceConvertible {
    case saveFailed

    var localizedStringResource: LocalizedStringResource { "Could not save the marker." }
}

struct LifeRecorderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark this moment in \(.applicationName)", "\(.applicationName) mark this moment"],
                    shortTitle: "Mark this moment",
                    systemImageName: "bookmark.fill")
    }
}
