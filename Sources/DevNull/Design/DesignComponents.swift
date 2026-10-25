import AppKit
import SwiftUI

// MARK: - Badges and pills

/// An unread count capped at 99+, with the exact count for VoiceOver and in the help tag. Muted conversations draw it
/// grey; on a filled selection it inverts to white so it stays readable.
struct CountBadge: View {
    @Environment(\.backgroundProminence) private var prominence
    let count: Int
    var muted = false

    var body: some View {
        let selected = prominence == .increased

        Text(count > DS.Metrics.badgeCap ? "\(DS.Metrics.badgeCap)+" : String(count))
            .font(DS.Fonts.monoBadge)
            .foregroundStyle(selected ? DS.Colors.primaryFill : DS.Colors.onPrimary)
            .padding(.horizontal, 6)
            .frame(minWidth: DS.Metrics.badgeHeight, minHeight: DS.Metrics.badgeHeight)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(selected ? Color.white.opacity(muted ? 0.75 : 1) : muted ? DS.Colors.inkFaint : DS.Colors.primaryFill)
            )
            .fixedSize()
            .help(count == 1 ? "1 unread message" : "\(count) unread messages")
            .accessibilityLabel("\(count) unread")
    }
}

/// Day headers, org events and floating hover groups: a pill that reads on the chat background in both appearances.
struct ServicePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Fonts.monoCaption)
            .foregroundStyle(DS.Colors.inkMuted)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.xs)
            .background(DS.Colors.servicePill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            // The pill shares the bubbles' fill, so the floating day header needs an edge to read over one.
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.Colors.hairline))
    }
}

/// A compact status label, like "Maintainer": 4pt corners, as the web draws status and count labels.
struct StatusLabel: View {
    let text: String
    var tint: Color = DS.Colors.inkMuted

    var body: some View {
        Text(text)
            .font(DS.Fonts.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xxs)
            .background(DS.Colors.wash, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .fixedSize()
    }
}

// MARK: - Buttons

/// The web's buttons: 6pt corners, 32pt (40pt large) tall, primary in Commit Blue, outline on the shell, ghost with no
/// fill until hover, destructive in Rm Red.
struct DSButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case outline
        case ghost
        case destructive
    }

    var kind: Kind = .primary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        DSButton(configuration: configuration, kind: kind, large: large)
    }

    private struct DSButton: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let kind: Kind
        let large: Bool

        var body: some View {
            configuration.label
                .font(large ? DS.Fonts.bodyMedium.weight(.semibold) : DS.Fonts.bodyMedium)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, large ? DS.Spacing.xl + 4 : DS.Spacing.l)
                .frame(minHeight: large ? DS.Metrics.controlHeightLarge : DS.Metrics.controlHeight)
                .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay {
                    if kind == .outline {
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.Colors.rail)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(DS.Motion.quick, value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary, .destructive: DS.Colors.onPrimary
            case .outline, .ghost: DS.Colors.ink
            }
        }

        private var background: Color {
            let active = isEnabled && (isHovered || configuration.isPressed)

            return switch kind {
            case .primary: active ? Color(nsColor: .dynamic(light: 0x2E5CCB, dark: 0x3560CC)) : DS.Colors.primaryFill
            case .outline: active ? DS.Colors.wash : DS.Colors.shell
            case .ghost: active ? DS.Colors.wash : .clear
            case .destructive: active ? DS.Colors.destructive.opacity(0.88) : Color(nsColor: .dynamic(light: 0xC92A2A, dark: 0xD64545))
            }
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsOutline: DSButtonStyle { DSButtonStyle(kind: .outline) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
}

/// A square icon button with the hover wash, for toolbars inside sheets, hover actions and the composer.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = DS.Metrics.iconButton
    var tint: Color = DS.Colors.inkMuted

    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration, size: size, tint: tint)
    }

    private struct IconButton: View {
        @State private var isHovered = false
        let configuration: Configuration
        let size: CGFloat
        let tint: Color

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(isHovered || configuration.isPressed ? DS.Colors.wash : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Lists

/// A quiet label above a group of rows.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DS.Fonts.label)
            .foregroundStyle(DS.Colors.inkMuted)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The web's empty state in the Mac's words: a mono `fatal:` line, one or two plain sentences, and at most one link.
struct EmptyState<Action: View>: View {
    let fatal: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            Text(fatal)
                .font(DS.Fonts.monoFatal)
                .foregroundStyle(DS.Colors.inkMuted)
            Text(message)
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            action()
        }
        .padding(DS.Spacing.xxl)
        .accessibilityElement(children: .combine)
    }
}

extension EmptyState where Action == EmptyView {
    init(fatal: String, message: String) {
        self.init(fatal: fatal, message: message) { EmptyView() }
    }
}

/// A link-styled button in Commit Blue, the single action an empty state may offer.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Fonts.bodyMedium)
            .foregroundStyle(configuration.isPressed ? DS.Colors.primaryHover : DS.Colors.primary)
            .contentShape(Rectangle())
    }
}

// MARK: - Loading

/// A placeholder bar for skeletons.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            .fill(DS.Colors.wash)
            .frame(width: width, height: height)
    }
}

/// Pulses a skeleton gently, and only shows it after `DS.Motion.skeletonDelay`, so fast loads never flash it. The
/// space stays reserved meanwhile.
struct SkeletonPresentation: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? (isDimmed ? 0.55 : 1) : 0)
            .task {
                try? await Task.sleep(for: DS.Motion.skeletonDelay)
                withAnimation(.easeOut(duration: 0.2)) { isVisible = true }

                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isDimmed = true }
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    func skeleton() -> some View {
        modifier(SkeletonPresentation())
    }
}

// MARK: - Fields

/// The chrome of a text field in sheets: a 1pt rail border inside 6pt corners that turns Commit Blue while focused,
/// instead of the system's outer focus ring, which clips against neighbors.
struct FieldChrome: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .focusEffectDisabled()
            .padding(.horizontal, DS.Spacing.m + 2)
            .padding(.vertical, DS.Spacing.m)
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(isFocused ? DS.Colors.primary : DS.Colors.rail)
            }
            .animation(DS.Motion.quick, value: isFocused)
    }
}

extension View {
    func fieldChrome() -> some View {
        modifier(FieldChrome())
    }
}

/// A borderless search field on the wash, as the web's command palette draws its input. Focus shows as a 1pt Commit
/// Blue border inside the field's own corners instead of the system's outer ring, which clips against sidebar edges.
/// Escape clears the text, then gives the focus back.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    /// When set, the field stays out of the window's initial focus and Tab loop (the sidebar's must never take the
    /// keyboard from the composer on launch) and focuses on a click or when this notification is posted.
    var focusedBy: Notification.Name?

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFocused ? DS.Colors.primary : DS.Colors.inkFaint)

            SearchTextField(prompt: prompt, text: $text, isFocused: $isFocused, focusedBy: focusedBy)

            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DS.Colors.inkFaint)
            }
            .buttonStyle(.plain)
            .opacity(text.isEmpty ? 0 : 1)
            .disabled(text.isEmpty)
            .help("Clear")
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, DS.Spacing.m + 2)
        .frame(height: DS.Metrics.controlHeight)
        .background(isFocused ? DS.Colors.popover : DS.Colors.wash, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(isFocused ? DS.Colors.primary : .clear, lineWidth: 1)
        }
        .animation(DS.Motion.quick, value: isFocused)
    }
}

/// The text part of `SearchField`: an AppKit field, so it can draw no focus ring and decline to be the window's first
/// key view while still focusing on a click.
private struct SearchTextField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusedBy: Notification.Name?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.placeholderAttributedString = NSAttributedString(string: prompt, attributes: [.foregroundColor: NSColor.dynamic(light: 0x8B919A, dark: 0x707075), .font: NSFont.systemFont(ofSize: 13)])
        field.setAccessibilityLabel(prompt)
        field.delegate = context.coordinator
        field.joinsKeyLoop = focusedBy == nil
        field.onFocus = { [weak field] in field.map(context.coordinator.syncFocus) }
        field.stringValue = text

        if let focusedBy {
            context.coordinator.observer = NotificationCenter.default.addObserver(forName: focusedBy, object: nil, queue: .main) { [weak field] _ in
                MainActor.assumeIsolated {
                    guard let field else { return }
                    if let editor = field.currentEditor() { editor.selectAll(nil) } else { field.window?.makeFirstResponder(field) }
                }
            }
        }

        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self

        if field.stringValue != text {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        coordinator.observer.map(NotificationCenter.default.removeObserver)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextField
        var observer: NSObjectProtocol?

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        /// Reads focus from the field itself once the responder change settles: ending and starting an edit arrive
        /// back to back when focus is asked for again, and only the final state counts.
        func syncFocus(_ field: NSTextField) {
            let binding = parent.$isFocused
            DispatchQueue.main.async { [weak field] in
                let focused = field?.currentEditor() != nil
                if binding.wrappedValue != focused { binding.wrappedValue = focused }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NSTextField).map(syncFocus)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }

            if control.stringValue.isEmpty {
                control.window?.makeFirstResponder(nil)
            } else {
                control.stringValue = ""
                parent.text = ""
            }

            return true
        }
    }

    final class Field: NSTextField {
        var joinsKeyLoop = true
        var onFocus: () -> Void = {}

        override var canBecomeKeyView: Bool { joinsKeyLoop && super.canBecomeKeyView }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus() }
            return became
        }
    }
}

// MARK: - Selection

/// The sidebar's selection, drawn by the app instead of the system: Commit Blue with white text while the window is
/// active, the Blue Wash (the web's "you are here") when it isn't, so the current conversation never turns a neutral
/// grey. Rows read `backgroundProminence` to switch their colors, as they would on a system selection.
struct SidebarSelection: ViewModifier {
    @Environment(\.controlActiveState) private var activeState
    let isSelected: Bool

    func body(content: Content) -> some View {
        let isFilled = isSelected && activeState != .inactive

        content
            .environment(\.backgroundProminence, isFilled ? .increased : .standard)
            .listRowBackground(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(isSelected ? (isFilled ? DS.Colors.primaryFill : DS.Colors.primarySoft) : .clear)
                    .padding(.horizontal, DS.Metrics.sidebarInset)
            )
    }
}

extension View {
    func sidebarSelection(_ isSelected: Bool) -> some View {
        modifier(SidebarSelection(isSelected: isSelected))
    }

    /// Turns off the system's selection highlight of the list this view sits in, for lists that draw their own.
    func hidesSystemSelection() -> some View {
        background(SystemSelectionRemover())
    }
}

/// Finds the `NSTableView` behind a SwiftUI `List` and stops it from drawing its own selection; selection itself,
/// keyboard navigation and accessibility keep working.
private struct SystemSelectionRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var ancestor = view.superview

            while let current = ancestor {
                if let table = Self.table(in: current) {
                    table.selectionHighlightStyle = .none
                    return
                }

                ancestor = current.superview
            }
        }
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }

        for subview in view.subviews {
            if let table = table(in: subview) { return table }
        }

        return nil
    }
}
