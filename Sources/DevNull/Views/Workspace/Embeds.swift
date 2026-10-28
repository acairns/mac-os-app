import AppKit
import SwiftUI

/// What a commit carries under its text, in the web's order: images, the link card, the quoted commit, the poll.
struct CommitEmbeds: View {
    let commit: Commit
    var allowsQuote = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if let images = commit.images, !images.isEmpty {
                CommitImageGrid(images: images, author: commit.author?.displayName ?? "", date: commit.createdAt ?? .now)
            }

            if let preview = commit.linkPreview, preview.isPending != true, preview.title != nil {
                CommitLinkCard(preview: preview)
            }

            if allowsQuote, let quoted = commit.quotedCommit?.value {
                QuoteEmbed(commit: quoted)
            }

            if let poll = commit.poll {
                PollView(commitId: commit.id, poll: poll)
            }
        }
        .frame(maxWidth: DS.Metrics.readingMeasure, alignment: .leading)
    }
}

/// The hairline box every embed shares: radius `lg`, 8/10 padding, `wash` on hover when it is a button.
private struct EmbedBox: ViewModifier {
    var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? DS.Colors.wash : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }
}

/// A quoted commit: one button to its commit page. It never nests a second quote.
struct QuoteEmbed: View {
    /// None in the composer window, where the quote only shows what will be quoted.
    @Environment(Navigation.self) private var navigation: Navigation?
    let commit: Commit

    @State private var isHovered = false

    var body: some View {
        Button {
            navigation?.push(.commit(commit.id))
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if commit.isTombstone {
                    Text("[deleted]")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                } else {
                    HStack(spacing: DS.Spacing.s) {
                        Avatar(user: commit.author, size: 20)
                        Text(commit.author?.displayName ?? "")
                            .font(DS.Fonts.commitAuthor)
                            .foregroundStyle(DS.Colors.ink)
                            .lineLimit(1)
                        Text("@\(commit.author?.handle ?? "") · \(Formatting.relative(commit.createdAt))")
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(DS.Colors.inkMuted)
                            .lineLimit(1)
                    }

                    Text(commit.text)
                        .font(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.ink)
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                }
            }
            .modifier(EmbedBox(isHovered: isHovered))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Quoted commit by \(commit.author?.displayName ?? "someone"): \(commit.text)")
    }
}

/// A link's card: the URL in mono, the title, and the page's image on the trailing side.
struct CommitLinkCard: View {
    @Environment(\.openURL) private var openURL
    let preview: LinkPreview

    @State private var isHovered = false

    var body: some View {
        Button {
            if let url = URL(string: preview.url) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(URL(string: preview.url)?.host() ?? preview.url)
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .lineLimit(1)
                    Text(preview.title ?? preview.url)
                        .font(DS.Fonts.bodyMedium)
                        .foregroundStyle(DS.Colors.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let description = preview.description {
                        Text(description)
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.inkMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let image = preview.imageUrl.flatMap(URL.init(string:)) {
                    RemoteImage(url: image) { DS.Colors.wash }
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                }
            }
            .modifier(EmbedBox(isHovered: isHovered))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(preview.url)
        .accessibilityLabel("Link: \(preview.title ?? preview.url)")
    }
}

/// The web's image grid: one, two or three tiles with 8pt corners and 2pt gaps, opening in the lightbox.
struct CommitImageGrid: View {
    let images: [CommitImage]
    let author: String
    let date: Date

    var body: some View {
        Group {
            switch images.count {
            case 1:
                tile(images[0])
                    .aspectRatio(ratio(images[0]), contentMode: .fit)
                    .frame(maxHeight: 420, alignment: .leading)
            case 2:
                HStack(spacing: 2) {
                    tile(images[0])
                    tile(images[1])
                }
                .frame(height: 240)
            default:
                HStack(spacing: 2) {
                    tile(images[0])
                    VStack(spacing: 2) {
                        tile(images[1])
                        tile(images[2])
                    }
                }
                .frame(height: 280)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }

    private func ratio(_ image: CommitImage) -> CGFloat {
        guard let width = image.width, let height = image.height, height > 0 else { return 4 / 3 }

        return max(0.6, min(2.4, CGFloat(width) / CGFloat(height)))
    }

    private func tile(_ image: CommitImage) -> some View {
        Button {
            open(image)
        } label: {
            Color.clear
                .overlay {
                    RemoteImage(url: URL(string: image.url)) { DS.Colors.wash }
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ImageAnchor(id: image.id))
        .accessibilityLabel(image.description.map { "Image: \($0)" } ?? "Image")
        .help(image.description ?? "")
    }

    private func open(_ image: CommitImage) {
        let items = images.map { LightboxItem(image: MessageImage(id: $0.id, width: $0.width, height: $0.height, description: $0.description, url: $0.url), sender: author, date: date) }

        guard let index = items.firstIndex(where: { $0.id == image.id }) else { return }

        Lightbox.present(items, index: index, over: NSApp.keyWindow ?? NSApp.mainWindow)
    }
}

/// A poll: options as bars with the percentage and count in mono once results show, a click to vote while it is open.
struct PollView: View {
    @Environment(Workspace.self) private var workspace
    let commitId: String
    let poll: Poll

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(poll.options) { option in
                if poll.showsResults || poll.isClosed {
                    result(option)
                } else {
                    Button {
                        workspace.vote(commitId, option: option.id)
                    } label: {
                        Text(option.label)
                            .font(DS.Fonts.bodyMedium)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.dsOutline)
                    .accessibilityLabel("Vote for \(option.label)")
                }
            }

            Text(footer)
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func result(_ option: PollOption) -> some View {
        let percentage = option.percentage ?? 0

        return HStack(spacing: DS.Spacing.m) {
            Text(option.label)
                .font(DS.Fonts.body.weight(option.voted ? .semibold : .regular))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
            if option.voted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.primary)
                    .accessibilityLabel("Your vote")
            }
            Spacer(minLength: DS.Spacing.m)
            Text("\(percentage)% · \(option.votesCount ?? 0)")
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
        }
        .padding(.horizontal, DS.Spacing.m)
        .frame(height: 28)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(option.voted ? DS.Colors.primarySoft : DS.Colors.wash)
                    .frame(width: proxy.size.width * CGFloat(percentage) / 100)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: String {
        let votes = poll.totalVotes.map { "\($0) vote\($0 == 1 ? "" : "s")" } ?? "votes hidden until you vote"

        guard !poll.isClosed, let closesAt = poll.closesAt else { return "\(votes) · final results" }

        let seconds = max(0, closesAt.timeIntervalSinceNow)
        let left = seconds >= 86400 ? "\(Int(seconds / 86400))d" : seconds >= 3600 ? "\(Int(seconds / 3600))h" : "\(max(1, Int(seconds / 60)))m"

        return "\(votes) · \(left) left"
    }
}
