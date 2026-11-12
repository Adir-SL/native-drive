import AppKit
import SwiftUI
import NativeDriveCore

@MainActor
final class ShareSession: ObservableObject, Identifiable {
    let id = UUID()
    let files: [DriveFile]
    let domain: String?
    private let client: DriveClient
    private let suggestionsFor: @MainActor (String) -> [Collaborator]
    var onRemember: (@MainActor ([DrivePermission]) -> Void)?

    @Published private(set) var permissions: [DrivePermission] = []
    @Published var email = ""
    @Published var role: ShareRole = .reader
    @Published var notify = true
    @Published var message = ""
    @Published var writersCanShare = true
    @Published var viewersCanCopy = true
    @Published private(set) var canShare: Bool?
    @Published private(set) var canChangeCopy = true
    @Published private(set) var isLoading = true
    @Published var errorMessage: String?
    @Published var pendingTransfer: DrivePermission?

    init(
        files: [DriveFile],
        client: DriveClient,
        domain: String?,
        suggestions: @escaping @MainActor (String) -> [Collaborator]
    ) {
        self.files = files
        self.client = client
        self.domain = domain
        self.suggestionsFor = suggestions
        if let file = files.first {
            writersCanShare = file.writersCanShare ?? true
            viewersCanCopy = !(file.copyRequiresWriterPermission ?? false)
            canShare = file.capabilities?.canShare
        }
    }

    var title: String {
        if files.count == 1 { return "Share \"\(files[0].name)\"" }
        return "Share \(files.count) items"
    }

    var allowsEdits: Bool {
        canShare != false && files.allSatisfy { $0.capabilities?.canShare != false }
    }

    var allowsPeopleEdits: Bool { allowsEdits && files.count == 1 }

    var lockReason: String? {
        guard !allowsEdits else { return nil }
        return "You don't have permission to change sharing."
    }

    var copyLockReason: String? {
        guard allowsEdits else { return lockReason }
        return canChangeCopy ? nil : "You can't change whether viewers can download or copy."
    }

    var people: [DrivePermission] { ShareList.people(permissions) }
    var general: GeneralAccess { ShareList.generalAccess(in: permissions) }
    var suggestions: [Collaborator] { suggestionsFor(email) }

    func load() async {
        guard let file = files.first else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.getFile(id: file.id)
            writersCanShare = fresh.writersCanShare ?? writersCanShare
            viewersCanCopy = !(fresh.copyRequiresWriterPermission ?? !viewersCanCopy)
            canShare = fresh.capabilities?.canShare ?? canShare
            let copyCapability = fresh.capabilities?.canChangeCopyRequiresWriterPermission
            let viewersCapability = fresh.capabilities?.canChangeViewersCanCopyContent
            canChangeCopy = copyCapability != false && viewersCapability != false
            permissions = try await client.listPermissions(fileID: file.id)
            onRemember?(permissions)
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func add() async {
        guard allowsEdits else { return }
        let addresses = ShareEmail.tokens(in: email)
        guard !addresses.isEmpty, addresses.allSatisfy(ShareEmail.isValid) else {
            errorMessage = "Enter a valid email address."
            return
        }
        let snapshot = permissions
        let optimistic = addresses.map { DrivePermission.optimistic(email: $0, role: role) }
        permissions = optimistic.reduce(permissions) { ShareList.upsert($1, into: $0) }
        email = ""
        let note = notify ? message : nil
        let chosenRole = role
        do {
            for file in files {
                for address in addresses {
                    let created = try await client.grantAccess(
                        fileID: file.id,
                        email: address,
                        role: chosenRole,
                        notify: notify,
                        message: note,
                        expiration: nil
                    )
                    if file.id == files[0].id {
                        permissions = ShareList.upsert(created, into: permissions)
                    }
                }
            }
            onRemember?(permissions)
            errorMessage = nil
        } catch {
            permissions = snapshot
            errorMessage = Self.describe(error)
        }
    }

    func setRole(_ permission: DrivePermission, to role: ShareRole) {
        guard allowsPeopleEdits, canEdit(permission) else { return }
        let snapshot = permissions
        var updated = permission
        updated.role = role.rawValue
        if !role.allowsExpiration { updated.expirationTime = nil }
        permissions = ShareList.upsert(updated, into: permissions)
        Task {
            do {
                let saved = try await client.updatePermission(
                    fileID: files[0].id,
                    permissionID: permission.id,
                    permission: PermissionWrite(role: role.rawValue, clearExpiration: !role.allowsExpiration)
                )
                permissions = ShareList.upsert(saved, into: permissions)
            } catch {
                permissions = snapshot
                errorMessage = Self.describe(error)
            }
        }
    }

    func setExpiration(_ permission: DrivePermission, to date: Date?) {
        guard allowsPeopleEdits, canEdit(permission), ShareRole(rawValue: permission.role)?.allowsExpiration == true else { return }
        let snapshot = permissions
        var updated = permission
        updated.expirationTime = date
        permissions = ShareList.upsert(updated, into: permissions)
        Task {
            do {
                let saved = try await client.updatePermission(
                    fileID: files[0].id,
                    permissionID: permission.id,
                    permission: PermissionWrite(expirationTime: date, clearExpiration: date == nil)
                )
                permissions = ShareList.upsert(saved, into: permissions)
            } catch {
                permissions = snapshot
                errorMessage = Self.describe(error)
            }
        }
    }

    func remove(_ permission: DrivePermission) {
        guard allowsPeopleEdits, canEdit(permission) else { return }
        let snapshot = permissions
        permissions = ShareList.remove(permission.id, from: permissions)
        Task {
            do {
                try await client.deletePermission(fileID: files[0].id, permissionID: permission.id)
            } catch {
                permissions = snapshot
                errorMessage = Self.describe(error)
            }
        }
    }

    func confirmTransfer(_ permission: DrivePermission) {
        guard allowsPeopleEdits, permission.type == "user", permission.role != "owner", !permission.isInherited else { return }
        pendingTransfer = permission
    }

    func transferConfirmed() {
        guard let permission = pendingTransfer else { return }
        pendingTransfer = nil
        let snapshot = permissions
        let kind = OwnershipTransfer.kind(ownerEmail: ownerEmail, recipientEmail: permission.emailAddress ?? "")
        var updated = permission
        if kind == .immediate {
            updated.role = ShareRole.owner.rawValue
        } else {
            updated.pendingOwner = true
        }
        permissions = ShareList.upsert(updated, into: permissions)
        Task {
            do {
                let write: PermissionWrite
                let flag: Bool
                if kind == .immediate {
                    write = PermissionWrite(role: ShareRole.owner.rawValue)
                    flag = true
                } else {
                    write = PermissionWrite(pendingOwner: true)
                    flag = false
                }
                let saved = try await client.updatePermission(
                    fileID: files[0].id,
                    permissionID: permission.id,
                    permission: write,
                    transferOwnership: flag
                )
                permissions = ShareList.upsert(saved, into: permissions)
            } catch {
                permissions = snapshot
                errorMessage = Self.describe(error)
            }
        }
    }

    func setGeneral(_ access: GeneralAccess) {
        guard allowsEdits else { return }
        let snapshot = permissions
        permissions = ShareList.applying(access, to: permissions)
        Task {
            do {
                for file in files {
                    let current = file.id == files[0].id ? snapshot : try await client.listPermissions(fileID: file.id)
                    try await reconcile(access, fileID: file.id, current: current)
                }
                if let first = files.first {
                    permissions = try await client.listPermissions(fileID: first.id)
                }
            } catch {
                permissions = snapshot
                errorMessage = Self.describe(error)
            }
        }
    }

    func setWritersCanShare(_ value: Bool) {
        guard allowsEdits else { return }
        let snapshot = writersCanShare
        writersCanShare = value
        Task {
            do {
                for file in files {
                    _ = try await client.updateSharingSettings(fileID: file.id, writersCanShare: value, copyRequiresWriterPermission: nil)
                }
            } catch {
                writersCanShare = snapshot
                errorMessage = Self.describe(error)
            }
        }
    }

    func setViewersCanCopy(_ value: Bool) {
        guard allowsEdits, canChangeCopy else { return }
        let snapshot = viewersCanCopy
        viewersCanCopy = value
        Task {
            do {
                for file in files {
                    _ = try await client.updateSharingSettings(
                        fileID: file.id,
                        writersCanShare: nil,
                        copyRequiresWriterPermission: !value
                    )
                }
            } catch {
                viewersCanCopy = snapshot
                errorMessage = Self.describe(error)
            }
        }
    }

    func copyLink() {
        let links = files.compactMap { $0.browserURL?.absoluteString }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    func canEdit(_ permission: DrivePermission) -> Bool {
        allowsPeopleEdits && !permission.isInherited && permission.role != "owner" && !NewItem.isLocalID(permission.id)
    }

    private var ownerEmail: String? {
        permissions.first { $0.role == "owner" }?.emailAddress ?? files.first?.owners.first?.emailAddress
    }

    private func reconcile(_ access: GeneralAccess, fileID: String, current: [DrivePermission]) async throws {
        let anyone = current.filter { $0.type == "anyone" && !NewItem.isLocalID($0.id) }
        let domains = current.filter { $0.type == "domain" && !NewItem.isLocalID($0.id) }
        switch access {
        case .restricted:
            for permission in anyone + domains {
                try await client.deletePermission(fileID: fileID, permissionID: permission.id)
            }
        case .anyone(let role, let discoverable):
            for permission in domains {
                try await client.deletePermission(fileID: fileID, permissionID: permission.id)
            }
            if let existing = anyone.first {
                _ = try await client.updatePermission(
                    fileID: fileID,
                    permissionID: existing.id,
                    permission: PermissionWrite(role: role.rawValue)
                )
                for extra in anyone.dropFirst() {
                    try await client.deletePermission(fileID: fileID, permissionID: extra.id)
                }
            } else {
                _ = try await client.createPermission(
                    fileID: fileID,
                    permission: PermissionWrite(type: "anyone", role: role.rawValue, allowFileDiscovery: discoverable),
                    sendNotification: false,
                    message: nil
                )
            }
        case .domain(let domain, let role, let discoverable):
            for permission in anyone {
                try await client.deletePermission(fileID: fileID, permissionID: permission.id)
            }
            if let existing = domains.first(where: { $0.domain?.lowercased() == domain.lowercased() }) {
                _ = try await client.updatePermission(
                    fileID: fileID,
                    permissionID: existing.id,
                    permission: PermissionWrite(role: role.rawValue)
                )
            } else {
                _ = try await client.createPermission(
                    fileID: fileID,
                    permission: PermissionWrite(type: "domain", role: role.rawValue, domain: domain, allowFileDiscovery: discoverable),
                    sendNotification: false,
                    message: nil
                )
            }
            for extra in domains where extra.domain?.lowercased() != domain.lowercased() {
                try await client.deletePermission(fileID: fileID, permissionID: extra.id)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct ShareSheet: View {
    @ObservedObject var session: ShareSession
    var onDismiss: () -> Void
    @State private var generalChoice: GeneralChoice = .restricted
    @State private var generalRole: ShareRole = .reader

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.title)
                .font(.title2)
            if session.files.count > 1 {
                Text("The people listed are for \(session.files[0].name). New people and general access apply to every selected item.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let reason = session.lockReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            addSection
            peopleSection
            generalSection
            settingsSection
            if let error = session.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Copy link") { session.copyLink() }
                Text(session.general.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            syncGeneral()
            Task { await session.load() }
        }
        .onChange(of: session.permissions) { _, _ in
            syncGeneral()
        }
        .alert("Transfer ownership?", isPresented: transferPresented) {
            Button("Transfer", role: .destructive) { session.transferConfirmed() }
            Button("Cancel", role: .cancel) { session.pendingTransfer = nil }
        } message: {
            Text(transferMessage)
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                TextField("Add people or groups", text: $session.email)
                    .onSubmit { Task { await session.add() } }
                    .disabled(!session.allowsEdits)
                Picker("Role", selection: $session.role) {
                    ForEach(ShareRole.assignable, id: \.self) { role in
                        Text(role.title).tag(role)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!session.allowsEdits)
                Button("Add") { Task { await session.add() } }
                    .disabled(!session.allowsEdits || session.email.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !session.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.suggestions, id: \.email) { person in
                        Button {
                            session.email = person.email
                        } label: {
                            Text(person.name.map { "\($0) · \(person.email)" } ?? person.email)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.callout)
            }
            Toggle("Notify people", isOn: $session.notify)
                .disabled(!session.allowsEdits)
            if session.notify {
                TextField("Message", text: $session.message, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(!session.allowsEdits)
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People with access")
                .font(.headline)
            if session.isLoading && session.people.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
            ForEach(session.people) { permission in
                personRow(permission)
            }
        }
    }

    private func personRow(_ permission: DrivePermission) -> some View {
        HStack(alignment: .center, spacing: 10) {
            avatar(permission)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.primaryLabel)
                    .lineLimit(1)
                if let secondary = permission.secondaryLabel {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if permission.pendingOwner == true {
                    Text("Pending owner")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if permission.isInherited {
                    Text("Inherited from a parent folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.canEdit(permission), ShareRole(rawValue: permission.role)?.allowsExpiration == true {
                    expirationControl(permission)
                }
            }
            Spacer()
            if permission.role == "owner" || permission.isInherited || !session.canEdit(permission) {
                Text(permission.isInherited ? "\(ShareRole.title(for: permission.role)) · inherited" : ShareRole.title(for: permission.role))
                    .foregroundStyle(.secondary)
            } else {
                Menu(ShareRole.title(for: permission.role)) {
                    ForEach(ShareRole.assignable, id: \.self) { role in
                        Button(role.title) { session.setRole(permission, to: role) }
                    }
                    if permission.type == "user" {
                        Divider()
                        Button("Transfer ownership…") { session.confirmTransfer(permission) }
                    }
                    Divider()
                    Button("Remove access") { session.remove(permission) }
                }
                .frame(width: 140)
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General access")
                .font(.headline)
            Picker("General access", selection: choiceBinding) {
                Text("Restricted").tag(GeneralChoice.restricted)
                Text("Anyone with the link").tag(GeneralChoice.anyone)
                if let domain = session.domain {
                    Text("Anyone in \(domain)").tag(GeneralChoice.domain)
                }
            }
            .disabled(!session.allowsEdits)
            if generalChoice != .restricted {
                Picker("Link role", selection: roleBinding) {
                    ForEach(ShareRole.assignable, id: \.self) { role in
                        Text(role.title).tag(role)
                    }
                }
                .disabled(!session.allowsEdits)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Editors can change permissions and share", isOn: Binding(
                get: { session.writersCanShare },
                set: { session.setWritersCanShare($0) }
            ))
            .disabled(!session.allowsEdits)
            Toggle("Viewers and commenters can see the option to download, print, and copy", isOn: Binding(
                get: { session.viewersCanCopy },
                set: { session.setViewersCanCopy($0) }
            ))
            .disabled(session.copyLockReason != nil)
            if let reason = session.copyLockReason, session.allowsEdits {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func avatar(_ permission: DrivePermission) -> some View {
        Group {
            if let link = permission.photoLink, let url = URL(string: link) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials(permission)
                }
            } else {
                initials(permission)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }

    private func initials(_ permission: DrivePermission) -> some View {
        let source = permission.displayName ?? permission.emailAddress ?? "?"
        let letter = source.first.map { String($0).uppercased() } ?? "?"
        return Text(letter)
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }

    private func syncGeneral() {
        switch session.general {
        case .restricted:
            generalChoice = .restricted
        case .anyone(let role, _):
            generalChoice = .anyone
            generalRole = ShareRole.assignable.contains(role) ? role : .reader
        case .domain(_, let role, _):
            generalChoice = .domain
            generalRole = ShareRole.assignable.contains(role) ? role : .reader
        }
    }

    private var choiceBinding: Binding<GeneralChoice> {
        Binding(get: { generalChoice }, set: { newValue in
            generalChoice = newValue
            applyGeneral(newValue)
        })
    }

    private var roleBinding: Binding<ShareRole> {
        Binding(get: { generalRole }, set: { newValue in
            generalRole = newValue
            applyGeneral(generalChoice)
        })
    }

    private func expirationControl(_ permission: DrivePermission) -> some View {
        Group {
            if let date = permission.expirationTime {
                DatePicker("Expires", selection: Binding(
                    get: { date },
                    set: { session.setExpiration(permission, to: $0) }
                ), displayedComponents: .date)
                Button("Remove expiration") { session.setExpiration(permission, to: nil) }
                    .buttonStyle(.borderless)
            } else {
                Button("Add expiration") {
                    session.setExpiration(permission, to: Date().addingTimeInterval(30 * 24 * 60 * 60))
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.caption)
    }

    private func applyGeneral(_ choice: GeneralChoice) {
        guard !matchesCurrent(choice) else { return }
        switch choice {
        case .restricted:
            session.setGeneral(.restricted)
        case .anyone:
            session.setGeneral(.anyone(role: generalRole, discoverable: false))
        case .domain:
            guard let domain = session.domain else { return }
            session.setGeneral(.domain(domain: domain, role: generalRole, discoverable: false))
        }
    }

    private func matchesCurrent(_ choice: GeneralChoice) -> Bool {
        switch (session.general, choice) {
        case (.restricted, .restricted):
            return true
        case (.anyone(let role, _), .anyone):
            return role == generalRole
        case (.domain(let domain, let role, _), .domain):
            return domain.lowercased() == session.domain?.lowercased() && role == generalRole
        default:
            return false
        }
    }

    private var transferPresented: Binding<Bool> {
        Binding(get: { session.pendingTransfer != nil }, set: { if !$0 { session.pendingTransfer = nil } })
    }

    private var transferMessage: String {
        let name = session.pendingTransfer?.primaryLabel ?? "this person"
        return "\(name) will be asked to become the owner. Consumer and cross-organization transfers stay pending until they accept."
    }
}

private enum GeneralChoice: Hashable {
    case restricted
    case anyone
    case domain
}
