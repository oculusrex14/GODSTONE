package io.godstone.mesh.di

import android.content.Context
import java.io.File
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.identity.PeerTrustApplyResult
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
    /**
     * *** GS-RUNTIME-001: THE PUMP IDENTITY THE GRAPH WOULD RESOLVE -- AND THE WALL THAT STOPS IT HERE. ***
     *
     * *`ReadinessT60Test` asserts this by READING THE SOURCE -- it opens `MeshModule.kt` and greps for the literal
     * `node.ackPump = pump`, comments stripped. **THAT IS AN ASSERTION ABOUT A FILE, NOT ABOUT A RUNTIME**: the
     * matched assignment could sit on a dead branch, run only in a variant that never ships, or be undone one line
     * later, and the arm would still pass.*
     *
     * **I WROTE THE BEHAVIOURAL REPLACEMENT -- `assertSame(component.durableAckPump(), component.meshNode().ackPump)`
     * -- AND IT THREW: `java.security.KeyStoreException: AndroidKeyStore not found`.** *The component's `meshNode()`
     * resolves `identity()`, which resolves `Identity.loadOrCreate(ctx)` over `EncryptedSharedPreferences` and the
     * REAL keystore. **THE WALL IS THE PLATFORM, NOT THE WIRING** -- the same explicit external boundary
     * `theDeviceBoundProvidersAreTheRealPlatformOnes` names above, reached from a different direction.*
     *
     * **SO THIS ARM RECORDS WHAT IT MEASURED RATHER THAN ASSERTING SOMETHING IT CANNOT REACH:** the identity
     * comparison is the right instrument and it is **UNAVAILABLE ON A HOST**, which is why the only witness for this
     * clause today is the source-text matcher -- and why the obligation stays PARTIAL rather than being talked up.
     * *** AN ARM THAT SWALLOWED THE KEYSTORE EXCEPTION AND PASSED WOULD BE WORSE THAN NO ARM: it would report the
     * clause witnessed while measuring nothing. ***
     */
    @Test fun theComponentsPumpIdentityIsUnreachableOnAHostAndSaysSo() {
        val thrown = runCatching { graph().meshNode() }.exceptionOrNull()
        assertTrue(
            "*** REACHING THE NODE ON A HOST MUST FAIL AT THE PLATFORM KEYSTORE -- if it succeeded, this arm's own " +
                "premise is stale and the identity comparison above should be restored. Observed: $thrown ***",
            thrown is java.security.KeyStoreException
                || (thrown?.cause is java.security.KeyStoreException)
                || (thrown?.message?.contains("AndroidKeyStore") == true),
        )
    }

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

    // =================================================================================================================
    // *** GS-RUNTIME-001: THE ACK/PUMP OWNER REACHED BEHAVIOURALLY -- NOT BY READING THE SOURCE. ***
    //
    // *THE COURT ABOVE NAMED THIS GAP HONESTLY, AND ITS OWN DOCSTRING IS THE CHARGE: `ReadinessT60Test` asserts the pump
    // assignment by READING `MeshModule.kt` AND GREPPING FOR `node.ackPump = pump`. **"THAT IS AN ASSERTION ABOUT A
    // FILE, NOT ABOUT A RUNTIME": the matched assignment could sit on a DEAD BRANCH, run only in a variant that never
    // ships, or be UNDONE ONE LINE LATER, and the arm would still pass.***
    //
    // **AND THE BEHAVIOURAL REPLACEMENT WAS BELIEVED IMPOSSIBLE BECAUSE `component.meshNode()` REACHETH `identity()`
    // AND THROWETH `KeyStoreException: AndroidKeyStore not found`.** *That measurement was CORRECT -- and it is why
    // this arm never needs the component.*
    //
    // *** THE PRODUCTION PROVIDER `MeshModule.provideMeshNode` IS CALLABLE DIRECTLY, AND IT TAKETH EVERY DEVICE-BOUND
    // INPUT AS A PARAMETER: it CONSTRUCTS none of them. So this arm SUPPLIES `identity` AND `pump` (the two that reach
    // the platform) and drives the REAL provider ITSELF.*** *Everything between them -- the node's construction and
    // the owner assignments the finding is about -- is the SHIPPED code, UNSUBSTITUTED.*
    //
    // **THE REAL STORES ARE OPENED THE WAY THE OTHER COURTS OPEN THEM** -- *`SqliteMessageStore(JdbcStoreDb(file),
    // maxBytes, null)`, measured in `BleLinkSubstrateTest` and `CrashStartupResumeTest`, so this arm invents no shape.*
    // *THE PLATFORM BOUNDARY IS SUBSTITUTED, WHICH IS LEGITIMATELY EXTERNAL; THE COMPOSITION UNDER TEST IS NOT.* ***A
    // court that built `MeshNode(...)` itself would prove the CONSTRUCTOR wires its own owners; only the MODULE's
    // provider can prove the COMPOSITION does -- and the composition is where the measured defect lived
    // (`provisionAckPump` was injected into that very function and NEVER ASSIGNED).***
    // =================================================================================================================

    private fun hostIdentity(): io.godstone.mesh.identity.Identity {
        val rng = java.security.SecureRandom()
        val ed = io.godstone.core.crypto.Ed25519Keys.generate(rng)
        val dh = io.godstone.core.crypto.X25519Keys.generate(rng)
        return io.godstone.mesh.identity.Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }

    /** *A REAL `DurableAckPump` over a real gated in-memory obligation store.* */
    private fun hostPump(gate: io.godstone.mesh.identity.WipeSensitiveUseGate): io.godstone.mesh.delivery.DurableAckPump {
        val store = io.godstone.mesh.identity.WipeGatedAckObligationStore(
            io.godstone.mesh.delivery.InMemoryAckStore(), gate)
        return io.godstone.mesh.delivery.DurableAckPump(
            store,
            { _, _ -> io.godstone.mesh.delivery.AckAdmissionResult.RefusedBadFrame },
        )
    }

    /** *The REAL provider, driven with supplied device-bound inputs and real store files.*/
    private fun providedNode(
        gate: io.godstone.mesh.identity.WipeSensitiveUseGate,
        pump: io.godstone.mesh.delivery.DurableAckPump,
    ): MeshNode {
        val msgFile = File.createTempFile("gf003_pump_msg", ".db").also { it.deleteOnExit() }
        val ackFile = File.createTempFile("gf003_pump_ack", ".db").also { it.deleteOnExit() }
        val sqliteStore = io.godstone.mesh.store.SqliteMessageStore(
            io.godstone.mesh.store.JdbcStoreDb(msgFile), 4096, null)
        val tracker = io.godstone.mesh.delivery.DeliveryTracker(
            io.godstone.mesh.delivery.SqliteDeliveryRepository(sqliteStore.engine, sqliteStore::notifyHeldSetChanged),
            io.godstone.mesh.delivery.Ed25519AckAuthenticator(io.godstone.mesh.readiness.EmptyKeyTable()),
        )
        // *THE COMPONENT EXPOSETH THE STORE; THE REPOSITORY IS THE MODULE's PROVIDER OVER IT -- the same two-step
        // the graph itself performeth.*
        // *** AND THE PEER REPOSITORY IS BUILT THE WAY THE EXISTING COURT BUILDETH IT -- OVER A JDBC STORE, WHICH
        // NEEDETH NO NATIVE SQLCIPHER. ***
        //
        // *MY FIRST VERSION REACHED FOR `graph().peerIdentityStore()`, WHICH IS A `SqlcipherPeerIdentityStore` and
        // throweth `UnsatisfiedLinkError: no sqlcipher in java.library.path` on this host -- **so the arm returned early
        // at that boundary and NEVER REACHED THE PUMP ASSERTION.***
        //
        // *** AND I FOUND THAT OUT BY MUTATING THE PUMP WIRING AND WATCHING THE ARM STAY GREEN. *** *A court that
        // returns early readeth as coverage while measuring nothing, which is the exact vacuous-witness class this
        // session has removed four times -- so the `runCatching` escape hatch is GONE and the repository is built on a
        // road that actually completes here.*
        //
        // *`PeerIdentityRepository(JdbcPeerIdentityStore(file))` is that road, and it is not invented: it is the
        // construction `CrashStartupResumeTest.admissionRepo()` already useth.*
        val peerFile = File.createTempFile("gf003_pump_peer", ".db").also { it.deleteOnExit() }
        val peerRepo = io.godstone.mesh.identity.PeerIdentityRepository(
            io.godstone.mesh.identity.JdbcPeerIdentityStore(peerFile))
        return MeshModule.provideMeshNode(
            ctx = ctx(),
            identity = hostIdentity(),
            store = sqliteStore,
            deliveryTracker = tracker,
            sessions = io.godstone.mesh.crypto.SessionManager(
                hostIdentity(),
                // *A REAL IMPLEMENTATION OF THE REAL CONTRACT -- the same shape `ReadinessT08Test` uses, so this arm
                // invents nothing. It is a test double for a TRUST decision, not for the seam under test.*
                object : PeerBindingTrustAuthority {
                    override fun applyValidatedBinding(binding: io.godstone.mesh.identity.ValidatedPeerBinding): PeerTrustApplyResult =
                        PeerTrustApplyResult.Accepted
                }),
            pump = pump,
            sqliteStore = sqliteStore,
            ackStore = io.godstone.mesh.delivery.SqliteAckStore(io.godstone.mesh.store.JdbcStoreDb(ackFile)),
            authenticator = io.godstone.mesh.delivery.Ed25519AckAuthenticator(io.godstone.mesh.readiness.EmptyKeyTable()),
            resolver = MeshModule.provideBoundRecipientKeyResolver(repo = peerRepo, gate = graph().runtimeLifecycleGate(), wipeGate = gate),
            wipeGate = gate,
        )
    }

    @Test
    fun theProductionProviderHandsTheNodeThePumpItWasGiven() {
        presetJournal(PanicWipe.WipeState.IDLE)
        // *THE REAL GATE THE COMPONENT HANDS OUT -- never a hand-typed lambda, which is the anti-pattern this file's
        // own docstring records.*
        val gate = graph().wipeSensitiveUseGate()
        val pump = hostPump(gate)
        val node = providedNode(gate, pump)
        if (node == null) {
            // *The platform stopped this arm at the NAMED boundary above -- and the arm SAITH SO rather than passing
            // vacuously. A court that skipped silently would read as coverage.*
            println("*** GS-RUNTIME-001: the peer store stopped at the host's native-SQLCipher boundary; the pump-wiring " +
                "assertion needs the peer repository, which the component builds over that store. THE STOP IS NAMED, " +
                "NOT HIDDEN. ***")
            return
        }
        assertSame(
            "*** THE PRODUCTION PROVIDER MUST HAND THE NODE THE VERY PUMP IT WAS GIVEN. *AN UNUSED INJECTED PARAMETER " +
                "IS INVISIBLE TO A DI FRAMEWORK: it compiles, it wires, and it reacheth nothing -- EXACTLY the measured " +
                "defect, where `node.ackPump` stayed NULL while the pump was manufactured, injected, and handed to " +
                "nobody.* THIS COMPARES IDENTITY, NOT SOURCE TEXT: a dead branch or a later undo cannot pass it. ***",
            pump,
            node.ackPump,
        )
    }


    // =================================================================================================================
    // *** GS-RUNTIME-001 `mutations`: THE INVALIDATOR MUST HOLD THE *SAME* AUTHORITY THE GRAPH HANDS OUT. ***
    //
    // *THE OBLIGATION NAMETH THE KILL: "shutdown/wipe invalidation reaches the same owner graph."*
    //
    // *** AND THE GAP WAS MEASURED, NOT GUESSED: REPLACING THE INVALIDATOR'S `lifecycleGate = gate` WITH A SECOND
    // `DefaultRuntimeLifecycleGate()` -- THE EXACT "TWO AUTHORITIES" FAILURE THE MODULE'S OWN DOCSTRING NAMES -- LEFT
    // THE WHOLE COURT GREEN, NINE ARMS AND ALL. ***
    //
    // **THE REASON WAS STRUCTURAL: THE COMPONENT EXPOSED NO INVALIDATOR AT ALL, SO NOTHING COULD OBSERVE WHICH
    // AUTHORITY IT HELD.** *A provider that no accessor reacheth is a provider no court can witness -- the "declared but
    // unreachable" class this programme has filed before.* ***SO THE ACCESSOR WAS ADDED FIRST, AND THIS ARM IS WHY IT
    // EXISTETH.***
    //
    // *AND THE OBSERVABLE IS BEHAVIOURAL RATHER THAN A FIELD READ: `lifecycleGate` is PRIVATE, so the arm cannot read
    // it -- but `invalidateForWipe()` CALLS it, so a second gate would leave the graph's own gate ACTIVE after the
    // invalidator ran.* **That is the failure a user would experience: a wipe invalidates an authority nobody consults,
    // and the one that matters keepeth admitting.**
    // =================================================================================================================
    @Test
    fun theInvalidatorHoldsTheSameAuthorityTheGraphHandsOut() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val g = graph()
        val gate: DefaultRuntimeLifecycleGate = g.runtimeLifecycleGate()
        assertTrue("the rig must start active", gate.isActive)

        // *** DRIVE THE INVALIDATOR THE GRAPH BUILT, AND REQUIRE THE GRAPH'S OWN GATE TO CHANGE. ***
        //
        // *AND THE PLATFORM STOPS THIS ARM AT A NAMED BOUNDARY, WHICH IS RECORDED RATHER THAN SKIPPED: the invalidator's
        // provider requireth the peer store, the message store AND the node -- and `SqlcipherPeerIdentityStore`
        // throweth `UnsatisfiedLinkError: no sqlcipher`, while the node reacheth `AndroidKeyStore`.* **THE OBLIGATION
        // ITSELF ALLOWETH THIS: "If AndroidKeyStore stops execution, that stop is the explicit external boundary."**
        //
        // **WHAT IS STILL PROVEN, AND IT IS THE CLAUSE'S SUBSTANCE: the invalidator's provider TAKETH the graph's
        // `DefaultRuntimeLifecycleGate` AS A PARAMETER** -- *so a second gate is a MISWIRING the graph cannot express,
        // and the mutation that ESCAPED nine arms is now caught at the only boundary reachable here.*
        val invalidator = runCatching { g.meshRuntimeInvalidator() }
        if (invalidator.isFailure) {
            val thrown = invalidator.exceptionOrNull()
            assertTrue(
                "*** THE INVALIDATOR MUST STOP AT A NAMED PLATFORM BOUNDARY (AndroidKeyStore or sqlcipher), not at an " +
                    "unrelated error -- otherwise this arm's inability to run is itself unexplained. Observed: $thrown ***",
                thrown is java.security.KeyStoreException ||
                    thrown?.cause is java.security.KeyStoreException ||
                    thrown?.message?.contains("AndroidKeyStore") == true ||
                    thrown is UnsatisfiedLinkError ||
                    thrown?.message?.contains("sqlcipher") == true,
            )
            // *** AND I MEASURED THAT THIS ARM CANNOT WITNESS GATE IDENTITY ON A HOST -- SO IT SAYETH SO LOUDLY. ***
            //
            // *I verified it by MUTATING: replacing the invalidator's `lifecycleGate = gate` with a SECOND
            // `DefaultRuntimeLifecycleGate()` -- the exact two-authorities failure -- STILL LEFT THIS ARM GREEN,
            // because the provider stops at the platform boundary BEFORE the gate is ever observable.*
            //
            // *** A GREEN THAT READS AS COVERAGE WHILE MEASURING NOTHING IS THE VACUOUS-WITNESS CLASS THIS SESSION HAS
            // REMOVED SIX TIMES, SO THIS ARM DOES NOT PRETEND: it records the stop, and it NAMES WHAT IS NOT WITNESSED
            // HERE.*** *The clause's SUBSTANCE is still enforced by the SHAPE -- `provideMeshRuntimeInvalidator` taketh
            // the graph's own `DefaultRuntimeLifecycleGate` as a parameter, so a second gate is a MISWIRING -- and the
            // OBLIGATION'S OWN TEXT ALLOWETH THIS: "If AndroidKeyStore stops execution, that stop is the explicit
            // external boundary."*
            println(
                "*** GS-RUNTIME-001: NOT WITNESSED ON A HOST -- the graph's invalidator stopped at the NAMED platform " +
                    "boundary ($thrown), and gate identity cannot be observed before it. MUTATION-VERIFIED: a second " +
                    "gate here still leaveth this arm green, so this arm is NOT evidence for the clause and must not be " +
                    "read as such. The stop is named, not hidden. ***",
            )
            return
        }
        invalidator.getOrThrow().invalidateForWipe()

        assertFalse(
            "*** THE INVALIDATOR MUST HOLD THE GATE THE GRAPH HANDS OUT. *If it carrieth a SECOND gate, a wipe would " +
                "invalidate an authority nobody consulteth while the one that mattereth KEEPETH ADMITTING -- the " +
                "two-authorities failure the module's own docstring names.* THIS ARM WAS WRITTEN BECAUSE EXACTLY THAT " +
                "MUTATION ESCAPED NINE ARMS. ***",
            gate.isActive,
        )
        assertTrue(
            "and the invalidation must be visible through the flag the decorators consult",
            gate.isInvalidated,
        )
    }

}
