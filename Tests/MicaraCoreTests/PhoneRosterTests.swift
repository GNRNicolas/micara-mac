import Testing
@testable import MicaraCore

@Suite("PhoneRoster")
struct PhoneRosterTests {
    @Test func arriveeDonneUnPointVertEtLOrdreEstCeluiDArrivee() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.joined(id: "B", nowMs: 10)
        r.joined(id: "C", nowMs: 20)
        #expect(r.dots.map(\.id) == ["A", "B", "C"])
        #expect(r.dots.allSatisfy { $0.state == .connected })
    }

    @Test func perteEtRetourDeMediaGardentLeMemeId() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        #expect(r.dots == [PhoneDot(id: "A", state: .reconnecting)])
        r.mediaRestored(id: "A", nowMs: 200)
        #expect(r.dots == [PhoneDot(id: "A", state: .connected)])
    }

    @Test func perteDeMediaNExpirePas() {
        // Le téléphone est toujours là (WebSocket ouvert) : effacer son point
        // reviendrait à effacer un participant présent.
        var r = PhoneRoster(ghostTTLMs: 1_000)
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        r.prune(nowMs: 100_000)
        #expect(r.dots == [PhoneDot(id: "A", state: .reconnecting)])
    }

    @Test func departDonneUnFantomeQuiDisparaitApresLeTTL() {
        var r = PhoneRoster(ghostTTLMs: 30_000)
        r.joined(id: "A", nowMs: 0)
        r.left(id: "A", nowMs: 1_000)
        #expect(r.dots == [PhoneDot(id: "A", state: .reconnecting)])
        r.prune(nowMs: 30_000)
        #expect(r.dots.count == 1)   // 29 s écoulées seulement
        r.prune(nowMs: 31_000)
        #expect(r.dots.isEmpty)
    }

    @Test func rejoinRemplaceLeFantomeCarLePhoneIdChange() {
        // Le serveur tire un phoneId neuf à chaque WebSocket : un téléphone qui
        // revient n'a plus le même id. Sans remplacement, un seul appareil
        // afficherait deux points.
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.left(id: "A", nowMs: 1_000)
        r.joined(id: "Z", nowMs: 2_000)
        #expect(r.dots == [PhoneDot(id: "Z", state: .connected)])
    }

    @Test func rejoinRemplaceLeFantomeLePlusAncienEtGardeSaPlace() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.joined(id: "B", nowMs: 10)
        r.joined(id: "C", nowMs: 20)
        r.left(id: "B", nowMs: 100)   // fantôme le plus ancien
        r.left(id: "C", nowMs: 200)
        r.joined(id: "Z", nowMs: 300)
        #expect(r.dots == [
            PhoneDot(id: "A", state: .connected),
            PhoneDot(id: "Z", state: .connected),   // a repris la place de B
            PhoneDot(id: "C", state: .reconnecting),
        ])
    }

    @Test func rejoinApresExpirationDuFantomeAjouteUnPointNeuf() {
        var r = PhoneRoster(ghostTTLMs: 1_000)
        r.joined(id: "A", nowMs: 0)
        r.left(id: "A", nowMs: 100)
        r.joined(id: "Z", nowMs: 5_000) // fantôme périmé → vraie arrivée
        #expect(r.dots == [PhoneDot(id: "Z", state: .connected)])
    }

    @Test func arriveeSansFantomeNeTouchePasAuxPointsOrangeDeMedia() {
        // `mediaLost` n'est pas un départ : un nouveau téléphone ne doit pas
        // voler la place d'un participant présent mais en reconnexion média.
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        r.joined(id: "B", nowMs: 200)
        #expect(r.dots == [
            PhoneDot(id: "A", state: .reconnecting),
            PhoneDot(id: "B", state: .connected),
        ])
    }

    @Test func joinedSurUnIdDejaConnuLeRepasseAuVert() {
        var r = PhoneRoster()
        r.joined(id: "A", nowMs: 0)
        r.mediaLost(id: "A", nowMs: 100)
        r.joined(id: "A", nowMs: 200)
        #expect(r.dots == [PhoneDot(id: "A", state: .connected)])
    }

    @Test func evenementSurUnIdInconnuNeCreeRien() {
        var r = PhoneRoster()
        r.mediaLost(id: "X", nowMs: 0)
        r.mediaRestored(id: "X", nowMs: 1)
        r.left(id: "X", nowMs: 2)
        #expect(r.dots.isEmpty)
    }
}
