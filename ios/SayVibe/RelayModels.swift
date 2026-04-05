import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppPreferenceKey {
    static let language = "sayvibe.settings.language"
    static let theme = "sayvibe.settings.theme"
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .system:
            return language.text("系统", "System")
        case .light:
            return language.text("浅色", "Light")
        case .dark:
            return language.text("深色", "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese
    case english

    var id: String { rawValue }

    static var current: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: AppPreferenceKey.language) ?? AppLanguage.simplifiedChinese.rawValue
        return AppLanguage(rawValue: rawValue) ?? .simplifiedChinese
    }

    var title: String {
        switch self {
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .simplifiedChinese:
            return "zh_Hans_CN"
        case .english:
            return "en_US"
        }
    }

    func text(_ chinese: @autoclosure () -> String, _ english: @autoclosure () -> String) -> String {
        self == .english ? english() : chinese()
    }
}

enum StatusTone {
    case neutral
    case info
    case success
    case error

    var background: Color {
        switch self {
        case .neutral:
            return Color(red: 0.12, green: 0.16, blue: 0.22)
        case .info:
            return Color(red: 0.11, green: 0.31, blue: 0.85)
        case .success:
            return Color(red: 0.09, green: 0.40, blue: 0.22)
        case .error:
            return Color(red: 0.60, green: 0.11, blue: 0.11)
        }
    }

    var foreground: Color {
        switch self {
        case .neutral:
            return Color(red: 0.80, green: 0.84, blue: 0.91)
        case .info:
            return Color(red: 0.86, green: 0.92, blue: 0.99)
        case .success:
            return Color(red: 0.86, green: 0.99, blue: 0.91)
        case .error:
            return Color(red: 1.00, green: 0.89, blue: 0.89)
        }
    }
}

struct LanDevice: Identifiable, Hashable {
    let ip: String
    let hostName: String
    let relayPortOpen: Bool

    var id: String { ip }

    var displayName: String {
        let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppLanguage.current.text("未知设备", "Unknown Device") : trimmed
    }
}

struct SyncPayload: Encodable {
    let type: String
    let text: String
    let cursor: Int
    let timestamp: Int64
    let requestId: String?

    init(text: String, cursor: Int, timestamp: Int64, requestId: String? = nil) {
        self.type = "sync_text"
        self.text = text
        self.cursor = cursor
        self.timestamp = timestamp
        self.requestId = requestId
    }
}

enum AutoImeActionMode: String, CaseIterable, Identifiable, Codable {
    case review
    case send

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .review:
            return language.text("待修改", "Review")
        case .send:
            return language.text("直接发送", "Send")
        }
    }

    func detail(for language: AppLanguage) -> String {
        switch self {
        case .review:
            return language.text("替换文本后停留在输入框", "Replace text and stay in the input")
        case .send:
            return language.text("替换文本后直接回车发送", "Replace text and press Return")
        }
    }
}

struct DesktopRelayState: Decodable {
    let autoImeSupported: Bool?
    let autoImeMode: AutoImeActionMode?
}

struct AutoImeModeControlRequest: Encodable {
    let mode: String
}

struct AutoImeModeControlResponse: Decodable {
    let ok: Bool?
    let mode: AutoImeActionMode?
}

struct PairingPayload {
    let ip: String
    let port: String

    static func parse(_ rawValue: String) -> PairingPayload? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed) {
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""

            if scheme == "sayvibe", host == "pair" {
                let ip = components.queryItems?.first(where: { $0.name == "ip" })?.value ?? ""
                let port = components.queryItems?.first(where: { $0.name == "port" })?.value ?? "18700"
                return PairingPayload(ip: ip, port: port)
            }

            if scheme == "http" || scheme == "https", let ip = components.host {
                return PairingPayload(ip: ip, port: components.port.map(String.init) ?? "18700")
            }
        }

        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        if let ip = parts.first, !ip.isEmpty {
            let port = parts.count > 1 ? parts[1] : "18700"
            return PairingPayload(ip: ip, port: port)
        }

        return nil
    }
}

struct RecentDevice: Identifiable, Hashable, Codable {
    let ip: String
    let hostName: String
    let port: String
    let lastUsedTimestamp: Int64

    var id: String {
        "\(ip):\(port)"
    }

    var displayName: String {
        let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppLanguage.current.text("未知设备", "Unknown Device") : trimmed
    }

    var subtitle: String {
        "\(ip):\(port)"
    }
}

struct MeetingNoteDocument: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var body: String
    var templateID: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        templateID: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.templateID = templateID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppLanguage.current.text("未命名纪要", "Untitled Note") : trimmed
    }

    var previewText: String {
        let lines = body
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            return AppLanguage.current.text("暂无内容", "No content yet")
        }

        return lines.prefix(2).joined(separator: " · ")
    }

    var exportFileName: String {
        let raw = displayTitle
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? AppLanguage.current.text("会议纪要", "Meeting Note") : cleaned
    }

    var exportedText: String {
        let language = AppLanguage.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let created = formatter.string(from: createdAt)
        let updated = formatter.string(from: updatedAt)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedBody.isEmpty {
            return language.text(
                """
# \(displayTitle)

创建时间：\(created)
更新时间：\(updated)

---

暂无内容
""",
                """
# \(displayTitle)

Created: \(created)
Updated: \(updated)

---

No content yet
"""
            )
        }

        return language.text(
            """
# \(displayTitle)

创建时间：\(created)
更新时间：\(updated)

---

\(trimmedBody)
""",
            """
# \(displayTitle)

Created: \(created)
Updated: \(updated)

---

\(trimmedBody)
"""
        )
    }
}

struct MeetingExportDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
final class MeetingNotesStore: ObservableObject {
    @Published private(set) var documents: [MeetingNoteDocument] = []
    @Published var selectedDocumentID: UUID?

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadDocuments()
    }

    var selectedDocument: MeetingNoteDocument? {
        if let selectedDocumentID,
           let document = documents.first(where: { $0.id == selectedDocumentID })
        {
            return document
        }
        return documents.first
    }

    func document(_ id: UUID) -> MeetingNoteDocument? {
        documents.first(where: { $0.id == id })
    }

    func selectDocument(_ id: UUID) {
        selectedDocumentID = id
    }

    func ensureInitialDocument(title: String, body: String, templateID: String) {
        guard documents.isEmpty else {
            if selectedDocumentID == nil {
                selectedDocumentID = documents.first?.id
            }
            return
        }

        createDocument(title: title, body: body, templateID: templateID)
    }

    @discardableResult
    func createDocument(title: String, body: String, templateID: String) -> MeetingNoteDocument {
        let document = MeetingNoteDocument(
            title: title,
            body: body,
            templateID: templateID
        )
        documents.insert(document, at: 0)
        selectedDocumentID = document.id
        persistDocument(document)
        return document
    }

    func updateSelectedDocument(title: String? = nil, body: String? = nil, templateID: String? = nil) {
        guard var document = selectedDocument else { return }

        if let title {
            document.title = title
        }
        if let body {
            document.body = body
        }
        if let templateID {
            document.templateID = templateID
        }

        document.updatedAt = Date()
        replaceDocument(document)
    }

    func updateDocument(_ id: UUID, title: String? = nil, body: String? = nil, templateID: String? = nil) {
        guard var document = document(id) else { return }

        if let title {
            document.title = title
        }
        if let body {
            document.body = body
        }
        if let templateID {
            document.templateID = templateID
        }

        document.updatedAt = Date()
        replaceDocument(document)
    }

    func deleteDocument(_ id: UUID) {
        documents.removeAll { $0.id == id }
        deleteDocumentFromDisk(id)

        if selectedDocumentID == id {
            selectedDocumentID = documents.first?.id
        }
    }

    private func replaceDocument(_ document: MeetingNoteDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index] = document
        documents.sort { $0.updatedAt > $1.updatedAt }
        selectedDocumentID = document.id
        persistDocument(document)
    }

    private func loadDocuments() {
        guard let directoryURL = ensureStorageDirectory() else {
            documents = []
            selectedDocumentID = nil
            return
        }

        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let loadedDocuments = fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> MeetingNoteDocument? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(MeetingNoteDocument.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        documents = loadedDocuments
        if selectedDocumentID == nil {
            selectedDocumentID = loadedDocuments.first?.id
        }
    }

    private func persistDocument(_ document: MeetingNoteDocument) {
        guard let directoryURL = ensureStorageDirectory() else { return }
        let fileURL = directoryURL
            .appendingPathComponent(document.id.uuidString)
            .appendingPathExtension("json")

        guard let data = try? encoder.encode(document) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func deleteDocumentFromDisk(_ id: UUID) {
        guard let directoryURL = ensureStorageDirectory() else { return }
        let fileURL = directoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
        try? fileManager.removeItem(at: fileURL)
    }

    private func ensureStorageDirectory() -> URL? {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first

        guard let baseURL else { return nil }

        let directoryURL = baseURL.appendingPathComponent("MeetingNotes", isDirectory: true)

        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        return directoryURL
    }
}
