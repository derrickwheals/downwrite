import SwiftUI
import AppKit

/// Keeps the window that hosts this view above other windows (`.floating`) while `floating` is true.
/// Put it in a window's `.background`; it carries no content of its own.
struct WindowLevelSetter: NSViewRepresentable {
    var floating: Bool

    func makeNSView(context: Context) -> LevelView {
        let view = LevelView()
        view.floating = floating
        return view
    }

    func updateNSView(_ view: LevelView, context: Context) { view.floating = floating }

    final class LevelView: NSView {
        var floating = false { didSet { apply() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            let wanted: NSWindow.Level = floating ? .floating : .normal
            if window.level != wanted { window.level = wanted }
        }
    }
}

/// The frontmost window's "Keep on Top" switch, for the Window menu.
struct KeepOnTopKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var keepOnTop: Binding<Bool>? {
        get { self[KeepOnTopKey.self] }
        set { self[KeepOnTopKey.self] = newValue }
    }
}

/// Window ▸ Keep on Top: floats the current window above other windows (a checkmark shows while it is on).
struct WindowCommands: Commands {
    @FocusedBinding(\.keepOnTop) private var keepOnTop

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Toggle("Keep on Top", isOn: Binding(get: { keepOnTop ?? false }, set: { keepOnTop = $0 }))
                .disabled(keepOnTop == nil)
        }
    }
}
