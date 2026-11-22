import Testing

@testable import BookReader

/// The book reader reports every page, not only every new element.
struct ReportedSpotTests {

    /// A long paragraph over several pages: same CFI, the fraction moves - that is a new report,
    /// otherwise the reading-time counter sees no page turns and takes the reading for a pause.
    @Test func samePlaceNewPageIsReported() {
        let a = BookController.ReportedSpot(cfi: "/6/4!/4/2", fraction: 0.10)
        let b = BookController.ReportedSpot(cfi: "/6/4!/4/2", fraction: 0.11)
        #expect(b.isNew(after: a))
    }

    /// Without an element Readium leaves only the chapter - the pages still count.
    @Test func chapterOnlyStillReportsPages() {
        let a = BookController.ReportedSpot(cfi: "/6/4", fraction: 0.30)
        let b = BookController.ReportedSpot(cfi: "/6/4", fraction: 0.3025)
        #expect(b.isNew(after: a))
    }

    /// Readium calls back twice for the same spot - that goes out once.
    @Test func sameSpotTwiceGoesOutOnce() {
        let a = BookController.ReportedSpot(cfi: "/6/4!/4/2", fraction: 0.10)
        #expect(!a.isNew(after: a))
        #expect(a.isNew(after: nil))
    }
}
