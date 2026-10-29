import AVFoundation
import Combine
import Foundation
import os
import UIKit
import UserNotifications

/// One microphone the audio session can record from.
struct AudioInput: Identifiable, Equatable {
    let id: String // AVAudioSessionPortDescription.uid
    let name: String
    let type: AVAudioSession.Port

    init(id: String, name: String, type: AVAudioSession.Port) {
        self.id = id
        self.name = name
        self.type = type
    }

    init(_ port: AVAudioSessionPortDescription) {
        self.init(id: port.uid, name: port.portName, type: port.portType)
    }

    var isExternal: Bool { type != .builtInMic }
    var isBluetooth: Bool { type == .bluetoothHFP }

    var kind: String {
        switch type {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return String(localized: "Bluetooth")
        case .usbAudio: return "USB"
        case .headsetMic: return String(localized: "Headset")
        case .builtInMic: return "iPhone"
        case .builtInSpeaker: return String(localized: "Speaker")
        case .builtInReceiver: return String(localized: "Receiver")
        case .headphones: return String(localized: "Headphones")
        case .carAudio: return String(localized: "Car")
        default: return type.rawValue
        }
    }

    var label: String { "\(name) (\(kind))" }

    /// Automatic choice prefers a DJI transmitter connected directly, then a wired/USB receiver, then the
    /// built-in microphone. Other Bluetooth devices (AirPods, headsets, phones) are only used when chosen by hand,
    /// so connecting headphones to listen never takes over the microphone.
    private var rank: Int {
        switch type {
        case .bluetoothHFP: return name.localizedCaseInsensitiveContains("DJI") ? 0 : 10
        case .usbAudio: return 1
        case .headsetMic: return 2
        case .builtInMic: return 9
        default: return 5
        }
    }

    /// A microphone that was chosen (by the user, or automatically when recording started) is never
    /// silently replaced by another external device: while it is missing, use the built-in mic.
    static func choose(from inputs: [AudioInput], preferredID: String?, sessionID: String?) -> AudioInput? {
        if let wanted = preferredID ?? sessionID {
            return inputs.first { $0.id == wanted } ?? inputs.first { $0.type == .builtInMic }
        }
        return inputs.min { $0.rank < $1.rank }
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "recorderEnabled")
    @Published private(set) var recording = false
    @Published private(set) var status = String(localized: "Recorder is off")
    @Published private(set) var incompleteClips = 0
    @Published private(set) var currentInput: AudioInput?
    @Published private(set) var availableInputs: [AudioInput] = []
    @Published private(set) var currentOutput: AudioInput?
    @Published private(set) var preferredInputID = UserDefaults.standard.string(forKey: "preferredInputID")
    @Published private(set) var requireExternalInput = UserDefaults.standard.bool(forKey: "requireExternalInput")
    @Published private(set) var waitingForExternal = false
    /// Set while the microphone recording started with is missing; shown in red and sent as a notification.
    @Published private(set) var microphoneWarning: String?
    @Published private(set) var events: [String] = []
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var writer: ChunkWriter?
    private var starting = false
    private var stopping = false
    private var recovered = false
    private var interrupted = false
    private var lastStart = Date.distantPast
    /// The external microphone this recording session started with.
    private var sessionInput: AudioInput?
    private var observers: [NSObjectProtocol] = []
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LifeRecorder", category: "recorder")

    init() {
        if enabled { status = String(localized: "Ready to resume") }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in await self?.handleInterruption(note) }
            })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.note("Media services were reset")
                    await self.stopCapture()
                    await self.resumeIfEnabled(allowBackground: true)
                }
            })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                    .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                Task { @MainActor in await self?.handleRouteChange(reason) }
            })
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        UserDefaults.standard.set(value, forKey: "recorderEnabled")
        if value {
            // Disconnect alerts must reach a locked phone.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            await resumeIfEnabled()
        } else {
            await stopCapture()
            waitingForExternal = false
            sessionInput = nil
            microphoneWarning = nil
            try? Self.configure(AVAudioSession.sharedInstance()) // Show Bluetooth mics again in the list.
            refreshInputs()
            status = String(localized: "Recorder is off")
        }
    }

    /// nil selects automatically (external microphones first).
    func setPreferredInput(_ id: String?) async {
        preferredInputID = id
        UserDefaults.standard.set(id, forKey: "preferredInputID")
        sessionInput = nil
        microphoneWarning = nil
        note("Preferred input: " + (id.flatMap { id in availableInputs.first { $0.id == id }?.label } ?? "automatic"))
        await restartIfActive()
    }

    func setRequireExternalInput(_ value: Bool) async {
        requireExternalInput = value
        UserDefaults.standard.set(value, forKey: "requireExternalInput")
        note(value ? "External microphone required" : "iPhone microphone allowed as fallback")
        await restartIfActive()
    }

    /// Bluetooth mics are only visible while Bluetooth input is enabled; this checks for them again,
    /// e.g. after turning on a DJI transmitter while recording with the iPhone microphone.
    func rescanInputs() async {
        note("Rescanning microphones")
        if recording || waitingForExternal {
            await restartIfActive()
        } else {
            try? Self.configure(AVAudioSession.sharedInstance())
            refreshInputs()
        }
    }

    /// Reads the current route and the microphones iOS offers for this category.
    func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord { try? Self.configure(session) }
        let inputs = (session.availableInputs ?? []).map(AudioInput.init)
        if session.categoryOptions.contains(.allowBluetoothHFP) {
            availableInputs = inputs
        } else {
            // Bluetooth mics are hidden while Bluetooth is output-only; keep listing the ones seen last time.
            availableInputs = inputs + availableInputs.filter { $0.isBluetooth && !inputs.contains($0) }
        }
        currentInput = session.currentRoute.inputs.first.map(AudioInput.init)
        currentOutput = session.currentRoute.outputs.first.map(AudioInput.init)
    }

    func resumeIfEnabled(allowBackground: Bool = false) async {
        guard enabled, !recording, !starting, !stopping, !interrupted else { return }
        // Background upload completion must never start a new microphone session.
        guard allowBackground || UIApplication.shared.applicationState == .active else { return }
        starting = true
        defer { starting = false }
        if !recovered {
            incompleteClips = await QueueStore.recoverInterruptedFiles()
            recovered = true
        }
        let permission = AVAudioApplication.shared.recordPermission
        if permission == .undetermined {
            guard UIApplication.shared.applicationState == .active else { return }
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { status = String(localized: "Allow microphone access in Settings to record"); return }
        } else if permission == .denied {
            status = String(localized: "Allow microphone access in Settings to record")
            return
        }
        guard enabled else { return } // The switch may have changed during permission/recovery.
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try Self.configure(audioSession) // Bluetooth input on, so every microphone can be seen.
            try audioSession.setActive(true)
            if let pick = selectInput(audioSession), !pick.choice.isBluetooth, !pick.fallback {
                // No Bluetooth mic wanted: make Bluetooth output-only so AirPods play in high quality
                // and can never become the microphone. (While a chosen mic is missing, input stays
                // enabled so its reconnection is noticed.)
                try Self.configure(audioSession, bluetoothInput: false)
                selectInput(audioSession)
            }
            refreshInputs()
            updateMicrophoneWarning()
            if requireExternalInput && currentInput?.isExternal != true {
                // Keep the session so a reconnect in the foreground can resume; never fall back silently.
                waitingForExternal = true
                status = String(localized: "No external microphone. Not recording.")
                note("Holding: input is " + (currentInput?.label ?? "none"))
                return
            }
            waitingForExternal = false
            let nextEngine = AVAudioEngine()
            let input = nextEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                throw NSError(domain: "Recorder", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "The microphone is unavailable. Reopen the app to retry.")])
            }
            let nextWriter = ChunkWriter(onChunk: {
                DispatchQueue.main.async { UploadManager.shared.pump() }
            }, onError: { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.note("Writer error: " + message)
                    await self.stopCapture()
                    self.status = message
                }
            })
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in nextWriter.consume(buffer) }
            nextEngine.prepare()
            try nextEngine.start()
            // A format change (e.g. switching to a 16 kHz Bluetooth mic) stops the engine without a route-change
            // reason we restart for; without this the app would show "Recording" while capturing nothing.
            engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: nextEngine, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.recording else { return }
                        self.note("Audio engine configuration changed")
                        await self.restartCapture()
                    }
                }
            engine = nextEngine
            writer = nextWriter
            recording = true
            lastStart = Date()
            if sessionInput == nil, let current = currentInput, current.isExternal { sessionInput = current }
            let source = currentInput?.label ?? "unknown input"
            note("Recording from \(source), \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
            status = currentInput?.isExternal == true ? String(localized: "Recording, including when locked")
                : String(localized: "Recording with the iPhone microphone")
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            note("Start failed: " + error.localizedDescription)
            status = String(localized: "Could not start: \(error.localizedDescription)")
        }
    }

    /// HFP is required for a Bluetooth mic, but iOS then also sends all output to that same device.
    /// Without it, Bluetooth headphones are used through A2DP for output only.
    private static func configure(_ session: AVAudioSession, bluetoothInput: Bool = true) throws {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        if bluetoothInput { options.insert(.allowBluetoothHFP) }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
    }

    /// Pins the microphone to use. `fallback` is true when the wanted microphone is missing.
    @discardableResult
    private func selectInput(_ session: AVAudioSession) -> (choice: AudioInput, fallback: Bool)? {
        let inputs = (session.availableInputs ?? []).map(AudioInput.init)
        let wanted = preferredInputID ?? sessionInput?.id
        guard let choice = AudioInput.choose(from: inputs, preferredID: preferredInputID, sessionID: sessionInput?.id)
        else { return nil }
        do {
            // Pin even the built-in mic: otherwise iOS may switch to whichever Bluetooth device it likes.
            // A reconnecting microphone is picked up by the route-change handler instead.
            try session.setPreferredInput(session.availableInputs?.first(where: { $0.uid == choice.id }))
        } catch {
            note("Could not select \(choice.label): \(error.localizedDescription)")
        }
        return (choice, wanted != nil && choice.id != wanted)
    }

    /// Compares the live input with the session's microphone and alerts once per change.
    private func updateMicrophoneWarning() {
        guard let expected = sessionInput else { microphoneWarning = nil; return }
        if currentInput?.id == expected.id {
            guard microphoneWarning != nil else { return }
            microphoneWarning = nil
            note("\(expected.label) is back")
            Self.notify(title: String(localized: "Microphone reconnected"),
                        body: String(localized: "\(expected.name) reconnected. Recording with it again."))
            return
        }
        let message = requireExternalInput
            ? String(localized: "\(expected.name) disconnected. Recording is paused. Reconnect it, then open the app to resume.")
            : String(localized: "\(expected.name) disconnected. Recording with the iPhone microphone.")
        guard microphoneWarning != message else { return }
        microphoneWarning = message
        note("\(expected.label) missing; input is \(currentInput?.label ?? "none")")
        Self.notify(title: String(localized: "Microphone disconnected"), body: message)
    }

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content, trigger: nil))
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) async {
        let before = currentInput
        refreshInputs()
        guard let reason, [.oldDeviceUnavailable, .newDeviceAvailable].contains(reason) else { return }
        note("\(reason == .newDeviceAvailable ? "Device connected" : "Device disconnected"); input "
             + "\(before?.label ?? "none") -> \(currentInput?.label ?? "none")")
        // The engine's configuration-change observer may already have restarted capture for this change.
        guard Date().timeIntervalSince(lastStart) > 2 else { return }
        await restartIfActive()
    }

    private func restartIfActive() async {
        if recording { await restartCapture() }
        else if waitingForExternal { await resumeIfEnabled(allowBackground: true) }
        else { refreshInputs() }
    }

    private func restartCapture() async {
        // Keep the session active: capture is continuing, and iOS may refuse to reactivate it in the background.
        await stopCapture(deactivate: false)
        await resumeIfEnabled(allowBackground: true)
    }

    private func stopCapture(deactivate: Bool = true) async {
        guard !stopping else { return }
        stopping = true
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish audio chunk")
        defer {
            stopping = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        recording = false
        let previous = writer
        writer = nil
        await previous?.finish()
        if deactivate { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        UploadManager.shared.pump()
    }

    private func handleInterruption(_ notification: Notification) async {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            interrupted = true
            note("Interruption began")
            await stopCapture(deactivate: false)
            if enabled { status = String(localized: "Interrupted by another audio session") }
        } else {
            interrupted = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            note("Interruption ended" + (shouldResume ? "; resuming" : "; not allowed to resume"))
            if shouldResume {
                await resumeIfEnabled(allowBackground: true)
            } else if enabled { status = String(localized: "Recording paused. Reopen the app to resume.") }
        }
    }

    /// Keeps a short on-screen history for testing without a Mac, and mirrors it to the system log.
    private func note(_ message: String) {
        Self.log.notice("\(message, privacy: .public)")
        events.insert(Date().formatted(date: .omitted, time: .standard) + "  " + message, at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }
}
