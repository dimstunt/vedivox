import Foundation

/// The caption of a Settings → Storage row: where it lives and how
/// big it is, then at most one line of why.
enum StorageCaption {
    static func text(_ url: URL, size: String, note: String? = nil) -> String {
        let place = "\((url.path as NSString).abbreviatingWithTildeInPath) · \(size)"
        return note.map { "\(place)\n\($0)" } ?? place
    }
}
