import Testing
@testable import MicaraCore

@Suite("PhoneRoster")
struct PhoneRosterTests {
    @Test func joiningGivesAGreenDotAndTheOrderIsArrivalOrder() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.joined(id: "B", nowMs: 10)
        r.joined(id: "C", nowMs: 20)
        #expect(r.dots.map(\.id) == ["A", "B", "C"])
        #expect(r.dots.allSatisfy { $0.state == .connected })
    }

    @Test func losingAndRegainingMediaKeepsTheSameId() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        #expect(r.dots == [PhoneDot(id: "A", state: .reconnecting)])
        r.mediaRestored(id: "A", nowMs: 200)
        #expect(r.dots == [PhoneDot(id: "A", state: .connected)])
    }

    @Test func lostMediaNeverExpires() {
        // The phone is still here (WebSocket open): erasing its dot would erase
        // a participant who is present.
        var r = PhoneRoster(ghostTTLMs: 1_000)
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        r.prune(nowMs: 100_000)
        #expect(r.dots == [PhoneDot(id: "A", state: .reconnecting)])
    }

    @Test func leavingGivesAGhostThatDisappearsAfterTheTTL() {
        var r = PhoneRoster(ghostTTLMs: 30_000)
        r.joined(id: "A", nowMs: 0)
        r.left(id: "A", nowMs: 1_000)
        #expect(r.dots == [PhoneDot(id: "A", state: .reconnecting)])
        r.prune(nowMs: 30_000)
        #expect(r.dots.count == 1)   // only 29 s have elapsed
        r.prune(nowMs: 31_000)
        #expect(r.dots.isEmpty)
    }

    @Test func rejoiningReplacesTheGhostBecauseThePhoneIdChanges() {
        // The server draws a fresh phoneId per WebSocket: a phone that comes
        // back no longer has the same id. Without replacement, a single device
        // would show two dots.
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.left(id: "A", nowMs: 1_000)
        r.joined(id: "Z", nowMs: 2_000)
        #expect(r.dots == [PhoneDot(id: "Z", state: .connected)])
    }

    @Test func rejoiningReplacesTheOldestGhostAndKeepsItsSlot() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.joined(id: "B", nowMs: 10)
        r.joined(id: "C", nowMs: 20)
        r.left(id: "B", nowMs: 100)   // the oldest ghost
        r.left(id: "C", nowMs: 200)
        r.joined(id: "Z", nowMs: 300)
        #expect(r.dots == [
            PhoneDot(id: "A", state: .connected),
            PhoneDot(id: "Z", state: .connected),   // took over B's slot
            PhoneDot(id: "C", state: .reconnecting),
        ])
    }

    @Test func rejoiningAfterTheGhostExpiredAddsABrandNewDot() {
        var r = PhoneRoster(ghostTTLMs: 1_000)
        r.joined(id: "A", nowMs: 0)
        r.left(id: "A", nowMs: 100)
        r.joined(id: "Z", nowMs: 5_000) // ghost expired → a genuine arrival
        #expect(r.dots == [PhoneDot(id: "Z", state: .connected)])
    }

    @Test func joiningWithNoGhostLeavesMediaOrangeDotsAlone() {
        // `mediaLost` is not a departure: a new phone must not steal the slot of
        // a participant who is present but reconnecting its media.
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        r.joined(id: "B", nowMs: 200)
        #expect(r.dots == [
            PhoneDot(id: "A", state: .reconnecting),
            PhoneDot(id: "B", state: .connected),
        ])
    }

    @Test func joinedOnAnAlreadyKnownIdTurnsItGreenAgain() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        r.joined(id: "A", nowMs: 200)
        #expect(r.dots == [PhoneDot(id: "A", state: .connected)])
    }

    @Test func anEventOnAnUnknownIdCreatesNothing() {
        var r = PhoneRoster()
        r.mediaLost(id: "X", nowMs: 0)
        r.mediaRestored(id: "X", nowMs: 1)
        r.left(id: "X", nowMs: 2)
        #expect(r.dots.isEmpty)
    }
}
