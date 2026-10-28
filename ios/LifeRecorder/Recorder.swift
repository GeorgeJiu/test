import AVFoundation
import Combine
import Foundation
import os
import UIKit

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

    var kind: String {
        switch type {
        case .bluetoothHFP: return "Bluetooth"
        case .usbAudio: return "USB"
        case .headsetMic: return "Headset"
        case .builtInMic: return "iPhone"
        case .carAudio: return "Car"
        default: return type.rawValue
        }
    }

    var label: String { "\(name) (\(kind))" }

    /// Automatic choice prefers a Bluetooth mic (e.g. a DJI transmitter connected directly),
    /// then a wired/USB receiver, and the built-in microphone last.
    private var rank: Int {
        switch type {
        case .bluetoothHFP: return 0
        case .usbAudio: return 1
        case .headsetMic: return 2
        case .builtInMic: return 9
        default: return 5
        }
    }

    /// The saved choice when it is connected, otherwise the best-ranked input.
    static func choose(from inputs: [AudioInput], preferredID: String?) -> AudioInput? {
        if let preferredID, let saved = inputs.first(where: { $0.id == preferredID }) { return saved }
        return inputs.min { $0.rank < $1.rank }
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "recorderEnabled")
    @Published private(set) var recording = false
    @Published private(set) var status = "Recorder is off"
    @Published private(set) var incompleteClips = 0
    @Published private(set) var currentInput: AudioInput?
    @Published private(set) var availableInputs: [AudioInput] = []
    @Published private(set) var preferredInputID = UserDefaults.standard.string(forKey: "preferredInputID")
    @Published private(set) var requireExternalInput = UserDefaults.standard.bool(forKey: "requireExternalInput")
    @Published private(set) var waitingForExternal = false
    @Published private(set) var events: [String] = []
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var writer: ChunkWriter?
    private var starting = false
    private var stopping = false
    private var recovered = false
    private var interrupted = false
    private var lastStart = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LifeRecorder", category: "recorder")

    init() {
        if enabled { status = "Ready to resume" }
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
        if value { await resumeIfEnabled() }
        else {
            await stopCapture()
            waitingForExternal = false
            status = "Recorder is off"
        }
    }

    /// nil selects automatically (external microphones first).
    func setPreferredInput(_ id: String?) async {
        preferredInputID = id
        UserDefaults.standard.set(id, forKey: "preferredInputID")
        note("Preferred input: " + (id.flatMap { id in availableInputs.first { $0.id == id }?.label } ?? "automatic"))
        await restartIfActive()
    }

    func setRequireExternalInput(_ value: Bool) async {
        requireExternalInput = value
        UserDefaults.standard.set(value, forKey: "requireExternalInput")
        note(value ? "External microphone required" : "iPhone microphone allowed as fallback")
        await restartIfActive()
    }

    /// Reads the current route and the microphones iOS offers for this category.
    func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord { try? Self.configure(session) }
        availableInputs = (session.availableInputs ?? []).map(AudioInput.init)
        currentInput = session.currentRoute.inputs.first.map(AudioInput.init)
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
            guard granted else { status = "Allow microphone access in Settings to record"; return }
        } else if permission == .denied {
            status = "Allow microphone access in Settings to record"
            return
        }
        guard enabled else { return } // The switch may have changed during permission/recovery.
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try Self.configure(audioSession)
            try audioSession.setActive(true)
            selectInput(audioSession)
            refreshInputs()
            if requireExternalInput && currentInput?.isExternal != true {
                // Keep the session so a reconnect in the foreground can resume; never fall back silently.
                waitingForExternal = true
                status = "No external microphone. Not recording."
                note("Holding: input is " + (currentInput?.label ?? "none"))
                return
            }
            waitingForExternal = false
            let nextEngine = AVAudioEngine()
            let input = nextEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                throw NSError(domain: "Recorder", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone is unavailable. Reopen the app to retry."])
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
            let source = currentInput?.label ?? "unknown input"
            note("Recording from \(source), \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
            status = currentInput?.isExternal == true ? "Recording, including when locked"
                : "Recording with the iPhone microphone"
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            note("Start failed: " + error.localizedDescription)
            status = "Could not start: " + error.localizedDescription
        }
    }

    private static func configure(_ session: AVAudioSession) throws {
        // .allowBluetooth (renamed .allowBluetoothHFP in iOS 26) is required for a Bluetooth mic to be an input.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
    }

    private func selectInput(_ session: AVAudioSession) {
        let inputs = (session.availableInputs ?? []).map(AudioInput.init)
        guard let choice = AudioInput.choose(from: inputs, preferredID: preferredInputID) else { return }
        do {
            // Leave the built-in mic unpinned so iOS can follow a microphone that connects later.
            let port = choice.isExternal ? session.availableInputs?.first(where: { $0.uid == choice.id }) : nil
            try session.setPreferredInput(port)
        } catch {
            note("Could not select \(choice.label): \(error.localizedDescription)")
        }
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
            if enabled { status = "Interrupted by another audio session" }
        } else {
            interrupted = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            note("Interruption ended" + (shouldResume ? "; resuming" : "; not allowed to resume"))
            if shouldResume {
                await resumeIfEnabled(allowBackground: true)
            } else if enabled { status = "Recording paused. Reopen the app to resume." }
        }
    }

    /// Keeps a short on-screen history for testing without a Mac, and mirrors it to the system log.
    private func note(_ message: String) {
        Self.log.notice("\(message, privacy: .public)")
        events.insert(Date().formatted(date: .omitted, time: .standard) + "  " + message, at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }
}
