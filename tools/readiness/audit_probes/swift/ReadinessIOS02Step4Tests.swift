// IOS-02 STEP 4 -- "At the proper trusted-ready transition, automatically initiate the specified encrypted
// challenge/echo procedure using the existing DATA writer": the RED arm, PARKED, with a MEASURED DIAGNOSIS.
//
// THE RED WAS TAKEN AND IT DID NOT COMPILE-FAIL -- IT RAN: 17 tests, EXACTLY 1 FAILURE, the other 16 green:
//   "IOS-02 step 4: THE TRUSTED-READY TRANSITION MUST ITSELF INITIATE THE ENCRYPTED CHALLENGE -- nothing
//    else did, and the hour is trusted."
// (And the arm's FIRST draft used T22's rig names -- `rigT23`, `cleanup` -- rather than THIS file's own
// `standDoor`: THE SIXTH SPECIES AGAIN, A NAME ASSUMED INSTEAD OF READ, caught by the compiler.)
//
// THE REPAIR WAS WRITTEN: at the initiator's trusted-ready transition
// (`handleInboundHandshakeRecordInitiatorSide`, immediately after `guard conn.markTrustedReady()`), the
// transport issueth the challenge ONCE -- only if none already standeth -- and NAMETH any refusal in the
// rejection ring rather than swallowing it. T23's six challenge-driving arms were reconciled BY
// CONSTRUCTION to the new law: they no longer issue a challenge of their own; they READ the one production
// put on the wire (`keyConfirmation.outstanding()`) and answer THAT.
//
// **AND THE MEASUREMENT REFUTED THE PLACEMENT: 17 tests, 43 FAILURES, IN 299 SECONDS** (the timeouts alone
// made iteration expensive). The symptom is exact and was read from the ring: the challenge DATA, issued at
// the initiator's transition, reacheth a RESPONDER STILL IN HANDSHAKE --
//   "ingest.write|record type data at stage handshake" -- and the relations never come to ready.
// THE LAW IS NOT WRONG; THE PLACEMENT IS: the INITIATOR marketh its trusted hour when it WRITETH hs3, while
// the RESPONDER marketh its own only upon RECEIVING it. A record sent at that instant is therefore EARLY,
// however trusted the sender's own hour.
//
// SO THE NEXT INSTRUMENT IS NAMED: FIND THE TRANSITION WHERE THE PEER IS ALSO KNOWN TO BE TRUSTED (or queue
// the challenge behind the peer's readiness -- e.g. issue it when the responder's trust is observed, or when
// the peer's own counsel arrives on a ready relation), and prove it with the SAME silent arm, which still
// standeth in the patch.
//
// THE WHOLE ATTEMPT IS PRESERVED AS A RE-APPLIABLE PATCH:
//   `.../REMEDIATION/IOS-02/round193-step4-challenge-at-the-transition.patch`
//   (sha256 d282c1ce49f18b25..., 174 lines).
//
// NOTHING WAS LEFT BROKEN: the tree was REVERTED and re-measured green (T23 16 tests / 0 failures; python
// courts OK).

// ============================================================================================================
// ROUND 194: **MY ROUND-193 DIAGNOSIS IS WITHDRAWN, AND THE MEASUREMENT IS THE REASON.**
//
// I wrote that the placement was wrong -- that the initiator marketh its hour when it WRITETH hs3 while the
// responder marketh its own only upon RECEIVING it, so a record sent then is EARLY. THAT WAS A PLAUSIBLE
// STORY, NOT A MEASUREMENT, and it is refuted by looking again at the RIG rather than at the prose:
//
//   THE RIG SELECTED THE THIRD COUNSEL BY POSITION --
//       `sample({ r.capturePeer.writes.last(where: { $0 != hs1 }) })`  in T23,
//       `if w.count > priorCount, let last = w.last, last != hs1 { hs3 = last; break }`  in T21 and T22 --
//   so with production now writing the CHALLENGE immediately after hs3, the positional rule picked THE
//   CHALLENGE and pushed it to the responder, which refused a DATA record at a handshake stage:
//       "ingest.write|record type data at stage handshake"
//   THE PLACEMENT WAS NOT THE CAUSE. THE RIG'S RULE WAS.
//
// AND THE SECOND MEASUREMENT SAITH THE SAME OF THE ARMS THEMSELVES: with the rigs corrected to select HS3 BY
// TYPE, the failures fell from 43 to 25 and their OWN WORDS name the remaining cause --
//       "the third record must be HS3"   ... got 24  (0x18 = DATA, the challenge)
//       "the HS3 message is one hundred ninety-seven octets" ... got 74 (the challenge's record)
// so THE ARMS ASSERT ON RECORD POSITIONS TOO, and an extra record shifts every one of them.
//
// THE RECONCILIATION IS THEREFORE: CONVERT POSITIONAL RECORD SELECTION **AND POSITIONAL ASSERTIONS** TO
// TYPE-BASED ONES, ARM BY ARM -- a rig helper is not enough, because the arms look at `writes[N]` directly.
// BOTH HALVES ARE PRESERVED: the rig fixes in
//   `round194-step4-with-type-based-selection.patch` (sha256 ddfe20b2bb649ba3...), which carrieth the repair,
// the RED arm, the reconciled challenge reads AND the type-based HS3 selection (T21, T22, T23).
//
// THE LESSON, AND IT IS THE ONE THIS PROGRAMME KEEPS RE-LEARNING: **A CAUSE THAT SURVIVES EVERY REPAIR TO THE
// PLACE THE FAILURE APPEARETH IS NOT IN THAT PLACE** -- and a diagnosis built from reading the production
// code, without reading the RIG that driveth it, is a story. The ring message was the evidence, and it
// pointed at the responder's gate; the rig's rule was what fed it.

// ============================================================================================================
// ROUND 195: THE REPAIR IS PROVEN ON THE WIRE; WHAT REMAINETH IS THE ARMS' POSITIONAL EXPECTATIONS.
//
// With the round-194 patch applied AND every HS3 detection converted to search the NEW WRITES BY TYPE, the
// measured failures fell 43 -> 25 -> 23 -> 22 -> **14**, and the wire itself now beareth witness to the law:
//
//       "the HS3 never answered; ring: | state=ready | writes=2 kinds=[20, 24] | slot=true"
//
// -- 20 is HS3 (0x14), 24 is the challenge's DATA (0x18), IN THAT ORDER, UPON A READY RELATION. THE
// PRODUCTION LAW IS IMPLEMENTED AND CORRECT. (Two of my own fixes were wrong on the way and are recorded in
// the code: I first tested only `w.last` for the HS3 type, forgetting that hs3 is no longer last; and my
// first regex missed the `last != hs1` variant of the same idiom in T21 and T22.)
//
// THE FOURTEEN THAT REMAIN SAY WHAT THEY WANT IN THEIR OWN WORDS, AND EVERY ONE IS POSITIONAL:
//   * T21 `testTheHS3PrecededEveryDATAInTheWriterOrder` -- "the last writing of the exchange must be..."
//     got 24 where it expecteth 20. THE LAW IT NAMETH STILL HOLDETH ([hs3, DATA] is the order); what falleth
//     is its positional reading. It should assert that the FIRST hs3 precedeth EVERY DATA by INDEX.
//   * T22 `testTheRejectedAndRevokedBindingsPerishTheRelationAtTheThirdCounsel` -- "the denied binding must
//     refuse the seal; ring: ingest.write|record type data at stage handshake": **THE PRODUCTION BEHAVIOUR
//     HERE IS RIGHT, NOT WRONG** -- a responder whose binding was DENIED never reacheth its trusted hour, so
//     it MUST refuse the challenge's DATA. The arm readeth the ring's LAST entry and now findeth that
//     refusal where it expected another.
//   * T22 `testTheThirdSpokenAgainAfterTheTrustIsAConflictingSequence` and its kin: the pair's trust is
//     asserted through a path that now also carrieth the challenge.
//
// SO THE NEXT ROUND'S WORK IS EXACTLY THIS: RE-FRAME THOSE FOURTEEN ARMS' POSITIONAL EXPECTATIONS (the
// writer-order arm to index comparison; the ring-reading arms to search for their named reason rather than
// the last entry), and RUN THE WHOLE LANE -- the repair itself is already written and proven.
//
// THE WHOLE STATE IS PRESERVED: `round195-step4-type-based-everywhere.patch` (sha256 1bd3a01ddd49e29d...),
// carrying the production repair, the silent RED arm, the reconciled challenge reads, and every type-based
// record selection. The tree was REVERTED and re-measured green.
