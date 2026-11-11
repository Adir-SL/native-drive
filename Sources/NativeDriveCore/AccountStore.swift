import Foundation

public actor AccountStore {
    private let fileURL: URL
    private var accounts: [DriveAccount]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            accounts = try JSONCoders.makeDecoder().decode([DriveAccount].self, from: data)
        } else {
            accounts = []
        }
    }

    public func list() -> [DriveAccount] {
        accounts.sorted { $0.addedAt < $1.addedAt }
    }

    public func upsert(_ account: DriveAccount) throws {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            var existing = accounts[index]
            existing.email = account.email
            existing.displayName = account.displayName
            existing.pictureURL = account.pictureURL
            accounts[index] = existing
        } else {
            accounts.append(account)
        }
        try persist()
    }

    public func remove(id: String) throws {
        accounts.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONCoders.makeEncoder().encode(accounts)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: temporary, to: fileURL)
    }
}
