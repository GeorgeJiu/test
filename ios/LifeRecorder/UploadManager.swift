import Combine
import CryptoKit
import Foundation
import os
import Security
import UIKit

final class UploadManager: NSObject, ObservableObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    static let shared = UploadManager()
    static let sessionID = "com.browseruse.liferecorder.uploads"
    @Published private(set) var pendingCount = 0
    @Published private(set) var status = String(localized: "Pair with a receiver to upload")
    @Published private(set) var storedBytes: Int64 = 0
    @Published private(set) var lastUploadedAt: Date?
    @Published private(set) var events: [String] = []
    @Published private(set) var markers: [Marker] = []
    @Published private(set) var keepsUploadedCopies = QueueStore.keepsUploadedCopies
    @Published private(set) var uploadedCopyCount = 0
    @Published private(set) var uploadedCopyBytes: Int64 = 0
    private static let markerPrefix = "marker-"
    var backgroundCompletion: (() -> Void)?
    private var responseData: [Int: Data] = [:]
    private var retries: [String: Date] = [:]
    private var failureCounts: [String: Int] = [:]
    private var pumping = false
    private var authenticationRejected = false
    private var timer: Timer?
    private static let staleTaskInterval: TimeInterval = 15 * 60
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        // A connectivity-waiting task must not occupy one of the two upload
        // slots for days if the LAN route or hostname becomes stale.
        config.timeoutIntervalForResource = 30 * 60
        config.httpMaximumConnectionsPerHost = 2
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
    }

    func activate() {
        _ = session // Reattach transfers if iOS launched us to deliver an upload result.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.pump() }
        }
        pump()
    }

    func configurationChanged() {
        authenticationRejected = false
        retries.removeAll()
        failureCounts.removeAll()
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            DispatchQueue.main.async { self.pump() }
        }
    }

    func pump() {
        assert(Thread.isMainThread)
        let pending = QueueStore.pending()
        pendingCount = pending.count
        storedBytes = QueueStore.storedAudioBytes()
        let pruned = QueueStore.pruneUploadedCopies()
        if pruned > 0 { note("Low free space: removed \(pruned) oldest uploaded copies") }
        let copies = QueueStore.uploadedCopies()
        uploadedCopyCount = copies.count
        uploadedCopyBytes = copies.bytes
        markers = MarkerStore.all()
        guard let settings = ReceiverSettings.load() else { status = String(localized: "Pair with a receiver to upload"); return }
        guard !authenticationRejected else { return }
        guard !pumping else { return }
        pumping = true
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.pumping = false }
                let now = Date()
                var active = Set<String>()
                for task in tasks {
                    guard let id = Self.taskID(task.taskDescription) else {
                        task.cancel()
                        continue
                    }
                    if let started = Self.taskStart(task.taskDescription),
                       now.timeIntervalSince(started) > Self.staleTaskInterval {
                        // The delegate will retain this clip and schedule a
                        // bounded retry after the cancellation completes.
                        task.cancel()
                        continue
                    }
                    active.insert(id)
                }
                var available = max(0, 2 - active.count)
                // Markers are tiny; send them ahead of audio.
                for marker in MarkerStore.pending() where !active.contains(Self.markerPrefix + marker.name) {
                    guard available > 0 else { break }
                    let key = Self.markerPrefix + marker.name
                    if let retry = self.retries[key], retry > Date() { continue }
                    guard let body = try? MarkerStore.uploadBody(marker, timestamp: Self.timestamp(marker.at)) else { continue }
                    let url = settings.baseURL.appendingPathComponent("v1/markers").appendingPathComponent(marker.name)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization")
                    request.setValue(QueueStore.deviceID, forHTTPHeaderField: "X-Device-ID")
                    let task = self.session.uploadTask(with: request, fromFile: body)
                    task.taskDescription = Self.taskDescription(for: key)
                    task.resume()
                    self.note("Marker upload started: \(marker.name.prefix(8))")
                    available -= 1
                }
                for chunk in pending where !active.contains(chunk.name) {
                    guard available > 0 else { break }
                    if let retry = self.retries[chunk.name], retry > Date() { continue }
                    guard FileManager.default.fileExists(atPath: chunk.audioURL.path) else {
                        self.status = String(localized: "A pending audio file is missing; its record has been retained")
                        continue
                    }
                    let url = settings.baseURL.appendingPathComponent("v1/chunks").appendingPathComponent(chunk.name)
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization")
                    request.setValue(chunk.sha256, forHTTPHeaderField: "X-Audio-SHA256")
                    request.setValue(QueueStore.deviceID, forHTTPHeaderField: "X-Device-ID")
                    request.setValue(Self.timestamp(chunk.startedAt), forHTTPHeaderField: "X-Started-At")
                    request.setValue(String(chunk.duration), forHTTPHeaderField: "X-Duration-Seconds")
                    let task = self.session.uploadTask(with: request, fromFile: chunk.audioURL)
                    task.taskDescription = Self.taskDescription(for: chunk.name)
                    task.countOfBytesClientExpectsToSend = (try? chunk.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init) ?? NSURLSessionTransferSizeUnknown
                    task.countOfBytesClientExpectsToReceive = 512
                    task.resume()
                    self.note("Upload started: \(chunk.name.prefix(8))")
                    available -= 1
                }
                if pending.isEmpty { self.status = String(localized: "All completed audio uploaded") }
                else if active.isEmpty && available == 2 { /* Keep the latest actionable error. */ }
                else { self.status = String(localized: "Uploading when connected") }
            }
        }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LifeRecorder", category: "upload")

    /// Short on-screen history so upload failures can be diagnosed on the phone.
    private func note(_ message: String) {
        Self.log.notice("\(message, privacy: .public)")
        events.insert(Date().formatted(date: .omitted, time: .standard) + "  " + message, at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }

    private static func describe(_ error: Error?, _ response: HTTPURLResponse?, _ data: Data) -> String {
        if let error = error as NSError? { return "\(error.domain) \(error.code): \(error.localizedDescription)" }
        guard let response else { return "no response" }
        let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
        return "HTTP \(response.statusCode) \(body)"
    }

    func setKeepsUploadedCopies(_ value: Bool) {
        QueueStore.keepsUploadedCopies = value
        keepsUploadedCopies = value
        note(value ? "Uploaded copies will be kept" : "Uploaded copies will be deleted")
    }

    /// Bookmarks this moment and queues it for upload.
    @discardableResult
    func addMarker() -> Marker? {
        do {
            let marker = try MarkerStore.add()
            note("Marked \(marker.at.formatted(date: .omitted, time: .standard))")
            pump()
            return marker
        } catch {
            note("Could not save marker: \(error.localizedDescription)")
            return nil
        }
    }

    private func markerFinished(key: String, error: Error?, response: HTTPURLResponse?, data: Data) {
        let name = String(key.dropFirst(Self.markerPrefix.count))
        guard let marker = MarkerStore.pending().first(where: { $0.name == name }) else { return }
        struct Receipt: Decodable { let id: String; let durable: Bool }
        if error == nil, let response, [200, 201].contains(response.statusCode),
           let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.durable, receipt.id == name {
            do {
                try MarkerStore.markUploaded(marker)
                retries.removeValue(forKey: key)
                failureCounts.removeValue(forKey: key)
                note("Marker uploaded: \(name.prefix(8))")
            } catch { note("Marker uploaded; saving its state failed: \(error.localizedDescription)") }
        } else {
            note("Marker upload failed: \(name.prefix(8)): " + Self.describe(error, response, data))
            let failures = (failureCounts[key] ?? 0) + 1
            failureCounts[key] = failures
            retries[key] = Date().addingTimeInterval(min(1800, 15 * pow(2, Double(min(failures, 7)))))
            if response?.statusCode == 401 { authenticationRejected = true }
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func taskDescription(for id: String) -> String {
        "\(id)|\(Int(Date().timeIntervalSince1970))"
    }

    private static func taskID(_ description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        return String(description.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)[0])
    }

    private static func taskStart(_ description: String?) -> Date? {
        guard let description,
              let stamp = description.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first,
              let seconds = TimeInterval(stamp) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if (responseData[dataTask.taskIdentifier]?.count ?? 0) + data.count > 16384 {
            dataTask.cancel()
            return
        }
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        if let key = Self.taskID(task.taskDescription), key.hasPrefix(Self.markerPrefix) {
            markerFinished(key: key, error: error, response: task.response as? HTTPURLResponse, data: data)
            pump()
            return
        }
        guard let id = Self.taskID(task.taskDescription),
              let chunk = QueueStore.pending().first(where: { $0.name == id }) else { pump(); return }
        struct Receipt: Decodable { let id: String; let sha256: String; let durable: Bool }
        let response = task.response as? HTTPURLResponse
        if error == nil, let response, [200, 201].contains(response.statusCode),
           let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
           receipt.durable, receipt.id == id, receipt.sha256 == chunk.sha256 {
            do {
                let keep = QueueStore.keepsUploadedCopies
                if keep { try QueueStore.archiveAcknowledged(chunk) } else { try QueueStore.removeAcknowledged(chunk) }
                retries.removeValue(forKey: id)
                failureCounts.removeValue(forKey: id)
                lastUploadedAt = Date()
                note("Uploaded: \(id.prefix(8)) (HTTP \(response.statusCode))")
                status = keep ? String(localized: "Uploaded safely; copy kept on this iPhone")
                    : String(localized: "Uploaded safely; local copy removed")
            } catch { status = String(localized: "Uploaded; local cleanup will retry on reopening") }
        } else {
            note("Upload failed: \(id.prefix(8)): " + Self.describe(error, response, data))
            let failures = (failureCounts[id] ?? 0) + 1
            failureCounts[id] = failures
            retries[id] = Date().addingTimeInterval(min(1800, 15 * pow(2, Double(min(failures, 7)))))
            switch response?.statusCode {
            case 401:
                authenticationRejected = true
                status = String(localized: "Pairing token rejected. Audio remains on this phone.")
            case 409: status = String(localized: "Receiver reported a chunk conflict. Audio remains on this phone.")
            case 507: status = String(localized: "Receiver storage is full. Audio remains on this phone.")
            default: status = String(localized: "Waiting to upload. Audio remains on this phone.")
            }
        }
        pump()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let settings = ReceiverSettings.load(),
              challenge.protectionSpace.host.lowercased() == settings.baseURL.host?.lowercased() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if settings.certificateSHA256.isEmpty {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
            .map { String(format: "%02x", $0) }.joined()
        if hash == settings.certificateSHA256 {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            note("Server certificate does not match the paired fingerprint")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }
}
