import AppKit
import SwiftUI

/// The About window, in place of the standard panel: what the app is, which build this is and whether a newer one is
/// out, where to go on the web, what it keeps on this Mac, and who made it.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        let window = window ?? make()
        self.window = window

        #if DEBUG
            // The preview is driven from a script and never takes focus from the app in front.
            if Preview.isEnabled {
                window.orderFrontRegardless()
                return
            }
        #endif

        window.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "About /dev/null"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let controller = NSHostingController(rootView: AboutView())
        controller.sizingOptions = [.preferredContentSize]
        window.contentViewController = controller
        window.center()

        return window
    }
}

struct AboutView: View {
    private let updates = Updates.shared
    private let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, DS.Spacing.xxxl + DS.Spacing.s)
                .padding(.bottom, DS.Spacing.xl)

            #if !APP_STORE
                UpdateStatus(updates: updates)
                    .padding(.bottom, DS.Spacing.xl)
            #endif

            Divider().overlay(DS.Colors.hairline)

            links
                .padding(.vertical, DS.Spacing.l)

            Divider().overlay(DS.Colors.hairline)

            privacy
                .padding(.vertical, DS.Spacing.l)

            Divider().overlay(DS.Colors.hairline)

            credits
                .padding(.top, DS.Spacing.l)
                .padding(.bottom, DS.Spacing.xl)
        }
        .padding(.horizontal, DS.Spacing.xxl)
        .frame(width: width + DS.Spacing.xxl * 2)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Colors.shell)
        .tint(DS.Colors.primaryFill)
    }

    private var header: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Wordmark()
                .accessibilityAddTraits(.isHeader)

            Text(versionLine)
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
                .textSelection(.enabled)
                .accessibilityLabel(versionLabel)

            Text("Remotes and orgs from /dev/null, native on your Mac.")
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Spacing.xs)
        }
    }

    /// `1.0.0 (1234) · a003e08`, as `git describe` would print it.
    private var versionLine: String {
        "\(Updates.version) (\(Updates.build))" + (Updates.revision.map { " · \($0)" } ?? "")
    }

    private var versionLabel: String {
        "Version \(Updates.version), build \(Updates.build)" + (Updates.revision.map { ", commit \($0)" } ?? "")
    }

    private var links: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Spacing.xl, verticalSpacing: DS.Spacing.s) {
            GridRow {
                AboutLink(title: "dev-null.sh", symbol: "globe", url: APIClient.baseURL)
                AboutLink(title: "Apps", symbol: "square.grid.2x2", url: APIClient.baseURL.appending(path: "apps"))
            }
            GridRow {
                AboutLink(title: "Privacy", symbol: "hand.raised", url: APIClient.baseURL.appending(path: "privacy"))
                AboutLink(title: "Manage Devices", symbol: "laptopcomputer", url: APIClient.baseURL.appending(path: "settings/devices"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var privacy: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            Image(systemName: "lock")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.inkMuted)
                .accessibilityHidden(true)

            Text("This Mac's device key stays in your Keychain, and banners never show what a message says. Messages and images are kept in memory only: besides a few preferences, nothing is saved on this Mac.")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.inkMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var credits: some View {
        VStack(spacing: DS.Spacing.s) {
            Text("Made with ♥ by Nuno Maduro and the /dev/null contributors.")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Made with love by Nuno Maduro and the /dev/null contributors.")

            HStack(spacing: DS.Spacing.l) {
                Link("Source on GitHub", destination: URL(string: "https://github.com/dev-null-sh/dev-null.sh")!)
                Text("·").foregroundStyle(DS.Colors.inkFaint).accessibilityHidden(true)
                Link("Contributors", destination: APIClient.baseURL.appending(path: "about"))
            }
            .font(DS.Fonts.caption)
        }
    }
}

/// One of the About window's links: a line icon and a label in Commit Blue, opening the page in the browser.
private struct AboutLink: View {
    let title: String
    let symbol: String
    let url: URL

    @State private var isHovered = false

    var body: some View {
        Link(destination: url) {
            Label {
                Text(title).underline(isHovered, color: DS.Colors.primary.opacity(0.5))
            } icon: {
                Image(systemName: symbol).frame(width: 16)
            }
            .font(DS.Fonts.body)
            .foregroundStyle(DS.Colors.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.absoluteString)
        .accessibilityHint("Opens \(url.host() ?? "the page") in your browser")
    }
}

/// The update check's answer, in one fixed-height line, so checking never moves the window's contents.
private struct UpdateStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let updates: Updates

    var body: some View {
        ZStack {
            switch updates.status {
            case .unknown:
                Button("Check for Updates") { Task { await updates.check(unlessCheckedWithin: 0) } }
                    .buttonStyle(.dsOutline)
            case .checking:
                HStack(spacing: DS.Spacing.m) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…")
                }
                .accessibilityElement(children: .combine)
            case .current:
                Label("You're up to date.", systemImage: "checkmark.circle")
            case let .available(release):
                Button("Update to /dev/null \(release.version)") { updates.update(to: release) }
                    .buttonStyle(.dsPrimary)
                    .accessibilityHint("Downloads and installs it, then reopens /dev/null")
            case .installing:
                HStack(spacing: DS.Spacing.m) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                }
                .accessibilityElement(children: .combine)
            case .failed:
                HStack(spacing: DS.Spacing.m) {
                    Text("Couldn't reach dev-null.sh.")
                    Button("Try Again") { Task { await updates.check(unlessCheckedWithin: 0) } }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        }
        .font(DS.Fonts.body)
        .foregroundStyle(DS.Colors.inkMuted)
        .frame(height: DS.Metrics.controlHeight)
        .animation(DS.Motion.respecting(reduceMotion, DS.Motion.quick), value: updates.status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Updates")
    }
}
