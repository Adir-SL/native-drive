import Combine
import Foundation
import NativeDriveCore

@MainActor
final class TransferCenter: ObservableObject {
    struct Item: Identifiable, Equatable {
        enum Direction: Equatable { case download, upload }
        enum Phase: Equatable {
            case queued
            case running
            case completed
            case failed(String)
            case cancelled
        }

        let id: UUID
        var accountID: String
        var name: String
        var direction: Direction
        var completedBytes: Int64
        var totalBytes: Int64?
        var phase: Phase

        var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(completedBytes) / Double(totalBytes))
        }
    }

    @Published private(set) var items: [Item] = []
    @Published var isPresented = false

    private var tasks: [UUID: Task<Void, Error>] = [:]
    private var active = 0
    private let limit = 3

    var activeCount: Int {
        items.reduce(into: 0) { count, item in
            switch item.phase {
            case .queued, .running: count += 1
            case .completed, .failed, .cancelled: break
            }
        }
    }

    func download(file: DriveFile, accountID: String, destination: URL, client: DriveClient) async throws {
        try await run(
            name: file.name,
            accountID: accountID,
            direction: .download,
            total: file.size,
            reveal: true
        ) { id in
            try await client.download(fileID: file.id, to: destination) { [weak self] bytes, total in
                Task { @MainActor in
                    self?.update(id, bytes: bytes, total: total ?? file.size)
                }
            }
        }
    }

    @discardableResult
    func upload(fileURL: URL, name: String, mimeType: String, parentID: String, accountID: String, client: DriveClient) async throws -> DriveFile {
        var uploaded: DriveFile?
        try await run(
            name: name,
            accountID: accountID,
            direction: .upload,
            total: Self.fileSize(fileURL),
            reveal: true
        ) { id in
            uploaded = try await client.uploadFile(at: fileURL, name: name, mimeType: mimeType, parentID: parentID) { [weak self] bytes, total in
                Task { @MainActor in
                    self?.update(id, bytes: bytes, total: total)
                }
            }
        }
        guard let uploaded else {
            throw DriveAPIError.transport("The upload finished without a file.")
        }
        return uploaded
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        setPhase(id, .cancelled)
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.phase {
            case .completed, .failed, .cancelled: return true
            case .queued, .running: return false
            }
        }
    }

    private func run(
        name: String,
        accountID: String,
        direction: Item.Direction,
        total: Int64?,
        reveal: Bool,
        body: @escaping @MainActor (UUID) async throws -> Void
    ) async throws {
        let id = UUID()
        items.insert(Item(id: id, accountID: accountID, name: name, direction: direction, completedBytes: 0, totalBytes: total, phase: .queued), at: 0)
        if reveal { isPresented = true }
        let task = Task { @MainActor in
            guard await self.acquire() else {
                self.setPhase(id, .cancelled)
                throw DriveAPIError.cancelled
            }
            defer { self.release() }
            guard !Task.isCancelled else {
                self.setPhase(id, .cancelled)
                throw DriveAPIError.cancelled
            }
            self.setPhase(id, .running)
            try await body(id)
            self.setPhase(id, .completed)
        }
        tasks[id] = task
        defer { tasks[id] = nil }
        do {
            try await task.value
        } catch {
            if items.first(where: { $0.id == id })?.phase != .cancelled {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                setPhase(id, .failed(message))
            }
            throw error
        }
    }

    private func acquire() async -> Bool {
        while active >= limit {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if Task.isCancelled { return false }
        active += 1
        return true
    }

    private func release() {
        active = max(0, active - 1)
    }

    private func update(_ id: UUID, bytes: Int64, total: Int64?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].completedBytes = bytes
        if let total { items[index].totalBytes = total }
    }

    private func setPhase(_ id: UUID, _ phase: Item.Phase) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = phase
    }

    private static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let number = attributes?[.size] as? NSNumber { return number.int64Value }
        if let size = attributes?[.size] as? Int { return Int64(size) }
        return nil
    }
}
