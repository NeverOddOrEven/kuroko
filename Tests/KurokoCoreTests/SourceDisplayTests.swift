import CoreGraphics
import Testing
@testable import KurokoCore

struct SourceDisplayTests {
    let displays: [(id: CGDirectDisplayID, uuid: String?)] = [(1, "MAIN"), (2, "EXTERNAL")]

    @Test func prefersTheSavedDisplay() {
        #expect(SourceDisplay.resolve(savedUUID: "EXTERNAL", displays: displays, mainID: 1) == 2)
    }

    @Test func fallsBackToMainWhenSavedDisplayIsGone() {
        #expect(SourceDisplay.resolve(savedUUID: "UNPLUGGED", displays: displays, mainID: 1) == 1)
        #expect(SourceDisplay.resolve(savedUUID: nil, displays: displays, mainID: 1) == 1)
    }

    @Test func fallsBackToFirstWhenMainIsNotAmongThem() {
        #expect(SourceDisplay.resolve(savedUUID: nil, displays: displays, mainID: 9) == 1)
    }

    @Test func returnsMainWhenThereAreNoDisplays() {
        #expect(SourceDisplay.resolve(savedUUID: "MAIN", displays: [], mainID: 9) == 9)
    }
}
