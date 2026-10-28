import SwiftUI

/// The `.inspector`: a commit's thread beside a list of commits, or the info of the remote in the center.
struct RepliesPane: View {
    @Environment(Navigation.self) private var navigation
    @Environment(Inbox.self) private var inbox

    var body: some View {
        Group {
            switch navigation.pane {
            case let .thread(id):
                ThreadPane(commitId: id)
                    .id(id)
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            case .info:
                if case let .remote(reference) = navigation.item {
                    InfoPane(thread: inbox.thread(for: reference))
                        .id(reference.id)
                }
            case nil:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.surface)
    }
}

/// The 44pt head every pane mode shares: a title, mono detail, muted context and a close button (Esc).
struct PaneHeader<Detail: View>: View {
    @Environment(Navigation.self) private var navigation
    let title: String
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Text(title)
                .font(DS.Fonts.bodyMedium.weight(.semibold))
                .foregroundStyle(DS.Colors.ink)
            detail()
            Spacer(minLength: DS.Spacing.s)
            Button {
                navigation.closePane()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, DS.Spacing.l)
        .frame(height: 44)
        .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1) }
    }
}

/// What the info sheet held, laid out as a pane beside the chat.
struct InfoPane: View {
    let thread: ThreadModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: thread.isOrg ? "Org details" : "Info") { EmptyView() }
            ScrollView {
                ThreadInfoView(thread: thread, isPane: true)
            }
        }
    }
}
