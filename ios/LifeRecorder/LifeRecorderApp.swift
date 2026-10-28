import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == UploadManager.sessionID else { completionHandler(); return }
        UploadManager.shared.backgroundCompletion = completionHandler
        UploadManager.shared.activate()
    }
}

@main
struct LifeRecorderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder()
    @StateObject private var uploads = UploadManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var pairingError: String?

    var body: some Scene {
        WindowGroup {
            ContentView(recorder: recorder, uploads: uploads, showSettings: $showSettings)
                .task { uploads.activate(); recorder.refreshInputs(); await recorder.resumeIfEnabled() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        uploads.activate()
                        recorder.refreshInputs()
                        Task { await recorder.resumeIfEnabled() }
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "liferecorder", url.host == "pair",
                          let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                    let query = Dictionary(parts.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                                           uniquingKeysWith: { _, last in last })
                    do {
                        try ReceiverSettings.save(url: query["url"] ?? "", token: query["token"] ?? "",
                                                  pin: query["pin"] ?? "")
                        uploads.configurationChanged()
                        showSettings = true
                    } catch { pairingError = error.localizedDescription }
                }
                .alert("Could not pair", isPresented: Binding(get: { pairingError != nil },
                    set: { if !$0 { pairingError = nil } })) {
                        Button("OK") { pairingError = nil }
                    } message: { Text(pairingError ?? "") }
        }
    }
}

struct ContentView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var uploads: UploadManager
    @Binding var showSettings: Bool
    @State private var changing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Keep the context.").font(.system(size: 36, weight: .semibold, design: .rounded))
                        Text("Your phone records. Your server keeps the audio.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 20) {
                        Image(systemName: recorder.recording ? "waveform" : "mic")
                            .font(.system(size: 52)).foregroundStyle(recorder.recording ? .red : .secondary)
                            .frame(height: 70)
                        Text(recorder.status).font(.headline).multilineTextAlignment(.center)
                        Button {
                            changing = true
                            Task { await recorder.setEnabled(!recorder.enabled); changing = false }
                        } label: {
                            Label(LocalizedStringKey(recorder.enabled ? "Switch recorder off" : "Switch recorder on"),
                                  systemImage: recorder.enabled ? "stop.fill" : "mic.fill")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent).tint(recorder.enabled ? .red : .indigo)
                        .disabled(changing).accessibilityIdentifier("recorderToggle")
                    }
                    .padding(24).frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 28))
                    InputSection(recorder: recorder)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("\(uploads.pendingCount) clips waiting to upload", systemImage: "tray")
                        Text(uploads.status).foregroundStyle(.secondary)
                        if let date = uploads.lastUploadedAt {
                            Text("Last upload: \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if recorder.incompleteClips > 0 {
                            Text("\(recorder.incompleteClips) interrupted clips need recovery. They remain on this phone.")
                                .foregroundStyle(.orange)
                        }
                        DisclosureGroup("Recent upload events") {
                            VStack(alignment: .leading, spacing: 4) {
                                if uploads.events.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
                                ForEach(Array(uploads.events.enumerated()), id: \.offset) { _, event in
                                    Text(event).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    StorageSection(uploads: uploads)
                    Text("Records with the screen locked. After restarting the phone or force-quitting, open this app once to resume. Switching off stays off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .navigationTitle("Life Recorder").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Pair server", systemImage: "server.rack") { showSettings = true } }
            .sheet(isPresented: $showSettings) { PairingView(uploads: uploads) }
        }
    }
}

/// Shows which microphone is really in use, so a fallback to the iPhone mic is never silent.
struct InputSection: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(recorder.currentInput.map { String(localized: "Input: \($0.label)") } ?? String(localized: "Input: none"),
                  systemImage: recorder.currentInput?.isExternal == true ? "mic.fill" : "iphone")
                .font(.headline)
            if let warning = recorder.microphoneWarning {
                Text(warning).font(.headline).foregroundStyle(.red)
            } else if recorder.recording && recorder.currentInput?.isExternal != true {
                Text("Recording from the iPhone's own microphone, not an external mic.")
                    .foregroundStyle(.orange)
            }
            if recorder.waitingForExternal && recorder.microphoneWarning == nil {
                Text("Waiting for an external microphone. Nothing is being recorded. If the screen is locked, reopen the app after reconnecting.")
                    .foregroundStyle(.red)
            }
            if recorder.preferredInputID == nil && recorder.availableInputs.filter(\.isBluetooth).count > 1 {
                Text("Several Bluetooth devices are connected. Choose your microphone below so recording never switches to another device.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Picker("Microphone", selection: Binding(get: { recorder.preferredInputID ?? "" },
                                                    set: { id in Task { await recorder.setPreferredInput(id.isEmpty ? nil : id) } })) {
                Text("Automatic (external first)").tag("")
                ForEach(recorder.availableInputs) { Text($0.label).tag($0.id) }
                if let saved = recorder.preferredInputID, !recorder.availableInputs.contains(where: { $0.id == saved }) {
                    Text("Saved microphone (not connected)").tag(saved)
                }
            }
            Toggle("Only record from the chosen external microphone", isOn: Binding(get: { recorder.requireExternalInput },
                                                                         set: { value in Task { await recorder.setRequireExternalInput(value) } }))
            DisclosureGroup("Recent audio events") {
                VStack(alignment: .leading, spacing: 4) {
                    if recorder.events.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
                    ForEach(Array(recorder.events.enumerated()), id: \.offset) { _, event in
                        Text(event).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Says where recordings live, so the phone copy can be found and its lifetime is clear.
struct StorageSection: View {
    @ObservedObject var uploads: UploadManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Where recordings are saved", systemImage: "folder").font(.headline)
            Text("On this iPhone: Files › On My iPhone › Life Recorder › Recordings")
            Text("\(uploads.pendingCount) clips, \(uploads.storedBytes.formatted(.byteCount(style: .file))) on this iPhone")
                .foregroundStyle(.secondary)
            if let receiver = UserDefaults.standard.string(forKey: "receiverURL") {
                Text("Uploads to: \(receiver)").foregroundStyle(.secondary).textSelection(.enabled)
                Text("After the server confirms a clip is saved, the copy on this iPhone is deleted.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("No server paired. Recordings stay on this iPhone.").foregroundStyle(.secondary)
            }
            Button("Open in Files", systemImage: "arrow.up.forward.app") {
                // shareddocuments:// opens the Files app at a path inside this app's Documents.
                if let url = URL(string: "shareddocuments://" + QueueStore.directory.path) { openURL(url) }
            }
        }
    }
}

struct PairingView: View {
    @ObservedObject var uploads: UploadManager
    @Environment(\.dismiss) private var dismiss
    @State private var address = UserDefaults.standard.string(forKey: "receiverURL") ?? ""
    @State private var token = Credentials.token()
    @State private var pin = UserDefaults.standard.string(forKey: "certificateSHA256") ?? ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Your receiver") {
                    TextField("https://your-server:8765", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Pairing token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Certificate fingerprint", text: $pin, axis: .vertical)
                        .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("Uploads use Wi-Fi or cellular. When the receiver is unreachable, audio stays here until it can be uploaded.")
                    Text("Use the pairing link generated by your receiver to fill these fields, or enter them by hand. The receiver must be reachable over HTTPS.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Pair your receiver")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try ReceiverSettings.save(url: address, token: token, pin: pin)
                            uploads.configurationChanged()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
