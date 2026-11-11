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

    private var cancellers: [UUID: () -> Void] = [:]
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
        ) { [self] id in
            let knownSize = file.size
            try await client.download(fileID: file.id, to: destination) { [self] bytes, total in
                Task { @MainActor [self] in
                    self.update(id, bytes: bytes, total: total ?? knownSize)
                }
            }
        }
    }

    @discardableResult
    func upload(fileURL: URL, name: String, mimeType: String, parentID: String, accountID: String, client: DriveClient) async throws -> DriveFile {
        try await run(
            name: name,
            accountID: accountID,
            direction: .upload,
            total: Self.fileSize(fileURL),
            reveal: true
        ) { [self] id in
            try await client.uploadFile(at: fileURL, name: name, mimeType: mimeType, parentID: parentID) { [self] bytes, total in
                Task { @MainActor [self] in
                    self.update(id, bytes: bytes, total: total)
                }
            }
        }
    }

    func cancel(_ id: UUID) {
        cancellers[id]?()
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

    @discardableResult
    private func run<Result: Sendable>(
        name: String,
        accountID: String,
        direction: Item.Direction,
        total: Int64?,
        reveal: Bool,
        body: @escaping @MainActor (UUID) async throws -> Result
    ) async throws -> Result {
        let id = UUID()
        items.insert(Item(id: id, accountID: accountID, name: name, direction: direction, completedBytes: 0, totalBytes: total, phase: .queued), at: 0)
        if reveal { isPresented = true }
        let task = Task { @MainActor () -> Result in
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
            let value = try await body(id)
            self.setPhase(id, .completed)
            return value
        }
        cancellers[id] = { task.cancel() }
        defer { cancellers[id] = nil }
        do {
            return try await task.value
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
