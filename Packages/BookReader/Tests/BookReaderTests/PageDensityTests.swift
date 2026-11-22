import Testing

@testable import BookReader

@Suite("Page density")
struct PageDensityTests {

    @Test("A title page with one word is no sample - a long book keeps its number")
    func titlePage() {
        var d = PageDensity()
        let title = d.take(chapter: 0, character: 12, pages: 1)
        #expect(!title)
        #expect(d.value == nil)
        let chapter = d.take(chapter: 3, character: 60_000, pages: 40)
        #expect(chapter)
        let previously = d.value
        let again = d.take(chapter: 7, character: 12, pages: 1)
        #expect(!again)
        #expect(d.value == previously, "the title page does not change the density")
    }

    @Test("The density is the mean of all samples, the last page counts half")
    func average() throws {
        var d = PageDensity()
        d.take(chapter: 1, character: 60_000, pages: 40)
        let one = try #require(d.value)
        #expect(abs(one - 60_000 / 39.5) < 0.01)
        d.take(chapter: 2, character: 30_000, pages: 20)
        let two = try #require(d.value)
        #expect(abs(two - 90_000 / 59.0) < 0.01)
        // Measuring the same chapter again replaces its sample, it does not double it.
        d.take(chapter: 2, character: 30_000, pages: 21)
        let three = try #require(d.value)
        #expect(abs(three - 90_000 / 60.0) < 0.01)
    }

    @Test("Font or window change -> all samples gone, the next measurement counts")
    func clear() {
        var d = PageDensity()
        d.take(chapter: 1, character: 60_000, pages: 40)
        d.clearOut()
        #expect(d.value == nil)
        let tooShort = d.take(chapter: 1, character: 1_499, pages: 2)
        #expect(!tooShort, "no sample below the minimum length")
        let enough = d.take(chapter: 1, character: 1_500, pages: 2)
        #expect(enough)
    }
}
