import SwiftUI

/// The bottom-center toast: git-speak in mono on the popover surface, with its action (Undo) when it has one.
struct ToastView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toasts = workspace.toasts

        ZStack {
            if let toast = toasts.current {
                // The toast hugs its text, and only truncates once it would pass 460pt.
                ViewThatFits(in: .horizontal) {
                    content(toast).fixedSize()
                    content(toast)
                }
                .padding(.horizontal, DS.Spacing.l)
                .padding(.vertical, DS.Spacing.m)
                .frame(maxWidth: 460)
                .background(DS.Colors.popover, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))
                .elevation(DS.Elevation.popover)
                .onHover { toasts.isHovered = $0 }
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
                .id(toast.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(DS.Motion.respecting(reduceMotion, DS.Motion.standard), value: toasts.current?.id)
    }

    private func content(_ toast: Toast) -> some View {
        HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.text)
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = toast.detail {
                    Text(detail)
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .lineLimit(2)
                }
            }

            if let action = toast.action {
                Button(action.title) { workspace.toasts.performAction() }
                    .buttonStyle(LinkButtonStyle())
                    .font(DS.Fonts.monoCaption)
            }
        }
    }
}
