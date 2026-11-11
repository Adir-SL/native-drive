import Foundation

public enum MediaKind: Equatable, Sendable {
    case image
    case playableVideo
    case playableAudio
    case unsupportedVideo
    case other
}

public enum MediaClassifier {
    public static func kind(mimeType: String, fileName: String) -> MediaKind {
        let mime = normalizedMIME(mimeType)
        if let fromMIME = kind(mime: mime) {
            return fromMIME
        }
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return kind(extension: ext) ?? .other
    }

    public static func kind(of file: DriveFile) -> MediaKind {
        kind(mimeType: file.mimeType, fileName: file.name)
    }

    private static func normalizedMIME(_ mimeType: String) -> String {
        let trimmed = mimeType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = trimmed.firstIndex(of: ";") {
            return String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func kind(mime: String) -> MediaKind? {
        if mime.isEmpty || mime == "application/octet-stream" {
            return nil
        }
        if mime.hasPrefix("image/") {
            return .image
        }
        if unsupportedVideoMIMEs.contains(mime) {
            return .unsupportedVideo
        }
        if playableVideoMIMEs.contains(mime) {
            return .playableVideo
        }
        if mime.hasPrefix("video/") {
            return .unsupportedVideo
        }
        if playableAudioMIMEs.contains(mime) || mime.hasPrefix("audio/") {
            return .playableAudio
        }
        return nil
    }

    private static func kind(extension ext: String) -> MediaKind? {
        if imageExtensions.contains(ext) { return .image }
        if unsupportedVideoExtensions.contains(ext) { return .unsupportedVideo }
        if playableVideoExtensions.contains(ext) { return .playableVideo }
        if playableAudioExtensions.contains(ext) { return .playableAudio }
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "bmp", "svg",
        "heic", "heif", "heics", "heifs",
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "raw", "srw", "pef"
    ]

    private static let playableVideoMIMEs: Set<String> = [
        "video/mp4", "video/quicktime", "video/m4v", "video/x-m4v",
        "video/mpeg", "video/3gpp", "video/3gpp2"
    ]

    private static let playableVideoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mpeg", "mpg", "mpe", "3gp", "3g2", "m4p"
    ]

    private static let unsupportedVideoMIMEs: Set<String> = [
        "video/x-matroska", "video/webm", "video/x-msvideo", "video/avi",
        "video/x-ms-wmv", "video/x-flv", "application/x-matroska", "video/ogg"
    ]

    private static let unsupportedVideoExtensions: Set<String> = [
        "mkv", "avi", "wmv", "flv", "webm", "ogv", "m2ts", "vob", "asf", "divx"
    ]

    private static let playableAudioMIMEs: Set<String> = [
        "audio/mpeg", "audio/mp3", "audio/mp4", "audio/m4a", "audio/x-m4a",
        "audio/wav", "audio/x-wav", "audio/wave", "audio/aac", "audio/x-aac",
        "audio/aiff", "audio/x-aiff", "audio/flac", "audio/x-flac", "audio/x-caf"
    ]

    private static let playableAudioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "wave", "aiff", "aif", "flac", "caf", "alac"
    ]
}

public enum MediaNavigator {
    public static func playlist(in files: [DriveFile], kind: MediaKind) -> [DriveFile] {
        files.filter { MediaClassifier.kind(of: $0) == kind }
    }

    public static func index(of fileID: String, in playlist: [DriveFile]) -> Int? {
        playlist.firstIndex { $0.id == fileID }
    }

    public static func neighborIndex(current: Int, count: Int, delta: Int) -> Int? {
        let next = current + delta
        guard count > 0, next >= 0, next < count else { return nil }
        return next
    }

    public static func positionLabel(index: Int, count: Int) -> String {
        guard count > 0, index >= 0, index < count else { return "" }
        return "\(index + 1) of \(count)"
    }
}

public enum MediaCacheKey {
    public static func relativePath(accountID: String, fileID: String, fileName: String) -> String {
        let account = AccountID.sanitize(accountID)
        let file = AccountID.sanitize(fileID)
        let name = FileName.sanitize(fileName)
        return "\(account)/\(file)/\(name)"
    }
}

public struct MediaCacheEntry: Equatable, Sendable {
    public var key: String
    public var byteCount: Int64
    public var lastAccessed: Date

    public init(key: String, byteCount: Int64, lastAccessed: Date) {
        self.key = key
        self.byteCount = byteCount
        self.lastAccessed = lastAccessed
    }
}

public enum MediaCacheEviction {
    public static let defaultBudget: Int64 = 2 * 1024 * 1024 * 1024

    /// Oldest unpinned files whose removal brings the cache under `budget`.
    public static func keysToRemove(
        entries: [MediaCacheEntry],
        budget: Int64 = defaultBudget,
        protectedKeys: Set<String> = []
    ) -> [String] {
        var total = entries.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
        guard total > budget else { return [] }
        let victims = entries
            .filter { !protectedKeys.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.lastAccessed != rhs.lastAccessed { return lhs.lastAccessed < rhs.lastAccessed }
                return lhs.key < rhs.key
            }
        var remove: [String] = []
        for victim in victims {
            if total <= budget { break }
            remove.append(victim.key)
            total -= max(0, victim.byteCount)
        }
        return remove
    }
}

public enum DriveThumbnailURL {
    /// Drive thumbnail links end in `=s220`. Ask for a larger edge so the first paint is sharp.
    public static func enlarged(_ urlString: String, edge: Int = 1600) -> String {
        guard edge > 0, let range = urlString.range(of: #"=s\d+$"#, options: .regularExpression) else {
            return urlString
        }
        return urlString.replacingCharacters(in: range, with: "=s\(edge)")
    }
}

public enum HTTPContentRange {
    /// Total length from a `Content-Range` value such as `bytes 0-99/1234`.
    public static func totalLength(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let total = trimmed[trimmed.index(after: slash)...]
        if total == "*" { return nil }
        return Int64(total)
    }
}
