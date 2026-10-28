import ServiceManagement
import SwiftUI

/// The Settings window: General, Profile, Pastéis, Remotes, Privacy, Devices and Account, each a grouped form.
/// Identity is never edited here; it comes from GitHub.
struct SettingsView: View {
    @Environment(Session.self) private var session

    @AppStorage("settings-tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
                .tag("general")
            ProfileSettings()
                .tabItem { Label("Profile", systemImage: "person") }
                .tag("profile")
            PasteisSettings()
                .tabItem { Label("Pastéis", systemImage: "gift") }
                .tag("pasteis")
            RemotesSettingsPane()
                .tabItem { Label("Remotes", systemImage: "bubble.left.and.bubble.right") }
                .tag("remotes")
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag("privacy")
            DevicesSettings()
                .tabItem { Label("Devices", systemImage: "laptopcomputer") }
                .tag("devices")
            AccountSettingsPane()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag("account")
        }
        .tint(DS.Colors.primaryFill)
        .frame(width: 520)
        .task { await session.workspace?.loadSettings() }
    }
}

/// Where each pane saves: the endpoints answer as GET me does, so the session's user stays current.
@MainActor
private func saveUser(_ session: Session, _ path: String, _ json: [String: Any]?) async {
    guard let api = session.api else { return }

    do {
        let response: DataEnvelope<CurrentUser> = try await api.send("PUT", path, json: json)
        session.update(user: response.data)
        await session.workspace?.loadSettings()
    } catch {
        presentAlert(error.localizedDescription)
    }
}

// MARK: - General

/// Light, dark or the system's appearance, applied to every window; a preference of this Mac only.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static var current: Appearance { Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system }

    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct GeneralSettings: View {
    @Environment(Session.self) private var session

    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @State private var launchAtLogin = false

    var body: some View {
        let settings = session.workspace?.settings

        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { Appearance.current.apply() }

                Toggle("Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        if Preferences.launchAtLogin != launchAtLogin { Preferences.launchAtLogin = launchAtLogin }
                    }
            }

            Section {
                Picker("Timezone", selection: timezone(settings)) {
                    Text("Follow this Mac (\(TimeZone.current.identifier))").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { zone in
                        Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                    }
                }
                Text("Times on /dev/null show in this timezone. Following this Mac keeps it in step when you travel.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }

            Section {
                Picker("Translation language", selection: Binding(get: { settings?.translationLanguage ?? "" }, set: { code in
                    Task { await saveUser(session, "me/translation-language", ["translation_language": code.isEmpty ? NSNull() : code]) }
                })) {
                    Text("This Mac's language").tag("")
                    ForEach(settings?.translationLanguages ?? []) { Text("\($0.name) · \($0.nativeName)").tag($0.code) }
                }
                Toggle("Translate automatically", isOn: Binding(get: { settings?.automaticTranslation ?? false }, set: { enabled in
                    Task { await saveUser(session, "me/automatic-translation", ["enabled": enabled]) }
                }))
            }
            .disabled(settings == nil)
        }
        .formStyle(.grouped)
        // The login item can change in System Settings, so it's read whenever the pane shows.
        .onAppear { launchAtLogin = Preferences.launchAtLogin }
    }

    private func timezone(_ settings: AccountSettings?) -> Binding<String> {
        Binding(get: { settings?.timezone ?? "" }, set: { zone in
            let json: [String: Any] = ["timezone": zone.isEmpty ? NSNull() : zone, "show_local_time": settings?.showLocalTime ?? false]
            Task { await saveUser(session, "me/timezone", json) }
        })
    }
}

// MARK: - Profile

private struct ProfileSettings: View {
    @Environment(Session.self) private var session
    @Environment(\.openURL) private var openURL

    @State private var isSyncing = false

    var body: some View {
        Form {
            if let user = session.user {
                Section {
                    identity("name", user.name)
                    identity("handle", "@" + user.handle)
                    identity("bio", user.bio)
                    identity("company", user.company)
                    identity("location", user.location)
                    identity("website", user.website)
                    identity("github", user.htmlUrl)
                    identity("synced", user.githubSyncedAt.map { Formatting.stamp($0) })
                } header: {
                    Text("Identity")
                } footer: {
                    HStack {
                        Text("Your profile mirrors GitHub. Change it there, then sync.")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.inkMuted)
                        Spacer()
                        Button("Edit on GitHub") { openURL(URL(string: "https://github.com/settings/profile")!) }
                        Button(isSyncing ? "Syncing…" : "Sync from GitHub") {
                            isSyncing = true
                            Task {
                                await saveUser(session, "me/github", nil)
                                isSyncing = false
                            }
                        }
                        .disabled(isSyncing)
                    }
                }

                Section("Lane") {
                    LanePicker(user: user)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func identity(_ key: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            Text(key)
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
                .frame(width: 72, alignment: .leading)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "null")
                .font(value?.isEmpty == false ? DS.Fonts.body : DS.Fonts.monoCaption)
                .foregroundStyle(value?.isEmpty == false ? DS.Colors.ink : DS.Colors.inkFaint)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}

/// Automatic, then the six lanes, with a live preview: a rail node, the avatar with its ring, the lane-dotted handle.
private struct LanePicker: View {
    @Environment(Session.self) private var session
    let user: CurrentUser

    var body: some View {
        let preview = user.asUser

        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.l) {
                GraphRail(above: .clear, lane: LaneColor.of(preview), hasTail: false)
                    .frame(height: 44)
                Avatar(user: preview, size: 48).laneRing(preview)
                HStack(spacing: DS.Spacing.s) {
                    LaneDot(user: preview)
                    Text("@\(user.handle)")
                        .font(DS.Fonts.monoHandle)
                        .foregroundStyle(DS.Colors.inkMuted)
                }
            }

            HStack(spacing: DS.Spacing.m) {
                swatch(nil, color: DS.Colors.lane(user.automaticLane ?? 0), label: "Auto")
                ForEach(0 ..< 6, id: \.self) { index in
                    swatch(index, color: DS.Colors.lane(index), label: nil)
                }
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private var selected: Int? {
        if case let .palette(index)? = user.preferredLane { index } else { nil }
    }

    private func swatch(_ index: Int?, color: Color, label: String?) -> some View {
        let isSelected = index == selected

        return Button {
            Task { await saveUser(session, "me/lane", ["lane": index.map { $0 as Any } ?? NSNull()]) }
        } label: {
            ZStack {
                Circle().fill(color)
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? DS.Colors.ink : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? "Lane \(index.map { $0 + 1 } ?? 0)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Pastéis

private struct PasteisSettings: View {
    @Environment(Session.self) private var session

    var body: some View {
        Form {
            Section {
                Toggle("Pastéis mode", isOn: Binding(get: { session.user?.pasteisMode ?? false }, set: { enabled in
                    Task { await saveUser(session, "me/pasteis-mode", ["enabled": enabled]) }
                }))
                Text("A little appreciation, fresh daily. Get 10 pastéis to give to other people’s commits, one per click. Your allowance resets at 00:00 UTC.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
                Text("When off, all pastéis controls and counters are hidden. You still receive pastéis from others.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Remotes

/// The remotes settings as the app has always had them, with the alerts of this Mac.
private struct RemotesSettingsPane: View {
    @Environment(Session.self) private var session

    @State private var notifications = Preferences.notificationsEnabled
    @State private var sound = Preferences.soundEnabled
    @State private var isSaving = false

    var body: some View {
        Form {
            if let user = session.user {
                Section("Remotes") {
                    Toggle("Remotes", isOn: Binding(get: { user.remotes != nil }, set: { enabled in
                        save("me/remotes", ["enabled": enabled])
                    }))

                    if let remotes = user.remotes {
                        Picker("Who can push to you", selection: Binding(get: { remotes.from }, set: { from in
                            save("me/remote-preferences", ["from": from, "pull_receipts": remotes.pullReceipts])
                        })) {
                            Text("People you follow").tag("following")
                            if remotes.everyone {
                                Text("Everyone").tag("everyone")
                            }
                        }

                        Toggle("Share pull receipts", isOn: Binding(get: { remotes.pullReceipts }, set: { receipts in
                            save("me/remote-preferences", ["from": remotes.from, "pull_receipts": receipts])
                        }))

                        Text("Pull receipts show when someone pulled your messages, only when you both share them.")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.inkMuted)
                    }
                }
                .disabled(isSaving)
            }

            Section("Alerts on this Mac") {
                Toggle("Notifications", isOn: $notifications)
                    .onChange(of: notifications) { Preferences.notificationsEnabled = notifications }
                Toggle("Sound", isOn: $sound)
                    .onChange(of: sound) { Preferences.soundEnabled = sound }
                Text("Alerts never show what a message says. Muted remotes stay quiet. There is no push service: when /dev/null quits, all checks stop.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }
        }
        .formStyle(.grouped)
    }

    private func save(_ path: String, _ json: [String: Any]) {
        isSaving = true

        Task {
            await saveUser(session, path, json)
            isSaving = false
        }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @Environment(Session.self) private var session

    @State private var muted: [User] = []
    @State private var blocked: [User] = []
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section("Muted") {
                people(muted, empty: "Nobody muted.", action: "Unmute") { user in
                    try await session.api?.perform("DELETE", "users/\(user.handle)/mute")
                    muted.removeAll { $0.id == user.id }
                }
            }

            Section {
                people(blocked, empty: "Nobody blocked.", action: "Unblock") { user in
                    try await session.api?.perform("DELETE", "users/\(user.handle)/block")
                    blocked.removeAll { $0.id == user.id }
                }
            } header: {
                Text("Blocked")
            } footer: {
                Text("Mutes and blocks follow your account everywhere.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }
        }
        .formStyle(.grouped)
        .task {
            guard let api = session.api else { return }

            async let mutedPage: Page<User>? = try? api.get("me/muted")
            async let blockedPage: Page<User>? = try? api.get("me/blocked")
            muted = await mutedPage?.data ?? []
            blocked = await blockedPage?.data ?? []
            hasLoaded = true
        }
    }

    @ViewBuilder
    private func people(_ users: [User], empty: String, action: String, perform: @escaping (User) async throws -> Void) -> some View {
        if !hasLoaded {
            ProgressView().controlSize(.small)
        } else if users.isEmpty {
            Text(empty)
                .foregroundStyle(DS.Colors.inkMuted)
        } else {
            ForEach(users) { user in
                HStack(spacing: DS.Spacing.m) {
                    Avatar(user: user, size: 24)
                    Text(user.displayName)
                    Text("@\(user.handle)")
                        .font(DS.Fonts.monoHandle)
                        .foregroundStyle(DS.Colors.inkMuted)
                    Spacer()
                    Button(action) {
                        Task {
                            do { try await perform(user) } catch { presentAlert(error.localizedDescription) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Devices

private struct DevicesSettings: View {
    @Environment(Session.self) private var session

    @State private var devices: [Device] = []
    @State private var hasLoaded = false
    @State private var thisMac = (try? DeviceKey.loadOrCreate())?.fingerprint

    var body: some View {
        Form {
            Section {
                if !hasLoaded {
                    ProgressView().controlSize(.small)
                }

                ForEach(devices) { device in
                    let isThisMac = device.fingerprint == thisMac

                    HStack(spacing: DS.Spacing.m) {
                        Image(systemName: isThisMac ? "laptopcomputer" : "iphone.and.arrow.forward")
                            .foregroundStyle(DS.Colors.inkMuted)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: DS.Spacing.s) {
                                Text(device.name)
                                if isThisMac { StatusLabel(text: "This Mac") }
                            }
                            Text("\(device.fingerprint.prefix(23))… · last used \(device.lastUsedAt.map { Formatting.relative($0) } ?? "never")")
                                .font(DS.Fonts.monoMeta)
                                .foregroundStyle(DS.Colors.inkMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !isThisMac {
                            Button("Revoke", role: .destructive) { revoke(device) }
                        }
                    }
                }
            } footer: {
                Text("Revoking a device signs it out. To sign this Mac out, use Account → Sign Out.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        if let page: DataEnvelope<[Device]> = try? await session.api?.get("me/devices") {
            devices = page.data
        }

        hasLoaded = true
    }

    private func revoke(_ device: Device) {
        guard Confirmations.confirm("Revoke \(device.name)?", "It's signed out and has to be approved again to sign in.", action: "Revoke") else { return }

        Task {
            do {
                try await session.api?.perform("DELETE", "me/devices/\(device.id)")
                devices.removeAll { $0.id == device.id }
            } catch {
                presentAlert(error.localizedDescription)
            }
        }
    }
}

// MARK: - Account

private struct AccountSettingsPane: View {
    @Environment(Session.self) private var session
    @Environment(\.openURL) private var openURL

    @State private var exportStarted = false
    @State private var showsDelete = false

    var body: some View {
        Form {
            if let user = session.user {
                Section {
                    HStack(spacing: DS.Spacing.l) {
                        Avatar(user: user.asUser, size: 44)
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(user.asUser.displayName)
                                .font(DS.Fonts.rowTitle)
                            Text("@" + user.handle)
                                .font(DS.Fonts.monoHandle)
                                .foregroundStyle(DS.Colors.inkMuted)
                        }
                        Spacer()
                        Button("Sign Out") { session.signOut() }
                    }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export your data")
                            Text(exportStarted ? "Your export downloads in the browser." : "Everything stored about you, as a file.")
                                .font(DS.Fonts.caption)
                                .foregroundStyle(DS.Colors.inkMuted)
                        }
                        Spacer()
                        Button("Export…") {
                            openURL(APIClient.baseURL.appending(path: "settings/export"))
                            exportStarted = true
                        }
                    }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete account")
                            Text("Erases your commits, remotes and everything else. It can't be undone.")
                                .font(DS.Fonts.caption)
                                .foregroundStyle(DS.Colors.inkMuted)
                        }
                        Spacer()
                        Button("Delete Account…", role: .destructive) { showsDelete = true }
                    }
                }

                if session.workspace?.settings?.isAdmin == true {
                    Section("Admin") {
                        Button("Moderation on the Web") { openURL(APIClient.baseURL.appending(path: "moderation")) }
                        Button("Operations on the Web") { openURL(APIClient.baseURL.appending(path: "operations")) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsDelete) { DeleteAccountSheet() }
    }
}

/// Deleting the account asks for the handle, typed, before the button works.
private struct DeleteAccountSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var isDeleting = false

    var body: some View {
        let handle = session.user?.handle ?? ""

        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Delete @\(handle)?")
                .font(DS.Fonts.section)
            Text("Your commits, replies, stars, remotes and devices are erased, on the web and on every device. This can't be undone.")
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Type \(handle) to confirm.")
                .font(DS.Fonts.body)
            TextField(handle, text: $typed)
                .textFieldStyle(.plain)
                .font(DS.Fonts.monoHandle)
                .fieldChrome()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isDeleting ? "Deleting…" : "Delete Account", role: .destructive) { delete() }
                    .buttonStyle(.dsDestructive)
                    .disabled(typed != handle || isDeleting)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 420)
    }

    private func delete() {
        isDeleting = true

        Task {
            do {
                try await session.api?.perform("DELETE", "me")
                dismiss()
                session.signOut()
            } catch {
                presentAlert(error.localizedDescription)
            }

            isDeleting = false
        }
    }
}
