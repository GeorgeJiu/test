import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "recorderEnabled")
    @Published private(set) var recording = false
    @Published private(set) var status = "Recorder is off"
    @Published private(set) var incompleteClips = 0
    private var engine: AVAudioEngine?
    private var writer: ChunkWriter?
    private var starting = false
    private var stopping = false
    private var recovered = false
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []

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
                    await self.stopCapture()
                    await self.resumeIfEnabled(allowBackground: true)
                }
            })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      [.oldDeviceUnavailable, .newDeviceAvailable].contains(reason) else { return }
                Task { @MainActor in
                    guard let self, self.recording else { return }
                    await self.stopCapture()
                    await self.resumeIfEnabled(allowBackground: true)
                }
            })
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        UserDefaults.standard.set(value, forKey: "recorderEnabled")
        if value { await resumeIfEnabled() }
        else {
            await stopCapture()
            status = "Recorder is off"
        }
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
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try audioSession.setActive(true)
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
                    await self.stopCapture()
                    self.status = message
                }
            })
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in nextWriter.consume(buffer) }
            nextEngine.prepare()
            try nextEngine.start()
            engine = nextEngine
            writer = nextWriter
            recording = true
            status = "Recording, including when locked"
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            status = "Could not start: " + error.localizedDescription
        }
    }

    private func stopCapture(deactivate: Bool = true) async {
        guard !stopping else { return }
        stopping = true
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish audio chunk")
        defer {
            stopping = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
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
            await stopCapture(deactivate: false)
            if enabled { status = "Interrupted by another audio session" }
        } else {
            interrupted = false
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                await resumeIfEnabled(allowBackground: true)
            } else if enabled { status = "Recording paused. Reopen the app to resume." }
        }
    }
}
