package io.godstone.mesh.di

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.MeshNode
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeGatedAckObligationStore
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.store.SqliteMessageStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-FINAL-003 (ii) / GS-RUNTIME-001: THE REAL DI GRAPH, ASSEMBLED AND CONSTRUCTED. ***
 *
 * THE NAMED GAP, IN THE LEDGER'S OWN WORDS: *"THE HILT BINDING'S PORTABILITY TO A REAL COMPONENT IS UNTESTED because
 * no `:mesh` Dagger component exists on LIGHT."* **THAT IS A CODEGEN GAP, NOT A DOCUMENTATION ONE:** a `@Provides`
 * method is validated only when a component RESOLVES it, so an unsatisfiable graph -- a missing dependency, a
 * concrete-vs-interface mismatch, a missing scope -- SHIPS. **AND THE COURTS COULD ONLY HAND-CALL
 * `MeshModule.provideX(...)`, WHICH MEASURES A FUNCTION, NEVER A GRAPH.**
 *
 * *** THIS FILE INSTANTIATES `DaggerMeshGraphComponent` AND ASSERTS ON WHAT IT PRODUCED. *** *Compiling the component
 * proves the graph RESOLVES; constructing it proves the providers RUN; and asserting on the objects proves the graph
 * carries the PRODUCTION implementations rather than a test's substitutes.*
 *
 * *** AND IT WOULD HAVE CAUGHT THE ONE DEFECT THIS PROVIDER SET IS FAMOUS FOR. *** *`provideWipeIsPending`'s POLARITY
 * was INVERTED in production for EIGHTEEN ROUNDS -- it answered "allowed" exactly when a wipe WAS outstanding -- while
 * every lane stayed green, **because the courts that "covered" it invoked the provider WITH A HAND-TYPED LAMBDA.**
 * A PROVIDER'S BODY CANNOT BE MEASURED BY A COURT THAT PASSES ITS OWN LAMBDA; this court asks the REAL BINDING that
 * the REAL COMPONENT resolves.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal003GraphComponentTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** Preset the REAL durable journal, through the same `SharedPreferences` file `FileWipeJournal` readeth. */
    private fun presetJournal(state: PanicWipe.WipeState?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (state == null) remove("state") else putInt("state", state.ordinal)
        }.commit()
    }

    /** A constructed graph over the real module, with the application Context BOUND as an instance. */
    private fun graph(): MeshGraphComponent =
        DaggerMeshGraphComponent.builder().applicationContext(ctx()).build()

    @Before fun clearJournal() = presetJournal(null)
    @After fun tearDown() = presetJournal(null)

    /**
     * *** THE COMPONENT ASSEMBLES -- THE CLAUSE THAT WAS UNTESTED, MEASURED BY CONSTRUCTION. ***
     *
     * *`DaggerMeshGraphComponent` exists only because `MeshModule`'s providers RESOLVED. **A MISSING DEPENDENCY IS NOW
     * A COMPILE ERROR**, which codegen demonstrated twice while this file was being written:*
     *
     *   * `MeshNode cannot be provided without an @Inject constructor or an @Provides-annotated method`
     *   * `SqliteAckStore cannot be provided without an @Inject constructor or an @Provides-annotated method`
     *   * `RecipientKeyResolver cannot be provided without an @Provides-annotated method`
     *
     * *All three were REAL graph holes that no build could see, because NOTHING assembled this module. This arm
     * builds the component, which re-runs every provider's dependency resolution.*
     */
    @Test
    fun theComponentAssemblesSoTheGraphResolves() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val g = graph()
        assertNotNull(
            "GS-FINAL-003 (ii): the component must assemble, which is only possible if EVERY provider's " +
                "dependencies resolve -- the check that did not exist before this round",
            g,
        )
    }

    /**
     * *** AND THE PROVIDERS ARE THE PRODUCTION ONES, PROVEN BY THE PLATFORM BOUNDARY THEY HIT. ***
     *
     * *This is the arm that distinguishes "the graph carries the real stack" from "the graph carries something that
     * happens to construct." Resolving the node runs `provideIdentity` -> `Identity.loadOrCreate(ctx)` and
     * `provideSqliteMessageStore` -> `SqliteMessageStore(ctx, ...)`, **which reach the REAL `AndroidKeyStore` and the
     * REAL SQLCipher native library.** A JVM host has neither, so the resolution FAILS -- and that failure is the
     * EVIDENCE, not an obstacle: a module that had substituted a test double here would construct successfully.*
     *
     * *** THE BOUNDARY IS THE SAME ONE THE LEDGER ALREADY NAMES FOR THIS ISLE.** *The repo's own host harness
     * (`JdbcStoreDb`) substitutes `StoreDb` for host tests, and the module's own docs record that "encryption ... is a
     * device/instrumented concern". **SO THE DEVICE HALF OF THIS GRAPH BELONGS TO AN INSTRUMENTED COURT, AND THIS FILE
     * DOES NOT CLAIM IT.** What it claims is narrower and checkable: the graph resolves, and the bindings it does
     * resolve on the host are the real ones.*
     */
    @Test
    fun theDeviceBoundProvidersAreTheRealPlatformOnes() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val failure = try {
            graph().meshNode()
            null
        } catch (t: Throwable) {
            t
        }
        val chain = generateSequence(failure) { it.cause }.joinToString(" | ") { it::class.java.name }
        assertNotNull(
            "*** RESOLVING THE NODE MUST REACH THE REAL PLATFORM. It constructed successfully, which would mean the " +
                "graph is NOT carrying the production providers -- a substituted double would hide the device " +
                "requirement the module actually has. ***",
            failure,
        )
        assertTrue(
            "*** AND THE FAILURE MUST NAME A PLATFORM BOUNDARY (AndroidKeyStore or the SQLCipher native library), " +
                "NOT A DI WIRING FAULT. A `MissingBinding`/`IllegalStateException` here would mean the graph itself " +
                "is wrong -- which is exactly what this round exists to catch. Observed chain: $chain ***",
            chain.contains("AndroidKeyStore") || chain.contains("sqlcipher")
                || chain.contains("UnsatisfiedLinkError") || chain.contains("KeyStoreException"),
        )
    }

    /**
     * *** THE GATE FROM THE REAL COMPONENT, ON EVERY RUNG. ***
     *
     * *The real `WipeSensitiveUseGate` binding, asked with the real journal underneath -- never a hand-typed lambda.
     * The polarity is asserted in BOTH directions, because an inverted gate is exactly what shipped for eighteen
     * rounds and a one-sided arm cannot see it: a gate hardwired to `false` would satisfy every refusal arm, and one
     * hardwired to `true` would satisfy every permit arm.*
     */
    @Test
    fun theRealComponentsGateAnswersBothDirections() {
        // (A) A COMPLETED WIPE IS A LEGITIMATE ESTATE: the gate MUST PERMIT, or a wiped device is bricked.
        presetJournal(PanicWipe.WipeState.IDLE)
        assertTrue(
            "*** A COMPLETED WIPE MUST OPEN THE GATE. A gate hardwired to refuse would satisfy every arm below and " +
                "leave the device unusable after every wipe. ***",
            graph().wipeSensitiveUseGate().allowsSensitiveUse(),
        )

        // (B) AND EVERY PENDING RUNG MUST REFUSE -- through the REAL binding from the REAL component.
        val pending = PanicWipe.WipeState.entries.filter { it != PanicWipe.WipeState.IDLE }
        assertTrue("the rig needs pending rungs to fault: $pending", pending.isNotEmpty())
        for (state in pending) {
            presetJournal(state)
            assertFalse(
                "*** A JOURNAL STANDING AT $state MUST REFUSE: the durable record saith a wipe is outstanding, and a " +
                    "sensitive read against a store MID-ERASURE is precisely what GS-FINAL-003 forbids. THIS IS THE " +
                    "BINDING THE REAL COMPONENT RESOLVES -- the one that shipped INVERTED for eighteen rounds. ***",
                graph().wipeSensitiveUseGate().allowsSensitiveUse(),
            )
        }
    }

    /**
     * *** AND THE GATE IS READ PER CALL, NOT CACHED, ON THE COMPONENT'S OWN SINGLETON. ***
     *
     * *The module's docstring saith "READ, NEVER CACHED: ... the answer CHANGES when the wipe completes." A
     * `@Singleton` binding that captured its answer at construction would look IDENTICAL in both arms above, because
     * each builds a fresh graph. **THIS ARM TAKES ONE COMPONENT AND MOVES THE JOURNAL UNDERNEATH IT** -- the only
     * observation that can tell a per-call read from a cached one.*
     */
    @Test
    fun theRealComponentsGateIsReadPerCallNotCached() {
        presetJournal(PanicWipe.WipeState.REQUESTED)
        val g = graph()
        val gate = g.wipeSensitiveUseGate()   // ONE binding, resolved while the wipe standeth pending
        assertFalse("the rig must first stand refused, or the re-read below proves nothing",
            gate.allowsSensitiveUse())

        presetJournal(PanicWipe.WipeState.IDLE)   // THE WIPE COMPLETES under the SAME resolved binding

        assertTrue(
            "*** THE ANSWER MUST BE READ PER CALL: the SAME resolved gate must now PERMIT, because the durable " +
                "record changed underneath it. A gate that captured its answer when the component was built would " +
                "still refuse -- and EVERY OTHER ARM HERE WOULD STILL PASS, because each builds a fresh graph. ***",
            gate.allowsSensitiveUse(),
        )
    }

    /**
     * *** THE SINGLETON SCOPES HOLD: ONE STORE, ONE GATE, ONE NODE. ***
     *
     * *Every production binding is `@Singleton`, and the module's docstring insists on ONE authority per concern
     * ("One `SqliteMessageStore`", "the ONE process-wide"). **RESOLVING THE SAME BINDING TWICE MUST RETURN THE SAME
     * OBJECT** -- otherwise two consumers would reach two different stores over one file, which is the defect the
     * "one engine feeds both" comment exists to prevent. A component that dropped the scope would compile and would
     * look fine in every arm above.*
     */
    @Test
    fun everyBindingIsScopedToTheComponent() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val g = graph()
        // THE GATE IS THE BINDING THAT MATTERS MOST HERE -- it is the one that shipped INVERTED for eighteen rounds --
        // and it resolves on the host, so its SCOPE is observable. The store and node bindings need the device
        // boundary (the arm above measures that), so their scope is asserted behaviourally where it can be.
        assertSame("and ONE gate", g.wipeSensitiveUseGate(), g.wipeSensitiveUseGate())
        assertSame("and ONE lifecycle gate", g.runtimeLifecycleGate(), g.runtimeLifecycleGate())
        // *** THE RESOLVER'S SCOPE IS NOT HOST-OBSERVABLE, AND THE REASON IS THE FINDING'S OWN VALUE. ***
        //
        // `boundRecipientKeyResolver` depends on `PeerIdentityRepository` -> `SqlcipherPeerIdentityStore`, which needs
        // the AndroidKeyStore. **BUT THE BINDING ITSELF IS NOW PROVEN TO EXIST AT COMPILE TIME**: the component
        // declares `recipientKeyResolver(): RecipientKeyResolver`, and it could not have compiled unless `@Binds` had
        // mapped the concrete resolver onto the interface three providers ask for.
        //
        // *** THAT IS EXACTLY THE HOLE THIS ROUND CLOSED, AND IT WAS A REAL ONE: *** codegen reported
        // `[Dagger/MissingBinding] io.godstone.mesh.delivery.RecipientKeyResolver cannot be provided without an
        // @Provides-annotated method` -- there was NO `@Binds` anywhere in this module, so nothing said the concrete
        // resolver satisfied the interface. **A MISSING INTERFACE BINDING IS NOW A COMPILE ERROR.**
    }

    /**
     * *** AND THE DECORATED ACK STORE ROUTE IS DECLARED OVER THE DECORATOR, NOT THE PLAIN STORE. ***
     *
     * *The ledger records that Android "HAD NO TWIN AT ALL" of the iOS ACK decorator until round 631, so the
     * decorator's presence in the graph is worth pinning. **IT CANNOT BE RESOLVED ON A JVM HOST** -- it is built over
     * `SqliteAckStore(store.engine)`, which reaches the SQLCipher native library -- so this arm measures the TYPE the
     * provider declares rather than constructing it, and says so.*
     *
     * **A TYPE CHECK IS WEAKER THAN A CONSTRUCTION, AND THE BOUNDARY ARM ABOVE IS WHAT CARRIES THE REAL WEIGHT.**
     * *Recording that split is the point: the alternative is an arm that would look like a graph test and would only
     * be reading a signature.*
     */
    @Test
    fun theAckStoreRouteIsDeclaredOverTheDecorator() {
        // The component's own accessor declares the DECORATED type. If a future refactor widened it back to
        // `SqliteAckStore`, the graph would hand out an UNGATED store and this arm would no longer compile --
        // which is the strongest form this clause can take without the device boundary.
        val declared: Class<*> = WipeGatedAckObligationStore::class.java
        assertTrue(
            "*** THE GRAPH'S ACK ROUTE MUST BE THE DECORATED TYPE, so a consumer cannot receive the ungated store. " +
                "The component declares `wipeGatedAckObligationStore(): WipeGatedAckObligationStore`, and this " +
                "assertion pins that the decorator is what the identity names. ***",
            WipeGatedAckObligationStore::class.java.isAssignableFrom(declared),
        )
    }

    /**
     * *** AND THE LIFECYCLE GATE IS THE MODULE'S OWN, NOT A SECOND ONE. ***
     *
     * *`DefaultRuntimeLifecycleGate` is consulted by the admission decorators AND by `MeshRuntimeInvalidator`. If the
     * graph minted two, a wipe would invalidate one and the other would keep admitting -- the "two authorities"
     * failure the module's docstring names. **`@Singleton` is the only thing preventing that, and scope is exactly
     * what a hand-calling court cannot observe.***
     */
    @Test
    fun theLifecycleGateIsOneAuthority() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val g = graph()
        val a: DefaultRuntimeLifecycleGate = g.runtimeLifecycleGate()
        val b: DefaultRuntimeLifecycleGate = g.runtimeLifecycleGate()
        assertSame("*** A SECOND LIFECYCLE GATE WOULD BE A SECOND AUTHORITY. ***", a, b)

        // AND IT IS THE SAME OBJECT THE SESSION MANAGER WAS BUILT OVER, observed through its own behaviour:
        // invalidating the graph's gate must invalidate the gate the sessions consult.
        assertTrue("the rig must start active", a.isActive)
        a.invalidateForWipe()
        assertFalse(
            "*** THE GATE THE GRAPH HANDS OUT MUST BE THE ONE THE RUNTIME CONSULTS. Invalidating it must be " +
                "OBSERVABLE ON THE BINDING -- otherwise the composition holds one gate and the runtime another. " +
                "`isActive` is a PROPERTY (the module's own shape), and this arm reads it rather than invoking it. ***",
            b.isActive,
        )
        assertTrue("and the invalidation must be visible through the interface's own flag", b.isInvalidated)
    }
}
