# ADR-005 — SOS authenticity, delivery semantics and capability lifecycle

**STATUS: OPEN.**

## V4 safety position

SOS transmission is disabled on both platforms while M1-wire/M2-link and this
ADR remain incomplete. The UI reports the reason and does not claim that a
message carries location, a call sign, or recipient delivery.

The required lifecycle is:

```text
UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
                                      \-> EXPIRED | CANCELLED_LOCALLY
```

A successful GATT write is only `HANDED_TO_RELAY`. `SENT` is forbidden unless an
authenticated intended recipient ACKs the exact message ID. Cancellation cannot
recall already relayed copies and must say so.

## Decisions still required

- minimum stranger-to-stranger authenticity model;
- signature transcript and how the verification key is obtained/bound;
- recipient/group addressing without exposing the social graph;
- ACK authentication, timeout, retry, duplicate and multi-recipient semantics;
- optional location acquisition, freshness and consent;
- permission/capability states: denied, permanently denied, revoked, Bluetooth
  off, unsupported radio, background restrictions and critical battery;
- accessible hold/confirm/cancel behavior under stress.

## Exit criteria

Truth-table tests for every state; reboot recovery; no unsigned SOS accepted;
tamper/replay rejected; no UI phrase stronger than its cryptographic evidence;
and Android↔iOS hardware tests with radios captured.
