import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session

    @State private var notifications = Preferences.notificationsEnabled
    @State private var sound = Preferences.soundEnabled
    @State private var launchAtLogin = false
    @State private var isSaving = false

    var body: some View {
        Form {
            if let user = session.user {
                Section("Account") {
                    HStack(spacing: DS.Spacing.l) {
                        Avatar(user: user.asUser, size: 44)
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(user.asUser.displayName)
                                .font(DS.Fonts.rowTitle)
                                .foregroundStyle(DS.Colors.ink)
                                .lineLimit(1)
                            Text("@" + user.handle)
                                .font(DS.Fonts.monoHandle)
                                .foregroundStyle(DS.Colors.inkMuted)
                                .lineLimit(1)
                        }
                        .help(user.asUser.displayName + " · @" + user.handle)
                        Spacer()
                        Button("Sign Out") { session.signOut() }
                            .buttonStyle(.dsOutline)
                    }
                    .padding(.vertical, DS.Spacing.xxs)
                }

                Section("Remotes") {
                    Toggle("Remotes", isOn: Binding(get: { user.remotes != nil }, set: { enabled in
                        save { try await $0.send("PUT", "me/remotes", json: ["enabled": enabled]) }
                    }))

                    if let remotes = user.remotes {
                        Picker("Who can push to you", selection: Binding(get: { remotes.from }, set: { from in
                            save { try await $0.send("PUT", "me/remote-preferences", json: ["from": from, "pull_receipts": remotes.pullReceipts]) }
                        })) {
                            Text("People you follow").tag("following")
                            if remotes.everyone {
                                Text("Everyone").tag("everyone")
                            }
                        }

                        Toggle("Share pull receipts", isOn: Binding(get: { remotes.pullReceipts }, set: { receipts in
                            save { try await $0.send("PUT", "me/remote-preferences", json: ["from": remotes.from, "pull_receipts": receipts]) }
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
                Text("Alerts never show what a message says. Muted remotes stay quiet.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }

            Section("This Mac") {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        if Preferences.launchAtLogin != launchAtLogin { Preferences.launchAtLogin = launchAtLogin }
                    }
                Text("Opens /dev/null when you log in to this Mac.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }

            Section {
                Button("Manage Devices on /dev/null…") {
                    NSWorkspace.shared.open(APIClient.baseURL.appending(path: "settings/devices"))
                }
                .buttonStyle(LinkButtonStyle())
            }
        }
        .formStyle(.grouped)
        .tint(DS.Colors.primaryFill)
        // The login item can change in System Settings, so it's read whenever the window shows instead of once.
        .onAppear { launchAtLogin = Preferences.launchAtLogin }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Saves a setting; each of these endpoints answers as GET /api/v1/me does.
    private func save(_ request: @escaping (APIClient) async throws -> DataEnvelope<CurrentUser>) {
        guard let api = session.api else { return }

        isSaving = true

        Task {
            do {
                session.update(user: try await request(api).data)
            } catch {
                presentAlert(error.localizedDescription)
            }

            isSaving = false
        }
    }
}
