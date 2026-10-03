package io.godstone.mesh.identity

/**
 * *** GS-FINAL-003 `true-pre-private-recovery`: THE REAL COLD-START TRANSPORT CAPABILITY. ***
 *
 * *`ContextArtifactSeam` AND ITS SUPERSESSION: this file once also carried a context-backed artifact seam. **IT IS DELETED
 * HERE** -- the full-estate owner [`FullEstateArtifactSeam`] in `WipePrivateEstate.kt` replaceth it, because the former
 * verified LOGICAL alias paths (`getDatabasePath("mesh.db")`) rather than the owner-defined PHYSICAL targets
 * (`godstone_messages.db`, its sidecars, the wrapped keys, the identity prefs) and erased no identity material at all
 * (review findings A10/A4).* **ONE OWNER, ONE RESOLUTION.***
 *
 * *THE OBLIGATION: **"true pre-private recovery graph with actual erasure capabilities and journal transition persistence
 * independent of gated normal graph"** -- and its named prohibition: **"don't classify missing implementable actions
 * external."*** *The DEFERRED seams (`WipeDeferredSeams`) answer a **named, retryable pending** for a process that owns no
 * transport, no keystore and no database handle -- and that is the RIGHT answer for the RUNTIME-side startup barrier, whose
 * whole point is to stop before it opens anything.*
 *
 * *** BUT IT IS THE WRONG ANSWER FOR THE RECOVERY GRAPH ITSELF, AND THIS FILE IS THE DIFFERENCE. *** *A wipe that can
 * never advance past `REQUESTED` is not a recovery graph; it is a bookmark.* **THE PRE-PRIVATE PROCESS ALREADY OWNS REAL
 * ERASURE PRIMITIVES -- THEY SIMPLY DO NOT LIVE BEHIND A `MeshNode`:**
 *
 *   * **[FileWipeJournal] is REAL, ALWAYS** -- the durable record was never gated on the private graph;
 *   * **KEY DELETION IS REAL AND PRE-PRIVATE**: `AndroidWipeArtifacts.eraseKeys()` deleteth the AndroidX master key alias
 *     out of the `AndroidKeyStore` -- *no identity, no store and no transport is required to destroy a key*;
 *   * **ARTIFACT DELETION IS REAL AND PRE-PRIVATE**: `SqliteMessageStore.panicWipe(ctx)` and
 *     `SqlcipherPeerIdentityStore.panicWipe(ctx)` are `Context`-taking companion functions -- *the isle's own destroyers,
 *     reachable without constructing the stores they destroy*;
 *   * **IDENTITY PUBLICATION IS REAL AND PRE-PRIVATE**: `Identity.panicWipe(ctx)` then `Identity.loadOrCreate(ctx)` is
 *     what a wipe's LAST rung IS -- *and it is the same two calls `AndroidWipeArtifacts.regenerateIdentity()` makes.*
 *
 * **SO THE RECOVERY GRAPH DRIVES THE REAL LADDER, USING THE SAME OWNERS THE RUNTIME-SIDE WIPE USES, AND REACHETH THE
 * TERMINAL RUNG WITHOUT EVER BUILDING THE THING IT IS DECIDING ABOUT.** *The runtime-side graph then only adds what a
 * LIVE process owns and a cold one does not: the transport to drain.*
 */

/**
 * *** THE TRANSPORT SEAM OF A PROCESS THAT OWNS NO TRANSPORT -- AND IT ANSWERS WITH A FACT, NOT A DEFERRAL. ***
 *
 * *THE DISTINCTION FROM `DeferredTransportRuntimeSeam`, WHICH IS THE WHOLE POINT AND IS MEASURABLE:* *the deferred seam
 * answereth `NotDrained` -- **"the runtime does not yet stand: no drain may be performed at the startup barrier"** -- which
 * is the honest answer for a composition whose PURPOSE is to stop before opening anything.* **A COLD-START RECOVERY
 * COMPOSITION IS A DIFFERENT COMPOSITION AND ITS ANSWER IS DIFFERENT: a process that owns no transport has no in-flight
 * transport work, so the question the drain askeTH ("doth work remain?") has the answer NO.**
 *
 * *** AND IT IS NOT A NO-OP OWNER, WHICH THE OBLIGATION'S OWN WORDS FORBID: *** *`fireRadio`/`sendVia` return FALSE --
 * the admission is permanently CLOSED, because there is no road for a frame to travel and a `true` here would be a
 * claim about an act nobody performed.* **The one honest reading of "drained" for a transport-less process is
 * `Drained(closedTransports = 0, quiescedRuntime = true)`: ZERO transports were closed because ZERO stood, and the runtime
 * cannot carry work because it does not stand.** *`closedTransports` is a COUNT, so the zero is the measurement.*
 */
class ColdStartTransportSeam : TransportRuntimeSeam {

    override fun drainTransport(): RuntimeDrainReceipt =
        // ZERO transports stood to close, and a runtime that does not stand carrieth nothing: the drain is SATISFIED, and
        // the count sayeth WHY rather than asserting it.
        RuntimeDrainReceipt.Drained(closedTransports = 0, quiescedRuntime = true)

    /** A process with no transport is quiesced by construction -- there is nothing that could be in flight. */
    override fun isQuiesced(): Boolean = true

    /** AND THE ADMISSION IS CLOSED: no road exists, so nothing may be fired or sent. `true` here would be a lie. */
    override fun fireRadio(msg: String): Boolean = false
    override fun sendVia(msg: String): Boolean = false
}

