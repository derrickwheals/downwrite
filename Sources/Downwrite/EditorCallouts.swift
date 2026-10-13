import AppKit
import DownwriteCore

/// Callouts in the editor (DW-006): what VoiceOver is told when the caret moves into one. Revealing a callout's marker needs no code
/// here: the marker is an ordinary `Marker` whose reveal range is its line, so `selectionChanged` restyles that line like any other.
extension EditorCoordinator {
    /// The callout the selection touches, as an index into `analysis.callouts` (nil in the source view). Kept silently by `reanalyze`
    /// (typing a marker, undo, an external reload and leaving the source view do not announce) and updated by caret moves.
    func syncActiveCallout() {
        activeCallout = sourceMode ? nil : textView.flatMap { analysis.calloutIndex(touching: $0.selectedRange()) }
    }

    /// The caret or selection moved. When it has gone from outside every callout, or from one callout, into a callout, announces
    /// "Note callout" (the type's name, not the title): once per entry, not while it stays inside, and at medium priority so it queues
    /// behind the line VoiceOver is reading instead of cutting it off.
    func announceCalloutIfEntered(selection: NSRange) {
        let now = analysis.calloutIndex(touching: selection)
        let before = activeCallout
        activeCallout = now
        guard let now, now != before, let tv = textView else { return }
        let message = "\(analysis.callouts[now].kind.title) callout"
        onAnnouncement?(message)
        NSAccessibility.post(element: tv, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
