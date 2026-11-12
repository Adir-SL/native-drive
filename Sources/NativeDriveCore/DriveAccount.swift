import Foundation

public struct DriveAccount: Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var displayName: String?
    public var pictureURL: String?
    public var addedAt: Date
    public var hostedDomain: String?

    public init(id: String, email: String, displayName: String?, pictureURL: String?, addedAt: Date, hostedDomain: String? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.addedAt = addedAt
        self.hostedDomain = hostedDomain
    }

    /// The address people use to tell two accounts with the same name apart.
    public var title: String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if AccountIdentity.isEmail(trimmed) {
            return trimmed
        }
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return trimmed.isEmpty ? "Account" : trimmed
    }

    /// The person's name, when it adds something the email does not.
    public var subtitle: String? {
        guard let displayName else { return nil }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.caseInsensitiveCompare(title) != .orderedSame else { return nil }
        return name
    }
}

extension DriveAccount: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, email, displayName, pictureURL, addedAt, hostedDomain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        pictureURL = try container.decodeIfPresent(String.self, forKey: .pictureURL)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
        hostedDomain = try container.decodeIfPresent(String.self, forKey: .hostedDomain)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(email, forKey: .email)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(pictureURL, forKey: .pictureURL)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(hostedDomain, forKey: .hostedDomain)
    }
}

public enum AccountIdentity {
    public static func isEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return false }
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        guard !local.isEmpty, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return !trimmed.contains(where: \.isWhitespace)
    }
}

public enum AccountEmailMigration {
    /// Fills an account that was saved without an address. A stored address is left alone.
    public static func resolve(
        stored: DriveAccount,
        aboutEmail: String?,
        aboutName: String?,
        aboutPicture: String?,
        userInfoEmail: String?,
        userInfoName: String?,
        userInfoPicture: String?,
        idToken: String?
    ) -> DriveAccount? {
        guard !AccountIdentity.isEmail(stored.email) else { return nil }
        let candidates = [aboutEmail, userInfoEmail, IDTokenClaims.string("email", jwt: idToken ?? "")]
        guard let email = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: AccountIdentity.isEmail) else {
            return nil
        }
        var updated = stored
        updated.email = email
        let name = aboutName ?? userInfoName
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.displayName = name
        }
        let picture = aboutPicture ?? userInfoPicture
        if let picture, !picture.isEmpty {
            updated.pictureURL = picture
        }
        return updated
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
