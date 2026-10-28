import AVFoundation
import CryptoKit
import Foundation
import Security

struct Chunk: Codable {
    let id: UUID
    let startedAt: Date
    let duration: Double
    let sha256: String
    var name: String { id.uuidString.lowercased() }
    var audioURL: URL { QueueStore.directory.appendingPathComponent(name + ".m4a") }
    var manifestURL: URL { QueueStore.directory.appendingPathComponent(name + ".json") }
}

struct RecordingJournal: Codable {
    let id: UUID
    let startedAt: Date
}

enum QueueStore {
    /// Documents/Recordings, visible in the Files app under On My iPhone › Life Recorder.
    static let directory: URL = {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Recordings", isDirectory: true)
        try! fileManager.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excludedURL = url
        try? excludedURL.setResourceValues(values)
        // Earlier builds queued audio in Application Support, which the Files app cannot show.
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("PendingAudio", isDirectory: true)
        if let files = try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
            for file in files { try? fileManager.moveItem(at: file, to: url.appendingPathComponent(file.lastPathComponent)) }
            if (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
                try? fileManager.removeItem(at: legacy)
            }
        }
        return url
    }()

    /// Clips the server has acknowledged, kept when "Keep a copy on this iPhone" is on.
    static var uploadedDirectory: URL { directory.appendingPathComponent("Uploaded", isDirectory: true) }

    static var keepsUploadedCopies: Bool {
        get { UserDefaults.standard.object(forKey: "keepUploadedCopies") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepUploadedCopies") }
    }

    /// Below this much free space, the oldest uploaded copies are deleted so recording can continue.
    static let minimumFreeBytes: Int64 = 1_000_000_000

    /// Total size of the audio currently kept on this phone.
    static func storedAudioBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "m4a" }
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static var deviceID: String {
        if let value = UserDefaults.standard.string(forKey: "deviceID") { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "deviceID")
        return value
    }

    static func pending() -> [Chunk] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".recording.") }
            .compactMap { try? JSONDecoder().decode(Chunk.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ journal: RecordingJournal, duration: Double) throws -> Chunk {
        let name = journal.id.uuidString.lowercased()
        let audio = directory.appendingPathComponent(name + ".m4a")
        let chunk = Chunk(id: journal.id, startedAt: journal.startedAt, duration: duration,
                          sha256: try checksum(audio))
        try JSONEncoder().encode(chunk).write(to: chunk.manifestURL, options: .atomic)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".recording.json"))
        return chunk
    }

    static func recoverInterruptedFiles() async -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var unrecoverable = 0
        for file in files where file.lastPathComponent.hasSuffix(".recording.json") {
            do {
                let journal = try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: file))
                let audio = directory.appendingPathComponent(journal.id.uuidString.lowercased() + ".m4a")
                let duration = try await AVURLAsset(url: audio).load(.duration).seconds
                guard duration.isFinite && duration > 0 else { unrecoverable += 1; continue }
                _ = try seal(journal, duration: duration)
            } catch {
                // Keep an incomplete file for recovery; never pretend it was uploaded.
                unrecoverable += 1
            }
        }
        // Removal of an acknowledged manifest is the local commit point. Finish cleanup after a crash.
        for audio in files where audio.pathExtension == "m4a" {
            let stem = audio.deletingPathExtension().lastPathComponent
            // The folder is visible in the Files app; only clean up clips this app named.
            guard UUID(uuidString: stem) != nil else { continue }
            // Archiving moves the manifest first; finish moving its audio after a crash.
            if FileManager.default.fileExists(atPath: uploadedDirectory.appendingPathComponent(stem + ".json").path) {
                try? FileManager.default.moveItem(at: audio, to: uploadedDirectory.appendingPathComponent(audio.lastPathComponent))
                continue
            }
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + ".json").path)
                && !FileManager.default.fileExists(atPath: directory.appendingPathComponent(stem + ".recording.json").path) {
                try? FileManager.default.removeItem(at: audio)
            }
        }
        return unrecoverable
    }

    /// Keeps an acknowledged clip in Uploaded/. Moving the manifest out of the queue is the commit point.
    static func archiveAcknowledged(_ chunk: Chunk) throws {
        try FileManager.default.createDirectory(at: uploadedDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: chunk.manifestURL,
                                         to: uploadedDirectory.appendingPathComponent(chunk.manifestURL.lastPathComponent))
        if FileManager.default.fileExists(atPath: chunk.audioURL.path) {
            try FileManager.default.moveItem(at: chunk.audioURL,
                                             to: uploadedDirectory.appendingPathComponent(chunk.audioURL.lastPathComponent))
        }
    }

    /// Count and size of the uploaded copies kept on this phone.
    static func uploadedCopies() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: uploadedDirectory,
            includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let audio = files.filter { $0.pathExtension == "m4a" }
        return (audio.count, audio.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
    }

    /// Deletes the oldest uploaded copies while free space is low. Never touches clips still waiting to upload.
    @discardableResult
    static func pruneUploadedCopies() -> Int {
        func freeBytes() -> Int64 {
            (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? .max
        }
        guard freeBytes() < minimumFreeBytes else { return 0 }
        let manifests = ((try? FileManager.default.contentsOfDirectory(at: uploadedDirectory,
            includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        let oldestFirst = manifests.compactMap { url -> (URL, Date)? in
            guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(contentsOf: url)) else { return nil }
            return (url, chunk.startedAt)
        }.sorted { $0.1 < $1.1 }
        var removed = 0
        for (manifest, _) in oldestFirst {
            guard freeBytes() < minimumFreeBytes else { break }
            try? FileManager.default.removeItem(at: manifest.deletingPathExtension().appendingPathExtension("m4a"))
            try? FileManager.default.removeItem(at: manifest)
            removed += 1
        }
        return removed
    }

    static func removeAcknowledged(_ chunk: Chunk) throws {
        // Only called after a verified durable receipt. Commit dequeue before deleting its audio.
        try FileManager.default.removeItem(at: chunk.manifestURL)
        if FileManager.default.fileExists(atPath: chunk.audioURL.path) {
            try FileManager.default.removeItem(at: chunk.audioURL)
        }
    }
}

/// A bookmark on the recording timeline, created with "Mark this moment".
struct Marker: Codable, Identifiable {
    let id: UUID
    let at: Date
    var note: String
    var uploaded: Bool
    var name: String { id.uuidString.lowercased() }
}

enum MarkerStore {
    /// Documents/Markers, one small JSON file per marker.
    static let directory: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("Markers", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }()

    /// Request bodies for background uploads, which must come from files.
    private static let uploadDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("MarkerUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func all() -> [Marker] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Marker.self, from: Data(contentsOf: $0)) }
            .sorted { $0.at > $1.at }
    }

    /// Oldest first, so markers upload in the order they were made.
    static func pending() -> [Marker] { Array(all().filter { !$0.uploaded }.reversed()) }

    @discardableResult
    static func add(note: String = "", at date: Date = Date()) throws -> Marker {
        let marker = Marker(id: UUID(), at: date, note: note, uploaded: false)
        try save(marker)
        return marker
    }

    static func markUploaded(_ marker: Marker) throws {
        var done = marker
        done.uploaded = true
        try save(done)
        try? FileManager.default.removeItem(at: uploadDirectory.appendingPathComponent(marker.name + ".json"))
    }

    /// Writes the JSON the receiver expects and returns its file for an upload task.
    static func uploadBody(_ marker: Marker, timestamp: String) throws -> URL {
        let url = uploadDirectory.appendingPathComponent(marker.name + ".json")
        try JSONSerialization.data(withJSONObject: ["at": timestamp, "note": marker.note]).write(to: url, options: .atomic)
        return url
    }

    private static func save(_ marker: Marker) throws {
        try JSONEncoder().encode(marker).write(to: directory.appendingPathComponent(marker.name + ".json"),
                                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum Credentials {
    private static let service = "com.browseruse.liferecorder.receiver"
    static func token() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func setToken(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        let changes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct ReceiverSettings {
    let baseURL: URL
    let token: String
    let certificateSHA256: String

    static func load() -> ReceiverSettings? {
        guard let raw = UserDefaults.standard.string(forKey: "receiverURL"),
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let token = Credentials.token()
        guard !token.isEmpty else { return nil }
        return ReceiverSettings(baseURL: url, token: token,
            certificateSHA256: UserDefaults.standard.string(forKey: "certificateSHA256") ?? "")
    }

    static func save(url: String, token: String, pin: String) throws {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.scheme == "https", parsed.host != nil, parsed.user == nil, parsed.password == nil,
              parsed.query == nil, parsed.fragment == nil,
              parsed.path.isEmpty || parsed.path == "/", !token.isEmpty else {
            throw NSError(domain: "Settings", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Enter an HTTPS receiver address and its pairing token.")])
        }
        let cleanPin = pin.lowercased().replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPin.isEmpty || (cleanPin.count == 64 && cleanPin.allSatisfy { $0.isHexDigit }) else {
            throw NSError(domain: "Settings", code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "The certificate fingerprint must contain 64 hexadecimal characters.")])
        }
        try Credentials.setToken(token)
        UserDefaults.standard.set(parsed.absoluteString, forKey: "receiverURL")
        UserDefaults.standard.set(cleanPin, forKey: "certificateSHA256")
    }
}
