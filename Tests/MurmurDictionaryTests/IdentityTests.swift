import Foundation
import Testing

@testable import MurmurDictionary

/// A reload of the dictionary file must not change which entry is which, or edits made
/// from the panel against the old ids are silently dropped.
struct IdentityTests {
    @Test func reloadKeepsIds() {
        let old = [
            DictionaryEntry(kind: .term, write: "InfoAscent"),
            DictionaryEntry(kind: .correction, write: "Claude Code", hear: "cloud code"),
        ]
        // What a re-parse of the same file produces: same content, brand-new ids.
        let reparsed = old.map {
            DictionaryEntry(kind: $0.kind, write: $0.write, hear: $0.hear, isEnabled: $0.isEnabled)
        }
        let merged = DictionaryEntry.carryingIdentity(from: old, into: reparsed)
        #expect(merged.map(\.id) == old.map(\.id))
    }

    @Test func toggledEntryKeepsItsId() {
        let old = [DictionaryEntry(kind: .term, write: "Alvin")]
        let reparsed = [DictionaryEntry(kind: .term, write: "Alvin", isEnabled: false)]
        let merged = DictionaryEntry.carryingIdentity(from: old, into: reparsed)
        #expect(merged[0].id == old[0].id)
        #expect(merged[0].isEnabled == false)
    }

    @Test func newEntryGetsFreshId() {
        let old = [DictionaryEntry(kind: .term, write: "Alvin")]
        let added = DictionaryEntry(kind: .term, write: "Zernio")
        let merged = DictionaryEntry.carryingIdentity(from: old, into: [old[0], added])
        #expect(merged[0].id == old[0].id)
        #expect(merged[1].id == added.id)
    }
}
