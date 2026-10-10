import Foundation

/// The name a heading goes by in a `#fragment` link. The editor resolves `[jump](#some-heading)` with it, and the exported HTML gives
/// every heading the same name as its `id`, so a link that works in the editor works in the file.
public enum HeadingAnchor {
    /// The slug of a heading's title (`HeadingInfo.title`, the inline source as typed): lower-cased, letters, marks, digits, spaces and
    /// hyphens kept, everything else dropped, then each space becomes a hyphen. Nothing is trimmed or collapsed.
    public static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
        return String(String.UnicodeScalarView(allowed)).replacingOccurrences(of: " ", with: "-")
    }

    /// The `id` for each heading, from the headings' slugs in document order. The first heading with a slug keeps it (the editor resolves
    /// a fragment to the first match); a later heading that would repeat an id takes `-1`, `-2` … after it. A suffix never lands on a slug
    /// that some heading in the document has by its own title, so a heading called "Foo 1" keeps `foo-1` and `#foo-1` goes where the editor
    /// sends it, whatever order the headings come in. A heading with an empty slug has no id and takes no part.
    public static func unique(_ slugs: [String]) -> [String?] {
        let natural = Set(slugs.filter { !$0.isEmpty })
        var used = Set<String>()
        var nextSuffix: [String: Int] = [:]
        return slugs.map { slug in
            guard !slug.isEmpty else { return nil }
            if used.insert(slug).inserted { return slug }
            var n = nextSuffix[slug, default: 1]
            while natural.contains("\(slug)-\(n)") || used.contains("\(slug)-\(n)") { n += 1 }
            let id = "\(slug)-\(n)"
            used.insert(id)
            nextSuffix[slug] = n + 1
            return id
        }
    }
}
