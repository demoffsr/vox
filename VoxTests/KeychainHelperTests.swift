import Testing
@testable import Vox

@Suite(.serialized)
struct KeychainHelperTests {
    let helper = KeychainHelper(service: "com.vox.test.apikey")

    init() {
        try? helper.delete() // ensure clean state
    }

    @Test func saveAndLoad() throws {
        try helper.save("sk-test-key-12345")
        let loaded = try helper.load()
        #expect(loaded == "sk-test-key-12345")
        try helper.delete()
    }

    @Test func loadWhenEmpty() {
        let result = try? helper.load()
        #expect(result == nil)
    }

    @Test func deleteRemovesKey() throws {
        try helper.save("sk-temp")
        try helper.delete()
        let result = try? helper.load()
        #expect(result == nil)
    }

    @Test func overwriteExistingKey() throws {
        try helper.save("sk-old")
        try helper.save("sk-new")
        let loaded = try helper.load()
        #expect(loaded == "sk-new")
        try helper.delete()
    }
}
