import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where each image tile of the open thread is on screen, so the lightbox zooms out of the tile and back into it.
@MainActor
final class ImageAnchors {
    static let shared = ImageAnchors()

    private let views = NSMapTable<NSString, AnchorView>.strongToWeakObjects()

    func register(_ id: String, _ view: AnchorView) {
        views.setObject(view, forKey: id as NSString)
    }

    /// The tile's rect in screen coordinates, when it is on screen and not scrolled out of view.
    func screenRect(_ id: String) -> CGRect? {
        guard let view = views.object(forKey: id as NSString), view.imageId == id, let window = view.window, window.isVisible else { return nil }

        let visible = view.visibleRect

        guard visible.width > view.bounds.width * 0.5, visible.height > view.bounds.height * 0.5 else { return nil }

        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

final class AnchorView: NSView {
    var imageId = ""

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Marks where an image tile is, for the lightbox.
struct ImageAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.imageId = id
        ImageAnchors.shared.register(id, view)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        guard view.imageId != id else { return }

        view.imageId = id
        ImageAnchors.shared.register(id, view)
    }
}

/// An image the lightbox can show, with who sent it and when.
struct LightboxItem: Identifiable, Equatable {
    let image: MessageImage
    let sender: String
    let date: Date

    var id: String { image.id }
}

@MainActor
@Observable
final class LightboxModel {
    let items: [LightboxItem]
    var index: Int
    var expanded = false
    var zoomed = false

    @ObservationIgnored var close: () -> Void = {}

    init(items: [LightboxItem], index: Int) {
        self.items = items
        self.index = index
    }

    var current: LightboxItem { items[index] }

    func move(_ step: Int) {
        let next = index + step

        guard items.indices.contains(next) else { return }

        zoomed = false
        index = next
    }
}

/// The image viewer, like Telegram's: a borderless window over the chat that zooms the image out of its thumbnail,
/// moves between the thread's images with the arrow keys, saves with ⌘S and copies with ⌘C, and zooms back into the
/// thumbnail on Escape.
@MainActor
enum Lightbox {
    private static var panel: LightboxPanel?

    static func present(_ items: [LightboxItem], index: Int, over window: NSWindow?) {
        guard let window, panel == nil, items.indices.contains(index) else { return }

        let model = LightboxModel(items: items, index: index)
        let panel = LightboxPanel(contentRect: window.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.model = model
        panel.contentView = NSHostingView(rootView: LightboxView(model: model, frameInWindow: { id in
            guard let rect = ImageAnchors.shared.screenRect(id) else { return nil }
            return CGRect(x: rect.minX - window.frame.minX, y: window.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }))

        model.close = { [weak panel] in
            guard let panel, model.expanded else { return }

            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.expanded = false }

            Task {
                try? await Task.sleep(for: .milliseconds(300))
                window.removeChildWindow(panel)
                panel.orderOut(nil)
                Self.panel = nil
                window.makeKey()
            }
        }

        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        Self.panel = panel

        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { model.expanded = true }
        }
    }
}

final class LightboxPanel: NSPanel {
    var model: LightboxModel?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }

        let command = event.modifierFlags.contains(.command)

        switch (event.keyCode, command, event.charactersIgnoringModifiers) {
        case (123, false, _): model.move(-1)
        case (124, false, _): model.move(1)
        case (53, _, _), (49, false, _): model.close()
        case (_, true, "s"): LightboxActions.save(model.current.image)
        case (_, true, "c"): LightboxActions.copy(model.current.image)
        case (_, true, "w"): model.close()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        model?.close()
    }
}

enum LightboxActions {
    @MainActor static func save(_ image: MessageImage) {
        guard let url = URL(string: image.url) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "image.png"
        panel.allowedContentTypes = [.png]

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            if let nsImage = await ImageLoader.shared.load(url),
               let tiff = nsImage.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: destination)
            }
        }
    }

    @MainActor static func copy(_ image: MessageImage) {
        guard let url = URL(string: image.url) else { return }

        Task {
            if let nsImage = await ImageLoader.shared.load(url) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([nsImage])
            }
        }
    }
}

struct LightboxView: View {
    @Bindable var model: LightboxModel
    let frameInWindow: (String) -> CGRect?

    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let item = model.current
            let target = fitted(item, in: geometry.size)
            let source = frameInWindow(item.id)
            let frame = model.expanded ? target : source ?? target.insetBy(dx: target.width * 0.06, dy: target.height * 0.06)

            ZStack {
                Color.black
                    .opacity(model.expanded ? 0.92 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }

                RemoteImage(url: URL(string: item.image.url), contentMode: .fill) {
                    Rectangle().fill(.white.opacity(0.06))
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: model.expanded ? 2 : 10))
                .position(x: frame.midX, y: frame.midY)
                .opacity(model.expanded || source != nil ? 1 : 0)
                .id(item.id)
                .transition(.opacity)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { model.zoomed.toggle() }
                }
                .accessibilityLabel(item.image.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Image")

                controls(in: geometry.size)
                    .opacity(model.expanded ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.18), value: model.index)
        }
        .ignoresSafeArea()
        .onHover { hovering = $0 }
    }

    /// The image fitted in the window with room for the bars, or at its own size when zoomed in.
    private func fitted(_ item: LightboxItem, in size: CGSize) -> CGRect {
        let loaded = URL(string: item.image.url).flatMap { ImageLoader.shared.cached($0) }?.pixelSize
        let width = CGFloat(item.image.width ?? Int(loaded?.width ?? 800))
        let height = CGFloat(item.image.height ?? Int(loaded?.height ?? 600))
        let available = CGSize(width: size.width - 120, height: size.height - 150)
        let scale = model.zoomed ? max(1, min(available.width / width, available.height / height) * 2) : min(available.width / width, available.height / height, 2)
        let fitted = CGSize(width: width * scale, height: height * scale)

        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2 + 8, width: fitted.width, height: fitted.height)
    }

    private func controls(in size: CGSize) -> some View {
        let item = model.current

        return VStack {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.sender).font(DS.Fonts.bodyMedium.weight(.semibold)).lineLimit(1)
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(DS.Fonts.monoCaption).opacity(0.7)
                }

                Spacer()

                if model.items.count > 1 {
                    Text("\(model.index + 1) of \(model.items.count)")
                        .font(DS.Fonts.monoCaption.weight(.medium))
                        .opacity(0.8)
                        .contentTransition(.numericText())
                }

                Spacer()

                Group {
                    Button { LightboxActions.copy(item.image) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy (⌘C)")
                        .accessibilityLabel("Copy image")
                    Button { LightboxActions.save(item.image) } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Save (⌘S)")
                        .accessibilityLabel("Save image")
                    Button { model.close() } label: { Image(systemName: "xmark") }
                        .help("Close (Esc)")
                        .accessibilityLabel("Close")
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)

            Spacer()

            HStack {
                navigation(-1, systemImage: "chevron.left", enabled: model.index > 0)
                Spacer()
                navigation(1, systemImage: "chevron.right", enabled: model.index < model.items.count - 1)
            }
            .padding(.horizontal, 16)

            Spacer()

            if let description = item.image.description, !description.isEmpty {
                Text(description)
                    .font(DS.Fonts.body)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                    .frame(maxWidth: 560)
            }

            Color.clear.frame(height: 24)
        }
        .foregroundStyle(.white)
    }

    private func navigation(_ step: Int, systemImage: String, enabled: Bool) -> some View {
        Button { model.move(step) } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? (hovering ? 1 : 0.5) : 0)
        .disabled(!enabled)
        .help(step < 0 ? "Previous (←)" : "Next (→)")
        .accessibilityLabel(step < 0 ? "Previous image" : "Next image")
    }
}
