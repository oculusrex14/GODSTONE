"""ANDROID-06 (T18) -- a reservation must CAPTURE its relation's generation and capacity epoch, and must be
CANCELLABLE so that a dead operation returneth its slot.

The card's own steps, measured at round 215 and now asserted:

  step 1: "reserve must atomically allocate ONE record slot and capture exact connection generation,
           capacity/MTU epoch ..."  -- measured: `reserve(...)` runneth under the lock, but the `Reservation`
           carrieth only (writer, operationId, recordType, clearLength): NEITHER the generation NOR an epoch.
  step 2: "... provide cancellation that returns a slot."  -- measured: ABSENT ENTIRELY. The surface carrieth
           reserve / sealAndQueue / nextOut / completed / rewindInFlight / failed / shutdown, and `shutdown()`
           releaseth the WHOLE writer, which is not cancellation.
  step 3: "Perform every revocable admission/lifetime check BEFORE sealing; if a connection/MTU change
           invalidates a pending reservation, retire it without sealing."  -- measured: PARTIAL, because with
           nothing captured there is nothing to invalidate against.

WHAT ALREADY HOLDS, AND IS ASSERTED HERE AS A REGRESSION CONTROL RATHER THAN AS A RED: single consumption
(`SealAnswer` carrieth the "was consumed" refusal) and the four-record bound (`TooManyAdmitted(4)`, counting
RESERVED-but-unsealed records rather than only sealed fragments). A control that never failed proveth less than
one that did, and these two were MEASURED holding -- the caveat is recorded here so no reader overreadeth them.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth fields and a method, and a behavioural arm of a method that doth
not exist cannot compile. The behavioural arms ship WITH the repair in `ReadinessT18Test.kt`, and this arm stays
afterwards as the regression control.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for candidate in [here.parent, *here.parents]:
        if (candidate / "ci" / "check_repository.py").exists():
            return candidate
    raise SystemExit("the repository root could not be located from " + str(here))


REPO = _repo_root()
WRITER = REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/RecordWriter.kt"


class ReservationCaptureAndCancelTest(unittest.TestCase):
    """W00 -- the positive control: the writer, its slots and the laws that already hold still exist."""

    def test_w00_the_writer_and_its_two_holding_laws_still_exist(self):
        w = WRITER.read_text(encoding="utf-8")
        self.assertIn("class RecordWriter(", w)
        self.assertIn("fun reserve(", w)
        self.assertIn("was consumed", w, "single consumption must stay refused on a second seal")
        self.assertIn("TooManyAdmitted", w, "the four-record bound must stay a typed refusal")

    def test_the_reservation_captures_its_generation_and_epoch(self):
        w = WRITER.read_text(encoding="utf-8")
        self.assertRegex(
            w, r"class Reservation internal constructor\([\s\S]{0,900}?generation: Long",
            "ANDROID-06 step 1: the `Reservation` must CAPTURE the exact connection generation it belongeth to, "
            "or no later change can be validated against the relation it speaketh for")
        self.assertRegex(
            w, r"class Reservation internal constructor\([\s\S]{0,900}?(capacityEpoch|maxAttValueLength|payloadCapacity)",
            "ANDROID-06 step 1: it must capture the CAPACITY/MTU EPOCH as well, or an MTU change cannot "
            "invalidate a pending reservation")

    def test_a_per_reservation_cancellation_returns_the_slot(self):
        w = WRITER.read_text(encoding="utf-8")
        self.assertRegex(
            w, r"fun cancel\w*\(reservation: Reservation\)",
            "ANDROID-06 step 2: 'provide cancellation that returns a slot' -- measured ABSENT: the surface "
            "carrieth no per-reservation cancellation, and `shutdown()` releaseth the whole writer")

    def test_the_epoch_is_consulted_before_the_sealer(self):
        w = WRITER.read_text(encoding="utf-8")
        body = w[w.index("internal fun sealAndQueueOf("):]
        body = body[:body.index("\n    }", 400)]
        self.assertRegex(
            body, r"generation|capacityEpoch",
            "ANDROID-06 step 3: the revocable check must consulte the CAPTURED generation/epoch BEFORE the "
            "sealer, and must retire the reservation WITHOUT sealing when a change invalidated it")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
