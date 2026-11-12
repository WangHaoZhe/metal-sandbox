import SwiftUI
import AppKit
import FrontendCore

struct TerminalOutputView: NSViewRepresentable {
    let text: String
    let autoScroll: Bool
    var wrapsLines = false
    var accessibilityIdentifier = "terminal_output"
    var accessibilityLabel = ui("终端输出", "Terminal Output")
    func makeNSView(context: Context) -> TerminalOutputScrollView {
        let view = TerminalOutputScrollView(frame: .zero)
        view.configureAccessibility(identifier: accessibilityIdentifier, label: accessibilityLabel)
        return view
    }
    func updateNSView(_ view: TerminalOutputScrollView, context: Context) {
        view.configureAccessibility(identifier: accessibilityIdentifier, label: accessibilityLabel)
        view.update(text: text, autoScroll: autoScroll, wrapsLines: wrapsLines)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalOutputScrollView, context: Context) -> CGSize? {
        guard wrapsLines, let width = proposal.width else { return nil }
        return CGSize(width: width, height: min(proposal.height ?? .greatestFiniteMagnitude, nsView.wrappedHeight(width: width)))
    }
}

/// Control the vertical offset explicitly; scrolling a target into view can
/// otherwise also move the horizontal axis to the end of a long output line.
final class TerminalOutputScrollView: NSScrollView {
    private let output = NSTextView(frame: .zero)
    private var autoScroll = true
    private var wrapsLines = false
    private var pendingOrigin: NSPoint?
    private var viewportSize = NSSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        borderType = .noBorder; backgroundColor = .textBackgroundColor
        output.isEditable = false; output.isSelectable = true; output.isRichText = false
        output.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        output.textColor = .textColor; output.backgroundColor = .textBackgroundColor
        output.textContainerInset = NSSize(width: 12, height: 12)
        output.isHorizontallyResizable = true; output.isVerticallyResizable = true
        output.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        output.textContainer?.widthTracksTextView = false
        output.textContainer?.containerSize = output.maxSize
        output.textContainer?.lineFragmentPadding = 0
        output.setAccessibilityIdentifier("terminal_output")
        output.setAccessibilityLabel(ui("终端输出", "Terminal Output"))
        documentView = output
        setAccessibilityIdentifier("terminal_output_scroll")
    }
    required init?(coder: NSCoder) { nil }

    func configureAccessibility(identifier: String, label: String) {
        output.setAccessibilityIdentifier(identifier)
        output.setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier + "_scroll")
    }

    func update(text: String, autoScroll: Bool, wrapsLines: Bool = false) {
        guard output.string != text || self.autoScroll != autoScroll || self.wrapsLines != wrapsLines else { return }
        pendingOrigin = pendingOrigin ?? contentView.bounds.origin
        self.autoScroll = autoScroll
        self.wrapsLines = wrapsLines
        hasHorizontalScroller = !wrapsLines
        output.isHorizontallyResizable = !wrapsLines
        if output.string != text { output.string = text }
        needsLayout = true
    }

    func wrappedHeight(width: CGFloat) -> CGFloat {
        let bounds = (output.string as NSString).boundingRect(with: NSSize(width: max(1, width - 24), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: output.font!])
        return ceil(bounds.height) + 24
    }

    override func layout() {
        super.layout()
        let viewport = contentView.bounds.size
        guard pendingOrigin != nil || viewport != viewportSize,
              let container = output.textContainer, let manager = output.layoutManager else { return }
        let origin = pendingOrigin ?? contentView.bounds.origin
        pendingOrigin = nil; viewportSize = viewport
        container.containerSize = NSSize(width: wrapsLines ? max(1, viewport.width - 24) : .greatestFiniteMagnitude,
                                        height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let size = NSSize(width: wrapsLines ? viewport.width : max(viewport.width, ceil(used.maxX) + 24),
                          height: max(viewport.height, ceil(used.maxY) + 24))
        output.setFrameSize(size)
        let x = min(max(0, origin.x), max(0, size.width - viewport.width))
        let bottom = max(0, size.height - viewport.height)
        contentView.scroll(to: NSPoint(x: x, y: autoScroll ? bottom : min(max(0, origin.y), bottom)))
        reflectScrolledClipView(contentView)
    }
}
