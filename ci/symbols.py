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
# The modifier set is COMPLETE for a type declaration. `inner` was missing, and with it
# an `private inner class Rig(...)` was never registered as a declaration at all: its
# members were unparsed and every call on it looked unresolved (GS-CTRL-002 -- one
# missing keyword produced 47 false positives across five test files).
TYPE_MODIFIERS = (r"(?:public\s+|internal\s+|private\s+|protected\s+|abstract\s+|open\s+|"
                  r"sealed\s+|data\s+|value\s+|inner\s+|enum\s+|annotation\s+|"
                  r"companion\s+|expect\s+|actual\s+|final\s+|external\s+|const\s+)*")
TYPE_DECL = re.compile(
    r"^\s*" + TYPE_MODIFIERS +
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
    r"^\s*" + r"(?:public\s+|internal\s+|private\s+|protected\s+|abstract\s+|open\s+|"
    r"sealed\s+|inner\s+|value\s+)*"
    r"data\s+class\s+([A-Z][\w]*)", re.M)
DATA_SYNTHETIC = {"copy", "equals", "hashCode", "toString"}

# D2 (GS-CTRL-002): the leading anchor accepteth a `fun` that followeth `{` or `;`
# on the SAME line, so a one-line body such as `interface SenderClock { fun now(): T }`
# registereth its member. The old line-start anchor missed it, which made the whole
# interface look memberless and silenced R2 for every call on it.
FUN_DECL = re.compile(
    r"(?:^|[;{])\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|protected\s+)?"
    r"(?P<override>override\s+)?(?:abstract\s+|open\s+|suspend\s+|inline\s+|operator\s+|"
    r"tailrec\s+|external\s+)*"
    r"fun\s+(?:<[^>]*>\s+)?(?P<name>[a-zA-Z_][\w]*)", re.M)

# D5 (GS-CTRL-002): an EXTENSION function `fun Type.name(...)` maketh `name` available
# on Type. The resolver did not model extensions at all, so a legitimate extension call
# was reported as an unresolved member.
EXT_FUN = re.compile(
    r"fun\s+(?:<[^>]*>\s+)?([A-Z][\w]*(?:\.[A-Z][\w]*)*)(?:<[^>]*>)?\."
    r"([a-zA-Z_][\w]*)\s*\(")

# D3 (GS-CTRL-002): every Kotlin class inherits Any, whose overridable members are
# exactly these. An `override fun equals/hashCode/toString` therefore overrideth
# something even when no DECLARED supertype nameth it.
ANY_OVERRIDABLE = frozenset({"equals", "hashCode", "toString"})

# D4 (GS-CTRL-002): a smart cast (`if (x is T)`) maketh T's members available INSIDE
# that branch only. Modelling it per branch keepeth the check honest: a call outside
# the branch is still judged against the declared type alone.
SMART_CAST = re.compile(r"\b([a-z][\w]*)\s+is\s+([A-Z][\w]*)")

# `val x: T` / `private val x: T` / constructor `private val x: T,`
# (c) GS-CTRL-002: the type may be QUALIFIED (`Json.Obj`), and a FUNCTION PARAMETER is
# a declaration too. Both omissions mistyped receivers and produced false positives.
TYPED_VAL = re.compile(
    r"\b(?:private\s+|internal\s+|public\s+)?(?:val|var)\s+"
    r"([a-z][\w]*)\s*:\s*([A-Z][\w]*(?:\.[A-Z][\w]*)*)")
TYPED_PARAM = re.compile(
    r"(?<=[(,])\s*(?:private\s+|internal\s+|public\s+)?(?:val\s+|var\s+)?"
    r"([a-z][\w]*)\s*:\s*([A-Z][\w]*(?:\.[A-Z][\w]*)*)")

# A `fun` HEADER, so a parameter list can be read without mistaking a named argument
# (`foo(bar = 1)`) for a declaration.
FUN_HEADER = re.compile(r"\bfun\s+(?:<[^>]*>\s+)?(?:[A-Z][\w]*\.)?[a-zA-Z_][\w]*\s*\(")

CALL = re.compile(r"\b([a-z][\w]*)\.([a-z][\w]*)\s*[({]")

# (f) GS-CTRL-002: `val x = someCall()` carrieth NO type annotation, so it SHADOWETH any
# outer declaration of `x` with a type the resolver cannot know. A receiver shadowed
# that way is not judged (rather than judged against a stale outer type).
UNTYPED_BINDING = re.compile(
    r"\b(?:val|var)\s+([a-z][\w]*)\s*=(?!=)")


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


def declaration_regions(src: str) -> tuple[list[str], list]:
    """Per TYPE_DECL match, the declaration region with nested type bodies blanked.

    The slice-at-a-later-declaration heuristic attributed every method written
    after a nested type (data class, sealed variant, nested exception) to that
    nested type, and left the outer class registered with an empty member set,
    so calls on the outer class were reported unresolved although the
    (never-compiled here) sources are sound. The region of a declaration now
    spans up to the start of the next declaration that is not its descendant
    (determined by brace matching its own body), with each DIRECT child's
    region blanked to newlines. Each fun stays with its innermost declared
    owner, mirroring the language's own scoping, while the trailing gap after
    a class's closing brace remains with the class, as before. An unbalanced
    brace scan degrades to the old bound behaviour, never to silence.
    """
    decls = list(TYPE_DECL.finditer(src))
    if not decls:
        return [src], decls
    starts = [m.start() for m in decls]
    ends: list[int] = []
    for i, m in enumerate(decls):
        op = header_body_start(src, m.start())
        close = -1
        if op != -1:
            depth, j = 0, op
            while j < len(src):
                if src[j] == chr(123):
                    depth += 1
                elif src[j] == chr(125):
                    depth -= 1
                    if depth == 0:
                        close = j
                        break
                j += 1
        ends.append((op, close))
    def descendants(i: int) -> list[int]:
        op, close = ends[i]
        if close == -1:
            return []
        out = []
        for k, s in enumerate(starts):
            if k != i and op < s < close:
                out.append(k)
        return out
    regions = []
    for i, m in enumerate(decls):
        kids = descendants(i)
        kid_starts = set(starts[k] for k in kids)
        nxt = len(src)
        for s in starts:
            if starts[i] < s and s not in kid_starts:
                nxt = s
                break
        text = list(src[starts[i]:nxt])
        for k in kids:
            stop, close = ends[k]
            span_end = close + 1 if close != -1 else starts[k]
            for q in range(starts[k] - starts[i], min(span_end, nxt) - starts[i]):
                if 0 <= q < len(text):
                    text[q] = chr(10)
        regions.append("".join(text))
    return [src[:starts[0]]] + regions, decls


def header_body_start(src: str, from_index: int) -> int:
    """D1 (GS-CTRL-002): the `{` that BEGINNETH a declaration's body, or -1.

    The old bound was `src.find('{', m.end())`. It broke twice over:

      * when the declaration header spanned more than one line (a multi-line
        constructor, a generic base, a defaulted lambda parameter) the first `{` found
        was a LAMBDA inside the parameter list, so the brace-matched "body" was a few
        characters long and the type registered with NO members -- silently disabling R2
        for every call on it (243 of 903 declared types at the audited SHA);
      * and because the TYPE_DECL match itself swallows an opening `(` and stops at the
        first `)`, scanning from `m.end()` started INSIDE the parameter list with a
        paren depth that was already off by one, so a spurious `)` clamped the depth to
        zero and the next method's brace was taken for the class's.

    This walker therefore starteth at the DECLARATION (`internal class X(...)`, not at
    the name), tracketh paren/bracket depth, skippeth comments and string literals, and
    terminateth at the next declaration at depth zero. A genuinely braceless declaration
    (`data object X : Y`) returneth -1, exactly as before.
    """
    depth = 0
    index = from_index
    quote = ''
    line_start = True
    while index < len(src):
        ch = src[index]
        if quote:
            if ch == '\\':
                index += 2
                continue
            if ch == quote:
                quote = ''
            index += 1
            continue
        if ch == '/' and index + 1 < len(src) and src[index + 1] == '/':
            newline = src.find(chr(10), index)
            index = len(src) if newline == -1 else newline + 1
            line_start = True
            continue
        if ch == '/' and index + 1 < len(src) and src[index + 1] == '*':
            close = src.find('*/', index + 2)
            index = len(src) if close == -1 else close + 2
            continue
        if ch in '"\'':
            quote = ch
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth = max(0, depth - 1)
        elif ch == '[':
            depth += 1
        elif ch == ']':
            depth = max(0, depth - 1)
        elif ch == '{' and depth == 0:
            return index
        elif ch == '}' and depth == 0:
            return -1                      # the previous declaration endeth here
        elif ch == chr(10):
            line_start = True
            index += 1
            continue
        elif depth == 0 and line_start and not ch.isspace():
            # a NEW declaration at depth zero terminateth a BRACELESS one
            line_end = src.find(chr(10), index)
            line = src[index:len(src) if line_end == -1 else line_end]
            if TYPE_DECL.match(line) and index != from_index:
                return -1
        if not ch.isspace():
            line_start = False
        index += 1
    return -1


def parse_types(files: list[Path]) -> tuple[dict, dict, set]:
    """-> ({TypeName: {members}}, {TypeName: [supertypes]}, {declared type names})

    The third value is what R2 must judge by: a type that appeareth ONLY as an
    extension receiver (`fun String.toBytes()`) is NOT a project type, and judging
    `String.trim()` against `{toBytes}` would be a false positive. Extensions still add
    their member to a DECLARED type. (That distinction was learned the hard way: the
    first version of D5 made 247 stdlib calls look unresolved.)
    """
    members: dict[str, set[str]] = {}
    supers: dict[str, list[str]] = {}
    declared: set[str] = set()
    for f in files:
        src = f.read_text(encoding="utf-8", errors="ignore")
        regions, decls = declaration_regions(src)
        for i, m in enumerate(decls):
            name = m.group(1)
            declared.add(name)
            body = regions[i + 1][m.end() - m.start():]
            members.setdefault(name, set())
            members[name] |= {fm.group("name") for fm in FUN_DECL.finditer(body)}
            # (e) GS-CTRL-002: a supertype clause may span lines
            # (`internal abstract class StoreDb(ctx: Context) :\n    SQLiteOpenHelper(...) {`).
            # Reading it from the HEADER text (up to the body brace) keepeth the clause
            # whole, while a braceless declaration still yieldeth only its own line.
            opening = header_body_start(src, m.start())
            header_text = src[m.start():opening] if opening != -1 \
                else src[m.start():src.find(chr(10), m.start()) if src.find(chr(10), m.start()) != -1 else len(src)]
            clause = m.group(2)
            depth = 0
            colon = -1
            for index, ch in enumerate(header_text):
                if ch in '([':
                    depth += 1
                elif ch in ')]':
                    depth = max(0, depth - 1)
                elif ch == ':' and depth == 0:
                    colon = index
                    break
            if colon != -1:
                clause = header_text[colon + 1:]
            if clause:
                bases = [b.strip().split("(")[0].split("<")[0].split(chr(10))[0].strip()
                         for b in clause.split(",")]
                supers.setdefault(name, []).extend(
                    b for b in bases if b and b[0].isupper() and ' ' not in b.strip())
    # A data class synthesises copy()/equals()/hashCode()/toString() that are
    # never written as `fun` in source; add them so R2 does not flag valid
    # `x.copy(...)` calls as unresolved (see DATA_CLASS docstring).
    for dm in DATA_CLASS.finditer("\n".join(f.read_text(encoding="utf-8", errors="ignore")
                                           for f in files)):
        members.setdefault(dm.group(1), set()).update(DATA_SYNTHETIC)
    # D5: an extension function belongeth to its RECEIVER type -- but only when that
    # receiver IS a declared project type; otherwise the stdlib would become judgeable
    # D3 (R2 half): every class inheriteth Any, so these three members exist everywhere
    for name in declared:
        members.setdefault(name, set()).update(ANY_OVERRIDABLE)
    for f in files:
        src = f.read_text(encoding="utf-8", errors="ignore")
        for em in EXT_FUN.finditer(src):
            receiver = em.group(1)
            # `fun Json.Obj.req(...)` belongeth to `Json.Obj`, which is declared as the
            # nested type `Obj`: register on BOTH the qualified name and its simple tail
            for candidate in (receiver, receiver.rsplit('.', 1)[-1]):
                if candidate in declared:
                    members.setdefault(candidate, set()).add(em.group(2))
    return members, supers, declared


def _matching_paren(src: str, opening: int) -> int:
    """The index of the paren that closeth the one at `opening`, or -1."""
    depth = 0
    index = opening
    while index < len(src):
        if src[index] == '(':
            depth += 1
        elif src[index] == ')':
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


def matching_brace(src: str, opening: int) -> int:
    """The index of the brace that closeth the one at `opening`, or -1."""
    depth = 0
    index = opening
    while index < len(src):
        if src[index] == chr(123):
            depth += 1
        elif src[index] == chr(125):
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


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
    members, supers, declared = parse_types(files)
    problems: list[str] = []

    # (b) GS-CTRL-002: an override can only be judged when the WHOLE inheritance chain
    # is declared in this project. When a supertype is an SDK/library class
    # (`SQLiteOpenHelper`), the member may well be declared there, so the resolver
    # SKIPPETH the type rather than reporting a false positive -- and the count of
    # skipped types is printed as a visible limitation.
    incomplete: set = set()
    truncated: set = set()

    def chain_complete(name: str, seen=None) -> bool:
        seen = seen or set()
        if name in seen:
            return True
        seen.add(name)
        if name not in declared:
            return False
        return all(chain_complete(base, seen) for base in supers.get(name, []))

    for f in files:
        src = f.read_text(encoding="utf-8", errors="ignore")
        rel = f.relative_to(root)
        regions, decls = declaration_regions(src)

        # Which declarations were read IN FULL? A region that endeth before its own
        # body's closing brace carrieth only part of the type, so its member set is
        # known to be incomplete and R2 must not judge calls against it.
        for i, m in enumerate(decls):
            opening = header_body_start(src, m.start())
            closing = matching_brace(src, opening) if opening != -1 else -1
            region_end = m.start() + len(regions[i + 1])
            if closing == -1 or region_end < closing + 1:
                truncated.add(m.group(1))
            if opening != -1 and closing != -1:
                # PROOF of incompleteness: a `fun` inside the type's own braces that the
                # parse did not attribute to it. Nested declarations are excluded, since
                # their members legitimately belong to THEM.
                own = src[opening + 1:closing]
                nested_spans = []
                for k, other in enumerate(decls):
                    if k == i:
                        continue
                    other_open = header_body_start(src, other.start())
                    if other_open == -1 or not (opening < other_open < closing):
                        continue
                    other_close = matching_brace(src, other_open)
                    nested_spans.append((other.start(), other_close if other_close != -1
                                         else other_open))
                masked = list(own)
                for start, end in nested_spans:
                    for q in range(max(0, start - opening - 1), min(end - opening, len(masked))):
                        masked[q] = chr(10)
                own_names = {fm.group('name') for fm in FUN_DECL.finditer(''.join(masked))}
                if own_names - members.get(m.group(1), set()):
                    INCOMPLETE_PARSED.add(m.group(1))

        # -- R1: an override must override something in a supertype ----------
        for i, m in enumerate(decls):
            name = m.group(1)
            body = regions[i + 1][m.end() - m.start():]
            if supers.get(name) and not chain_complete(name):
                incomplete.add(name)
                continue
            if name in INCOMPLETE_PARSED or set(supers.get(name, [])) & INCOMPLETE_PARSED:
                incomplete.add(name)
                continue
            inherited: set[str] = set()
            for s in supers.get(name, []):
                inherited |= all_members(s, members, supers)
            if not inherited:
                continue
            # D3: every class inheriteth Any, so these three override something even
            # when no DECLARED supertype nameth them
            inherited |= ANY_OVERRIDABLE
            for fm in FUN_DECL.finditer(strip_anonymous_objects(body)):
                if fm.group("override") and fm.group("name") not in inherited:
                    problems.append(
                        f"{rel}: {name}.{fm.group('name')}() is marked "
                        f"`override` but no supertype {supers.get(name)} "
                        f"declares it")

        # -- R2: calls on a receiver whose declared type we know -------------
        # Scope variable declarations to their enclosing class/declaration scope
        # so that files declaring multiple classes (e.g., adapters/decorators sharing
        # variable names like `delegate` or `lifecycleGate`) do not conflate types.
        scopes = regions

        for scope_src in scopes:
            # (d) GS-CTRL-002: the NEAREST preceding declaration winneth (lexical
            # scoping, approximated), so a parameter or a local `val` shadowing a
            # class-level property typeth the receiver correctly.
            declarations = []
            for match in TYPED_VAL.finditer(scope_src):
                declarations.append((match.start(), match.group(1), match.group(2)))
            # parameters come ONLY from the inside of a `fun` header's parentheses
            for header in FUN_HEADER.finditer(scope_src):
                opening = scope_src.find('(', header.end() - 1)
                closing = matching_brace(scope_src.replace('(', '{').replace(')', '}'), opening) \
                    if False else _matching_paren(scope_src, opening)
                if opening == -1 or closing == -1:
                    continue
                params = scope_src[opening:closing]
                for match in TYPED_PARAM.finditer(params):
                    declarations.append((opening + match.start(), match.group(1), match.group(2)))
            if not declarations:
                continue
            declarations.sort()
            # D4: the branches in which a SMART CAST maketh another type available
            cast_spans = []
            for cast in SMART_CAST.finditer(scope_src):
                opening = scope_src.find(chr(123), cast.end())
                # (a) GS-CTRL-002: an if-EXPRESSION without braces (`if (x is T) x.m()`)
                # maketh the cast available to the end of its LINE
                line_end = scope_src.find(chr(10), cast.end())
                if line_end == -1:
                    line_end = len(scope_src)
                if opening == -1 or opening > line_end:
                    opening, closing = cast.end(), line_end
                    cast_spans.append((cast.start(), opening, closing,
                                       cast.group(1), cast.group(2)))
                    continue
                closing = matching_brace(scope_src, opening)
                if closing == -1:
                    continue
                cast_spans.append((cast.start(), opening, closing, cast.group(1), cast.group(2)))
            for call in CALL.finditer(scope_src):
                recv, method = call.group(1), call.group(2)
                visible = [entry for entry in declarations
                           if entry[1] == recv and entry[0] < call.start()]
                t = visible[-1][2] if visible else None
                if not t:
                    continue
                shadow = [match.start() for match in UNTYPED_BINDING.finditer(scope_src)
                          if match.group(1) == recv and match.start() < call.start()]
                if shadow and shadow[-1] > visible[-1][0]:
                    continue                      # the receiver's type is UNKNOWN here
                # an ambiguous receiver (two DIFFERENT types at the same nearest
                # position) is not judged: the resolver never guesseth
                nearest = visible[-1][0]
                ambiguous = {entry[2] for entry in visible if entry[0] == nearest}
                if len(ambiguous) > 1:
                    continue
                if t not in declared:
                    # a QUALIFIED name (`Json.Obj`) may be a nested type declared by its
                    # simple name; resolve it that way, and only then give up
                    simple = t.rsplit('.', 1)[-1]
                    if simple in declared:
                        t = simple
                    else:
                        continue                  # not a project type: cannot judge it
                if t in INCOMPLETE_PARSED or t in truncated:
                    # the type's declaration was NOT read in full, so its member set is
                    # known to be incomplete: SKIP, and count the limitation
                    global SKIPPED_INCOMPLETE
                    SKIPPED_INCOMPLETE.add(t)
                    continue
                candidates = {t}
                for span_start, opening, closing, cast_recv, cast_type in cast_spans:
                    if cast_recv == recv and opening <= call.start() <= closing:
                        candidates.add(cast_type)
                if any(method in all_members(candidate, members, supers)
                       for candidate in candidates):
                    continue
                problems.append(
                    f"{rel}: {recv}.{method}() -- `{recv}` is typed `{t}`, "
                    f"which declares no such member")

    for name in sorted(incomplete):
        # a VISIBLE limitation, never a silent pass: these types are not judged because
        # their inheritance leaveth the project
        pass
    globals()['INCOMPLETE_CHAINS'] = sorted(incomplete)
    print(f"  (not judged: {len(incomplete)} type(s) whose inheritance leaveth the project, "
          f"{len(SKIPPED_INCOMPLETE)} whose declaration was not read in full -- a visible "
          f"limitation, and the compiler is the authority for them)", file=sys.stderr)
    return sorted(set(problems))


def selftest(root: Path) -> int:
    """Prove the resolver fires on the exact defect that shipped and handles multi-class scoping.

    1. Removes the streaming declarations from the MessageStore interface, runs the
       resolver, and requires it to complain.
    2. Injects a non-existent method call into a multi-class file and requires it to be caught.
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

    # Multi-class scoping mutation test
    gate_target = (root / "android/mesh/src/main/java/io/godstone/mesh"
                   "/identity/RuntimeLifecycleGate.kt")
    gate_original = gate_target.read_text(encoding="utf-8")
    print("\nSELFTEST -- verifying multi-class scoped receiver resolution\n")
    try:
        gate_broken = gate_original.replace(
            "delegate.eraseKeys()",
            "delegate.nonExistentMethod()", 1)
        if gate_broken == gate_original:
            print("  BROKEN -- could not inject multi-class defect")
            return 1
        gate_target.write_text(gate_broken, encoding="utf-8")
        gate_found = resolve(root)
        gate_hits = [p for p in gate_found if "nonExistentMethod" in p]
        for p in gate_hits:
            print("  detected: " + p)
        gate_caught = len(gate_hits) >= 1
        print(f"\n  multi-class scoping control: {'OK' if gate_caught else 'BROKEN'}")
    finally:
        gate_target.write_text(gate_original, encoding="utf-8")

    clean = resolve(root)
    print(f"  restored tree: {len(clean)} unresolved "
          f"({'OK' if not clean else 'BROKEN'})")
    return 0 if (caught and gate_caught and not clean) else 1


#: Types whose inheritance chain leaveth the project, so their overrides are NOT
#: judged (a visible limitation rather than a silent pass).
INCOMPLETE_CHAINS: list = []

#: Types whose declaration region was not read in full, so their member set is KNOWN to
#: be incomplete and calls on them are NOT judged. Printed by the summary: an
#: unjudgeable type is a VISIBLE limitation, never a silent pass.
SKIPPED_INCOMPLETE: set = set()

#: Types that the parse PROVED incomplete: their own body braces contain a `fun` the
#: parser did not attribute to them. Neither calls nor overrides are judged against
#: them. This is the resolver being honest about its own blindness instead of emitting
#: a false positive -- the compiler is the authority for these types.
INCOMPLETE_PARSED: set = set()


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
