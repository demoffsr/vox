// VoxTests/TranslationStreamViewModelTests.swift
import Testing
@testable import Vox

@MainActor
struct TranslationStreamViewModelTests {
    @Test func appendAddsTextWithSpaceSeparator() {
        let vm = TranslationStreamViewModel()
        vm.append("Hello world")
        vm.append("second chunk")
        #expect(vm.accumulatedText == "Hello world second chunk")
    }

    @Test func appendSkipsEmptyText() {
        let vm = TranslationStreamViewModel()
        vm.append("first")
        vm.append("")
        vm.append("  ")
        #expect(vm.accumulatedText == "first")
    }

    @Test func clearResetsText() {
        let vm = TranslationStreamViewModel()
        vm.append("some text")
        vm.clear()
        #expect(vm.accumulatedText == "")
    }

    @Test func firstAppendHasNoLeadingSpace() {
        let vm = TranslationStreamViewModel()
        vm.append("first chunk")
        #expect(vm.accumulatedText == "first chunk")
    }
}
