import Foundation

extension DocumentHTML {
    /// Why an image is not in the output (R14, R16).
    public enum OmissionReason: String, Sendable, Equatable {
        case notFound, tooLarge, notAnImage, insecure, sizeLimit, unsavedDocument
    }

    public struct Omission: Sendable, Equatable {
        public var source: String
        public var reason: OmissionReason
        public init(source: String, reason: OmissionReason) {
            self.source = source
            self.reason = reason
        }
    }

    /// What the output does with one image source.
    public enum ImageOutcome: Sendable, Equatable {
        /// A local file, embedded as this `data:` URI.
        case embedded(dataURI: String)
        /// A `data:` or `https:` source, kept as written.
        case keep
        case leftOut(OmissionReason)
    }

    /// What the app found when it looked for one local file.
    public enum LocalImage: Sendable, Equatable {
        /// An image WebKit shows, no larger than 8,000,000 bytes; `byteCount` is the size of the file.
        case image(dataURI: String, byteCount: Int)
        case notFound, tooLarge, notAnImage
    }

    /// The most image data one output embeds (R14). Images are taken in document order; once this much is held no more are read.
    public static let embeddedImageBudget = 64_000_000

    /// R14's table. Each distinct source is decided once, in the order given. Local files are looked up through `load`, which is given the
    /// source as written (percent-decoding, `~` and `file:` are the app's business); a relative source in a document with no folder is
    /// never looked up, so the process's working directory cannot stand in for one.
    public static func resolveImages(_ sources: [String], documentHasFolder: Bool, load: (String) -> LocalImage) -> [String: ImageOutcome] {
        var outcomes: [String: ImageOutcome] = [:]
        var held = 0
        for source in sources where outcomes[source] == nil {
            switch LinkPolicy.imageSourceKind(source) {
            case .data, .https:
                outcomes[source] = .keep
            case .http:
                outcomes[source] = .leftOut(.insecure)
            case .unsupported:
                outcomes[source] = .leftOut(.notFound)
            case .local(let relative):
                if relative && !documentHasFolder {
                    outcomes[source] = .leftOut(.unsavedDocument)
                } else if held >= embeddedImageBudget {
                    outcomes[source] = .leftOut(.sizeLimit)
                } else {
                    switch load(source) {
                    case .image(let uri, let bytes): held += bytes; outcomes[source] = .embedded(dataURI: uri)
                    case .notFound: outcomes[source] = .leftOut(.notFound)
                    case .tooLarge: outcomes[source] = .leftOut(.tooLarge)
                    case .notAnImage: outcomes[source] = .leftOut(.notAnImage)
                    }
                }
            }
        }
        return outcomes
    }
}
