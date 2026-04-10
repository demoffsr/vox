import Testing
@testable import Vox

@MainActor
struct TranslationStreamViewModelTests {
    @Test func updateDraftSetsText() {
        let vm = TranslationStreamViewModel()
        vm.updateDraft("Hello world")
        #expect(vm.accumulatedText == "Hello world")
    }

    @Test func updateDraftTrimsWhitespace() {
        let vm = TranslationStreamViewModel()
        vm.updateDraft("  hello  ")
        #expect(vm.accumulatedText == "hello")
    }

    @Test func commitFinalAppendsToDraft() {
        let vm = TranslationStreamViewModel()
        vm.commitFinal("first sentence")
        vm.updateDraft("second")
        #expect(vm.accumulatedText == "first sentence second")
    }

    @Test func commitFinalClearsDraft() {
        let vm = TranslationStreamViewModel()
        vm.updateDraft("draft text")
        vm.commitFinal("final text")
        #expect(vm.accumulatedText == "final text")
    }

    @Test func clearResetsEverything() {
        let vm = TranslationStreamViewModel()
        vm.commitFinal("some text")
        vm.updateDraft("more")
        vm.clear()
        #expect(vm.accumulatedText == "")
    }

    @Test func finalLengthReflectsCommittedText() {
        let vm = TranslationStreamViewModel()
        vm.commitFinal("hello")
        vm.updateDraft("draft")
        #expect(vm.finalLength == "hello".count + 1) // +1 for space
    }

    @Test func accumulatedTextEmptyWhenNothingSet() {
        let vm = TranslationStreamViewModel()
        #expect(vm.accumulatedText == "")
    }

    @Test func commitFinalSkipsEmptyText() {
        let vm = TranslationStreamViewModel()
        vm.commitFinal("")
        vm.commitFinal("  ")
        #expect(vm.accumulatedText == "")
    }
}
