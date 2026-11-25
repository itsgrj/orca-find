import AppKit
import ObjectiveC
import SwiftUI

/// Pointing-hand cursor over every clickable control in the app, without having to remember
/// `.handCursor()` on each one.
///
/// Two kinds of control need it:
/// - System controls SwiftUI draws with AppKit: segmented pickers, on/off switches, pop-up
///   pickers, checkboxes and menus. They get a pointing-hand cursor rect on their own bounds,
///   installed once at launch (`NativeControlCursor.install()`).
/// - Plain SwiftUI buttons. Use `.buttonStyle(.plainHand)`: it looks exactly like `.plain`
///   and shows the hand while the button is enabled.
enum NativeControlCursor {
    private static var installed = false

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        let sel = #selector(NSView.resetCursorRects)
        typealias Original = @convention(c) (NSView, Selector) -> Void
        // Each class gets its own wrapper around whatever it did before (its own override or
        // the inherited one), so nothing the system draws loses its existing cursor behaviour.
        for cls in [NSButton.self, NSSegmentedControl.self, NSSwitch.self, NSPopUpButton.self] as [AnyClass] {
            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (NSView) -> Void = { view in
                original(view, sel)
                guard let control = view as? NSControl, control.isEnabled, !isWindowButton(control) else { return }
                view.addCursorRect(view.bounds, cursor: .pointingHand)
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
    }

    /// The close / minimise / full-screen buttons keep the arrow, as everywhere else on the Mac.
    private static func isWindowButton(_ control: NSControl) -> Bool {
        guard let window = control.window else { return false }
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .toolbarButton, .documentIconButton]
        return kinds.contains { window.standardWindowButton($0) === control }
    }
}

/// `.plain`, plus the pointing hand while the button can be clicked.
struct PlainHandButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlainHandBody(configuration: configuration)
    }

    private struct PlainHandBody: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            Button(configuration).buttonStyle(.plain).handCursor(isEnabled)
        }
    }
}

extension PrimitiveButtonStyle where Self == PlainHandButtonStyle {
    static var plainHand: PlainHandButtonStyle { PlainHandButtonStyle() }
}
