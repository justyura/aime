import Foundation

/// Client for the local Vox API service.
///
/// The API service exposes authenticated REST endpoints on port 8081. File bytes
/// are uploaded directly to the presigned object-storage URL returned by Vox;
/// the API service is only used to coordinate the upload and transcription task.
struct VoxAPIClient {
    struct Credentials {
        let email: String
        let password: String
    }

    struct UploadTicket {
        let fileID: String
        let uploadURL: URL
    }

    struct TaskInfo {
        let taskID: String
        let inputFileID: String
        let outputFileID: String
        let status: String
        var type = ""
        var createdAt: Date?
    }

    struct FileInfo {
        let fileID: String
        let name: String
        let createdAt: Date?
    }

    /// Mirrors the worker's transcript JSON: {"text": ..., "segments": [{start_ms, end_ms, text}]}.
    struct Transcript: Equatable {
        struct Segment: Equatable {
            let startMS: Int
            let endMS: Int
            let text: String
        }

        let text: String
        let segments: [Segment]

        /// Falls back to the raw body as plain text, like the web client.
        static func parse(_ raw: String) -> Transcript {
            guard let root = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  let text = root["text"] as? String else {
                return Transcript(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), segments: [])
            }
            let segments = (root["segments"] as? [[String: Any]] ?? []).compactMap { item -> Segment? in
                guard let start = (item["start_ms"] as? NSNumber)?.intValue,
                      let end = (item["end_ms"] as? NSNumber)?.intValue,
                      start >= 0, end >= start else { return nil }
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : Segment(startMS: start, endMS: end, text: text)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Transcript(text: trimmed.isEmpty ? segments.map(\.text).joined(separator: " ") : trimmed,
                              segments: segments)
        }
    }

    enum ClientError: LocalizedError {
        case invalidURL
        case notAuthenticated
        case invalidResponse
        case server(status: Int, message: String)
        case taskFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Vox 本地 API 地址无效"
            case .notAuthenticated:
                return "请先登录 Vox 本地服务"
            case .invalidResponse:
                return "Vox 本地 API 返回格式异常"
            case let .server(status, message):
                return message.isEmpty ? "Vox 本地 API 请求失败（HTTP \(status)）" : message
            case .taskFailed:
                return "Vox 本地 Worker 转写失败"
            }
        }
    }

    static let defaultBaseURL = URL(string: "http://127.0.0.1:8081/api/v1")!
    static let baseURLDefaultsKey = "voxAPIBaseURL"
    static let emailDefaultsKey = "voxAPIEmail"
    static let tokenDefaultsKey = "voxAPIToken"

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL = VoxAPIClient.configuredBaseURL(), token: String) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    static func configuredBaseURL(from defaults: UserDefaults = VoiceDefaults.store) -> URL {
        let raw = (defaults.string(forKey: baseURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.isEmpty ? defaultBaseURL.absoluteString : raw) ?? defaultBaseURL
    }

    static func login(
        credentials: Credentials,
        baseURL: URL = VoxAPIClient.configuredBaseURL(),
        session: URLSession = .shared
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData(["email": credentials.email, "password": credentials.password])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? String,
              !token.isEmpty else {
            throw ClientError.invalidResponse
        }
        return token
    }

    func uploadTicket(filename: String) async throws -> UploadTicket {
        let data = try await request(
            path: "upload",
            method: "POST",
            body: Self.formData(["filename": filename]),
            contentType: "application/x-www-form-urlencoded; charset=utf-8"
        )
        let root = try jsonObject(data)
        guard let fileID = root["file_id"] as? String,
              let uploadString = root["upload_url"] as? String,
              let uploadURL = URL(string: uploadString) else {
            throw ClientError.invalidResponse
        }
        return UploadTicket(fileID: fileID, uploadURL: uploadURL)
    }

    func putFile(at fileURL: URL, to uploadURL: URL) async throws {
        let request = try Self.storageUploadRequest(fileURL: fileURL, uploadURL: uploadURL)
        // upload(for:fromFile:) synthesizes application/octet-stream on macOS.
        // A data task with a file stream preserves the unsigned, absent Content-Type.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ClientError.server(status: status, message: Self.storageError(data: data, status: status))
        }
    }

    static func storageUploadRequest(fileURL: URL, uploadURL: URL) throws -> URLRequest {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber,
              let stream = InputStream(url: fileURL) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(size.stringValue, forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = stream
        return request
    }

    static func storageError(data: Data, status: Int) -> String {
        let details = StorageErrorDetails()
        let parser = XMLParser(data: Data(data.prefix(65_536)))
        parser.shouldResolveExternalEntities = false
        parser.delegate = details
        let valid = parser.parse()
        var message = "对象存储上传失败（HTTP \(status)）"
        if valid {
            for key in ["Code", "Message", "RequestId"] {
                if let value = details.values[key], !value.isEmpty {
                    message += " · \(key): \(value.prefix(500))"
                }
            }
        }
        return message
    }

    func completeUpload(fileID: String) async throws {
        _ = try await request(path: "files/\(pathComponent(fileID))/complete", method: "POST")
    }

    func createTranscriptionTask(fileID: String, language: String = "") async throws -> String {
        let body: [String: Any] = [
            "input_file_id": fileID,
            "type": "transcribe",
            "language": language,
        ]
        let data = try await request(path: "tasks", method: "POST", json: body)
        let root = try jsonObject(data)
        guard let taskID = root["task_id"] as? String else {
            throw ClientError.invalidResponse
        }
        return taskID
    }

    func task(taskID: String) async throws -> TaskInfo {
        let data = try await request(path: "tasks/\(pathComponent(taskID))", method: "GET")
        let root = try jsonObject(data)
        guard let task = root["task"] as? [String: Any], let info = Self.taskInfo(from: task) else {
            throw ClientError.invalidResponse
        }
        return info
    }

    /// Every task of the signed-in account, shared with the web workbench.
    func listTasks() async throws -> [TaskInfo] {
        let root = try jsonObject(try await request(path: "tasks", method: "GET"))
        // gin renders an empty repeated field as null.
        return (root["tasks"] as? [[String: Any]] ?? []).compactMap(Self.taskInfo(from:))
    }

    func listFiles() async throws -> [FileInfo] {
        let root = try jsonObject(try await request(path: "listfiles", method: "GET"))
        let iso = ISO8601DateFormatter()
        return (root["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let id = file["file_id"] as? String else { return nil }
            return FileInfo(fileID: id, name: file["file_name"] as? String ?? "",
                            createdAt: (file["created_at"] as? String).flatMap(iso.date(from:)))
        }
    }

    /// Protobuf structs are rendered by encoding/json: empty strings are omitted and
    /// created_at is a {seconds, nanos} object rather than an RFC 3339 string.
    static func taskInfo(from task: [String: Any]) -> TaskInfo? {
        guard let id = task["task_id"] as? String, !id.isEmpty else { return nil }
        let created = (task["created_at"] as? [String: Any]).flatMap { stamp -> Date? in
            guard let seconds = (stamp["seconds"] as? NSNumber)?.doubleValue else { return nil }
            return Date(timeIntervalSince1970: seconds + ((stamp["nanos"] as? NSNumber)?.doubleValue ?? 0) / 1e9)
        }
        return TaskInfo(
            taskID: id,
            inputFileID: task["input_file_id"] as? String ?? "",
            outputFileID: task["output_file_id"] as? String ?? "",
            status: task["status"] as? String ?? "pending",
            type: task["type"] as? String ?? "",
            createdAt: created
        )
    }

    func waitForCompletion(taskID: String) async throws -> TaskInfo {
        while true {
            try Task.checkCancellation()
            let info = try await task(taskID: taskID)
            switch info.status {
            case "completed":
                return info
            case "failed":
                throw ClientError.taskFailed
            default:
                try await Task.sleep(nanoseconds: 1_800_000_000)
            }
        }
    }

    /// Presigned object-storage URL; also streamable by AVPlayer for the original recording.
    func downloadURL(fileID: String) async throws -> URL {
        let data = try await request(path: "download/\(pathComponent(fileID))", method: "GET")
        let root = try jsonObject(data)
        guard let downloadString = root["download_url"] as? String,
              let downloadURL = URL(string: downloadString) else {
            throw ClientError.invalidResponse
        }
        return downloadURL
    }

    func downloadResult(fileID: String) async throws -> String {
        let downloadURL = try await downloadURL(fileID: fileID)
        let (result, response) = try await session.data(from: downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ClientError.server(status: status, message: "无法读取转写结果（HTTP \(status)）")
        }
        guard let text = String(data: result, encoding: .utf8) else {
            throw ClientError.invalidResponse
        }
        return text
    }

    private func request(
        path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        json: [String: Any]? = nil
    ) async throws -> Data {
        guard !token.isEmpty else { throw ClientError.notAuthenticated }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return data
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? ""
            throw ClientError.server(status: http.statusCode, message: message)
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return object
    }

    static func formData(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Go's PostForm decodes a literal + as a space.
        return components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

/// Only surface diagnostic fields, never the signature or StringToSign in OSS errors.
private final class StorageErrorDetails: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var element = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        element = elementName
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if ["Code", "Message", "RequestId"].contains(element) {
            values[element, default: ""] += string
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) { element = "" }
}
