import Foundation

/// CRYPTO-005: **THE COMPOSITION'S TRUST ADAPTER** -- a `RecipientTrustResolver` over the LAB'S OWN KEY TABLE.
///
/// WHY AN ADAPTER RATHER THAN A REWRITE: the lab trusteth a node by its signing key (`ComposedNode.trust(_:signingKey:)` ->
/// `MutableKeyTable.put`), while `SendDirectAuthority` demandeth a `RecipientTrustResolver` whose answer is a TYPED `ResolvedRecipient`.
/// Production already hath a policy-bearing resolver (`TrustedPeerIdentityResolver`, over a `PeerIdentityLookupSource`) -- BUT GIVING THE LAB
/// ONE WOULD CHANGE **WHAT THE LAB MEANS BY TRUST**, WHICH IS OUTSIDE THIS FINDING'S SCOPE. THIS ADAPTER THEREFORE **CHANGETH NOTHING ABOUT WHAT
/// THE LAB TRUSTS** WHILE MAKING THE SEND PATH CAPABLE OF A DURABLE ENQUEUE -- WHICH IS THE CARD'S OWN SCOPE, AND THE CONSERVATIVE CHOICE.
///
/// **AND IT FAILETH CLOSED IN THE ISLE'S OWN VOCABULARY**, WHICH THE TRUST SEAM ALREADY SPEAKETH (`ResolvedRecipient` distinguisheth `absent`
/// from `corrupt` from `storageFailure` -- the very doctrine this finding repaired INTO the journal's `load` at round 475):
///   * a node id ABSENT from the table is **`.absent`** -- ABSENCE IS NOT A FAULT, exactly as `JournalLoadResult.notFound` is not one;
///   * a lookup that THROWETH is **`.storageFailure`** -- a fault is NEVER folded into absence;
///   * and a row that cannot yield the four fields `approved` requireth is **`.corrupt(reason:)`**, NOT a silent success.
///
/// *** THE LAB'S TABLE CARRieth A SIGNING KEY PER NODE ID AND NOTHING ELSE, SO THE OTHER TWO FIELDS (`recipientStaticDhPub`,
/// `acceptedGeneration`) COME FROM **THE NODE'S OWN BINDING MATERIAL**, SUPPLIED HERE AS PROVIDERS. THAT SPLIT IS THE ONE DECISION THE
/// COMPOSITION MAKETH, AND IT IS MADE EXPLICIT IN THE INITIALISER RATHER THAN HIDDEN IN A DEFAULT. ***
public final class KeyTableTrustResolver: RecipientTrustResolver, @unchecked Sendable {
    /// The lab's own trust table: a signing key per node id.
    private let signingKeyForNodeId: @Sendable (Data) throws -> Data?
    /// The binding half the table doth not carry: the node's static DH public half, by node id.
    private let staticDhForNodeId: @Sendable (Data) -> Data?
    /// And the accepted generation of that binding, by node id.
    private let generationForNodeId: @Sendable (Data) -> UInt32?

    public init(signingKeyForNodeId: @escaping @Sendable (Data) throws -> Data?,
                staticDhForNodeId: @escaping @Sendable (Data) -> Data?,
                generationForNodeId: @escaping @Sendable (Data) -> UInt32?) {
        self.signingKeyForNodeId = signingKeyForNodeId
        self.staticDhForNodeId = staticDhForNodeId
        self.generationForNodeId = generationForNodeId
    }

    public func resolve(recipientTrustRef: Data) -> ResolvedRecipient {
        let signingPub: Data?
        do {
            signingPub = try signingKeyForNodeId(recipientTrustRef)
        } catch {
            // A THROW IS A FAULT, AND A FAULT IS NEVER ABSENCE.
            return .storageFailure
        }
        guard let signingPub else {
            // THE LAB KNOWETH NO SUCH NODE: `.absent`, NOT A FAULT AND NOT A REFUSAL.
            return .absent
        }
        guard let staticDh = staticDhForNodeId(recipientTrustRef) else {
            return .corrupt(reason: "the trust table yielded a signing key but no static DH half for this node")
        }
        guard let generation = generationForNodeId(recipientTrustRef) else {
            return .corrupt(reason: "the trust table yielded a signing key but no accepted generation for this node")
        }
        return .approved(recipientNodeId: recipientTrustRef, recipientSigningPub: signingPub,
                         recipientStaticDhPub: staticDh, acceptedGeneration: generation)
    }
}
