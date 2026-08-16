#!/usr/bin/env python3
"""Type-aware Kotlin cross-file symbol resolver. Drives Invariant F.

    python ci/symbols.py            # resolve the tree
    python ci/symbols.py --selftest # prove the resolver actually fires

WHY THIS EXISTS
---------------
Kotlin and Swift are NEVER COMPILED in this verification environment, so
invariants A-E are structurally blind to an unresolved reference. That blind
spot shipped a real defect, inherited from the original workbook:

    Router.kt      store.forEachHeldOrderedByPriority { ... }
    MessageStore   declared only allHeldOrderedByPriority() / allHeldMsgIds()

`store` is typed as the INTERFACE, so that call does not resolve, and the
`override` in each implementation overrides nothing. Two compile errors that
every Python-only gate walked straight past.

WHY THE FIRST ATTEMPT WAS NOT GOOD ENOUGH
-----------------------------------------
The first version of this check asked "does this name exist as a `fun`
ANYWHERE in the tree?". It reported ok even with the defect reintroduced,
because the concrete classes still declared the method. A name-existence check
cannot model static types, so it could not see the bug it was written for.
It failed its own negative control, which is exactly the anti-pattern this
repository exists to eliminate, so it was replaced rather than tuned.

WHAT THIS ACTUALLY CHECKS
-------------------------
    R1  every `override fun N` must have N declared in some SUPERTYPE
    R2  every `recv.method()` where recv has a KNOWN declared type must
        resolve against that type's members, including inherited ones

HONEST LIMITS. This is a resolver, not a compiler. It does not do generics,
overload resolution by signature, extension functions, imports, or scoping.
It cannot replace `./gradlew build`; it makes ONE specific and historically
real failure mode -- a call or override with no matching declaration -- a merge
block rather than something found on a workstation months later.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# `class A : B(), C` / `interface A : B` / `object A : B`
#
# The supertype clause is captured up to the first `{` OR end-of-line
# (`[^\n{]+`), NOT `[^{]+`. A bare `[^{]+` runs past a BRACELESS member such
# as `data object Found(val record: DeliveryRecord) : DeliveryLookup()` (no
# `{` body) and swallows every following declaration up to the next `{` --
# including a later `interface DeliveryJournal {`, which then never registers
# as its own type, so its `fun insert` / `fun updateState` are never collected
# and R1 falsely flags every override of them. Capping at the newline keeps the
# supertype on its own line (Kotlin convention here; there are no genuine
# multi-line comma supertype lists in the tree) and lets each braceless
# `data object X : Y` register independently. Verified: zero genuine
# `class X : Y,\n    Z {` lists exist under android/.
TYPE_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|abstract\s+|open\s+|sealed\s+|data\s+)*"
    r"(?:class|interface|object)\s+([A-Z][\w]*)"
    r"(?:\s*<[^>]*>)?"
    r"(?:\s*\([^)]*\))?"
    r"(?:\s*:\s*([^\n{]+))?",
    re.M)

# `data class Name` -- a data class synthesises copy(), equals(), hashCode(),
# toString() and componentN() that never appear as `fun` in source. Without this,
# R2 flags `frame.copy(...)` as unresolved -- a false positive the GMP/2.1 cutover
# exposed (Router.openSealedMessage holds `val frame: FrameV2`, so the receiver
# `frame` in `forwardCopy` is type-resolved against the FrameV2 data class). The
# compiler accepts the call; this resolver must too.
DATA_CLASS = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|abstract\s+|open\s+|sealed\s+)*"
    r"data\s+class\s+([A-Z][\w]*)", re.M)
DATA_SYNTHETIC = {"copy", "equals", "hashCode", "toString"}

FUN_DECL = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|protected\s+)?"
    r"(?P<override>override\s+)?(?:abstract\s+|open\s+|suspend\s+|inline\s+)*"
    r"fun\s+(?:<[^>]*>\s+)?(?P<name>[a-zA-Z_][\w]*)", re.M)

# `val x: T` / `private val x: T` / constructor `private val x: T,`
TYPED_VAL = re.compile(
    r"\b(?:private\s+|internal\s+|public\s+)?(?:val|var)\s+"
    r"([a-z][\w]*)\s*:\s*([A-Z][\w]*)")

CALL = re.compile(r"\b([a-z][\w]*)\.([a-z][\w]*)\s*[({]")


def strip_anonymous_objects(body: str) -> str:
    """Remove `object : Base() { ... }` expression bodies.

    An override inside an anonymous object belongs to THAT object's base class,
    which is usually an Android SDK type this resolver cannot see. Attributing
    it to the enclosing named class produced three false positives on a clean
    tree (WifiAwareTransport's AttachCallback / DiscoverySessionCallback
    handlers). A checker that cries wolf gets muted, so it is scoped out.
    """
    out = []
    i = 0
    while i < len(body):
        m = re.compile(r"object\s*:\s*[A-Z][\w.]*\s*(?:\([^)]*\))?\s*\{").search(body, i)
        if not m:
            out.append(body[i:])
            break
        out.append(body[i:m.start()])
        depth, j = 1, m.end()
        while j < len(body) and depth:
            if body[j] == "{":
                depth += 1
            elif body[j] == "}":
                depth -= 1
            j += 1
        i = j
    return "".join(out)


def parse_types(files: list[Path]) -> tuple[dict, dict]:
    """-> ({TypeName: {members}}, {TypeName: [supertypes]})"""
    members: dict[str, set[str]] = {}
    supers: dict[str, list[str]] = {}
    for f in files:
        src = f.read_text(encoding="utf-8", errors="ignore")
        decls = list(TYPE_DECL.finditer(src))
        for i, m in enumerate(decls):
            name = m.group(1)
            end = decls[i + 1].start() if i + 1 < len(decls) else len(src)
            body = src[m.end():end]
            members.setdefault(name, set())
            members[name] |= {fm.group("name") for fm in FUN_DECL.finditer(body)}
            if m.group(2):
                bases = [b.strip().split("(")[0].split("<")[0]
                         for b in m.group(2).split(",")]
                supers.setdefault(name, []).extend(
                    b for b in bases if b and b[0].isupper())
    # A data class synthesises copy()/equals()/hashCode()/toString() that are
    # never written as `fun` in source; add them so R2 does not flag valid
    # `x.copy(...)` calls as unresolved (see DATA_CLASS docstring).
    for dm in DATA_CLASS.finditer("\n".join(f.read_text(encoding="utf-8", errors="ignore")
                                           for f in files)):
        members.setdefault(dm.group(1), set()).update(DATA_SYNTHETIC)
    return members, supers


def all_members(t: str, members: dict, supers: dict, seen=None) -> set[str]:
    """Members of t plus everything inherited."""
    seen = seen or set()
    if t in seen or t not in members:
        return set()
    seen.add(t)
    out = set(members[t])
    for s in supers.get(t, []):
        out |= all_members(s, members, supers, seen)
    return out


def resolve(root: Path) -> list[str]:
    files = sorted((root / "android").rglob("*.kt"))
    members, supers = parse_types(files)
    problems: list[str] = []

    for f in files:
        src = f.read_text(encoding="utf-8", errors="ignore")
        rel = f.relative_to(root)
        decls = list(TYPE_DECL.finditer(src))

        # -- R1: an override must override something in a supertype ----------
        for i, m in enumerate(decls):
            name = m.group(1)
            end = decls[i + 1].start() if i + 1 < len(decls) else len(src)
            body = src[m.end():end]
            inherited: set[str] = set()
            for s in supers.get(name, []):
                inherited |= all_members(s, members, supers)
            if not inherited:
                continue
            for fm in FUN_DECL.finditer(strip_anonymous_objects(body)):
                if fm.group("override") and fm.group("name") not in inherited:
                    problems.append(
                        f"{rel}: {name}.{fm.group('name')}() is marked "
                        f"`override` but no supertype {supers.get(name)} "
                        f"declares it")

        # -- R2: calls on a receiver whose declared type we know -------------
        recv_types = {v: t for v, t in TYPED_VAL.findall(src)}
        for recv, method in CALL.findall(src):
            t = recv_types.get(recv)
            if not t or t not in members:
                continue                      # unknown type: cannot judge
            if method not in all_members(t, members, supers):
                problems.append(
                    f"{rel}: {recv}.{method}() -- `{recv}` is typed `{t}`, "
                    f"which declares no such member")

    return sorted(set(problems))


def selftest(root: Path) -> int:
    """Prove the resolver fires on the exact defect that shipped.

    Removes the streaming declarations from the MessageStore interface, runs the
    resolver, and requires it to complain. A control that has never been
    observed failing is not a control.
    """
    target = (root / "android/mesh/src/main/java/io/godstone/mesh"
              "/store/MessageStore.kt")
    original = target.read_text(encoding="utf-8")
    print("SELFTEST -- reintroducing the inherited Router/MessageStore defect\n")
    try:
        broken = original.replace(
            "    suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean)\n",
            "", 1).replace(
            "    /** Stream held msg_ids, stopping as soon as [visit] returns false. */\n"
            "    suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean)\n", "", 1)
        if broken == original:
            print("  BROKEN -- could not reintroduce the defect; anchors moved")
            return 1
        target.write_text(broken, encoding="utf-8")
        found = resolve(root)
        hits = [p for p in found if "forEachHeld" in p]
        for p in hits[:4]:
            print("  detected: " + p)
        caught = len(hits) >= 2
        print(f"\n  negative control: {'OK' if caught else 'BROKEN'} "
              f"-- {len(hits)} finding(s) naming the removed members")
    finally:
        target.write_text(original, encoding="utf-8")
    clean = resolve(root)
    print(f"  restored tree: {len(clean)} unresolved "
          f"({'OK' if not clean else 'BROKEN'})")
    return 0 if (caught and not clean) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Kotlin cross-file symbol resolver")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest(ROOT)
    problems = resolve(ROOT)
    n = len(list((ROOT / "android").rglob("*.kt")))
    for p in problems:
        print("  UNRESOLVED  " + p)
    print(f"{n} Kotlin files scanned, {len(problems)} unresolved")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
