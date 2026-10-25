import SwiftUI

/// Who a thread is with. For an org: its name, which maintainers can change, its members and their roles, adding and
/// removing people, and leaving.
struct ThreadInfoView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    let thread: ThreadModel

    @State private var name = ""
    @State private var showsAdd = false

    private var isMaintainer: Bool { thread.role == .maintainer }

    /// An org always keeps a maintainer, so the only one can't be made a contributor.
    private var maintainerCount: Int { thread.members.filter { $0.role == .maintainer }.count }

    var body: some View {
        VStack(spacing: 0) {
            if let partner = thread.partner {
                partnerInfo(partner)
            } else {
                orgInfo
            }

            DS.Colors.hairline.frame(height: 1)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: 420)
        .background(DS.Colors.popover)
        .onAppear { name = thread.orgName ?? "" }
        .sheet(isPresented: $showsAdd) {
            if let id = thread.orgId {
                PeoplePicker(mode: .addToOrg(id: id)) { users, _, shareHistory in
                    Task { await thread.add(users.map(\.username), shareHistory: shareHistory) }
                }
            }
        }
    }

    private func partnerInfo(_ partner: User) -> some View {
        VStack(spacing: DS.Spacing.s) {
            Avatar(user: partner, size: 88)
                .padding(4)
                .overlay(Circle().strokeBorder(LaneColor.of(partner), lineWidth: 2))
                .padding(.bottom, DS.Spacing.s)

            Text(partner.displayName)
                .font(DS.Fonts.title)
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
                .help(partner.displayName)

            HStack(spacing: DS.Spacing.s) {
                Circle().fill(LaneColor.of(partner)).frame(width: 6, height: 6)
                Text("@" + partner.username)
                    .font(DS.Fonts.monoHandle)
                    .foregroundStyle(DS.Colors.inkMuted)

                if partner.followsYou == true {
                    StatusLabel(text: "Follows you")
                }
            }

            if let bio = partner.bio, !bio.isEmpty {
                Text(bio)
                    .font(DS.Fonts.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .lineLimit(3)
                    .padding(.top, DS.Spacing.xs)
            }

            Button("View Profile on /dev/null") {
                NSWorkspace.shared.open(APIClient.baseURL.appending(path: "@" + partner.username))
            }
            .buttonStyle(.dsOutline)
            .padding(.top, DS.Spacing.l)
        }
        .padding(DS.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }

    private var orgInfo: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.l) {
                OrgAvatar(members: thread.members.map(\.user).filter { $0.id != session.user?.id }, size: 48)

                if isMaintainer {
                    HStack(spacing: DS.Spacing.s) {
                        TextField("Org name", text: $name)
                            .font(DS.Fonts.body)
                            .fieldChrome()
                            .onChange(of: name) { name = String(name.prefix(60)) }
                            .onSubmit(rename)
                        Button("Rename", action: rename)
                            .buttonStyle(.dsOutline)
                            .disabled(name.trimmingCharacters(in: .whitespaces) == (thread.orgName ?? ""))
                    }
                } else {
                    Text(thread.orgName ?? "Org")
                        .font(DS.Fonts.title)
                        .foregroundStyle(DS.Colors.ink)
                        .lineLimit(1)
                        .help(thread.orgName ?? "Org")
                }
            }

            HStack {
                Text(thread.members.count == 1 ? "1 member" : "\(thread.members.count) members")
                    .font(DS.Fonts.label)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .monospacedDigit()
                Spacer()
                if thread.role != nil {
                    Button { showsAdd = true } label: {
                        Label("Add People…", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.dsGhost)
                }
            }

            List(thread.members, id: \.user.id) { member in
                memberRow(member)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 300)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))

            if thread.role != nil, let me = session.user?.asUser {
                Button("Leave Org", role: .destructive) {
                    Task {
                        await thread.remove(me)
                        dismiss()
                    }
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.bodyMedium)
                .foregroundStyle(DS.Colors.destructive)
            }
        }
        .padding(DS.Spacing.xl)
    }

    private func memberRow(_ member: Member) -> some View {
        let isLastMaintainer = member.role == .maintainer && maintainerCount == 1

        return HStack(spacing: 10) {
            Avatar(user: member.user, size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.user.id == session.user?.id ? "You" : member.user.displayName)
                    .font(DS.Fonts.bodyMedium)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Text("@" + member.user.username)
                    .font(DS.Fonts.monoHandle)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .lineLimit(1)
            }
            .help(member.user.displayName + " · @" + member.user.username)

            Spacer(minLength: DS.Spacing.m)

            if member.role == .maintainer {
                StatusLabel(text: "Maintainer")
            }

            if isMaintainer, member.user.id != session.user?.id {
                Menu {
                    if member.role == .maintainer {
                        Button("Make Contributor") { Task { await thread.setRole(.contributor, of: member.user) } }
                            .disabled(isLastMaintainer)
                            .help(isLastMaintainer ? "An org needs at least one maintainer. Make someone else a maintainer first." : "")
                    } else {
                        Button("Make Maintainer") { Task { await thread.setRole(.maintainer, of: member.user) } }
                    }
                    Button("Remove from Org", role: .destructive) { Task { await thread.remove(member.user) } }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(DS.Colors.inkMuted)
                }
                .menuStyle(.borderlessButton)
                .tint(DS.Colors.inkMuted)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(member.user.displayName)")
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func rename() {
        Task { await thread.rename(to: name.trimmingCharacters(in: .whitespaces)) }
    }
}
