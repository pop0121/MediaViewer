import XCTest
@testable import MediaViewer

final class MediaDateParserTests: XCTestCase {
    private let calendar = Calendar.current

    private func localDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    private func assertParses(_ fileName: String, _ expected: Date, line: UInt = #line) {
        XCTAssertEqual(
            MediaDateParser.parse(fileName: fileName),
            expected,
            "expected \(fileName)",
            line: line
        )
    }

    func testIMGCameraNames() {
        assertParses("IMG_20240702_162635.jpg", localDate(2024, 7, 2, 16, 26, 35))
        assertParses("IMG_20240702_162635(1).JPG", localDate(2024, 7, 2, 16, 26, 35))
        assertParses("IMG-20250623-093011.jpg", localDate(2025, 6, 23, 9, 30, 11))
    }

    func testScreenshotNames() {
        assertParses("Screenshot_20250609_091713.png", localDate(2025, 6, 9, 9, 17, 13))
        assertParses("Screenshot-20250609-091713(2).PNG", localDate(2025, 6, 9, 9, 17, 13))
    }

    func testScannerNames() {
        assertParses("扫描文件_20240615_143727.jpg", localDate(2024, 6, 15, 14, 37, 27))
        assertParses("扫描文件_20240527_120000_1.jpg", localDate(2024, 5, 27, 12, 0, 0))
    }

    func testWeChatPictureNames() {
        assertParses("微信图片_20240628195832.jpg", localDate(2024, 6, 28, 19, 58, 32))
        assertParses("微信图片_20240628195832(1).jpg", localDate(2024, 6, 28, 19, 58, 32))
    }

    func testMMExportThirteenDigitEpoch() {
        assertParses("mmexport1752318346790.jpg", Date(timeIntervalSince1970: 1_752_318_346.790))
        assertParses("mmexport_1752318346790.jpg", Date(timeIntervalSince1970: 1_752_318_346.790))
    }

    func testMMExportTenDigitEpoch() {
        assertParses("mmexport1690000000.jpg", Date(timeIntervalSince1970: 1_690_000_000))
        assertParses("mmexport_1690000000.jpg", Date(timeIntervalSince1970: 1_690_000_000))
    }

    func testPureThirteenDigitEpoch() {
        assertParses("1752318346790.jpg", Date(timeIntervalSince1970: 1_752_318_346.790))
        assertParses("1700000000000.mp4", Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testImageEditorEpoch() {
        assertParses("image_editor_1752318346790.jpg", Date(timeIntervalSince1970: 1_752_318_346.790))
        assertParses("image_editor_1690000000123_edited.jpg", Date(timeIntervalSince1970: 1_690_000_000.123))
    }

    func testInvalidAndFutureEpochsAreRejected() {
        XCTAssertNil(MediaDateParser.parse(fileName: "mmexport9999999999999.jpg"))
        XCTAssertNil(MediaDateParser.parse(fileName: "mmexport123.jpg"))
        XCTAssertNil(MediaDateParser.parse(fileName: "mmexport0000000000.jpg"))
        XCTAssertNil(MediaDateParser.parse(fileName: "9999999999999.jpg"))
        XCTAssertNil(MediaDateParser.parse(fileName: "image_editor_123.jpg"))
    }

    func testInvalidCalendarDatesAndNonDatesAreRejected() {
        XCTAssertNil(MediaDateParser.parse(fileName: "IMG_20241340_000000.jpg"))
        XCTAssertNil(MediaDateParser.parse(fileName: "IMG_20991231_235959.jpg"))
        XCTAssertNil(MediaDateParser.parse(fileName: "IMG_0822.JPG"))
        XCTAssertNil(MediaDateParser.parse(fileName: "IMG_0001.jpg"))
        XCTAssertNil(MediaDateParser.parse(fileName: "random_hash.jpg"))
    }

    func testMixedSuffixStillParses() {
        let expected = localDate(2024, 7, 2, 16, 26, 35)
        assertParses("IMG_20240702_162635_copy-edited.jpg", expected)
    }
}
