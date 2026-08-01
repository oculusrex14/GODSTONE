# Architecture Decision Records

ADRs separate decisions from implementation evidence. **ACCEPTED does not mean
SHIPPED.** A feature flag may move only after the ADR's acceptance criteria pass
against both platform ports and, where applicable, real radios.

| ADR | Decision | Status | Implementation state |
|---|---|---|---|
| 001 | canonical GMP/2.1 runtime model | **ACCEPTED** | M1-wire open; Android runtime still legacy and disabled |
| 002 | BLE advertisement, record layer and handshake driver | **ACCEPTED** | M2-link open; radio feature flags false |
| 003 | identity binding, contacts, TOFU and sealed sender | **OPEN** | privacy claims unsupported |
| 004 | durable store, retention and panic wipe | **OPEN** | Android partial; iOS absent |
| 005 | SOS authenticity, ACK lifecycle and permissions | **OPEN** | SOS transmission disabled |
| 006 | cross-platform bulk plane | **OPEN** | Android/iOS implementations disabled |
| 007 | future cipher-suite migration | **OPEN** | no runtime change |

`ci/integration.py` blocks interoperability claims until both routers use the
canonical generated type and blocks enabling one platform's radio while the
other remains disabled.
