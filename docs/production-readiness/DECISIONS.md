# DECISIONS

Statuses: ACCEPTED (builder-recorded, not external approval) / PROPOSED / SUPERSEDED.

## D-T01-a [ACCEPTED] Private evidence root
Path: /Users/oculus/Projects/GODSTONE_BUILDER_EVIDENCE (sibling of the original
checkout; outside every worktree, so it can never dirty either tree).

## D-T01-b [ACCEPTED] Continuation worktree
Path: /Users/oculus/Projects/GODSTONE_BUILDER, branch codex/production-blueprint,
created from exactly b5c3d3d394b70cf356cdde33b47511dad7cbb95c; original checkout
untouched on codex/archive-reliability (status bytes compared before/after, equal).

## D-T01-c [ACCEPTED] Planning-snapshot drift is documented, not corrected
The planning snapshot reported 33 porcelain entries (not a file count); the live
inventory counts 156 entries (18 modified + 138 untracked, the import package
included). Inventory bytes take precedence over snapshot prose.

## D-T01-d [ACCEPTED] Ignored-path classification policy
Relevant fixtures: allowlisted prefixes content/ crypto/ safety/ meshsim/ wire/
dist/ artifacts/ scripts/ ci/ provenance.json, minus build-noise markers
(__pycache__/, *.pyc, build dirs, venvs). Six such fixtures were inventoried and
preserved; they are debug/past-run outputs, NOT approved inputs.

## D-T01-e [ACCEPTED] Builder runtime facts (this environment)
Python 3.14.4: shutil exposes copy2/copyfile spellings; the copy_file spelling is
absent here (AttributeError at import-time during T01 development). Tools must
adapt; the classic spelling is reserved for runtimes that provide it.

## D-T02-a [ACCEPTED] Requirement alias resolution in the runner
TASKS.json manifests declare `requires: 'python'` while the machine
provides `python3` only (PEP 394: the unversioned alias is optional).
The runner accepts a versioned provider when it is the very
executable argv[0] names (python3 / python3.14 satisfies python);
unrelated tools never qualify and genuinely missing tools still
BLOCK. First observed as a real BLOCKED outcome, then resolved.

## D-T02-b [ACCEPTED] Harness discovery (read-only)
omp (Oh My Pi CLI) found at /opt/homebrew/bin/omp, self-reported
version 'omp/18.1.13'; `omp models ls --json` listed 742 models
(read-only catalog; captured under private evidence T02/probes/).
No model session was launched and no unverified launch command was
recorded. ollama 0.33.2 is present but does not satisfy the
NATIVE_MODELS gate. DGX/Linux: absent. JDK: unusable on this
machine (Android Gradle targets blocked at environment level).

## D-T02-c [ACCEPTED] Evidence placement and id uniqueness
Runner command entries follow the section 25 schema (exit_code, test
counts as UNKNOWN when absent); logs live under <evidence>/<task>/logs
with sha256 recorded; entry ids get a -NNN suffix when a log name
would collide, keeping the log append-only and every record addressable.

## D-T08-a [ACCEPTED] SessionSlot is the single serialization authority
All relation-scoped operations (handshake completion, seal, open, readiness
query, retire, and the drop transition) enter their relation through one lock
owned by the slot, never through the manager-wide map lock. The manager lock
guards only the registry mapping itself. Destructive lease destroy is routed
outside the serialize lock to avoid reentrancy hazards, and retired slots are
removed together with their lock entries; the remembered-generation registry is
bounded (256) so a replacement handle for the same relation carries generation
+1. Both engines implement the identical design.

## D-T08-b [ACCEPTED] Self-witnessing serialisation and teardown parity
Each slot records the peak number of distinct threads ever simultaneously
inside its serialize region (Kotlin: Thread identity + depth; Swift:
pthread_t identity + depth). The concurrency test asserts the peak stays below
2 after the join, so a lock-free mutation cannot survive silently. This
witness was required: the M2 mutation (serialize made non-locking) initially
SURVIVED the Swift host because retire() bypassed the slot lock; routing
retire through serialize on both engines (parity fix) made M2 kill on both
(negative evidence: M2b Android concurrency failure, M2c Swift 24 witness-
peak assertion failures). Lesson recorded: teardown paths must share the same
entry point as the operations they terminate, or the invariant is untested.

## D-T09-a [ACCEPTED] Canonical advertising adapter and injectable hooks
The mesh advertisement is produced by a canonical adapter (BleAdvertiser)
that translates a BLE-advertising-payload object model into an ordered
instruction stream executed by AdvertisingHooks. The single production hooks
implementation (RealAdvertisingHooks) is the only file touching
android.bluetooth.le in the advertising path; tests substitute a recording
double and inspect the exact settings and instruction stream that would
reach the platform. The decision logic - availability, GATT readiness,
legacy 31-octet budget audit, SecurityException handling - lives in the
adapter and is fully JVM-inspectable. Typed AdvertisingResult surfaces
every platform outcome; a stop without an outstanding submission is a
documented no-op, not a failure.

## D-T09-b [ACCEPTED] UUID-only air payload, LinkInfo served by GATT
The legacy defect (13-octet LinkInfo record pushed into the legacy
advertisement via addServiceData, exceeding the budget and leaking the
identity hint on air) is removed: the canonical payload carries only the
Flags AD and the complete 128-bit canonical service UUID list (21 octets).
The whole LinkInfo record remains served by the GATT link-info
characteristic provider (verified byte-identical to the snapshot), and the
scanner filter shares the single canonical UUID constant with the
advertisement. Both historical overflows (service data 52, manufacturer 38,
name 33 octets) are refused before dispatch. Mutations M1 (re-add service
data with the verbatim historical condition bytes) and M2 (blind the
budget audit) were killed with positive test execution and zero compile
errors. The isServiceReady gate keeps a private setter in production; JVM
tests drive it through the documented markServiceReadyForTest seam that
mirrors the platform callback transition.

## D-T09-c [ACCEPTED] Builder runtime facts (this environment)
The map façade java.util.LinkedHashMap does not expose the stdlib
mapValues extension (calls to it cascade into unresolved-reference errors
on the lambda body); entry iteration and index assignment are the proven
idioms. Array copy helpers spell copyOf/copyOfRange verbatim as shipped by
the baseline; token verification against the baseline bytes (ord dumps) is
the reliable channel, not tool-rendered text.

## D-T10-a [ACCEPTED] Contract-driven GATT profile with a whole-tree provisioning gate
The GATT surface of a GodStone peripheral - service A001 and the inbox/digest/
link-info characteristics A002/A003/A004 - is defined once by the generated
wire contract and consumed by RequiredCharacteristicSet on each engine. The
Android server previously served only inbox and link info (the digest
characteristic existed as a constant but was never installed and never
resolved); iOS served all three with hand-rolled FD01/FD02 characteristic
values that matched neither each other across engines nor the contract. All
installation, resolution and routing now derive from the contract: the server
installs its tree data-driven (property masks, permission mapping, CCC
descriptor on every notify-capable characteristic), the central resolves the
whole discovered tree (duplicate first, then unknown, then property gaps) and
fails provisioning on any deviation, and inbound writes route by the single
classify authority so LinkInfo records never reach the record decoder. The
legacy FD short-form values are deleted, never dual-registered, and refused
by the resolvers. Android gained the digest characteristic for cross-engine
parity; the Android subscription routing now ignores CCC writes owned by
non-inbox characteristics, mirroring the CoreBluetooth didSubscribe filter that
iOS already had.

## D-T10-b [ACCEPTED] Mutation campaign and the crash-tolerance lesson
Six mutants over three families (reverted FD constant in each production
adapter, blinded accepts(), truncated installation) were killed with positive
executions and zero compile errors on both engines. The first Swift run of
the truncated-installation family exposed a harness flaw: raw indexing of the
installed array trapped the test process after two witnesses, truncating the
report. The suite was hardened to map/zip views that report the same
differences as data (14 assertion failures across 6 cases, no trap), and the
family was re-run to a complete report. Rule recorded: resolver tests must
observe, never index blind.

## D-T10-c [ACCEPTED] Builder runtime facts (this environment)
Kotlin reports out-of-range list access as a test failure the JVM survives;
Swift traps the whole xctest process (signal 5) on the same class of defect,
aborting the remaining cases. Swift suites that inspect generated collections
must therefore prefer total, map and zip views over positional indexing when
the collection shape is the thing under test. The five-task boundary ladder
(L0-L1) caught a latent ci/symbols.py misattribution (nested types stealing
outer-class members) that had shipped green since T06; fixed with brace
matched declaration regions (commit f9633dd).

## D-T11-a [ACCEPTED] Context-bound scan callbacks and a single bounded discovery surface
Android scan callbacks previously mutated transport state with no notion of
which registration produced them: a delayed result of a stopped scan landed
in the state of the next run, and the metadata, rssi and hint caches grew
without limit under a flood of distinct advertisers (the driver's hint cache
was write-only). After T11 a registration is created complete, epoch plus
callback identity plus lease, before startScan is told to call anybody back.
The platform shim performs no mutation: it captures an immutable ScanEvent
naming its source context (no platform object rides the event; a late
callback can deliver only the snapshot). All mutation runs in the reducer,
which consults the exact context identity, the epoch read at arrival and the
lease, at every step including revalidation on completion before the
scheduling step. A scan failure terminates only its own context; permission
restoration is simply a fresh registration, and stop() releases the run's
registration and its bounded surface. BoundedDiscoveryIndex applies the
64-peer bound before any insertion, on both the transport and the driver:
least recently observed unpinned entries leave first, deterministically in
observation order, while active relations - scheduled clients, live driver
connections, published relations - are pinned and never evicted; if the
whole surface is pinned a newcomer is expelled instead of disturbing live
work. Metadata and signal are kept in one record per address so a flood
counts once against one bound and the two fields can never diverge.

## D-T11-b [ACCEPTED] Builder runtime facts (this environment)
Gradle's build cache serves testDebugUnitTest FROM-CACHE and materializes the
JUnit XML lazily: a mutation run whose tree hash matches a cached entry can
produce an empty results directory, and even a genuinely failing run may not
have unpacked the XML when the post-run extractor reads it. Mutation and
verification invocations therefore pass --rerun-tasks, and extractors must
fall back to the gradle "N tests completed, M failed" summary in the raw
log. The android ScanCallback facade names its failure hook onScanFailed
(not onScanFailure); BleLinkInfoConstants.SHORT_DIGEST_BYTES is 6, so a
13-byte LinkInfo payload is version+flags+hint(4)+digest(6)+queue. The
five-mutant campaign (arrival epoch read removed, arrival consultation
removed, bound never enforced, pinning removed, failure clears the run) was
killed with full 13-case executions and exact witnesses each.

## D-T12-a [ACCEPTED] One terminal authority for locally ended attempts
A local close invalidates the GATT callback lifetime: any slot that, after a
reject, provisional timeout or local cancel, still rested CLOSING awaited a
didDisconnect that could never arrive, leaving the peer unreachable for the
epoch. T12 makes termination explicit: TerminalEvent{RelationKey, reason}
names the exact relation that ends, and one terminate authority under the
driver lock performs the whole completion - the relation transitions once,
the lease leaves the capacity authority once (identity-matched), the
publication comes down once, the slot rests terminal at IDLE of that
generation - and returns an outcome, so effects (DisconnectGatt, PublishLost)
are scheduled from the event that earned them, never from a re-read of
current state. Late platform terminals for ended generations are idempotent
no-ops; foreign-generation events are refused entirely. Production callbacks
lost their default-zero fallbacks: handlers require their tokens, absent
arrival tokens are refused rather than correlated to the current slot, and
each scheduled client carries the relation generation it was stamped with,
so the close of the captured handle belongs to the exact attempt that
captured it (closeCapturedHandle, once). The server's local reject-teardown
rests QUARANTINED, terminal in itself, mirroring the iOS didSubscribe filter
at the platform boundary.

## D-T12-b [ACCEPTED] Builder runtime facts (this environment)
Mutation campaigns must run against committed trees: an uncommitted witness
strengthening was invisible to the disposable worktree, and a survivor verdict
for the transport-gate mutant was an artifact of the stale witness (the driver
re-checked the token, so the removed transport guard had no observable
consequence until the witness was strengthened to observe the gate's own side
effect on the live connection object). Corollary rule adopted: a redundant
defense-in-depth guard is only as alive as a witness that can see it. Also:
the gradle build cache serves testDebugUnitTest FROM-CACHE with lazy XML
materialisation even for genuinely-changed inputs on this machine, so campaign
and verification invocations pass --rerun-tasks, extractors read the fresh
JUnit XML by absolute path, and the gradle "N tests completed, M failed"
summary is treated as a fallback signal, not as proof of execution; a
gradle exit 0 with an absent summary line means "task delivered from cache",
never "suite passed".

## D-T13-a [ACCEPTED] Epoch-owned manager pairs with three-way source authentication
Long-lived CBCentralManager/CBPeripheralManager pairs with reassigned
delegate proxies made callback-source identity unprovable: a reused manager
carries wiring, state and in-flight callbacks across the epoch boundary, and
an event stamped with the current epoch could ride in from an object the new
epoch never created. Each opening of a transport epoch now builds a fresh
ManagerContext - one pair from the injected TransportManagerFactory, born on
a dedicated serial queue named for the epoch, wired to its own delegate
proxies once at birth and never rewired. The reducer admits a manager-sourced
event only when three identities agree: the sender is the very manager
instance of the active context, the wired delegate is still the context-own
proxy, and the event names the context's epoch. The zero token is no token:
absent tokens are refused, never correlated to the current slot, and the
default-zero fallbacks came out of the production callbacks and their
dispatcher surface. Stopping retires the context; late events of a closed
epoch are dropped where they stand. The five-mutant campaign (reuse of
managers with re-stamped delegates - the cards own negative case - blinded
sender check, dropped token obligation, removed wiring check, look-alike
birth wiring) is killed entirely, each mutant by a named witness; the
perfect-alibi case (stranger manager wearing the genuine delegate and the
current token) is what gives the sender check its full force.

## D-T13-b [ACCEPTED] Builder runtime facts (this environment)
The host CoreBluetooth overlay is thinner than production iOS: CBManager has
no readable delegateQueue on macOS, so queue dedication is observed at the
factory seam (the very queue object handed to both managers of a birth) plus
a serialisation barrier probe, and device runs must read delegateQueue
directly. Also: an output-token corruption pattern in this harness can swallow
the middle of long identifier literals when the assistant emits them
(DispatchQueue arrived as DispatchQ, twice, including inside a fix attempt);
repairs must assemble such tokens from short string fragments or character
codes and verify the bytes on disk after every write. Corollary: git
diff --check before committing catches the trailing-whitespace residue left
at injected seam lines, and the mirror parity check (sync --check) must run
after every canonical edit, not only before commit.

## D-T14-a [ACCEPTED] One uninterrupted reduction per admitted event on the epoch serial executor
Every mutating transport entry is wrapped so its validation, state transition and
effect scheduling run as one operation on the ManagerContext's dedicated serial
queue; reentrance is thread-marker based (the context stamps its own executing
thread), so an adapter already inside its context admits inline and never
recurses into a queue of its own. The lifecycle takes the same discipline: stop
quiesces the closing epoch on its own executor and start quiesces the previous
one before installing fresh drivers, which is what makes the card's barrier
scenario - pause between validation and action, queue a stop/start, resume the
old work - resolve to a single total order. Driver references are read once at
the critical instant of admission under the lock that guards their assignment,
and every action keeps the validated context identity with it, so a stale event
mutates no new state. Sealing and opening are trust work: they run outside the
critical section and their completions return token-checked to the executor
before any effect commits or the delegate is notified; failure is kept
distinguishable from empty success at every completion site. Chosen over
fine-grained locking around each mutation because the defect class the card
names is the split between validation and action, which only a serialised
reduction eliminates. The five-mutant campaign pins each pillar: unwrapping any
single entry or the lifecycle hop, or delivering untagged through an adapter,
kills a named witness case.

## D-T14-b [ACCEPTED] Builder runtime facts (this environment)
The output-token corruption pattern seen before (D-T12-b, D-T13-b) extends to
long literal payloads inside scripts that pass through the editing tools: a
Python campaign driver authored with long Swift anchor strings silently stopped
matching, while byte-identical round-trips of short structural fragments
succeeded; the durable form is to derive every anchor from the file's own bytes
via structural regex and rebuild replacements from captured groups, never to
carry long literals across the channel, and to let asserted counts (exit codes,
byte-equality round-trip checks) - not displayed text - decide whether a spec
is fit. Two more cases of the same family: a test verifier misreported '1
failure' as no run because its match pattern was written for the plural, and
the dash in the per-case summary line went unmatched by an over-escaped
bracket; verdicts were therefore recomputed offline from the retained logs,
and the runs themselves were never rerun for convenience of the parser. Also:
test seams must be declared forget-only where they must not be writable
(public private(set) plus an explicit clear...ForTest seam), and a dropped
assertion during a house-style rewrite of a test is invisible to green suites -
mutation resistance of the suite was proven only after the missing order
assertion was restored; keep campaigns should verify witness names, not merely
counts.

## D-T15-a [ACCEPTED] Timers are leases named by immutable whole keys
Every window - the provisional outbound attempt and the inbound inactivity
watch - is stored as a TimerLease keyed by TimerKey(RelationKey, operation
kind, unique operation id). Storage, cancellation and replacement run only
through reducer bodies on the epoch serial executor, each comparing the
whole key of the current occupant before removing anything: cancel releases
exactly the handle that matches, never a blind sweep of the slot that could
catch a newer lease. The fire closure carries the whole key and the arming
epoch's context; identity is re-verified under the lock before the
corresponding timeout reduction runs. Two decisions carry the weight: the
operation id source is monotone for the transport lifetime and never reset
at an opening (a reset lets a successor issue keys colliding with retired
ones - demonstrated by mutant MU-6, where the stale-fire refusal collapsed);
and the connect advance re-arms the window through the same reducer -
observed necessary because the admission arm alone left the replacement path
without production coverage, and it mirrors the Android driver's connect
lease from T12. Deadlines are computed against the injected MonotonicClock
at every arm, including replacements (MU-5 pins the stale-inherited variant).

## D-T15-b [ACCEPTED] Builder runtime facts (this environment)
Three campaign lessons extended: (1) an equivalence-class trap - the first
MU-2 and MU-5 passed as SURVIVED because the correct compare-cancel ordering
masked them: with the map membership check first in the field, weakening a
single redundant guard changes nothing observable; faithful mutants must
degrade every guard on the path (fire-time check and reduction re-validation)
or move the hoisted evaluation above the cancel; the specs were redeployed
non-equivalent before reporting, and no surviving mutant was ever called
killed. (2) The mutation driver's member-slice scanner must begin its
next-member search after the declaration's own line: with an attribute line
attached, a fixed-offset scan self-matched the declaration and truncated the
slice. (3) The verdict parsers are now built from character pieces (dashed
case lines, singular-or-plural failure summaries) and byte-exact
install/revert round-trips are a pre-condition of the campaign, asserted by
exit status, not by displayed text - the output-token corruption family
documented in D-T13-b/D-T14-b continues to strike long literals crossing
tool channels, and structural derivation from the file's own bytes remains
the durable defense.

## D-T16-a [ACCEPTED] Ambiguous subscriptions are refused, not guessed through
The actual CBCentral presented with a subscribe request is retained with the
inbound lease together with an inbox-subscription record naming the
characteristic and the maximum update length; responder notifications are
sent through the retained handle alone - a subscriber-list entry by itself
proves no more which central presented the subscription. Unsubscribe requests
are filtered by characteristic: a request naming the digest characteristic is
acknowledged leaving the inbox intact; a request that cannot name which
characteristic was written is the ambiguity the platform callbacks must not
guess through - the identity is quarantined for the epoch, the legacy removal
still proceeds with the driver transiting the slot as recorded since T12, and
only rotation of the manager context releases the quarantine, never a guessed
timeout. Generation matching compares the number the request itself carries
with the number the subscription stands under - the current one is never
resolved in its place - and the rejection answers with the distinguishable
rejectStaleUnsubscribe token against the driver's empty success. A failed
connection attempt is terminal immediately and requests no cancellation; the
lost-discovery path does, and the purge's cancel-record stash proves the
distinction (MU-7 pins both legs). Quarantine metadata is bounded (1024
marks, refusals counted); the admission history is bounded (4096 notes per
context, overflow counted); a context that has exhausted its budget rotates
at the next fully drained point - never while busy - and the rotation, which
re-initialises the managers from the factory on a fresh dedicated queue, is
the only release.

## D-T16-b [ACCEPTED] Builder runtime facts (this environment)
Five lessons, three from the corpus teaching. (1) The existing suites are the
normative record of the callback shapes: the first strict gates I staged over
subscribe/unsubscribe (nil-central claims quarantined; ambiguous-form
quarantine without removal) broke 14 recorded substrate cases; the rework
restored the documented behaviour - a missing handle claims nothing and
renews the record, an ambiguous unsubscribe quarantines and still removes,
answering with the driver's own action. New gates must be staged against the
recorded suites before the campaign, not after. (2) On this host the system
CoreBluetooth accepts punned present (NS)-objects on the central side
(updateValue to subscribers, identifier reads), but the peripheral side is
messaged with the whole family (discoverServices:, discoverCharacteristics:for:,
writeValue:for:type:, setNotifyValue:for:) - an incomplete mock raises
unrecognized selector; the responder declarations must enumerate every
selector the stack sends, taken from the production source's own call sites.
(3) The generation numbers are those of the drivers, and the drivers are
re-initialised for every transport epoch, so numbers restart at 1 with each
new context: staleness is judged within an epoch and the epoch token, not the
number, authenticates a request. The first stale-unsubscribe staging assumed
monotone numbers across a rotation and fell to this fact; the restaged case
now asserts the restart and the epoch-token gate. (4) `as!` between
unrelated NSObject classes is a checked cast and traps with SIGABRT; the
corpus's unchecked unsafeBitCast resolves in the test target and is the
idiom for punning - it must also keep the punned object alive for the
messages the stack will send it. (5) A compile-invalidated mutant run is not
a kill: the first MU-3 used an Optional-Bool `&&` form, did not compile, was
recorded INVALID (its log retained as MU-3-firstpass-invalid-t16.log) and
was redeployed type-preserving before any verdict was read.

## D-T17-a [ACCEPTED] The registry is a standing dependency of the shipping path
The plaintext fallback of the sessions-nil transport is removed on both platforms: without a
trusted registry, or when the registry refuses to seal, or before the relation reaches the
cryptographic ready, submission answers rejected with a bounded event and no unauthenticated
octet reaches the wire. The Android primitive keeps an optional sessions seam for testability
only; composition at the node mandates a real registry and retains the fail-closed one when
none is handed over, so the refusal is told at the admission gate, consulted before any
connection is located. The ready is dual - the physical readiness (subscription and attribute
space agreed) opens only the handshake door, and the cryptographic ready (a trusted session
slot) is reachable only through the handshake entries; beginHandshake is idempotent for its
own phase, exactly as the iOS twin always was. The openWithResult of the registry is total by
contract: a frame the cipher refuses is told by the rejected answer, whatever the underlying
layer throws, and the transport collector wraps its consultation in a catch of its own - a
forged packet produces one bounded event and the collect loop runs on, witnessed by the case
that ships the valid frame after the forgery.

## D-T17-b [ACCEPTED] Outlets behind hooks, one keying law, the blocking bridge
The Android outlets (notification and write legs of both planes) travel behind a BleOutletHooks
seam, following the AdvertisingHooks precedent: production binds the real gattServer and client
connections, tests inject the recording fake - the same separation the iOS suite performs with
its punned protocol objects. The keying law is one: a connection's own peerId is the registry
key on both planes (the drivers create connections from the colonned address bytes), while the
caller's argument to send or begin is a locator only, resolved either as the six-octet wire
id or as the seventeen-character address text. The handshake writers travel in the handler's
own course through the sanctioned runBlocking bridge - the precedent the LinkInfoSnapshot-
Authority sets in main - because the fork's bare scope.launch dispatches starve on this JVM
test harness; the iOS twins have always written synchronously, so the platforms now agree not
only in law but in motion. The demotion of every ForTest seam to internal, witnessed by the
reflection scan (internal members compile to mangled names, so an unmangled sighting is a
public escape), closes the release-symbol gate.

## D-T17-c [ACCEPTED] Builder runtime facts (this environment)
(1) The harness input layer and the display layer both mangle the fork's package brand: a
brand token typed into a tool call arrives at the file without its final letter, and printed
bytes collapse the other way; only byte-level inspection (od, hashes) is trustworthy, so the
brand is never typed but harvested from production bytes by regex and pasted by substitution.
(2) Two parser lineages must adjudicate a campaign: the summary line alone under-declares (a
line is a total across suite groups, and taking the max over lines is safe, believing a lone
min can mislead), and the case-line bracket capture must escape the class brackets the harness
itself prints - the first LOGRE, missing the closing class bracket the quantifier should stand
in, read the empty set and cried SURVIVED over eight killed. (3) A mutant is dead, not
invalid, only when the declared witness fell: M2 laid no failures while the lab stood at a
stale head, and the strengthened witness - which probes the trusted door from the bound state
directly - buried it at the next campaign. Pinned heads, forced reverts, and liveness-guarded
baselines are the campaign's own hygiene. (4) The in-repo evidence tree is tracked property:
an earlier straggler EVIDENCE/ nested inside it on the case-insensitive filesystem and a
sweep by name deleted the whole corpus; it returned from HEAD by checkout, and since then
the builder writes campaign evidence to the private external root only, and never sweeps by
name in either tree. (5) An unbounded wait is the fault of the observer, not of the observed:
every await now names itself and dumps the bounded ring, and it was those names that confessed
the premature ready-marking and the starved dispatch.

## D-T18-a [ACCEPTED] The reservation precedes the seal; the window slides
The whole-record writer of the outbound path takes its law from the card and the codec
together: no nonce is burnt and no sequence number consumed until every refusal has been
made - the sealed length (the clear plus the twenty-four-octet envelope the transport
ciphertext format lays out: nonce eight, tag sixteen) against min(MAX_RECORD, MAX_FRAGMENTS
times the agreed attribute space less the eight-octet record header), the fragment ceiling,
the station of the relation, and the budgets of the direction. The seal then happens exactly
once and the fragmentation exactly once, the sequence number is taken at that single seat
(takeOutboundSequence), and the values enter the staging - at most sixteen held, at most one
in flight, at most four records admitted - as an invariant kept by topping up on real
completions, not as a bar at the gate: a record of sixty-four fractions enters while the
window fills and drains about it, the queue-full refusal re-hands the very same fragment
unaltered, and a write that fails midway closes the relation and releases the staging while
the durable store stands untouched for a fresh session. The fixed five hundred twelve octet
bulk gate left the send path as the card commands - the dynamic ceiling carries the full
digest where the old gate refused - and the interface property canBulk with its constant
remain for the transports that report them. The two voices of every leg (Boolean and typed)
answer through one source, the Boolean delegating to the typed, so no caller old or new is
deceived.

## D-T18-b [ACCEPTED] Builder runtime facts (this environment)
(1) A fresh generator seeded within one clock tick repeats its neighbour's stream: the
fixture's identity draws, each instantiating its own SecureRandom inside the same
millisecond, drew sixty-four equal hints and the pair loop despaired of an ascending
relation. One generator, shared and called at load, cured it; witnesses that draw
randomness share the source, they do not mint it afresh per call. (2) The fork compiler
refuses while (true) with continue standing inside an inline synchronised lambda - it
reports 'Nothing was expected' where the corpus elsewhere, in plain functions, permits
the same construction; the hand-off was reformed as a total guard without a loop and the
complaint ceased. (3) The testing framework's fail answers void in this language binding:
an elvis whose right arm is fail() yields Any and poisons the locals' types; error(),
which returns Nothing, is the right verb for the elvis, and fail() keeps its station as
the bare statement. (4) The campaign's law proved itself again: a mutant must be
equivalent to no surviving verdict - the first M2 struck only the in-flight identity and
survived, because the duplicate it would misdirect arrived upon an empty flight; the
witness was strengthened to name the travelled fragment while another value stood in
flight, the mutant to strike both acknowledgement gates, and the kill then told the true
tale. (5) The recording fake registers attempts as faithfully as completions - the two
refused hands stand in the written list beside the eighteen values that travelled, and
the expectations count all twenty; a witness that counted only the successes would have
misspoken the queue.


## D-T19-a [ACCEPTED] The reservation precedes the seal; each direction carries its own maximum
The whole-record writer of the outbound path speaks the selfsame contract the Android twin
keeps, in the island's own speech: reserve(kind, clearLength, capacity) measures the sealed
length - the clear text plus the twenty-four octets the transport ciphertext format lays out,
nonce eight and tag sixteen - against min(MAX_RECORD, MAX_FRAGMENTS times (capacity minus the
eight-octet record header)), and refuses by value with nothing consumed; the capacity is the
direction's own, maximumWriteValueLength(for: .withoutResponse) upon the write leg and
maximumUpdateValueLength upon the manager serving the update leg, so one record may lawfully
fragment differently at the two ends (the card's own arithmetic: at capacity 264 the two
ceilings meet exactly at 16384 octets, sixty-four whole fractions of 256). The seal then
happens once, the fragmentation once, the sequence number passes its single seat
(takeOutboundSequenceIfReady, gated by the phase under the same lock), and the window of the
direction - sixteen held, one in flight, four admitted - slides by topping up only as real
completions retire values. A refused update returns its very fragment unaltered for the next
report of readiness; a write without response is retired upon the platform's acceptance and
claims nothing of the remote; a failed leg closes the relation and releases the staging, the
durable application data untouched. The responder-send census is kept for every attempt,
refused or taken alike, through the very handle retained with the lease, as it has been kept
since T16.

## D-T19-b [ACCEPTED] Builder runtime facts (this island)
(1) A method the framework imports speaks under the selector the header declares, not the one
the Swift name would auto-derive: the write maximum is sent as maximumWriteValueLengthForType:,
and a fake that answered the auto-derived name crashed the suite with an unrecognized selector -
pinned by an explicit @objc annotation, as the crash in the field taught. (2) Each suite owns
its witnesses: when production learns to ask a new question of a role, every fake standing for
that role across the subscribing suites must be bidden to answer it - the responder's send now
asks maximumUpdateValueLength of the destination central, and the central-acting fakes of the
subscribing suites were amended. (3) The real manager's answer to an update towards a mock
handle is the sandbox's own business and was observed to differ between runs; a fixture must
not rest its verdicts on it - the responder's manager is pinned through the factory seam to
answer as the house record states. (4) The test filter matches the qualified name
(target.Class) on a freshly built bundle; a warm build may answer the bare class name - the
gate logs use the bare dialect proven there, the lab the qualified. (5) The mirrored package
under ios/Packages is the compiler's true input: the canonical sync script's outputs - sources
and tests alike - must be committed together with the source they mirror, or a pinned lab
builds the elder law and the campaign's mutants die of nothing; the mutants are installed
where the build reads, upon the mirror.

## D-T19-c [ACCEPTED] The elder fixtures restated to the window law
Two witnessed cases of the elder suites counted in the old hard queue's semantics and were
restated, each keeping every assertion that still speaks true: the T17 backpressure case once
demanded that the queue admit a few sends before it reported its full - under the window law
the verdict follows the leg, the very first send may report backpressure while its values
wait, and the case now proves the holding through the direction's own writer witnesses; the
T16 digest-unsubscribe case counted an admitted send as a delivery - with the manager pinned
the delivery is true again, the census records stand, and the two verdicts were brought back
to that recorded truth rather than to the old silent queueing. No other expectation of the
elder suites was touched; the whole package of seven hundred forty seven cases remains green.


## D-T20-a - the absolute lease and the owner who alone closes
The reassembler keeps its sliding courtesy untouched (byte-identical law, duplicates included)
and gains one absolute token per admission: {relationKey, seq, admissionId, deadlineMono}, thirty
seconds on the ingress clock, moved by no arrival. When the term passes the reassembler releases
the buffers and raises a first-notice-wins token; only the owner, consulting the notice at the
ingress after the fragment is processed, closes the relation - and closes it through the
platforms own arms (handleCentralDisconnected with the peers tokens; the server fall with the
drivers generation; on the island the sanctioned reductions with the registrations own generation,
epoch and manager counsel). The close purges the registers whole and withdraws the publication;
the heartbeat sweepInboundLeases serves the silent-peer case no delivery will ever arrive to
trigger. This is documented local resource defence: the wire, the eight header bytes and the
uint8 framing are untouched, and no external gate moved.

## D-T20-b - the court of the epoch clause, found by elimination
The epoch-bypass control escaped four times before the court was made sound. The reductions
preamble keeps its own epoch clause (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch),
and it dams every event that the authenticator would also refuse - so an event bearing a
misrepresented epoch is refused twice and the bypass of either clause alone is unobservable.
The witness therefore carries the zero epoch: exempt by the reductions own clause, yet a value
no live context can hold (the counter is bumped before the context opens and counts from one),
so the authenticators first conjunct stands sole as the discriminating gate. With the whole line
bypassed the case falls; with production standing it lives: killed, once, by the ledgers own hand.
The elder trials also teach the oracles dialect: a method-form filter answers 'Test run with 0
tests' on this harness - only the class-form filter speaks the truth - and the lab must carry
the machines local.properties (provisioning, never content) and be mirror-synced after every
install, or the compiler reads stale scrolls and the witness swears to an unmutated world.

## D-T20-c - fixtures that speak only what the platform itself delivered
The adapter-facing fixtures received one law: a trace event names only the arguments the real
delegate receives (the peripheral identity, the value that travelled with the event, the octets
as delivered) plus the object identities the factory injected at the managers birth; where the
OS passes nil the trace carries nil. A trace from an uninjected manager, or crossing to another
peers address, is refused at the fixture and makes no delivery at all - the refusal is witnessed
as zero deliveries, never as an invented exception. The callback inventory is enumerated from the
platforms real delegate surface; sources the host harness cannot reach are recorded SKIPPED with
the reason, never quietly passed. The invariant ledger of each schedule reports every check by
id, scenario and statement, so the record shows what was verified, not merely that something
passed.

## D-T20-d - attestation seals follow the files, brought forward at the boundary
The boundary ladder found the MeshNode authority blobs behind the files: the T17 acts had
legitimately amended both islands MeshNode (typed answers, the fail-closed seam deletion) without
bringing the ARCHITECTURE_INVARIANTS seals forward. The windows of T03/T06/T35/T38/T40 govern the
invariant values - those stand untouched and the vector tests green; the seals are attestations
that follow the files, so they were recomputed, audited hunk by hunk against the T17 acts, and
brought forward in their own committed act (2e0b3f7), never folded into the tasks own commits.
The L0/L1 run that followed speaks green; the evidence rests in EVIDENCE/T20/ladder-boundary.

## D-T21-a - the drop belongeth to the owners hand
The destruction of the session slot is the mandate of the relation's owner: the close, the
heartbeat sweep, and the lease consult at the writers door. It was found dwelling inside the
shared inbound arm, which the platforms ambiguous-unsubscribe moment also traverseth - and
there it slew the T16 rotation law, which bideth the quarantined relation keep its trusted
session until the rotation. The drop was therefore excised from the arm and re-inlisted at the
three owners' hands, each of which is a true termination. The android island, whose disconnect
arms are wholly terminations, heard the same law at both arms and stood it unchanged.
## D-T21-b - the gate closings are narrowed to the handshake word
A record out of order at the initiators door is a conflicting sequence: the exact relation
perisheth. The first gate closings slew too wide - they fell upon every unexpected stage alike -
and were cured by narrowing: the closing reacheth only records whose type is HS1, HS2 or HS3,
and never upon a quarantined relation, which awaiteth its rotation. A DATA record at an unready
stage remaineth the T17 bounded refusal: typed, one event, the relation standeth.
## D-T21-c - the mid-flight duplicate case was deleted, not weakened
The section thirteen permiteth no retransmission within the same session: the bounded
transcript ignoreth exact duplicates only at the expected or just-consumed stages, and after the
trust an unexpected handshake record is refused by the gate and the relation is closed. A case
that replayed an in-flight duplicate mid-exchange was therefore tried and found to be no
distinct law from the T20 transcript witness, and it was deleted. On the island the reachable
form of the same law stands as the duplicate counsel refused by the gate after the trust.
## D-T21-d - the reservation flood is beyond the tests reach on the island
The writers pump draineth as it runneth, synchronously under the lock, and the staging is
private: no public handleth stayeth the flood between the stage and the drain. The reservation
refusal branch is accordingly proven on the android island by the flooder (the campaign witness
testTheHS3ReservationFailureClosesTheRelationExactly, KILLED), and on the island by inspection
of the very arm that recordeth 'hs3 reservation refused' and closit the exact relation. The
island court keepeth the duplicate-counsel witness in its place.
## D-T21-e - one entrance per peer, and the census that proved it
The publication ledger keepeth but one entrance per peer: the hand-stand of a second key
under a central already enrolled by the ladder was refused by that law - a production truth
found by the test, not a defect. The absence witness (the controller's READY publisheth no
link-ready relation) is proved by the equality of the census before and after the exchange;
the instrument itself is proved by withdrawing the ladders own enrollment and re-enlisting it,
the census falling and rising accordingly.

## D-T22-a - the court must be driven through the transports own begin
A court that minted the first counsel by calling the session manager directly left the initiators
transport behind the handshake: the second was never answered, the third never came forth, and three
witnesses failed with silent rings. The law of section thirteen bindeth the exchange to the transports
entry (beginTrustedHandshake), which witnesseth the duplex, elects by the hint order and advanceth the
stage machine; the court therefore driveth every exchange through that door, and the harvest of the
third baselines the capture-peripherals writes BEFORE the push and filtereth by the type octet - the
selfsame recipe the T21 twins established.
## D-T22-b - the ingress gate is the first to speak; the doors stage-guards are the second
A late or duplicate handshake counsel is refused by the ingress gate with the cry "at stage" before
the door is reached; the doors own stage-guards (hs1 at stage, hs3 at stage) ring when the gate hath
admitted the record and the hand itself must refuse. The courts therefore witness the ring by substring
("at stage" or "unexpected"), not by one exact phrase, and every such witness also proveth the fall of
the relation - a bounded refusal that let the relation stand would be the deeper defect.
## D-T22-c - the flood of the queued second is made by the fragment-bound, not by a knob
The writers pump on both isles draineth as it runneth, synchronously under the lock, and the staging
is private: no public handle stayeth the flood between the stage and the drain. The reservation-refusal
branch is therefore reached by making the destination central answer a capacity of ten octets: the
two-hundred-and-twenty-nine-octet second then requireth one hundred fifteen fragments, past the frozen
bound of sixty-four, and the fragmenter itself refuseth the record. The door hearkeneth the verdict,
ringeth "hs2 reservation refused", and the owners hand closeth the exact relation.
## D-T22-d - trust is never inferred from the subscription the ladders brought
The ladders rise and the subscriptions come; yet when the authority denieth the binding (revoked or
rolled back), the exchange foundereth at the third: the binder consulteth the authority as it openeth
the third counsel, refuseth the seal, and the relation perisheth with its slot - no session stands
trusted, no announcement riseth. The refusing authority is injected at the pairing forge, the selfsame
SessionManager entrance the production pairing useth.
## D-T22-e - the public discovery field and the authenticated identity are kept separate
An alien first counsel of the right shape is ANSWERED (the gate is bounded by the public discovery
field alone), while the alien third - right of length, false of seal - is CAST OUT at the authenticated
hour: the binder proveth the static key against its own remembrance and the relation falleth. The
discovery hint that the responder boundeth from the link-info exchange is immutable for the life of
the relation: the selfsame bound remembrance answereth the true counsel still, though a lesser
advertisement is shouted after the binding. Proven identically on both isles.
