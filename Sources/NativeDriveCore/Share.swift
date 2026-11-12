import Foundation

public enum ShareRole: String, Equatable, Sendable, CaseIterable {
    case reader
    case commenter
    case writer
    case owner

    public static let assignable: [ShareRole] = [.reader, .commenter, .writer]

    public var title: String {
        switch self {
        case .reader: return "Viewer"
        case .commenter: return "Commenter"
        case .writer: return "Editor"
        case .owner: return "Owner"
        }
    }

    public static func title(for role: String) -> String {
        if let known = ShareRole(rawValue: role) { return known.title }
        switch role {
        case "organizer": return "Manager"
        case "fileOrganizer": return "Content manager"
        default: return role
        }
    }

    /// Drive only accepts an expiration on viewer and commenter grants.
    public var allowsExpiration: Bool {
        self == .reader || self == .commenter
    }
}

public struct PermissionDetail: Codable, Equatable, Sendable {
    public var permissionType: String?
    public var role: String?
    public var inherited: Bool?
    public var inheritedFrom: String?

    public init(permissionType: String? = nil, role: String? = nil, inherited: Bool? = nil, inheritedFrom: String? = nil) {
        self.permissionType = permissionType
        self.role = role
        self.inherited = inherited
        self.inheritedFrom = inheritedFrom
    }
}

public struct DrivePermission: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var role: String
    public var emailAddress: String?
    public var displayName: String?
    public var photoLink: String?
    public var domain: String?
    public var expirationTime: Date?
    public var pendingOwner: Bool?
    public var allowFileDiscovery: Bool?
    public var permissionDetails: [PermissionDetail]?

    public init(
        id: String,
        type: String,
        role: String,
        emailAddress: String? = nil,
        displayName: String? = nil,
        photoLink: String? = nil,
        domain: String? = nil,
        expirationTime: Date? = nil,
        pendingOwner: Bool? = nil,
        allowFileDiscovery: Bool? = nil,
        permissionDetails: [PermissionDetail]? = nil
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.photoLink = photoLink
        self.domain = domain
        self.expirationTime = expirationTime
        self.pendingOwner = pendingOwner
        self.allowFileDiscovery = allowFileDiscovery
        self.permissionDetails = permissionDetails
    }

    public var isInherited: Bool {
        permissionDetails?.contains { detail in
            detail.inherited == true || (detail.inheritedFrom?.isEmpty == false)
        } == true
    }

    public var isPerson: Bool {
        type == "user" || type == "group"
    }

    public var primaryLabel: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let emailAddress, !emailAddress.isEmpty { return emailAddress }
        if type == "anyone" { return "Anyone with the link" }
        if let domain, !domain.isEmpty { return "Anyone in \(domain)" }
        return type
    }

    public var secondaryLabel: String? {
        if let emailAddress, !emailAddress.isEmpty, emailAddress != primaryLabel {
            return emailAddress
        }
        if type == "group" { return "Group" }
        return nil
    }
}

public enum GeneralAccess: Equatable, Sendable {
    case restricted
    case anyone(role: ShareRole, discoverable: Bool)
    case domain(domain: String, role: ShareRole, discoverable: Bool)

    public var summary: String {
        switch self {
        case .restricted:
            return "Restricted"
        case .anyone(let role, _):
            return "Anyone with the link can \(role.accessVerb)"
        case .domain(let domain, let role, _):
            return "Anyone in \(domain) can \(role.accessVerb)"
        }
    }
}

extension ShareRole {
    var accessVerb: String {
        switch self {
        case .reader: return "view"
        case .commenter: return "comment"
        case .writer: return "edit"
        case .owner: return "own"
        }
    }
}

public enum ShareList {
    public static func sorted(_ permissions: [DrivePermission]) -> [DrivePermission] {
        permissions.sorted { lhs, rhs in
            let leftOwner = lhs.role == "owner"
            let rightOwner = rhs.role == "owner"
            if leftOwner != rightOwner { return leftOwner && !rightOwner }
            let leftPending = lhs.pendingOwner == true
            let rightPending = rhs.pendingOwner == true
            if leftPending != rightPending { return leftPending && !rightPending }
            let leftRank = rank(lhs.role)
            let rightRank = rank(rhs.role)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.primaryLabel.localizedCaseInsensitiveCompare(rhs.primaryLabel) == .orderedAscending
        }
    }

    public static func people(_ permissions: [DrivePermission]) -> [DrivePermission] {
        sorted(permissions.filter(\.isPerson))
    }

    /// Anyone-with-the-link wins over a domain permission when both exist.
    public static func generalAccess(in permissions: [DrivePermission]) -> GeneralAccess {
        if let anyone = permissions.first(where: { $0.type == "anyone" }) {
            return .anyone(role: ShareRole(rawValue: anyone.role) ?? .reader, discoverable: anyone.allowFileDiscovery == true)
        }
        if let domain = permissions.first(where: { $0.type == "domain" }), let name = domain.domain, !name.isEmpty {
            return .domain(domain: name, role: ShareRole(rawValue: domain.role) ?? .reader, discoverable: domain.allowFileDiscovery == true)
        }
        return .restricted
    }

    public static func upsert(_ permission: DrivePermission, into permissions: [DrivePermission]) -> [DrivePermission] {
        var next = permissions.filter { $0.id != permission.id }
        if let email = permission.emailAddress?.lowercased(), permission.isPerson {
            next.removeAll { $0.emailAddress?.lowercased() == email && NewItem.isLocalID($0.id) }
        }
        next.append(permission)
        return sorted(next)
    }

    public static func remove(_ id: String, from permissions: [DrivePermission]) -> [DrivePermission] {
        permissions.filter { $0.id != id }
    }

    /// Local prediction of general access. Real ids are kept when the same anyone or domain grant already exists.
    public static func applying(_ access: GeneralAccess, to permissions: [DrivePermission]) -> [DrivePermission] {
        var next = permissions.filter { $0.type != "anyone" && $0.type != "domain" }
        switch access {
        case .restricted:
            break
        case .anyone(let role, let discoverable):
            let existing = permissions.first { $0.type == "anyone" }
            next.append(DrivePermission(
                id: existing?.id ?? "local:anyone",
                type: "anyone",
                role: role.rawValue,
                allowFileDiscovery: discoverable
            ))
        case .domain(let domain, let role, let discoverable):
            let existing = permissions.first { $0.type == "domain" && $0.domain?.lowercased() == domain.lowercased() }
            next.append(DrivePermission(
                id: existing?.id ?? "local:domain",
                type: "domain",
                role: role.rawValue,
                domain: domain,
                allowFileDiscovery: discoverable
            ))
        }
        return sorted(next)
    }

    private static func rank(_ role: String) -> Int {
        switch role {
        case "owner": return 0
        case "organizer": return 1
        case "fileOrganizer": return 2
        case "writer": return 3
        case "commenter": return 4
        case "reader": return 5
        default: return 6
        }
    }
}

public enum OwnershipTransfer: Equatable, Sendable {
    /// Same Workspace domain: Drive can move ownership immediately.
    case immediate
    /// Consumer accounts and cross-domain transfers stay pending until accepted.
    case pending

    public static func kind(ownerEmail: String?, recipientEmail: String) -> OwnershipTransfer {
        let owner = domain(of: ownerEmail)
        let recipient = domain(of: recipientEmail)
        let consumer: Set<String> = ["gmail.com", "googlemail.com"]
        if let owner, let recipient, owner == recipient, !consumer.contains(owner) {
            return .immediate
        }
        return .pending
    }

    private static func domain(of email: String?) -> String? {
        guard let email else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.lastIndex(of: "@") else { return nil }
        let host = String(trimmed[trimmed.index(after: at)...])
        return host.isEmpty ? nil : host
    }
}

public enum ShareEmail {
    public static func isValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(" "), let at = value.lastIndex(of: "@") else { return false }
        let local = value[..<at]
        let host = value[value.index(after: at)...]
        guard !local.isEmpty, host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("@") else {
            return false
        }
        return true
    }

    public static func tokens(in raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in raw.split(whereSeparator: { ",;\n\t ".contains($0) }) {
            let token = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = token.lowercased()
            guard !token.isEmpty, seen.insert(key).inserted else { continue }
            result.append(token)
        }
        return result
    }
}

public struct Collaborator: Equatable, Sendable {
    public var email: String
    public var name: String?

    public init(email: String, name: String? = nil) {
        self.email = email
        self.name = name
    }
}

public struct CollaboratorDirectory: Equatable, Sendable {
    public private(set) var entries: [Collaborator] = []
    public var limit: Int

    public init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    public mutating func remember(_ permissions: [DrivePermission]) {
        for permission in permissions {
            guard permission.isPerson, let email = permission.emailAddress, ShareEmail.isValid(email) else { continue }
            remember(Collaborator(email: email, name: permission.displayName))
        }
    }

    public mutating func remember(_ collaborator: Collaborator) {
        let key = collaborator.email.lowercased()
        entries.removeAll { $0.email.lowercased() == key }
        entries.insert(collaborator, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    public func suggestions(matching query: String, limit suggestionLimit: Int = 6) -> [Collaborator] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return Array(entries.filter { item in
            item.email.lowercased().contains(needle) || (item.name?.lowercased().contains(needle) == true)
        }.prefix(max(0, suggestionLimit)))
    }
}

public enum ShareAccount {
    /// Workspace hosted domain from the OpenID `hd` claim. Consumer accounts have none.
    public static func workspaceDomain(email: String?, idToken: String?) -> String? {
        if let token = idToken, let hosted = IDTokenClaims.string("hd", jwt: token) {
            let trimmed = hosted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

public struct PermissionWrite: Equatable, Sendable {
    public var type: String?
    public var role: String?
    public var emailAddress: String?
    public var domain: String?
    public var allowFileDiscovery: Bool?
    public var expirationTime: Date?
    public var pendingOwner: Bool?
    public var clearExpiration: Bool

    public init(
        type: String? = nil,
        role: String? = nil,
        emailAddress: String? = nil,
        domain: String? = nil,
        allowFileDiscovery: Bool? = nil,
        expirationTime: Date? = nil,
        pendingOwner: Bool? = nil,
        clearExpiration: Bool = false
    ) {
        self.type = type
        self.role = role
        self.emailAddress = emailAddress
        self.domain = domain
        self.allowFileDiscovery = allowFileDiscovery
        self.expirationTime = expirationTime
        self.pendingOwner = pendingOwner
        self.clearExpiration = clearExpiration
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(EncodedPermission(
            type: type,
            role: role,
            emailAddress: emailAddress,
            domain: domain,
            allowFileDiscovery: allowFileDiscovery,
            expirationTime: expirationTime.map(ShareDate.format),
            pendingOwner: pendingOwner,
            clearExpiration: clearExpiration
        ))
    }
}

private struct EncodedPermission: Encodable {
    var type: String?
    var role: String?
    var emailAddress: String?
    var domain: String?
    var allowFileDiscovery: Bool?
    var expirationTime: String?
    var pendingOwner: Bool?
    var clearExpiration: Bool

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(emailAddress, forKey: .emailAddress)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(allowFileDiscovery, forKey: .allowFileDiscovery)
        if clearExpiration {
            try container.encodeNil(forKey: .expirationTime)
        } else {
            try container.encodeIfPresent(expirationTime, forKey: .expirationTime)
        }
        try container.encodeIfPresent(pendingOwner, forKey: .pendingOwner)
    }

    private enum CodingKeys: String, CodingKey {
        case type, role, emailAddress, domain, allowFileDiscovery, expirationTime, pendingOwner
    }
}

public enum PermissionRequests {
    public static let permissionFields = "id,type,role,emailAddress,displayName,photoLink,domain,expirationTime,pendingOwner,allowFileDiscovery,permissionDetails(permissionType,role,inherited,inheritedFrom)"
    public static let listFields = "permissions(\(permissionFields)),nextPageToken"

    public static func listQuery(pageToken: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "fields", value: listFields)
        ]
        if let pageToken, !pageToken.isEmpty {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        return items
    }

    public static func createQuery(sendNotification: Bool, message: String?, transferOwnership: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "sendNotificationEmail", value: sendNotification ? "true" : "false"),
            URLQueryItem(name: "fields", value: permissionFields)
        ]
        if sendNotification, let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "emailMessage", value: message))
        }
        if transferOwnership {
            items.append(URLQueryItem(name: "transferOwnership", value: "true"))
        }
        return items
    }

    public static func updateQuery(transferOwnership: Bool) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: permissionFields)
        ]
        if transferOwnership {
            items.append(URLQueryItem(name: "transferOwnership", value: "true"))
        }
        return items
    }

    public static func deleteQuery() -> [URLQueryItem] {
        [URLQueryItem(name: "supportsAllDrives", value: "true")]
    }
}

public enum ShareSettings {
    public static func body(writersCanShare: Bool?, copyRequiresWriterPermission: Bool?) throws -> Data {
        try JSONEncoder().encode(Body(writersCanShare: writersCanShare, copyRequiresWriterPermission: copyRequiresWriterPermission))
    }

    private struct Body: Encodable {
        var writersCanShare: Bool?
        var copyRequiresWriterPermission: Bool?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(writersCanShare, forKey: .writersCanShare)
            try container.encodeIfPresent(copyRequiresWriterPermission, forKey: .copyRequiresWriterPermission)
        }

        private enum CodingKeys: String, CodingKey {
            case writersCanShare, copyRequiresWriterPermission
        }
    }
}

public enum ShareDate {
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

extension DrivePermission {
    public static func optimistic(email: String, role: ShareRole, id: String = NewItem.localID()) -> DrivePermission {
        DrivePermission(id: id, type: "user", role: role.rawValue, emailAddress: email, displayName: email)
    }
}

extension DrivePermission {
    enum CodingKeys: String, CodingKey {
        case id, type, role, emailAddress, displayName, photoLink, domain, expirationTime, pendingOwner, allowFileDiscovery, permissionDetails
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "user"
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "reader"
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        photoLink = try container.decodeIfPresent(String.self, forKey: .photoLink)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        if let text = try container.decodeIfPresent(String.self, forKey: .expirationTime) {
            expirationTime = DriveDate.parse(text)
        } else {
            expirationTime = nil
        }
        pendingOwner = try container.decodeIfPresent(Bool.self, forKey: .pendingOwner)
        allowFileDiscovery = try container.decodeIfPresent(Bool.self, forKey: .allowFileDiscovery)
        permissionDetails = try container.decodeIfPresent([PermissionDetail].self, forKey: .permissionDetails)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(emailAddress, forKey: .emailAddress)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(photoLink, forKey: .photoLink)
        try container.encodeIfPresent(domain, forKey: .domain)
        try container.encodeIfPresent(expirationTime.map(ShareDate.format), forKey: .expirationTime)
        try container.encodeIfPresent(pendingOwner, forKey: .pendingOwner)
        try container.encodeIfPresent(allowFileDiscovery, forKey: .allowFileDiscovery)
        try container.encodeIfPresent(permissionDetails, forKey: .permissionDetails)
    }
}
