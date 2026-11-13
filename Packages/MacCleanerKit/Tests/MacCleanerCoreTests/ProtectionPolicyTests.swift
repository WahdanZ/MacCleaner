import Testing
@testable import MacCleanerCore

// Pure rules: no file system, a made-up home folder.
private let home = "/Users/tester"
private func h(_ rel: String) -> String { home + "/" + rel }

@Suite("PathRules")
struct PathRulesTests {
    @Test func insideNeedsASlashBoundary() {
        #expect(PathRules.isInside("/a/b", "/a/b"))
        #expect(PathRules.isInside("/a/b/c", "/a/b"))
        #expect(!PathRules.isInside("/a/bc", "/a/b"))
        #expect(!PathRules.isInside("/a", "/a/b"))
    }

    @Test func joinMatchesURLAppending() {
        #expect(PathRules.join("/Users/tester", "Library/Caches") == "/Users/tester/Library/Caches")
        #expect(PathRules.join("/", "x") == "/x")
    }
}

@Suite("Permanent delete (cache sweep)")
struct PermanentDeleteTests {
    let rules = PermanentDeleteRules(home: home)

    @Test(arguments: ["Library/Caches/com.example.app", ".gradle/caches", "Library/Application Support/Example/Cache",
                      "Library/Containers/com.example.app/Data/Library/Caches/x", ".cache/pip",
                      "Library/Developer/Xcode/DerivedData/App-abc", "Library/Developer/Xcode/iOS DeviceSupport/17.2",
                      "Library/Application Support/Code/CachedData", "Library/Application Support/Chrome/Default/Service Worker/CacheStorage"])
    func allowsRegenerableCaches(_ rel: String) {
        #expect(rules.allows(resolvedPath: h(rel)))
    }

    @Test(arguments: ["Library/Caches", ".cache", "Library/Application Support/Example/Data",
                      "Library/Containers/com.apple.mail/Data/Library/Caches/x",
                      "Library/Containers/com.example.app/Data/Documents", "Documents/x", "Downloads/x",
                      ".pub-cache/bin/melos", "Library/Mobile Documents/com~apple~CloudDocs/x", "Library/Preferences/x.plist",
                      "Library/Application Support/com.apple.foo/Cache"])
    func refusesEverythingElse(_ rel: String) {
        #expect(!rules.allows(resolvedPath: h(rel)))
    }

    @Test func containerRootsOnlyWhenAsked() {
        #expect(!rules.allows(resolvedPath: h("Library/Caches")))
        #expect(rules.allows(resolvedPath: h("Library/Caches"), allowContainer: true))
        let containerCaches = h("Library/Containers/com.example.app/Data/Library/Caches")
        #expect(!rules.allows(resolvedPath: containerCaches))
        #expect(rules.allows(resolvedPath: containerCaches, allowContainer: true))
    }

    @Test func pathsOutsideHomeAreRefused() {
        #expect(!rules.allows(resolvedPath: "/Library/Caches/x"))
        #expect(!rules.allows(resolvedPath: "/Users/other/Library/Caches/x"))
        #expect(!rules.allows(resolvedPath: "/Users/tester-other/Library/Caches/x"))
    }

    @Test func containerDepth() {
        #expect(rules.containerCacheDepth(h("Library/Containers/a/Data/Library/Caches")) == 4)
        #expect(rules.containerCacheDepth(h("Library/Containers/a/Data/Library/Caches/b/c")) == 6)
        #expect(rules.containerCacheDepth(h("Library/Containers/com.apple.x/Data/Library/Caches/b")) == nil)
        #expect(rules.containerCacheDepth(h("Library/Containers/a/Data/Documents")) == nil)
    }
}

@Suite("Move to Trash")
struct TrashRulesTests {
    let rules = TrashRules(home: home)
    private func key(_ p: String) -> String { p.lowercased() }

    @Test(arguments: ["", "Library", "Documents", "Library/Application Support", ".Trash"])
    func refusesStructuralFolders(_ rel: String) {
        #expect(rules.refusal(key: key(rel.isEmpty ? home : h(rel))) == "System or account folder")
    }

    @Test func refusesStructuralInAnyCase() {
        #expect(rules.refusal(key: key(h("DOCUMENTS"))) != nil)
        #expect(rules.refusal(key: key(h("library"))) != nil)
    }

    @Test(arguments: ["Library/Keychains/login.keychain-db", "Library/Mail/V10", ".ssh/id_ed25519", ".SSH/id_x", ".gnupg/x"])
    func refusesSensitive(_ rel: String) {
        #expect(rules.refusal(key: key(h(rel))) == "Holds passwords, mail or settings")
    }

    @Test func messagesAttachmentsSingleItemsOnly() {
        #expect(rules.refusal(key: key(h("Library/Messages/Attachments/ab/img.heic"))) == nil)
        #expect(rules.refusal(key: key(h("Library/Messages/Attachments"))) != nil)
    }

    @Test func homeAndApplicationsAllowedOutsideRefused() {
        #expect(rules.refusal(key: key(h("Documents/report.pdf"))) == nil)
        #expect(rules.refusal(key: "/applications/example.app") == nil)
        #expect(rules.refusal(key: "/private/tmp/x") == "Outside your home folder (view only)")
        #expect(rules.refusal(key: "/applications") != nil)
    }
}

@Suite("User protection")
struct UserProtectionTests {
    let protection = UserProtection(paths: [h("Work/Keep"), h("notes.txt")])

    @Test func protectedInsideAndContaining() {
        #expect(protection.refusal(normalizedPath: h("Work/Keep")) == "Protected (Settings › Protection)")
        #expect(protection.refusal(normalizedPath: h("Work/Keep/a/b")) == "Protected (Settings › Protection)")
        #expect(protection.refusal(normalizedPath: h("Work")) == "Contains a protected item")
        #expect(protection.refusal(normalizedPath: h("Work/Keeper")) == nil)
        #expect(protection.refusal(normalizedPath: h("Other")) == nil)
    }

    @Test func ignoresLetterCase() {
        #expect(protection.refusal(normalizedPath: h("work/keep/x")) != nil)
        #expect(protection.refusal(normalizedPath: h("NOTES.TXT")) != nil)
    }

    @Test func coversIgnoresCaseToo() {   // RISK-012: used to compare exactly
        #expect(protection.covers(normalizedPath: h("Work/Keep/x")))
        #expect(protection.covers(normalizedPath: h("work/KEEP/x")))
        #expect(!protection.covers(normalizedPath: h("Work")))
    }

    @Test func cleanedDedupesAndSorts() {
        #expect(UserProtection.cleaned(["/b", "/a", "/b"]) == ["/a", "/b"])
    }
}
