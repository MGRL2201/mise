import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Full backup in one JSON file (SPEC §5). EventKit data and Keychain
/// secrets are not included.
// ponytail: base64 JSON inflates ~33% and loads fully in memory; switch to AppleArchive/streaming if backups get large
struct Backup: Codable {
    static let currentVersion = 2
    /// UserDefaults keys owned by ThemeStore / AppLock / CalendarStore / TravelTime / WorkingHours.
    static let settingsKeys = ["theme.palette", "lock.mode", "lock.grace", "calendar.hidden", "calendar.colors", "calendar.default",
                                "travel.transport", "travel.buffer", "planning.workStart", "planning.workEnd", "planning.workDays",
                                "planning.daily", "planning.dailyTime",
                                "planning.weekly", "planning.weeklyDay", "planning.weeklyTime"]

    var version: Int
    var createdAt: Date
    var attachments: [AttachmentRecord]
    var settings: Data
    /// Added in version 2; nil in version-1 backups.
    var tags: [String]?
    var taskExtras: [TaskExtrasRecord]?
    /// Optional: older v2 files lack them.
    var wakeAlarms: [WakeAlarmRecord]?
    var wakeLogs: [WakeLogRecord]?

    struct WakeAlarmRecord: Codable {
        var id: UUID
        var hour: Int
        var minute: Int
        var weekdays: [Int]
        var isOn: Bool
    }

    struct WakeLogRecord: Codable {
        var day: Date
        var firstRing: Date
        var reRings: Int
        var outOfBed: Date?
    }

    struct TaskExtrasRecord: Codable {
        var reminderID: String
        var externalID: String?
        var subtasks: [Subtask]
        var tagNames: [String]
        var eventID: String?
        var flagged: Bool?  // optional: older v2 files lack it
        var estimateMinutes: Int?  // optional: older files lack it
    }

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
        let tags = try context.fetch(FetchDescriptor<Tag>()).map(\.name)
        let taskExtras = try context.fetch(FetchDescriptor<TaskExtras>()).map {
            Backup.TaskExtrasRecord(reminderID: $0.reminderID, externalID: $0.externalID,
                                    subtasks: $0.subtasks, tagNames: ($0.tags ?? []).map(\.name), eventID: $0.eventID,
                                    flagged: $0.flagged, estimateMinutes: $0.estimateMinutes)
        }
        let wakeAlarms = try context.fetch(FetchDescriptor<WakeAlarm>()).map {
            Backup.WakeAlarmRecord(id: $0.id, hour: $0.hour, minute: $0.minute, weekdays: $0.weekdays, isOn: $0.isOn)
        }
        let wakeLogs = try context.fetch(FetchDescriptor<WakeLog>()).map {
            Backup.WakeLogRecord(day: $0.day, firstRing: $0.firstRing, reRings: $0.reRings, outOfBed: $0.outOfBed)
        }
        var settings: [String: Any] = [:]
        for key in Backup.settingsKeys { settings[key] = defaults.object(forKey: key) }
        return try JSONEncoder().encode(Backup(
            version: Backup.currentVersion, createdAt: .now, attachments: attachments,
            settings: PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0),
            tags: tags, taskExtras: taskExtras, wakeAlarms: wakeAlarms, wakeLogs: wakeLogs))
    }

    static func restore(_ data: Data, context: ModelContext, files: AttachmentFileStore, defaults: UserDefaults) throws {
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard (1...Backup.currentVersion).contains(version) else { throw BackupError.unsupportedVersion(version) }
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
            // Version-1 backups carry no tags/extras: leave existing ones alone.
            if let tagNames = backup.tags, let records = backup.taskExtras {
                try context.fetch(FetchDescriptor<TaskExtras>()).forEach(context.delete)
                try context.fetch(FetchDescriptor<Tag>()).forEach(context.delete)
                func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                var tagsByKey: [String: Tag] = [:]
                for name in tagNames where tagsByKey[key(name)] == nil {
                    let tag = Tag(name: name)
                    context.insert(tag)
                    tagsByKey[key(name)] = tag
                }
                for record in records {
                    let extras = TaskExtras(reminderID: record.reminderID, externalID: record.externalID)
                    extras.subtasks = record.subtasks
                    extras.eventID = record.eventID
                    extras.flagged = record.flagged ?? false
                    extras.estimateMinutes = record.estimateMinutes
                    context.insert(extras)
                    extras.tags = record.tagNames.compactMap { tagsByKey[key($0)] }
                }
            }
            // Files lacking wake alarms/logs leave existing ones alone.
            if let alarms = backup.wakeAlarms {
                try context.fetch(FetchDescriptor<WakeAlarm>()).forEach(context.delete)
                for record in alarms {
                    let alarm = WakeAlarm(hour: record.hour, minute: record.minute, weekdays: record.weekdays)
                    alarm.id = record.id
                    alarm.isOn = record.isOn
                    context.insert(alarm)
                }
            }
            if let logs = backup.wakeLogs {
                try context.fetch(FetchDescriptor<WakeLog>()).forEach(context.delete)
                for record in logs {
                    let log = WakeLog(firstRing: record.firstRing, calendar: .current)
                    log.day = record.day
                    log.reRings = record.reRings
                    log.outOfBed = record.outOfBed
                    context.insert(log)
                }
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
