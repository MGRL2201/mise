import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Full backup in one JSON file (SPEC §5). EventKit data and Keychain
/// secrets are not included.
// ponytail: base64 JSON inflates ~33% and loads fully in memory; switch to AppleArchive/streaming if backups get large
struct Backup: Codable {
    static let currentVersion = 1
    /// UserDefaults keys owned by ThemeStore / AppLock.
    static let settingsKeys = ["theme.palette", "lock.mode", "lock.grace"]

    var version: Int
    var createdAt: Date
    var attachments: [AttachmentRecord]
    var settings: Data

    struct AttachmentRecord: Codable {
        var id: UUID
        var filename: String
        var createdAt: Date
        var data: Data
    }
}

enum BackupError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case corruptSettings

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This backup uses format version \(version), which this version of mise can't read."
        case .corruptSettings:
            "This backup's settings are damaged, so nothing was restored."
        }
    }
}

enum BackupService {
    static func export(context: ModelContext, files: AttachmentFileStore, defaults: UserDefaults) throws -> Data {
        let attachments = try context.fetch(FetchDescriptor<Attachment>()).map {
            Backup.AttachmentRecord(id: $0.id, filename: $0.filename, createdAt: $0.createdAt,
                                    data: files.read(for: $0.id) ?? Data())
        }
        var settings: [String: Any] = [:]
        for key in Backup.settingsKeys { settings[key] = defaults.object(forKey: key) }
        return try JSONEncoder().encode(Backup(
            version: Backup.currentVersion, createdAt: .now, attachments: attachments,
            settings: PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)))
    }

    static func restore(_ data: Data, context: ModelContext, files: AttachmentFileStore, defaults: UserDefaults) throws {
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard version == Backup.currentVersion else { throw BackupError.unsupportedVersion(version) }
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        guard let settings = try PropertyListSerialization.propertyList(from: backup.settings, format: nil) as? [String: Any]
        else { throw BackupError.corruptSettings }

        // Files + DB first; old files and settings only change once save succeeds.
        let oldIDs: [UUID]
        do {
            for record in backup.attachments { try files.write(record.data, for: record.id) }
            let existing = try context.fetch(FetchDescriptor<Attachment>())
            oldIDs = existing.map(\.id)
            existing.forEach(context.delete)
            for record in backup.attachments {
                let attachment = Attachment(filename: record.filename)
                attachment.id = record.id
                attachment.createdAt = record.createdAt
                context.insert(attachment)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        let keep = Set(backup.attachments.map(\.id))
        for id in oldIDs where !keep.contains(id) { try? files.delete(for: id) }
        for key in Backup.settingsKeys { defaults.set(settings[key], forKey: key) }
    }
}

struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static var defaultFilename: String {
        "mise-backup-\(Date.now.formatted(.iso8601.year().month().day())).json"
    }
}
