import Foundation

public struct DriveAccount: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var displayName: String?
    public var pictureURL: String?
    public var addedAt: Date

    public init(id: String, email: String, displayName: String?, pictureURL: String?, addedAt: Date) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.addedAt = addedAt
    }

    public var title: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return email
    }
}

public enum AccountID {
    public static func make(email: String?, permissionID: String?) -> String {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let trimmedEmail, !trimmedEmail.isEmpty {
            return sanitize(trimmedEmail)
        }
        if let permissionID, !permissionID.isEmpty {
            return sanitize(permissionID)
        }
        return sanitize(UUID().uuidString)
    }

    public static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@-")
        var output = ""
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                output.append("_")
            }
        }
        return output.isEmpty ? "account" : output
    }
}
