import Testing
@testable import Vox

struct GlossaryTests {
    @Test func englishTermsExtractsLeftSideOfArrow() {
        let g = Glossary(
            showName: "Test",
            content: "Homelander → le Protecteur\nCompound V → Composé V",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms == ["Homelander", "Compound V"])
    }

    @Test func englishTermsStripsUncertaintyMarker() {
        let g = Glossary(
            showName: "Test",
            content: "Vought → Vought [?]",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms == ["Vought"])
    }

    @Test func englishTermsSupportsEmDashSeparator() {
        let g = Glossary(
            showName: "Test",
            content: "Supe — Supe",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms == ["Supe"])
    }

    @Test func englishTermsSkipsLinesWithoutSeparator() {
        let g = Glossary(
            showName: "Test",
            content: "Homelander → le Protecteur\nrandom line without separator\nSupes → les Supes",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms == ["Homelander", "Supes"])
    }

    @Test func englishTermsSkipsEmptyLines() {
        let g = Glossary(
            showName: "Test",
            content: "\nHomelander → le Protecteur\n\n\nVought → Vought",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms == ["Homelander", "Vought"])
    }

    @Test func englishTermsTrimsWhitespaceAroundTerm() {
        let g = Glossary(
            showName: "Test",
            content: "  Homelander  →  le Protecteur  ",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms == ["Homelander"])
    }

    @Test func englishTermsReturnsEmptyForEmptyContent() {
        let g = Glossary(
            showName: "Test",
            content: "",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms.isEmpty)
    }

    @Test func englishTermsPreservesOrder() {
        let g = Glossary(
            showName: "Test",
            content: "Zeta → Zeta\nAlpha → Alpha\nMiddle → Middle",
            asrHints: nil,
            confidence: .strict
        )
        #expect(g.englishTerms == ["Zeta", "Alpha", "Middle"])
    }
}
