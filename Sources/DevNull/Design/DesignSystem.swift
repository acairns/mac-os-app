import AppKit
import SwiftUI

/// The Mac app's design system: /dev/null's web tokens (DESIGN.md) translated to AppKit and SwiftUI, so every screen
/// draws from one palette, one type scale and one set of metrics instead of ad hoc numbers.
///
/// The register follows the web: a cool near-white shell (graphite in dark), flat surfaces cut by hairlines, one blue
/// that means "you can act here" or "you are here", and six lane colors that only ever mark a person. The system font
/// (SF) replaces Geist, one step smaller than the web's pixel sizes because macOS reads 13pt as body; SF Mono replaces
/// Geist Mono for what a machine would print (handles, times, counts), as the web's "Machine Speaks Mono" rule asks.
///
/// # Chat surfaces (spec for ChatView, MessageRow, MessageList, Composer, Lightbox, MessageMenu)
///
/// Those files belong to another engineer; this is what they should converge on, using only the tokens below.
///
/// - **Background:** `DS.Colors.chat` (wash in light, shell in dark). No wallpaper, no gradient.
/// - **Bubbles:** outgoing `DS.Colors.bubbleOutgoing` with `DS.Colors.onPrimary` text, incoming `DS.Colors.bubbleIncoming`
///   with `DS.Colors.ink` text. Corner radius `DS.Radius.bubble` (14); the corner nearest the sender's edge on the last
///   bubble of a run drops to `DS.Radius.bubbleTail` (4) instead of drawing a tail. Padding `DS.Metrics.bubblePadding`
///   (7 vertical, 11 horizontal). Max width `DS.Metrics.bubbleMaxWidth` (520) or 72% of the column, whichever is less.
///   Body `DS.Fonts.chatBody` (14). Runs from the same sender within 2 minutes stack `DS.Spacing.xxs` (2) apart;
///   new runs `DS.Spacing.m` (8). Incoming bubbles get a hairline border in light mode only (`DS.Colors.hairline`),
///   never a shadow (No Cards Rule).
/// - **Meta inside the bubble:** time and receipt bottom-right in `DS.Fonts.monoMeta` (10.5, tabular), at 70% of the
///   bubble's text color. Receipts stay `ReceiptMark(state:)` (MessageRow.swift), which the inbox row reuses so both
///   places draw the same glyph; tint pulled with `DS.Colors.primary` on incoming-colored meta.
/// - **Sender names in orgs:** `DS.Fonts.rowTitle` sized 12.5 semibold in the sender's `LaneColor` (lanes are identity).
/// - **Day pills and org events:** `ServicePill` (`DS.Colors.servicePill`, `DS.Fonts.monoCaption`, radius
///   `DS.Radius.md`), sticky at the top while scrolling, fading in 120ms. Copy stays dry: "Today", "Tue, Oct 13".
/// - **Reactions:** chips of `DS.Metrics.reactionHeight` (22) with radius `DS.Radius.md`; others' reactions on
///   `DS.Colors.bubbleInset` (inside incoming) or white 18% (inside outgoing); the user's own on `DS.Colors.primarySoft` with a
///   1pt `DS.Colors.primary` stroke. Counts in `DS.Fonts.monoCaption`, tabular, in a fixed-width slot.
/// - **Hover actions:** a `ServicePill`-backed group of `IconButtonStyle` buttons (24pt), overlaid beside the bubble so
///   hovering never moves text; appear with `DS.Motion.quick`, no delay on show, 150ms grace on hide.
/// - **Scroll-to-bottom button:** 36pt circle on `DS.Colors.popover`, `DS.Elevation.floating`, chevron in
///   `DS.Colors.inkMuted`, the unread count as a `CountBadge` pinned to its top edge. Offset 16pt from the trailing
///   edge and the composer; slides up 8pt and fades with `DS.Motion.standard`.
/// - **Composer:** a `DS.Colors.surface` bar with a top hairline; the field itself is borderless (web: no field chrome),
///   `DS.Fonts.composer` (15), min height 36, grows to 8 lines then scrolls. Icon buttons 28pt in `DS.Colors.inkMuted`,
///   send in `DS.Colors.primary`. Reply/edit previews sit in a 40pt reserved strip with a 2pt `DS.Colors.primary` bar.
/// - **Typing:** `TypingDots(color: DS.Colors.primary, size: 4)` beside "typing" in `DS.Fonts.preview`, same as the
///   inbox row, so both places animate in step.
/// - **Lightbox:** a black 92% backdrop in both appearances; chrome (close, save, counter) on a `DS.Colors.popover`
///   capsule-free bar with radius `DS.Radius.lg`, counter in `DS.Fonts.monoCaption`. Opens with `DS.Motion.standard`
///   scaling from the thumbnail; respects Reduce Motion with a crossfade.
/// - **Menus:** native `NSMenu`/`Menu`, destructive items with `role: .destructive`.
enum DS {
    // MARK: Colors

    /// Colors as dynamic `NSColor`s, so they resolve per appearance in AppKit and SwiftUI alike.
    enum Colors {
        /// Page background: the sign-in screen, settings and sheets.
        static let shell = Color(nsColor: .dynamic(light: 0xF6F7F8, dark: 0x111112))
        /// The sidebar and anything that sits on the shell as a column.
        static let surface = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x18181A))
        /// Floating things: popovers, the scroll-down button, pickers.
        static let popover = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x1F1F22))
        /// Hover, pressed and placeholder fills.
        static let wash = Color(nsColor: .dynamic(light: 0xEEF0F2, dark: 0x232326))
        /// Every divider.
        static let hairline = Color(nsColor: .dynamic(light: 0xE1E4E8, dark: 0x2A2A2D))
        /// Input strokes, skeleton bars and the stronger rule.
        static let rail = Color(nsColor: .dynamic(light: 0xD3D7DD, dark: 0x36363A))

        static let ink = Color(nsColor: .dynamic(light: 0x121417, dark: 0xECECEC))
        static let inkMuted = Color(nsColor: .dynamic(light: 0x5B616B, dark: 0xA1A1A6))
        /// Glyphs that only decorate (pin, muted bell): quieter than muted ink, still 3:1 on the surface.
        static let inkFaint = Color(nsColor: .dynamic(light: 0x8B919A, dark: 0x707075))

        /// Commit Blue for text, icons, links and focus.
        static let primary = Color(nsColor: .dynamic(light: 0x3B6FE0, dark: 0x7AA2F7))
        static let primaryHover = Color(nsColor: .dynamic(light: 0x2E5CCB, dark: 0x94B5F9))
        /// Commit Blue as a fill under white text: the web's dark primary is too light for white, so dark mode uses a
        /// deeper blue that keeps 4.5:1 with white (badges, selection, the primary button, outgoing bubbles).
        static let primaryFill = Color(nsColor: .primaryFill)
        static let primarySoft = Color(nsColor: .dynamic(light: 0xE8EFFC, dark: 0x18233A))
        static let onPrimary = Color.white
        static let destructive = Color(nsColor: .dynamic(light: 0xC92A2A, dark: 0xFF6B6B))

        /// The sidebar when the system's vibrant material is off (Increase Contrast, Reduce Transparency), and what
        /// stacked avatars knock out against there.
        static let sidebar = Color(nsColor: .dynamic(light: 0xF1F2F4, dark: 0x1C1C1F))
        /// The commit row whose thread is open in the replies pane.
        static let selectionSoft = primarySoft
        /// The focus ring and keyboard focus.
        static let focusRing = Color(nsColor: .primaryFill).opacity(0.5)
        /// Moderation status labels on the user's own pending or rejected commits, always beside a word: lane 1's green
        /// and lane 5's ochre, never marking a person.
        static let success = lane(1)
        static let warning = lane(5)

        static let chat = Color(nsColor: .dynamic(light: 0xEEF0F2, dark: 0x111112))
        static let bubbleOutgoing = Color(nsColor: .dynamic(light: 0x3B6FE0, dark: 0x2F5BC4))
        static let bubbleIncoming = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x232326))
        /// A fill set into an incoming bubble (others' reaction chips, inline code): the wash in light, a step above
        /// the bubble in dark, where the wash is the bubble's own color.
        static let bubbleInset = Color(nsColor: .dynamic(light: 0xEEF0F2, dark: 0x303034))
        static let servicePill = Color(nsColor: .dynamic(light: 0xFFFFFF, dark: 0x232326, alpha: 0.92))

        /// Author lanes, only ever marking a person.
        static let lanesLight: [Int] = [0xD9480F, 0x2F9E44, 0x9C36B5, 0x0C8599, 0xC2255C, 0xB7791F]
        static let lanesDark: [Int] = [0xFF8A4C, 0x51CF66, 0xDA77F2, 0x3BC9DB, 0xF06595, 0xFCC419]

        static func lane(_ index: Int) -> Color {
            let index = ((index % 6) + 6) % 6

            return Color(nsColor: .dynamic(light: lanesLight[index], dark: lanesDark[index]))
        }
    }

    // MARK: Typography

    /// The web's scale mapped onto SF, one step down: web 15px body reads as 13–14pt on the Mac.
    enum Fonts {
        /// The wordmark on the sign-in screen.
        static let display = Font.system(size: 30, weight: .bold).width(.standard)
        /// A person's or an org's name in its info sheet.
        static let title = Font.system(size: 20, weight: .semibold)
        /// Sheet titles and empty-state sentences.
        static let section = Font.system(size: 15, weight: .semibold)
        /// Names in inbox and people rows.
        static let rowTitle = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        /// The inbox's message preview.
        static let preview = Font.system(size: 13)
        static let chatBody = Font.system(size: 14)
        /// A sender's name over their bubbles in an org, in their lane color.
        static let senderName = Font.system(size: 12.5, weight: .semibold)
        /// Reply ghosts, link cards and the composer's reply bar: a strong first line over a plain second.
        static let chatCaption = Font.system(size: 12)
        static let chatCaptionStrong = Font.system(size: 12, weight: .semibold)
        /// Code blocks inside bubbles.
        static let code = Font.system(size: 12, design: .monospaced)
        static let composer = Font.system(size: 15)
        static let caption = Font.system(size: 11)
        /// Section labels above lists ("Start a conversation").
        static let label = Font.system(size: 11, weight: .semibold)
        /// Handles: `@maya`.
        static let monoHandle = Font.system(size: 12, design: .monospaced)
        /// Times in the inbox, day pills, counters.
        static let monoCaption = Font.system(size: 11, design: .monospaced).monospacedDigit()
        static let monoMeta = Font.system(size: 10.5, design: .monospaced).monospacedDigit()
        static let monoBadge = Font.system(size: 11, weight: .semibold, design: .monospaced).monospacedDigit()
        /// `fatal:` lines in empty states.
        static let monoFatal = Font.system(size: 12, weight: .medium, design: .monospaced)

        /// Commit bodies in the log, Starred, profiles and search; set with `commitLineSpacing`.
        static let commitBody = Font.system(size: 14)
        /// The commit at the top of the replies pane and on the commit page; set with `commitLineSpacing`.
        static let threadBody = Font.system(size: 15)
        static let replyBody = Font.system(size: 13.5)
        static let commitLineSpacing: CGFloat = 3
        /// The author's name in a commit header.
        static let commitAuthor = Font.system(size: 13, weight: .semibold)
        static let sidebarItem = Font.system(size: 13)
        static let sidebarItemUnread = Font.system(size: 13, weight: .semibold)
        /// "Logs", "Remotes", "You", in `inkFaint`.
        static let sidebarSection = Font.system(size: 11.5, weight: .semibold)
        /// The "/dev/null" workspace name, tracked −0.5.
        static let workspace = Font.system(size: 16, weight: .bold)
        static let toolbarTitle = Font.system(size: 13.5, weight: .semibold)
        static let profileName = title
    }

    // MARK: Spacing, radii, metrics

    /// A 2pt-based spacing scale; the web's 12px row padding and 16px gutter map to `l` and `xl`.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    /// The web's soft-but-small corners: 4 for compact labels, 6 for controls and badges, 8 for groups and overlays.
    /// Bubbles are the one larger radius, because a message is not a card but needs to read as one utterance.
    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
        static let xl: CGFloat = 12
        static let bubble: CGFloat = 14
        static let bubbleTail: CGFloat = 4
    }

    enum Metrics {
        static let avatarRow: CGFloat = 50
        /// The inbox row's content height: a name line and two preview lines next to a 50pt avatar, fixed so typing,
        /// drafts and one-line previews never change the row's height.
        static let rowHeight: CGFloat = 52
        static let rowPadding: CGFloat = 6
        /// How far the sidebar's search field and selected row sit from its edges, so their edges line up.
        static let sidebarInset: CGFloat = 10
        static let badgeHeight: CGFloat = 20
        /// Count badges show at most this; the exact number stays in the accessibility label and the help tag.
        static let badgeCap = 99
        static let controlHeight: CGFloat = 32
        static let controlHeightLarge: CGFloat = 40
        static let iconButton: CGFloat = 28
        static let bubblePadding = EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11)
        static let bubbleMaxWidth: CGFloat = 520
        /// The thread's side gutter, and the org avatar beside the last bubble of a run with its gap: what everything
        /// that lines up with bubbles (receipts, typing) offsets by.
        static let chatGutter: CGFloat = 12
        static let chatAvatar: CGFloat = 32
        static let chatAvatarGap: CGFloat = 6
        static let reactionHeight: CGFloat = 22

        // The workspace: the graph rail, commit rows, the sidebar and the overlays.

        /// The rail column of every commit row.
        static let railWidth: CGFloat = 44
        static let railLine: CGFloat = 2
        /// A graph node: a 2pt lane ring around a shell hole.
        static let node: CGFloat = 14
        /// The node's top in a commit row, so its center sits at y = 22, level with the avatar's.
        static let nodeTop: CGFloat = 15
        static let commitAvatar: CGFloat = 36
        static let threadAvatar: CGFloat = 40
        static let replyAvatar: CGFloat = 28
        /// The hollow node of a notification, holding a 14pt type icon.
        static let notificationNode: CGFloat = 32
        static let sidebarRow: CGFloat = 28
        static let sidebarAvatar: CGFloat = 18
        /// Commit text never runs wider than this, however wide the column.
        static let readingMeasure: CGFloat = 640
        static let commitGutter: CGFloat = 16
        /// The body and actions sit under the name: the 36pt avatar and its 8pt gap.
        static let bodyIndent: CGFloat = 44
        static let previewWidth: CGFloat = 304
        static let switcherWidth: CGFloat = 560
        static let activityCell: CGFloat = 10
        static let activityGap: CGFloat = 2
    }

    // MARK: Motion

    /// The web's motion translated to springs: snappy for hover and press, the 220ms expo-out for anything that slides.
    enum Motion {
        static let quick = Animation.snappy(duration: 0.16)
        static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// The web's sliding nav background and tab underline (220ms, expo-out).
        static let slide = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.22)
        /// Skeletons wait this long so fast loads show nothing.
        static let skeletonDelay: Duration = .milliseconds(300)

        /// The animation to use, or none when Reduce Motion is on.
        static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
            reduceMotion ? nil : animation
        }
    }

    // MARK: Elevation

    /// Flat by default (the web has no shadows); only things that float over content get one, kept soft.
    enum Elevation {
        struct Shadow {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }

        static let floating = Shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        static let popover = Shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }
}

extension View {
    func elevation(_ shadow: DS.Elevation.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(light: Int, dark: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: alpha) : NSColor(hex: light, alpha: alpha)
        }
    }

    static let primaryFill = NSColor.dynamic(light: 0x3B6FE0, dark: 0x3E6AD6)
}

#if DEBUG
    /// Lets the preview app be forced into one appearance (`-PreviewAppearance light|dark`), since the system ignores
    /// appearance overrides passed at launch. Never active outside the preview bundle.
    enum PreviewAppearance {
        @MainActor static func apply() {
            guard Preview.isEnabled, let value = UserDefaults.standard.string(forKey: "PreviewAppearance") else { return }

            NSApp.appearance = NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
        }
    }
#endif
