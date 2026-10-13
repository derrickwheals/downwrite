import AppKit

/// A stand-in for the drag session AppKit hands the drag-destination methods, so a drop can be tested without a mouse.
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let window: NSWindow?
    var location: NSPoint
    var operationMask: NSDragOperation = [.copy, .generic, .move, .link]
    /// What the drag started from: the editor itself for text dragged within it, nil for another app.
    var source: Any?

    /// `location` is in the window's coordinates, as `draggingLocation` is.
    init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint) {
        self.pasteboard = pasteboard
        self.window = window
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { operationMask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
