import XCTest
import SwiftUI
import AppKit
@testable import Downwrite

/// Window ▸ Keep on Top floats a window above other windows; `WindowLevelSetter` is what applies it.
@MainActor
final class KeepOnTopTests: XCTestCase {
    private func makeWindow(floating: Bool) -> (NSWindow, NSHostingView<WindowLevelSetter>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false          // ARC owns it; the default (true) would release it a second time on close()
        let host = NSHostingView(rootView: WindowLevelSetter(floating: floating))
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    func testAWindowStartsAtTheNormalLevel() async {
        let (window, _) = makeWindow(floating: false)
        defer { window.close() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(window.level, .normal)
    }

    func testTheWindowFloatsWhileTheSwitchIsOnAndComesBack() async {
        let (window, host) = makeWindow(floating: false)
        defer { window.close() }
        host.rootView = WindowLevelSetter(floating: true)
        let floated = await waitUntil(timeout: 5) { window.level == .floating }
        XCTAssertTrue(floated, "turning it on floats the window")
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.normal.rawValue)
        host.rootView = WindowLevelSetter(floating: false)
        let normal = await waitUntil(timeout: 5) { window.level == .normal }
        XCTAssertTrue(normal, "turning it off puts the window back")
    }

    func testAWindowThatAppearsWithTheSwitchOnIsAlreadyFloating() async {
        let (window, _) = makeWindow(floating: true)
        defer { window.close() }
        let floated = await waitUntil(timeout: 5) { window.level == .floating }
        XCTAssertTrue(floated)
    }

    func testEachWindowKeepsItsOwnLevel() async {
        let (a, hostA) = makeWindow(floating: false)
        let (b, _) = makeWindow(floating: false)
        defer { a.close(); b.close() }
        hostA.rootView = WindowLevelSetter(floating: true)
        _ = await waitUntil(timeout: 5) { a.level == .floating }
        XCTAssertEqual(a.level, .floating)
        XCTAssertEqual(b.level, .normal, "the other window is unaffected")
    }
}
