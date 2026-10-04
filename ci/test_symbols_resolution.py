#!/usr/bin/env python3
"""*** THE CROSS-FILE RESOLVER'S OWN ADVERSARIAL COURT: THE LEGAL SHAPES IT MUST ACCEPT AND THE ILLEGAL ONES IT MUST STILL FLAG. ***

`ci/symbols.py` drives Invariant F, and its standing negative control is `--selftest`
(the inherited Router/MessageStore defect plus multi-class scoping). That selftest proves
the resolver FIRES; this court proves the two things the 2026-10 rc15 release run exposed
and the earlier controls did not cover:

  * **IT MUST ACCEPT LEGAL KOTLIN.** Four shapes the resolver mis-read produced a hosted
    Invariant F failure on source the compiler accepts -- a BRACELESS declaration followed
    by a member (`data class Row(...)` then `fun mintSos()`), a QUALIFIED supertype
    (`class A : io.pkg.B`), a `when (x) { is T -> x.m() }` subject smart cast, and a
    QUALIFIED base in an anonymous object (`object : io.pkg.Iface { override ... }`).
  * **IT MUST STILL FLAG ILLEGAL KOTLIN.** Each fix above is paired with its plausible
    false-NEGATIVE guards so the widening is measured: a call to a member no candidate
    type declares; an `override` no supertype declares; a `!is T` arm (which EXCLUDETH T);
    a value/object arm boundary; a brace inside a string literal; a shadowed subject
    binding; an `override`/call reaching an unrelated class through an unverified
    QUALIFIED name (`absent.Base`); and a `when` arm over an unmatched qualified type --
    each is required to be REPORTED, with a legal counterpart accepted.

    python3 -m pytest ci/test_symbols_resolution.py -q
"""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

REPO = Path(__file__).resolve().parents[1]


def _load_symbols():
    spec = importlib.util.spec_from_file_location(
        "symbols_under_test", REPO / "ci" / "symbols.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class ResolverCourt(unittest.TestCase):
    """Each case is a tiny synthetic tree, so the assertion is about the resolver alone."""

    def setUp(self) -> None:
        self.symbols = _load_symbols()

    def _resolve(self, sources: dict[str, str]) -> list[str]:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, text in sources.items():
                target = root / "android" / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
            return self.symbols.resolve(root)

    # -- legal shapes the resolver must ACCEPT ---------------------------------
    def test_braceless_declaration_does_not_swallow_the_next_member(self) -> None:
        """A `data class Row(...)` before `fun mintSos()` must leave mintSos with its OWNER.

        This mirrors the hosted defect exactly: the braceless `Row` (no `{}` body) sits
        before `Authority.mintSos()`, and a SIBLING class carries a member whose body
        holdeth a string literal with a brace (`"${...}"`-style formatting). Before the
        fix the walker ran from `Row` past `mintSos` to that STRING brace, so `Row`'s
        region blanking stole every following member from `Authority`, which then
        reported `authority.mintSos()` unresolved although the compiler accepts it.
        """
        found = self._resolve({"a/Sos.kt": """
package io.t
class SosTest {
    private class Authority {
        private data class Row(val id: Int)
        fun mintSos(): Int = 1
        private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
    }
    private class AuthorityPort(private val authority: Authority) {
        fun go(): Int = authority.mintSos()
    }
}
"""})
        self.assertEqual([p for p in found if "mintSos" in p], [], found)

    def test_qualified_supertype_resolves_to_the_declared_type(self) -> None:
        """`interface Wipe : io.t.Composed` must inherit `f`, so `override fun f` is legal."""
        found = self._resolve({
            "rt/Composed.kt": "package io.t\ninterface Composed { fun f(): Int }\n",
            "lab/Wipe.kt": "package io.t\ninterface Wipe : io.t.Composed { fun g(): Int }\n",
            "lab/Prod.kt": ("package io.t\n"
                            "class Prod : io.t.Composed, Wipe {\n"
                            "    override fun f(): Int = 1\n"
                            "    override fun g(): Int = 2\n"
                            "}\n"),
        })
        self.assertEqual(found, [])

    def test_when_subject_smart_cast_types_the_receiver_in_its_arm(self) -> None:
        """`when (s) { is SqlStore -> s.specialized() }` is a legal qualified call."""
        found = self._resolve({"a/Store.kt": """
package io.t
interface Store { fun common(): Int }
class SqlStore : Store { fun specialized(): Int = 1 }
fun run(s: Store) {
    when (s) {
        is SqlStore -> s.specialized()
        else -> s.common()
    }
}
"""})
        self.assertEqual(found, [])

    def test_qualified_anonymous_object_base_strips_its_overrides(self) -> None:
        """An `object : io.t.Iface { override fun f() }` override belongeth to the OBJECT, not the enclosing class."""
        found = self._resolve({"a/Outer.kt": """
package io.t
interface Iface { fun f(): Int }
interface Owner { fun g(): Int }
class Outer : Owner {
    val x = object : io.t.Iface {
        override fun f(): Int = 1
    }
    override fun g(): Int = 2
}
"""})
        self.assertEqual(found, [])

    # -- illegal shapes the resolver must still FLAG ----------------------------
    def test_a_member_no_candidate_type_declares_is_reported(self) -> None:
        found = self._resolve({"a/Widget.kt": """
package io.t
class Widget { fun ok(): Int = 1 }
class WidgetUser {
    fun use(w: Widget) { w.missing() }
}
"""})
        self.assertEqual(len([p for p in found if "w.missing()" in p]), 1, found)

    def test_an_override_no_supertype_declares_is_reported(self) -> None:
        found = self._resolve({"a/Impl.kt": """
package io.t
interface Base { fun f(): Int }
class Impl : Base {
    override fun nope(): Int = 1
}
"""})
        self.assertEqual(len([p for p in found if "nope" in p]), 1, found)

    def test_a_when_arm_whose_type_lacks_the_member_is_reported(self) -> None:
        """Only the arm CONTAINING the call may type the receiver.

        `ArmA` declares `special` and `ArmB` does not, so the `is ArmB -> s.special()`
        arm is a genuine compile error while the `is ArmA` one is legal. A resolver that
        leaked the SIBLING arm's type into the call (a plausible over-widening) would
        report neither; this requires exactly the illegal one.
        """
        found = self._resolve({"a/Store2.kt": """
package io.t
interface Store2 { fun common(): Int }
class ArmA : Store2 { fun special(): Int = 1 }
class ArmB : Store2
class Store2User {
    fun run2(s: Store2) {
        when (s) {
            is ArmA -> s.special()
            is ArmB -> s.special()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_an_override_of_a_qualified_supertype_still_requires_the_member(self) -> None:
        """Resolving the qualified base must not blunt R1: an `override` it does not declare is still reported."""
        found = self._resolve({
            "rt/Composed.kt": "package io.t\ninterface Composed { fun f(): Int }\n",
            "lab/Wipe.kt": ("package io.t\n"
                            "interface Wipe : io.t.Composed { fun g(): Int }\n"),
            "lab/Prod.kt": ("package io.t\n"
                            "class Prod : io.t.Composed, Wipe {\n"
                            "    override fun f(): Int = 1\n"
                            "    override fun h(): Int = 2\n"
                            "}\n"),
        })
        self.assertEqual(len([p for p in found if "h()" in p]), 1, found)

    def test_a_negative_is_check_arm_grants_no_cast(self) -> None:
        """`!is A` EXCLUDETH A, so no cast: `s.spec()` is illegal there (the old regex read `is A` inside `!is A`)."""
        found = self._resolve({"a/NegArm.kt": """
package io.t
interface NegStore { fun common(): Int }
class NegA : NegStore { fun spec(): Int = 1 }
class NegRunner {
    fun run(s: NegStore) {
        when (s) {
            !is NegA -> s.spec()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.spec()" in p]), 1, found)

    def test_a_value_arm_boundary_ends_the_previous_type_arm(self) -> None:
        """A non-`is` arm (`Other -> ...`) endeth the previous type cast: its call is judged, not inherited."""
        found = self._resolve({"a/ValueArm.kt": """
package io.t
interface ValStore { fun common(): Int }
class ValA : ValStore { fun spec(): Int = 1 }
class Other : ValStore
class ValRunner {
    fun run(s: ValStore) {
        when (s) {
            is ValA -> s.common()
            Other -> s.spec()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.spec()" in p]), 1, found)

    def test_a_brace_in_a_string_does_not_extend_the_cast(self) -> None:
        """`println("{")` inside an `is A` arm must not stretch A's cast over a call AFTER the when."""
        found = self._resolve({"a/StringBrace.kt": """
package io.t
interface StrStore { fun common(): Int }
class StrA : StrStore { fun spec(): Int = 1 }
class StrRunner {
    fun run(s: StrStore) {
        when (s) {
            is StrA -> println("{")
            else -> Unit
        }
        s.spec()
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.spec()" in p]), 1, found)

    def test_a_shadowed_subject_breaks_the_outer_cast(self) -> None:
        """A `val s` re-binding inside an outer `is A` arm means the inner `when` over `s` is a DIFFERENT variable."""
        found = self._resolve({"a/Shadow.kt": """
package io.t
interface ShStore { fun common(): Int }
class ShA : ShStore { fun spec(): Int = 1 }
class ShB : ShStore
class ShRunner {
    fun run(s: ShStore, other: ShStore) {
        when (s) {
            is ShA -> {
                val s: ShStore = other
                when (s) {
                    is ShB -> s.spec()
                    else -> s.common()
                }
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.spec()" in p]), 1, found)

    def test_a_qualified_arm_type_that_names_no_project_package_grants_no_cast(self) -> None:
        """`is absent.A` must NOT resolve to the project `A`; the call is judged against the declared type."""
        found = self._resolve({"a/QualifiedArm.kt": """
package io.t
interface QStore { fun common(): Int }
class QA : QStore { fun spec(): Int = 1 }
class QRunner {
    fun run(s: QStore) {
        when (s) {
            is absent.QA -> s.spec()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.spec()" in p]), 1, found)

    def test_a_qualified_base_with_an_unrelated_qualifier_is_not_inherited(self) -> None:
        """`class Child : absent.Base()` must not inherit the project `Base`'s members by its bare tail."""
        found = self._resolve({"a/QualifiedBase.kt": """
package io.t
open class Base { fun projectOnly(): Int = 1 }
class Child : absent.Base() {
    fun own(): Int = 2
}
class BaseUser {
    fun use(c: Child) { c.projectOnly() }
}
"""})
        self.assertEqual(len([p for p in found if "c.projectOnly()" in p]), 1, found)

    # -- legal counterparts to the guards above --------------------------------
    def test_a_comma_arm_grants_no_new_cast_but_the_declared_type_still_resolves(self) -> None:
        """A comma arm granteth NO new cast. Here ONLY CommaA declares `spec`, so a first-positive reading
        would grant A and falsely accept `s.spec()`; declining the narrowing correctly REFUSES it."""
        found = self._resolve({"a/CommaArm.kt": """
package io.t
interface CommaStore { fun common(): Int }
class CommaA : CommaStore { fun spec(): Int = 1 }
class CommaB : CommaStore
class CommaRunner {
    fun run(s: CommaStore) {
        when (s) {
            is CommaA, is CommaB -> s.spec()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.spec()" in p]), 1, found)

    def test_a_comma_arm_call_resolves_through_the_declared_supertype(self) -> None:
        """The legal counterpart: a member on the DECLARED supertype resolves without any arm cast."""
        found = self._resolve({"a/CommaSup.kt": """
package io.t
interface CommaSup { fun shared(): Int }
class CommaSupA : CommaSup
class CommaSupB : CommaSup
class CommaSupRunner {
    fun run(s: CommaSup) {
        when (s) {
            is CommaSupA, is CommaSupB -> s.shared()
            else -> s.shared()
        }
    }
}
"""})
        self.assertEqual(found, [])

    def test_a_shadow_in_a_sibling_arm_does_not_suppress_a_valid_cast(self) -> None:
        """A rebinding in arm A must not suppress arm B's own valid `is B` cast."""
        found = self._resolve({"a/SiblingShadow.kt": """
package io.t
interface SibStore { fun common(): Int }
class SibA : SibStore
class SibB : SibStore { fun spec(): Int = 1 }
class SibRunner {
    fun run(s: SibStore, other: SibStore) {
        when (s) {
            is SibA -> { val s: SibStore = other; s.common() }
            is SibB -> s.spec()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual([p for p in found if "s.spec()" in p], [], found)

    def test_a_correctly_qualified_base_inherits(self) -> None:
        """A QUALIFIED base whose qualifier IS the type's declaring package must still resolve and inherit."""
        found = self._resolve({
            "x/Base.kt": "package io.t.x\nopen class Base { fun projectOnly(): Int = 1 }\n",
            "x/Child.kt": ("package io.t.x\n"
                           "class Child : io.t.x.Base() {\n"
                           "    fun own(): Int = 2\n"
                           "}\n"),
            "x/User.kt": ("package io.t.x\n"
                          "class BaseUser { fun use(c: Child) { c.projectOnly() } }\n"),
        })
        self.assertEqual(found, [])

    def test_a_call_in_the_next_arm_condition_gets_no_cast(self) -> None:
        """A call in the CONDITION that selecteth the next arm is evaluated before the cast: it is judged."""
        found = self._resolve({"a/CondCall.kt": """
package io.t
interface CondStore { fun common(): Int }
class CondA : CondStore { fun special(): Int = 1 }
class CondRunner {
    fun run(s: CondStore) {
        when (s) {
            is CondA -> Unit; s.special() -> Unit; else -> Unit
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_qualified_name_declared_in_two_packages_is_ambiguous(self) -> None:
        """`is b.Base` must not consume `a.Base`'s members when both are simply `Base` in the registry."""
        found = self._resolve({
            "shared.kt": "package shared\ninterface Store { fun common(): Int }\n",
            "a.kt": ("package a\n"
                     "class Base : shared.Store { fun special(): Int = 1 }\n"),
            "b.kt": ("package b\n"
                     "class Base : shared.Store\n"),
            "u.kt": ("package u\n"
                     "import shared.Store\n"
                     "class U {\n"
                     "    fun run(s: Store) {\n"
                     "        when (s) {\n"
                     "            is b.Base -> s.special()\n"
                     "            else -> s.common()\n"
                     "        }\n"
                     "    }\n"
                     "}\n"),
        })
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_unique_qualified_name_in_its_own_package_still_resolves(self) -> None:
        """The legal counterpart: a qualified name whose tail is unique resolves to that package's type."""
        found = self._resolve({
            "shared.kt": "package shared\ninterface Store { fun common(): Int }\n",
            "a.kt": ("package a\n"
                     "class OnlyBase : shared.Store { fun special(): Int = 1 }\n"),
            "u.kt": ("package u\n"
                     "import shared.Store\n"
                     "class U {\n"
                     "    fun run(s: Store) {\n"
                     "        when (s) {\n"
                     "            is a.OnlyBase -> s.special()\n"
                     "            else -> s.common()\n"
                     "        }\n"
                     "    }\n"
                     "}\n"),
        })
        self.assertEqual([p for p in found if "s.special()" in p], [], found)

    def test_a_qualified_base_from_another_package_is_not_inherited(self) -> None:
        """`wrong.Base` must not reach a `Base` declared only in package `actual`."""
        found = self._resolve({
            "actual/Base.kt": "package io.t.actual\nopen class Base { fun projectOnly(): Int = 1 }\n",
            "wrong/Child.kt": ("package io.t.wrong\n"
                               "class Child : io.t.wrong.Base() {\n"
                               "    fun own(): Int = 2\n"
                               "}\n"
                               "class ChildUser { fun use(c: Child) { c.projectOnly() } }\n"),
        })
        self.assertEqual(len([p for p in found if "c.projectOnly()" in p]), 1, found)

    def test_an_expired_inner_binding_does_not_suppress_the_cast(self) -> None:
        """An inner `val s` whose block hath closed before the call must NOT suppress a still-valid cast."""
        found = self._resolve({"a/ExpiredShadow.kt": """
package io.t
interface ExpStore { fun common(): Int }
class ExpA : ExpStore { fun special(): Int = 1 }
class ExpRunner {
    fun run(s: ExpStore, other: ExpStore, flag: Boolean) {
        when (s) {
            is ExpA -> {
                if (flag) { val s: ExpStore = other; s.common() }
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual([p for p in found if "s.special()" in p], [], found)

    def test_a_local_function_parameter_shadows_the_subject(self) -> None:
        """A `fun local(s: S)` parameter shadoweth the outer `s`, so the inner `is B` arm gets no outer A cast."""
        found = self._resolve({"a/ParamShadow.kt": """
package io.t
interface ParStore { fun common(): Int }
class ParA : ParStore { fun special(): Int = 1 }
class ParB : ParStore
class ParRunner {
    fun run(s: ParStore) {
        when (s) {
            is ParA -> {
                fun local(s: ParStore) {
                    when (s) {
                        is ParB -> s.special()
                        else -> s.common()
                    }
                }
                local(s)
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_nested_block_comment_braces_do_not_leak_the_cast(self) -> None:
        """A brace inside a NESTED block comment must not extend the `when` past its real boundary."""
        found = self._resolve({"a/NestedComment.kt": """
package io.t
interface NcStore { fun common(): Int }
class NcA : NcStore { fun special(): Int = 1 }
class NcRunner {
    fun run(s: NcStore) {
        when (s) {
            is NcA -> println(0) /* outer /* inner */ { */; else -> Unit
        }
        s.special()
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_multiline_comma_condition_keeps_all_its_alternatives(self) -> None:
        """A condition continued across a newline (`is A,` / `is B ->`) must not lose the earlier alternative."""
        found = self._resolve({"a/CommaMulti.kt": """
package io.t
interface CommaMStore { fun common(): Int }
class CommaMA : CommaMStore
class CommaMB : CommaMStore { fun special(): Int = 1 }
class CommaMRunner {
    fun run(s: CommaMStore) {
        when (s) {
            is CommaMB -> s.common()
            is CommaMA,
            is CommaMB -> s.special()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_an_expired_function_parameter_does_not_suppress_the_cast(self) -> None:
        """A `fun local(s)` whose BODY hath ended before the call must NOT shadow the later outer call."""
        found = self._resolve({"a/ParamExpired.kt": """
package io.t
interface PeStore { fun common(): Int }
class PeA : PeStore { fun special(): Int = 1 }
class PeRunner {
    fun run(s: PeStore, other: PeStore) {
        when (s) {
            is PeA -> {
                fun local(s: PeStore) { s.common() }
                local(other)
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual([p for p in found if "s.special()" in p], [], found)

    def test_a_string_interpolation_holding_a_nested_string_does_not_leak(self) -> None:
        """`println(\"${\"{\"}\")` must be blanked whole, so its brace cannot extend the when."""
        found = self._resolve({"a/Interp.kt": r'''
package io.t
interface InStore { fun common(): Int }
class InA : InStore { fun special(): Int = 1 }
class InRunner {
    fun run(s: InStore) {
        when (s) {
            is InA -> println("${"{"}")
            else -> Unit
        }
        s.special()
    }
}
'''})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)


    def test_a_blank_or_comment_line_does_not_break_a_comma_continuation(self) -> None:
        """`is A,` / blank / comment / `is B ->` must stay ONE condition, so the comma arm grants no cast."""
        found = self._resolve({"a/CommaBlank.kt": """
package io.t
interface CbStore { fun common(): Int }
class CbA : CbStore
class CbB : CbStore { fun special(): Int = 1 }
class CbC : CbStore
class CbRunner {
    fun run(s: CbStore) {
        when (s) {
            is CbC -> Unit
            is CbA,
            // an explanation line between the alternatives
            is CbB -> s.special()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_an_expression_bodied_local_function_does_not_inherit_the_outer_cast(self) -> None:
        """`fun local(s: Store) = s.special()` hath no brace body, so its parameter must still shadow `s`."""
        found = self._resolve({"a/ExprParam.kt": """
package io.t
interface EpStore { fun common(): Int }
class EpA : EpStore { fun special(): Int = 1 }
class EpRunner {
    fun run(s: EpStore) {
        when (s) {
            is EpA -> {
                fun local(s: EpStore) = s.special()
                local(s)
            }
            else -> Unit
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_an_expression_bodied_local_function_over_another_binding_is_legal(self) -> None:
        """The legal counterpart: a local expression-bodied function that reboundeth a DIFFERENT name must not
        suppress the outer arm's cast."""
        found = self._resolve({"a/ExprParamOther.kt": """
package io.t
interface EpoStore { fun common(): Int }
class EpoA : EpoStore { fun special(): Int = 1 }
class EpoRunner {
    fun run(s: EpoStore, other: EpoStore) {
        when (s) {
            is EpoA -> {
                fun local(x: EpoStore) = x.common()
                local(other)
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual([p for p in found if "s.special()" in p], [], found)


    def test_a_package_dot_tail_does_not_reach_a_nested_class(self) -> None:
        """`is io.t.NA` must NOT resolve to a NESTED `NOuter.NA` (whose real name is `io.t.NOuter.NA`)."""
        found = self._resolve({"a/Nested.kt": """
package io.t
open class NStore { fun common(): Int = 0 }
class NOuter {
    class NA : NStore() { fun special(): Int = 1 }
}
class NUser {
    fun run(s: NStore) {
        when (s) {
            is io.t.NA -> s.special()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_qualified_top_level_name_still_resolves(self) -> None:
        """The legal counterpart: `is io.t.TopA` for a TOP-LEVEL type resolves and inherits."""
        found = self._resolve({"a/Top.kt": """
package io.t
open class TStore { fun common(): Int = 0 }
class TopA : TStore() { fun special(): Int = 1 }
class TopUser {
    fun run(s: TStore) {
        when (s) {
            is io.t.TopA -> s.special()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(found, [])


    def test_a_qualified_tail_declared_twice_in_a_package_is_ambiguous(self) -> None:
        """`is p.A` must NOT consume the merged members when `A` is declared BOTH top-level and inside `Outer`."""
        found = self._resolve({
            "s.kt": "package p\nopen class Store { fun common(): Int = 0 }\n",
            "a.kt": ("package p\n"
                     "class A : Store()\n"
                     "class Outer {\n"
                     "    class A : Store() { fun special(): Int = 1 }\n"
                     "}\n"),
            "u.kt": ("package p\n"
                     "class U {\n"
                     "    fun run(s: Store) {\n"
                     "        when (s) {\n"
                     "            is p.A -> s.special()\n"
                     "            else -> s.common()\n"
                     "        }\n"
                     "    }\n"
                     "}\n"),
        })
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_qualified_tail_reaching_a_function_local_class_grants_no_cast(self) -> None:
        """`is p.Local` must NOT resolve to a class declared inside a FUNCTION body.

        The function body carrieth a `println("}")` whose LITERAL brace must not be counted
        as closing the function's block (the nesting depth is read from the mask).
        """
        found = self._resolve({
            "s.kt": "package p\ninterface Store {\n    fun common(): Int\n}\n",
            "l.kt": ("package p\n"
                     "fun make() {\n"
                     "    println(\"}\")\n"
                     "    class Local : Store {\n"
                     "        fun special(): Int = 1\n"
                     "        override fun common(): Int = 0\n"
                     "    }\n"
                     "}\n"),
            "u.kt": ("package p\n"
                     "class U {\n"
                     "    fun run(s: Store) {\n"
                     "        when (s) {\n"
                     "            is p.Local -> s.special()\n"
                     "            else -> s.common()\n"
                     "        }\n"
                     "    }\n"
                     "}\n"),
        })
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)


    def test_an_ambiguous_unqualified_arm_type_grants_no_cast(self) -> None:
        """`is A` where `A` is declared in TWO packages must not consume the merged `A`'s members."""
        found = self._resolve({
            "Common.kt": "package common\nopen class Store {\n    fun common(): Int = 0\n}\n",
            "A1.kt": ("package a\nimport common.Store\n"
                      "class A : Store() {\n    fun special(): Int = 1\n}\n"),
            "A2.kt": ("package b\nimport common.Store\n"
                      "class A : Store() {\n}\n"),
            "Use.kt": ("package b\nimport common.Store\n"
                       "class U {\n    fun run(s: Store) {\n        when (s) {\n"
                       "            is A -> s.special()\n"
                       "            else -> s.common()\n        }\n    }\n}\n"),
        })
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_unique_immutable_arm_type_still_grants_the_cast(self) -> None:
        """The legal counterpart: a UNIQUELY declared `A` makes `is A -> s.special()` resolve."""
        found = self._resolve({"a/Only.kt": """
package io.t
open class OStore { fun common(): Int = 0 }
class Only : OStore() { fun special(): Int = 1 }
class OUser {
    fun run(s: OStore) {
        when (s) {
            is Only -> s.special()
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(found, [])

    def test_a_reassigned_subject_loses_the_arm_cast(self) -> None:
        """`var s: Store = A(); ... s = other; s.special()` -- the reassignment invalidates the arm's A fact."""
        found = self._resolve({"a/Reassign.kt": """
package io.t
open class RStore { fun common(): Int = 0 }
class RA : RStore() { fun special(): Int = 1 }
class RUser {
    fun run(other: RStore) {
        var s: RStore = RA()
        when (s) {
            is RA -> {
                s = other
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)


    def test_a_write_to_the_same_live_binding_withholds_the_cast(self) -> None:
        """An assignment statement to the tested binding, still live at the call, invalidates the arm's fact."""
        found = self._resolve({"a/LiveWrite.kt": """
package io.t
interface LwStore { fun common(): Int }
class LwA : LwStore { fun special(): Int = 1 }
class LwRunner {
    fun run(s: LwStore, other: LwStore) {
        when (s) {
            is LwA -> {
                s = other
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_write_in_a_now_closed_block_to_the_outer_binding_still_invalidates(self) -> None:
        """`if (flag) { s = other }; s.special()` writes the OUTER mutable s, so the arm fact is gone.

        The write's own block having closed before the call doth NOT make it a different
        binding; only a shadowing declaration AT THE WRITE would.
        """
        found = self._resolve({"a/ClosedWrite.kt": """
package io.t
interface CwStore { fun common(): Int }
class CwA : CwStore { fun special(): Int = 1 }
class CwRunner {
    fun run(s: CwStore, other: CwStore, flag: Boolean) {
        when (s) {
            is CwA -> {
                if (flag) { s = other }
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_write_to_an_expired_inner_binding_keeps_the_outer_cast(self) -> None:
        """A write to a nested, already-closed shadowing binding must NOT withhold the outer valid cast."""
        found = self._resolve({"a/ExpiredWrite.kt": """
package io.t
interface EwStore { fun common(): Int }
class EwA : EwStore { fun special(): Int = 1 }
class EwRunner {
    fun run(s: EwStore, other: EwStore, flag: Boolean) {
        when (s) {
            is EwA -> {
                if (flag) { var s: EwStore = other; s = other; s.common() }
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual([p for p in found if "s.special()" in p], [], found)

    def test_a_named_argument_is_not_a_write_of_the_subject(self) -> None:
        """`inspect(s = other)` is a named argument (Kotlin assignment is no expression), not a write of `s`."""
        found = self._resolve({"a/NamedArg.kt": """
package io.t
interface NaStore { fun common(): Int }
class NaA : NaStore { fun special(): Int = 1 }
class NaRunner {
    fun run(s: NaStore, other: NaStore) {
        when (s) {
            is NaA -> {
                inspect(s = other)
                s.special()
            }
            else -> s.common()
        }
    }
}
fun inspect(s: NaStore) {}
"""})
        self.assertEqual([p for p in found if "s.special()" in p], [], found)

    def test_a_write_inside_a_nested_block_that_reaches_the_call_still_invalidates(self) -> None:
        """A nested `{ s = other }` whose block ENCLOSES the call writes the live binding, so the cast is withheld."""
        found = self._resolve({"a/NestedWrite.kt": """
package io.t
interface NwStore { fun common(): Int }
class NwA : NwStore { fun special(): Int = 1 }
class NwRunner {
    fun run(s: NwStore, other: NwStore, flag: Boolean) {
        when (s) {
            is NwA -> {
                if (flag) {
                    s = other
                    s.special()
                }
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)


    def test_a_write_after_another_statement_still_invalidates(self) -> None:
        """`s.common(); s = other; s.special()` -- the write followeth a non-keyword statement and still counts."""
        found = self._resolve({"a/AfterStmt.kt": """
package io.t
interface AsStore { fun common(): Int }
class AsA : AsStore { fun special(): Int = 1 }
class AsRunner {
    fun run(s: AsStore, other: AsStore) {
        when (s) {
            is AsA -> {
                s.common()
                s = other
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)

    def test_a_braceless_if_write_still_invalidates(self) -> None:
        """`if (true) s = other; s.special()` -- a braceless-if write to the outer binding still counts."""
        found = self._resolve({"a/BracelessIf.kt": """
package io.t
interface BiStore { fun common(): Int }
class BiA : BiStore { fun special(): Int = 1 }
class BiRunner {
    fun run(s: BiStore, other: BiStore) {
        when (s) {
            is BiA -> {
                if (true) s = other
                s.special()
            }
            else -> s.common()
        }
    }
}
"""})
        self.assertEqual(len([p for p in found if "s.special()" in p]), 1, found)


if __name__ == "__main__":
    unittest.main()
