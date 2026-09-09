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
