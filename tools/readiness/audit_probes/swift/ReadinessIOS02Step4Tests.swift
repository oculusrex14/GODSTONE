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
