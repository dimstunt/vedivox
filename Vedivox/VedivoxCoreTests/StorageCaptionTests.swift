import XCTest

/// Settings → Storage rows read alike: `~/path · size`, then one line of why.
final class StorageCaptionTests: XCTestCase {
    func testPathUnderHomeStartsWithTilde() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Vedivox/logs")
        XCTAssertEqual(StorageCaption.text(url, size: "2 MB"), "~/Library/Application Support/Vedivox/logs · 2 MB")
    }

    func testNoteGoesOnItsOwnLine() {
        let url = URL(fileURLWithPath: "/tmp/backups")
        XCTAssertEqual(StorageCaption.text(url, size: "7 GB", note: "Why."), "/tmp/backups · 7 GB\nWhy.")
    }
}
