import XCTest
@testable import SwiftDocxTemplate

final class SwiftDocxTemplateTests: XCTestCase {
    func testModuleImports() {
        XCTAssertEqual(DocxTemplateError.invalidArchive.localizedDescription.isEmpty, false)
    }
}
