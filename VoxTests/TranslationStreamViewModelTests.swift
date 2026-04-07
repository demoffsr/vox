import Testing
@testable import Vox

@MainActor
struct TranslationStreamViewModelTests {
    @Test func appendReturnsIndexAndBuildsText() {
        let vm = TranslationStreamViewModel()
        let i0 = vm.append("Hello world")
        let i1 = vm.append("second chunk")
        #expect(i0 == 0)
        #expect(i1 == 1)
        #expect(vm.accumulatedText == "Hello world second chunk")
    }

    @Test func appendSkipsEmptyText() {
        let vm = TranslationStreamViewModel()
        let i0 = vm.append("first")
        let i1 = vm.append("")
        let i2 = vm.append("  ")
        #expect(i0 == 0)
        #expect(i1 == nil)
        #expect(i2 == nil)
        #expect(vm.accumulatedText == "first")
    }

    @Test func clearResetsChunks() {
        let vm = TranslationStreamViewModel()
        _ = vm.append("some text")
        vm.clear()
        #expect(vm.accumulatedText == "")
    }

    @Test func firstAppendHasNoLeadingSpace() {
        let vm = TranslationStreamViewModel()
        _ = vm.append("first chunk")
        #expect(vm.accumulatedText == "first chunk")
    }

    @Test func replaceChunkUpdatesText() {
        let vm = TranslationStreamViewModel()
        _ = vm.append("hello world")
        let i1 = vm.append("second chunk")
        vm.replaceChunk(at: i1!, with: "Second chunk.")
        #expect(vm.accumulatedText == "hello world Second chunk.")
    }

    @Test func replaceChunkIgnoresInvalidIndex() {
        let vm = TranslationStreamViewModel()
        _ = vm.append("hello")
        vm.replaceChunk(at: 5, with: "nope")
        #expect(vm.accumulatedText == "hello")
    }

    @Test func contextReturnsLastWords() {
        let vm = TranslationStreamViewModel()
        _ = vm.append("one two three four five")
        _ = vm.append("six seven eight nine ten")
        let ctx = vm.context(beforeIndex: 2, maxWords: 6)
        #expect(ctx == "five six seven eight nine ten")
    }

    @Test func contextClampsToAvailableWords() {
        let vm = TranslationStreamViewModel()
        _ = vm.append("hello world")
        let ctx = vm.context(beforeIndex: 1, maxWords: 100)
        #expect(ctx == "hello world")
    }

    @Test func contextReturnsEmptyForFirstChunk() {
        let vm = TranslationStreamViewModel()
        _ = vm.append("first")
        let ctx = vm.context(beforeIndex: 0, maxWords: 30)
        #expect(ctx == "")
    }
}
