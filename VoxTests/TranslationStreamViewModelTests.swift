import Testing
@testable import Vox

@MainActor
struct TranslationStreamViewModelTests {
    @Test func appendAddsToPendingChunks() {
        let vm = TranslationStreamViewModel()
        vm.append("Hello world")
        vm.append("second chunk")
        #expect(vm.accumulatedText == "Hello world second chunk")
        #expect(vm.pendingChunksCount == 2)
    }

    @Test func appendSkipsEmptyText() {
        let vm = TranslationStreamViewModel()
        vm.append("first")
        vm.append("")
        vm.append("  ")
        #expect(vm.accumulatedText == "first")
        #expect(vm.pendingChunksCount == 1)
    }

    @Test func clearResetsEverything() {
        let vm = TranslationStreamViewModel()
        vm.append("some text")
        vm.commitRefinedText("Refined text.")
        vm.append("more")
        vm.clear()
        #expect(vm.accumulatedText == "")
        #expect(vm.pendingChunksCount == 0)
    }

    @Test func accumulatedTextCombinesRefinedAndPending() {
        let vm = TranslationStreamViewModel()
        vm.append("raw one")
        vm.append("raw two")
        vm.commitRefinedText("Refined one. Refined two.")
        vm.append("raw three")
        #expect(vm.accumulatedText == "Refined one. Refined two. raw three")
        #expect(vm.pendingChunksCount == 1)
    }

    @Test func commitRefinedTextClearsPendingChunks() {
        let vm = TranslationStreamViewModel()
        vm.append("chunk a")
        vm.append("chunk b")
        #expect(vm.pendingChunksCount == 2)
        vm.commitRefinedText("Chunk A. Chunk B.")
        #expect(vm.pendingChunksCount == 0)
        #expect(vm.accumulatedText == "Chunk A. Chunk B.")
    }

    @Test func pendingTextReturnsPendingChunksJoined() {
        let vm = TranslationStreamViewModel()
        vm.append("one")
        vm.append("two")
        vm.append("three")
        #expect(vm.pendingText == "one two three")
    }

    @Test func refinedTailReturnsLastWords() {
        let vm = TranslationStreamViewModel()
        vm.commitRefinedText("one two three four five six seven eight")
        let tail = vm.refinedTail(maxWords: 4)
        #expect(tail == "five six seven eight")
    }

    @Test func refinedTailReturnsEmptyWhenNoRefined() {
        let vm = TranslationStreamViewModel()
        vm.append("pending only")
        #expect(vm.refinedTail(maxWords: 30) == "")
    }

    @Test func refinedTailClampsToAvailable() {
        let vm = TranslationStreamViewModel()
        vm.commitRefinedText("hello world")
        #expect(vm.refinedTail(maxWords: 100) == "hello world")
    }
}
