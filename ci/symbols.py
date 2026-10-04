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
import tempfile
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

#: A file's own package, and its explicit imports. *** THE RESOLVER ONCE MODELLED NEITHER, AND THAT BLINDNESS
#: PRODUCED A FALSE POSITIVE: a `Cursor` typed receiver in a file that `import android.database.Cursor` was resolved
#: to a PROJECT class named `Cursor` declared in an unrelated test file, and `cursor.use()` was reported unresolved
#: although the Kotlin compiler accepteth it. *** *A simple name EXPLICITLY IMPORTED FROM A PACKAGE IS THAT PACKAGE'S
#: TYPE, NOT a same-named project class -- so the receiver's members live outside the project and must not be judged.
#: A `import a.b.C` is read as (C, "a.b"); a wildcard `import a.b.*` carrieth no simple name and is ignored.*
PACKAGE_DECL = re.compile(r"^\s*package\s+([\w.]+)", re.M)
IMPORT_DECL = re.compile(r"^\s*import\s+([\w.]+)(?:\s+as\s+(\w+))?\s*$", re.M)

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


def _block_comment_end(src: str, i: int, n: int) -> int:
    """End of a NESTED block comment beginning at `src[i:i+2] == '/*'`."""
    depth, j = 1, i + 2
    while j < n and depth:
        if src[j] == '/' and j + 1 < n and src[j + 1] == '*':
            depth += 1
            j += 2
            continue
        if src[j] == '*' and j + 1 < n and src[j + 1] == '/':
            depth -= 1
            j += 2
            continue
        j += 1
    return j


def _expr_end(src: str, i: int, n: int) -> int:
    """Index after the `}` matching a `${` whose body beginneth at `i` (Kotlin template).

    Interpolation bodies are CODE, so strings, chars and comments inside them are
    skipped (their braces/quotes must not be mistaken for the template's end). Reviewer
    finding (5): the earlier scanner stopped an ordinary string at the NEXT `"`, so a
    template such as `${"{"}` closed the outer string early and exposed a fake brace.
    """
    depth, j = 1, i
    while j < n and depth:
        if src[j] == '/' and j + 1 < n and src[j + 1] == '/':
            k = src.find(chr(10), j)
            j = n if k == -1 else k
            continue
        if src[j] == '/' and j + 1 < n and src[j + 1] == '*':
            j = _block_comment_end(src, j, n)
            continue
        if src[j] == '"' and src[j:j + 3] == '"""':
            k = src.find('"""', j + 3)
            j = n if k == -1 else k + 3
            continue
        if src[j] == '"':
            j = _string_end(src, j, n)
            continue
        if src[j] == "'":
            k = j + 1
            while k < n:
                if src[k] == '\\':
                    k += 2
                    continue
                if src[k] == "'":
                    break
                k += 1
            j = k + 1
            continue
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
        j += 1
    return j


def _string_end(src: str, i: int, n: int) -> int:
    """Index after the `"` closing an ORDINARY string beginning at `src[i] == '"'`.

    Escapes and `${...}` templates are honoured so the true closing quote is found even
    when the template holdeth a nested string (`"${"}")`).
    """
    j = i + 1
    while j < n:
        c = src[j]
        if c == '\\':
            j += 2
            continue
        if c == '$' and j + 1 < n and src[j + 1] == '{':
            j = _expr_end(src, j + 2, n)
            continue
        if c == '"':
            return j + 1
        j += 1
    return n


def code_mask(src: str) -> str:
    """A copy of `src` with comment and string/char-literal interiors BLANKED to spaces.

    Offsets are preserved exactly (newlines survive), so a structural scan -- brace
    matching, arm splitting -- runneth on the mask and still mapeth back to real source
    positions, while a `{` inside a string or comment can never masquerade as a real
    block boundary. This handleth, per the reviewer:
      * NESTED block comments (`/* outer /* inner */ { */`);
      * Kotlin raw strings (`\"\"\"...\"\"\"`, which may hold braces and newlines);
      * ordinary strings WITH `${...}` templates whose body is code and may hold a nested
        string (`println(\"${\"{\"}\")`) -- the WHOLE literal is blanked, since a template
        body is an expression, never a `when` arm or statement boundary.
    """
    out = list(src)
    n = len(src)
    i = 0
    while i < n:
        ch = src[i]
        if ch == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find(chr(10), i)
            j = n if j == -1 else j
        elif ch == '/' and i + 1 < n and src[i + 1] == '*':
            j = _block_comment_end(src, i, n)
        elif ch == '"' and src[i:i + 3] == '"""':
            k = src.find('"""', i + 3)
            j = n if k == -1 else k + 3
        elif ch == '"':
            j = _string_end(src, i, n)
        elif ch == "'":
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == "'":
                    j += 1
                    break
                j += 1
        else:
            i += 1
            continue
        for k in range(i, j):
            if out[k] != chr(10):
                out[k] = ' '
        i = j
    return ''.join(out)


def _split_top_commas(text: str) -> list[str]:
    """Split a `when` arm condition on commas that are not inside brackets."""
    parts, depth, start = [], 0, 0
    for index, ch in enumerate(text):
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth = max(0, depth - 1)
        elif ch == ',' and depth == 0:
            parts.append(text[start:index])
            start = index + 1
    parts.append(text[start:])
    return parts


def resolve_qualified_type(text: str, decl_pkg: str, declared: set,
                           type_packages: dict, top_level: set,
                           identity_count: dict) -> str | None:
    """(h) GS-CTRL-002: a QUALIFIED reference -> its project simple name, or None.

    The reviewer's finding (4): reducing `absent.Base` to the bare tail `Base` and then
    resolving it against ANY project `Base` marked the chain complete and inherited an
    UNRELATED class's members. The qualifier is therefore VERIFIED rather than dropped:
    the reference resolveth only when its prefix IS the declaring package of the unique
    project type that carrieth the tail name (or, for a same-package reference written
    out in full, the current package). An unmatched, external or ambiguous qualified name
    returneth None, so the caller keepeth it VISIBLY incomplete instead of guessing.
    """
    if not text or ' ' in text:
        return None
    if '.' not in text:
        # a SIMPLE name: judged as before. Its resolution dependeth on scope and imports,
        # which this resolver doth not model, so a same-named type elsewhere must NOT
        # invalidate it (that would drop legitimate local supertypes -- e.g. a file whose
        # own `Base` collides with another package's `Base` in the shared registry).
        return text if text[0].isupper() else None
    prefix, simple = text.rsplit('.', 1)
    if not simple or not simple[0].isupper():
        return None
    if simple not in declared:
        return None
    # EXACT identity: the qualifier must BE the DECLARING package of the tail type, so a
    # same-named type in another package cannot be reached through it. (The former
    # `prefix == decl_pkg` shortcut accepted `wrong.Base` for a `Base` declared only in
    # package `actual`, and `prefix in declared` accepted any enclosing-type spelling
    # without proving nesting.) An unverifiable qualified name returneth None and is
    # kept VISIBLY incomplete.
    packages = type_packages.get(simple, set())
    if len(packages) > 1:
        # the registry mergeth same-named declarations from different packages into ONE
        # member set, so NONE of them may be consumed: return None (reviewer finding 4).
        return None
    if prefix in packages and simple in top_level \
            and identity_count.get((prefix, simple), 1) == 1:
        # only a UNIQUE TOP-LEVEL type may satisfy `package.Tail`: a nested `Outer.Tail`
        # (`package.Outer.Tail`) or a function-local `Local` is a DIFFERENT declaration
        # identity, and a tail declared more than once in the package is ambiguous
        # (rounds 5-6 findings).
        return simple
    return None


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
        # (f) GS-CTRL-002: the base may be a QUALIFIED name whose first segment is a
        # package (`object : io.godstone.mesh.crypto.PeerBindingTrustAuthority {`).
        # Requiring an UPPERCASE first segment missed those, so the object's `override`s
        # were attributed to the enclosing class and R1 falsely flagged them.
        m = re.compile(r"object\s*:\s*[A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*"
                       r"\s*(?:\([^)]*\))?\s*\{").search(body, i)
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
    stops: list[int] = []
    for i, m in enumerate(decls):
        kind, index = walk_declaration(src, m.start())
        op = index if kind == 'brace' else -1
        stops.append(index if kind == 'stop' else -1)
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
        # D6: a BRACELESS declaration endeth at the member that followeth it, so its
        # region must not absorb the NEXT type's members (`data class Row(...)` before
        # `fun mintSos()` -- else mintSos was attributed to Row and Authority looked
        # memberless).
        if stops[i] != -1 and starts[i] < stops[i] < nxt:
            nxt = stops[i]
        text = list(src[starts[i]:nxt])
        for k in kids:
            stop, close = ends[k]
            span_end = close + 1 if close != -1 else starts[k]
            for q in range(starts[k] - starts[i], min(span_end, nxt) - starts[i]):
                if 0 <= q < len(text):
                    text[q] = chr(10)
        regions.append("".join(text))
    return [src[:starts[0]]] + regions, decls


# D6 (GS-CTRL-002): a line that BEGINNETH a class member, so a BRACELESS declaration
# (`private data class Row(...)` / `sealed interface X : Y`) terminateth at the next
# member instead of swallowing it into its own header and then scanning on until the
# next `{` -- which attributed the following type's body to the braceless declaration.
# *The defect this closes, measured: `private data class Row(...)` (no `{`) was followed
# by `fun mintSos()`, and the walker ran past Row to the NEXT class's `{`, so Row's body
# became the whole of the next class. The next class registered with an empty member set
# (`mintSos`, `statusOf`, `activeSos`, `cancel` all attributed to `Row`), and R2 reported
# a FALSE UNRESOLVED on `authority.mintSos()` although the compiler accepts it.* The
# anchor is a member KEYWORD (`fun`/`val`/`var`/`init`/`constructor`/`companion`) at
# the start of a line, so a BRACELESS declaration endeth at the next member while a
# member's own body (and the declarations inside it) stay with that member.
MEMBER_DECL_LINE = re.compile(
    r"^(?:@\w+\s+|(?:public|internal|private|protected|override|open|abstract|final|"
    r"sealed|const|lateinit|inline|suspend|operator|infix|tailrec|external|expect|"
    r"actual|vararg|noinline|crossinline|reified|dynamic)\s+)*"
    r"(?:fun|val|var|init|constructor|companion)\b")


def walk_declaration(src: str, from_index: int) -> tuple[str, int]:
    """Scan a declaration header -> ('brace', i) at its body `{`, ('stop', i) at the
    declaration/member that terminateth a BRACELESS declaration, or ('eof', len(src)).

    D1/D6 (GS-CTRL-002): a single walk serves BOTH `header_body_start` (which wanteth
    the body brace) and `declaration_regions` (which needeth the terminus of a braceless
    declaration). Keeping one scan keepeth the two from drifting apart.
    """
    depth = 0
    index = from_index
    while index < len(src) and src[index].isspace():
        index += 1
    decl_start = index          # THIS declaration's own first character
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
            return 'brace', index
        elif ch == '}' and depth == 0:
            return 'stop', index          # the previous declaration endeth here
        elif ch == chr(10):
            line_start = True
            index += 1
            continue
        elif depth == 0 and line_start and not ch.isspace():
            # a NEW declaration at depth zero terminateth a BRACELESS one -- and so doth
            # a member declaration (D6): `data class Row(...)` followed by `fun mintSos()`
            # ENDETH at Row, so Row's region never swalloweth the next member's declaration.
            line_end = src.find(chr(10), index)
            line = src[index:len(src) if line_end == -1 else line_end]
            if index != decl_start and (TYPE_DECL.match(line)
                                        or MEMBER_DECL_LINE.match(line)):
                return 'stop', index
        if not ch.isspace():
            line_start = False
        index += 1
    return 'eof', len(src)


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
    kind, index = walk_declaration(src, from_index)
    return index if kind == 'brace' else -1


def parse_types(files: list[Path]) -> tuple[dict, dict, set, dict, set]:
    """-> ({TypeName: {members}}, {TypeName: [supertypes]}, {declared type names},
           {TypeName: {declaring packages}}, {top-level TypeNames})

    The third value is what R2 must judge by: a type that appeareth ONLY as an
    extension receiver (`fun String.toBytes()`) is NOT a project type, and judging
    `String.trim()` against `{toBytes}` would be a false positive. Extensions still add
    their member to a DECLARED type. (That distinction was learned the hard way: the
    first version of D5 made 247 stdlib calls look unresolved.)
    """
    members: dict[str, set[str]] = {}
    supers: dict[str, list[str]] = {}
    declared: set[str] = set()
    # (h) GS-CTRL-002: the PACKAGE of every declared type, so a QUALIFIED reference can
    # be VERIFIED against declaration identity rather than reduced to a bare tail.
    type_packages: dict[str, set[str]] = {}
    # (h) rounds 5-6: the TOP-LEVELNESS and DECLARATION IDENTITY of every tail. A
    # QUALIFIED reference `p.A` may resolve ONLY to a single, UNIQUE, package-level `A`:
    #   * `top_level` is computed from the brace NESTING DEPTH at the declaration, so a
    #     local class inside a FUNCTION body is not top-level (its enclosing `{` is a
    #     function body, not a type);
    #   * `identity_count` counteth DISTINCT declarations of a tail within its package, so
    #     a tail with more than one declaration (a top-level `A` beside a nested
    #     `Outer.A`) is AMBIGUOUS and is refused -- its merged member set must not be
    #     consumed.
    top_level: set[str] = set()
    identity_count: dict[tuple, int] = {}
    # PASS 1 collects every declaration's NAME, PACKAGE, TOP-LEVELNESS and IDENTITY across
    # ALL files first, so a qualified supertype in an earlier file can be identity-verified
    # against a type declared in a later one (a single pass resolved `class Prod :
    # io.t.Composed` before `Composed` had been seen and wrongly marked the chain
    # incomplete).
    for f in files:
        src = f.read_text(encoding="utf-8", errors="ignore")
        pkg_match = PACKAGE_DECL.search(src)
        decl_pkg = pkg_match.group(1) if pkg_match else ""
        mask = code_mask(src)
        for m in TYPE_DECL.finditer(src):
            opening = header_body_start(src, m.start())
            declared.add(m.group(1))
            type_packages.setdefault(m.group(1), set()).add(decl_pkg)
            key = (decl_pkg, m.group(1))
            identity_count[key] = identity_count.get(key, 0) + 1
            # top-level = NO open brace encloseth the declaration's own start (every
            # enclosing brace is a type OR a function/init body, so either way the
            # declaration is not package-level). The depth cometh from the MASK, so a
            # brace inside a string/comment cannot forge a package-level declaration.
            depth = 0
            for ch in mask[:m.start()]:
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth = max(0, depth - 1)
            if depth == 0:
                top_level.add(m.group(1))
    # PASS 2 collects members and supertypes now that identities are known.
    for f in files:
        src = f.read_text(encoding="utf-8", errors="ignore")
        regions, decls = declaration_regions(src)
        pkg_match = PACKAGE_DECL.search(src)
        decl_pkg = pkg_match.group(1) if pkg_match else ""
        for i, m in enumerate(decls):
            name = m.group(1)
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
                # (f)+(h) GS-CTRL-002: a QUALIFIED supertype (`class A : io.godstone.x.B`)
                # nameth the project type `B`, but ONLY when the qualifier VERIFIABLY names
                # B's declaring package -- never by dropping the qualifier and grabbing an
                # unrelated same-named class (reviewer finding 4). An unverifiable base is
                # left unresolved, so the chain stayeth VISIBLY incomplete, never wrongly
                # complete.
                for b in bases:
                    resolved = resolve_qualified_type(b, decl_pkg, declared, type_packages,
                                                      top_level, identity_count)
                    if resolved:
                        supers.setdefault(name, []).append(resolved)
                    elif "." in b:
                        # an UNRESOLVED qualified base is recorded as-is, so
                        # chain_complete() seeth leaving the project and the subtype
                        # stayeth VISIBLY incomplete -- never silently dropped, never
                        # mapped onto an unrelated same-named class.
                        supers.setdefault(name, []).append(b)
                    elif b and b[0].isupper() and " " not in b:
                        supers.setdefault(name, []).append(b)
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
    return members, supers, declared, type_packages, top_level, identity_count


def brace_pairs(src: str) -> list:
    """Every brace pair, innermost included."""
    pairs, stack = [], []
    for index, ch in enumerate(src):
        if ch == '{':
            stack.append(index)
        elif ch == '}' and stack:
            pairs.append((stack.pop(), index))
    return pairs


def enclosing_span(pairs: list, offset: int):
    """The INNERMOST brace pair containing `offset`, or None."""
    best = None
    for start, end in pairs:
        if start < offset < end and (best is None or start > best[0]):
            best = (start, end)
    return best


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


WHEN_SUBJECT = re.compile(r"\bwhen\s*\(\s*([a-z][\w]*)\s*\)")


def _arm_types(condition: str) -> set:
    """The types a top-level `when` arm condition NARROWETH the subject to.

    The arm executeth when ANY comma-separated alternative matcht, so the subject's
    static type is the UNION of those alternatives and a member is accessible only when
    EVERY alternative declares it. This therefore returneth the FULL alternative set (the
    caller requireth the member on all of them), and returneth the EMPTY set whenever any
    alternative is not a supported positive `is T` (`!is T`, a value/object arm, `in`,
    `else`, `null`) -- because then the arm guaranteeth nothing about the subject's type.
    Reviewer finding (1): the earlier version returned the FIRST matching `is`, which
    granted A's members where the arm could have been entered through B.
    """
    positives = set()
    for part in _split_top_commas(condition):
        m = re.fullmatch(r"is\s+([A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*)", part.strip())
        if not m:
            return set()
        positives.add(m.group(1))
    return positives


def shadows_in_arm(mask: str, recv: str, body_start: int, call_offset: int,
                   pairs: list) -> bool:
    """True when a binding of `recv` SHADOWS the `when` subject at the call.

    (findings 3 and 4) Both a `val`/`var` re-binding AND a binding PARAMETER
    (`fun ...(recv:` / `{ recv ->` / `recv:`) are considered, and a binding counteth only
    when its own enclosing block still CONTAINETH the call -- so:
      * an expired inner `val s` inside a block that hath already closed doth NOT suppress
        a valid outer cast;
      * a binding parameter belongeth to its own function/lambda BODY (the brace AFTER its
        header), never to the arm block that precedeth the header, so a `fun local(s: S)`
        whose body endeth before the call doth NOT shadow the later outer call;
      * a binding parameter whose header is the ARM ITSELF (`is A -> { s -> ... }`) or a
        nested lambda/lambda-parameter that still encloseth the call correctly shadoweth.
    """
    region = mask[body_start:call_offset]
    # `val`/`var` re-bindings: their block is the brace enclosing the declaration
    for m in re.finditer(r"\b(?:val|var)\s+" + re.escape(recv) + r"\b", region):
        span = enclosing_span(pairs, body_start + m.start())
        if span is None or span[1] >= call_offset:
            return True
    # NAMED local functions with a binding parameter: their scope is the BODY -- a `{...}`
    # block, or (an expression body) to the end of their enclosing block. An expression
    # body (`fun local(s: S) = s.special()`) hath NO `{`, so it is conservatively treated
    # as shadowing for the whole arm (reviewer round-4 finding 2).
    for m in re.finditer(r"\bfun\s+[\w<>.]+\s*(?:@\w+\s*)*\(", region):
        opening = body_start + m.end() - 1
        close = _matching_paren(mask, opening)
        params = mask[opening + 1:close if close != -1 else len(mask)]
        if not re.search(r"\b" + re.escape(recv) + r"\s*:", params):
            continue
        after = close + 1 if close != -1 else len(mask)
        brace = mask.find(chr(123), after)
        eq = mask.find('=', after)
        if brace != -1 and (eq == -1 or brace < eq):
            span = enclosing_span(pairs, brace + 1)
            if span is None or span[1] >= call_offset:
                return True
        else:
            return True                       # expression body or unscopable: withhold
    # ANONYMOUS lambda parameters: belong to the NEXT `{` (the lambda body)
    for m in re.finditer(r"(?:\(|,|\{)\s*" + re.escape(recv) + r"\s*:", region):
        brace = mask.find(chr(123), body_start + m.end())
        if brace == -1:
            continue
        span = enclosing_span(pairs, brace + 1)   # the body brace's OWN pair
        if span is None or span[1] >= call_offset:
            return True
    return False


def subject_written(mask: str, pairs: list, recv: str, body_start: int,
                    call_offset: int) -> bool:
    """True when the binding the `when` TESTED (`recv`) is assigned before the call.

    (Main) A write invalidateth the arm's type fact ONLY if it targeteth the SAME binding
    the `when` tested. That is decided by the binding VISIBLE AT THE WRITE, never by the
    write's own block having closed before the call:

      * a write where NO declaration/parameter shadows `recv` at the write offset targeteth
        the tested subject -- so it invalidateth the cast REGARDLESS of whether the write
        block closed before the call (`if (flag) { s = other }; s.special()` MUST refuse);
      * a write where a `val`/`var`/parameter of `recv` SHADOWETH the subject at the write
        offset targeteth that OTHER binding and is ignored (`if (flag) { var s = other;
        s = other }; s.special()` keeps the outer cast).

    Scope at the write reuseth `shadows_in_arm`; a NAMED ARGUMENT (`inspect(s = other)`) is
    an argument inside brackets, never an assignment statement (Kotlin assignment is no
    expression), and a compound `+=` is conservatively a write.
    """
    bracket_set = bracket_pairs(mask)
    for m in re.finditer(r"(?<![\w.])" + re.escape(recv) + r"\s*", mask[body_start:call_offset]):
        at = body_start + m.start()
        k = body_start + m.end()
        bracket = enclosing_span(bracket_set, at)
        if bracket is not None and mask[bracket[0]] in '([':
            continue                       # `inspect(s = other)`: a named argument
        compound = k < len(mask) and mask[k] in '+-*/%'
        eq = k + 1 if compound else k
        while eq < call_offset and mask[eq] in ' \t\n':
            eq += 1
        if eq >= len(mask) or mask[eq] != '=':
            continue
        if eq + 1 < len(mask) and mask[eq + 1] == '=':
            continue
        if not shadows_in_arm(mask, recv, body_start, at, pairs):
            return True                    # writes the tested binding
    return False


def bracket_pairs(src: str) -> list:
    """Every paren/bracket pair, innermost included (for named-argument detection)."""
    pairs, stack = [], []
    for index, ch in enumerate(src):
        if ch in '([{':
            stack.append((ch, index))
        elif ch in ')]}' and stack:
            _o, start = stack.pop()
            pairs.append((start, index))
    return pairs


def when_branch_types(mask: str, pairs: list, recv: str, call_offset: int,
                      resolve_type) -> set:
    """(g)+(h) GS-CTRL-002: the `is T` arm type of the arm that CONTAINETH `call_offset`.

    A `when (x) { is T -> x.m() }` branch smart-casteth `x` to T for the duration of that
    arm, exactly as an `if (x is T)` doth. This helper therefore:

      * scans a COMMENT/STRING-BLANKED mask (`code_mask`), so a brace inside a literal
        (`println("{")`) can NEVER close the `when` early and leak a cast beyond its real
        boundary (reviewer finding 2);
      * recognises EVERY top-level arm boundary and granteth a type ONLY for a supported
        POSITIVE type check in the arm that actually CONTAINETH the call (finding 1);
      * refuseth to cast across a SHADOWING redeclaration or PARAMETER of the subject
        INSIDE the arm that containeth the call (`shadows_in_arm`), respecting lexical
        scope so an already-closed inner binding does not suppress a valid cast
        (findings 3 and 4);
      * resolveth a QUALIFIED arm type through `resolve_type`, so an unverifiable
        `io.other.A` never mapeth onto an unrelated project `A` (finding 4);
      * granteth NOTHING for a COMMA arm (`is A, is B`): Kotlin narroweth a disjunction
        to its closest common NOMINAL supertype, which this resolver cannot prove, so the
        receiver keepeth its DECLARED type rather than a duck-typed union (findings 1, 2).
    """
    out: set = set()
    for w in WHEN_SUBJECT.finditer(mask):
        if w.group(1) != recv:
            continue
        opening = mask.find(chr(123), w.end())
        if opening == -1:
            continue
        closing = matching_brace(mask, opening)
        if closing == -1 or not (opening < call_offset < closing):
            continue
        # top-level arm arrows: walk the mask tracking brace depth so a nested block's
        # `->` (a lambda inside an arm) is not mistaken for an arm boundary
        arrows: list[int] = []
        depth, index = 0, opening + 1
        while index < closing:
            ch = mask[index]
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth = max(0, depth - 1)
            elif (depth == 0 and ch == '-' and index + 1 < closing
                  and mask[index + 1] == '>'):
                arrows.append(index)
                index += 2
                continue
            index += 1
        # For each arm k the CONDITION is the LAST top-level statement (or comma-
        # continuation group) before its `->`, and the BODY runneth from `->` up to the
        # NEXT arm's condition start. A call INSIDE a body getteth that arm's cast; a call
        # INSIDE the NEXT arm's condition is evaluated BEFORE the arm is chosen and getteth
        # NO cast (reviewer finding 2). A comma CONTINUATION across a newline (`is A,` then
        # `is B ->`) is kept whole, so every alternative is seen (round-3 finding 2).
        def cond_start_for(seg_start: int, arrow: int) -> int:
            d, j, last = 0, seg_start, seg_start
            while j < arrow:
                c = mask[j]
                if c in '([{':
                    d += 1
                elif c in ')]}':
                    d = max(0, d - 1)
                elif d == 0 and c == ';':
                    last = j + 1
                elif d == 0 and c == chr(10):
                    # a comma CONTINUATION surviveth a newline AND blank/comment-only
                    # lines, so scan back over ALL whitespace (the mask blanketh comments
                    # to spaces but keepeth their newlines) to the last CODE character
                    k = j - 1
                    while k >= seg_start and mask[k] in ' \t\n':
                        k -= 1
                    if k >= seg_start and mask[k] != ',':
                        last = j + 1
                j += 1
            return last

        cond_starts = []
        for k, arrow in enumerate(arrows):
            if k == 0:
                cond_starts.append(opening + 1)
            else:
                cond_starts.append(cond_start_for(arrows[k - 1] + 2, arrow))

        arm_types: set = set()
        body_range = None
        for k, arrow in enumerate(arrows):
            body_start = arrow + 2
            body_end = cond_starts[k + 1] if k + 1 < len(arrows) else closing
            if body_start <= call_offset < body_end:
                arm_types = _arm_types(mask[cond_starts[k]:arrow])
                body_range = (body_start, call_offset)
                break
            if k + 1 < len(arrows) and cond_starts[k + 1] <= call_offset < arrows[k + 1]:
                # the call is in the CONDITION that selecteth arm k+1: no cast applies
                arm_types = set()
                body_range = None
                break
        if body_range is None:
            continue
        # (Main reassigned_subject) an ASSIGNMENT STATEMENT to the SAME binding the `when`
        # tested, still live at the call, invalidateth the arm's type fact. A named argument
        # (`inspect(s = other)`) or a write to an EXPIRED shadowing binding doth not.
        if subject_written(mask, pairs, recv, body_range[0], call_offset):
            continue
        # (findings 3 and 4) a redeclaration OR a parameter binding of the subject INSIDE
        # the containing arm's body, still IN SCOPE at the call, breaketh the cast.
        if shadows_in_arm(mask, recv, body_range[0], body_range[1], pairs):
            continue
        resolved_types: set = set()
        for arm_type in arm_types:
            resolved = resolve_type(arm_type)
            if not resolved:
                resolved_types = set()
                break
            resolved_types.add(resolved)
        # ONLY a SINGLE positive `is T` arm granteth a cast. A COMMA arm (`is A, is B`) is
        # DECLINED -- no new cast: Kotlin narroweth a disjunction to its closest common
        # NOMINAL supertype, which the registry cannot prove, so the receiver keepeth its
        # DECLARED type (whose own members still resolve). Reviewer findings (1, 2).
        if len(arm_types) == 1 and len(resolved_types) == 1:
            out |= resolved_types
    return out


def resolve(root: Path) -> list[str]:
    global SKIPPED_INCOMPLETE
    files = sorted((root / "android").rglob("*.kt"))
    members, supers, declared, type_packages, top_level, identity_count = parse_types(files)
    # *** EVERY PACKAGE THIS PROJECT DECLARES, so an import of a PROJECT type is not mistaken for an external one. ***
    # *The resolver compares an import's package against this set: a match meaneth the import names a project type
    # (keep judging its receivers); a miss meaneth an external type whose members this resolver cannot see (skip).*
    project_packages = set()
    for _f in files:
        _pkg = PACKAGE_DECL.search(_f.read_text(encoding="utf-8", errors="ignore"))
        if _pkg:
            project_packages.add(_pkg.group(1))
    globals()["PROJECT_PACKAGES"] = project_packages
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

        # *** AN EXPLICITLY-IMPORTED NON-PROJECT TYPE IS UNKNOWABLE: THE IMPORT WINNETH OVER A SAME-NAMED PROJECT CLASS. ***
        #
        # *THE DEFECT THIS CLOSES, MEASURED: a test file declared a PROJECT-LOCAL `private class Cursor(val text:
        # String)`, and `android/.../PeerIdentitySchema.kt` -- which explicitly `import android.database.Cursor` --
        # typed a receiver `Cursor` and called `cursor.use()`. **The resolver resolved the receiver to the PROJECT class
        # `Cursor` (by simple name) and reported a FALSE UNRESOLVED on a source the compiler accepts.** *In Kotlin an
        # explicit import BINDETH the simple name to that package's type, so a project class elsewhere is NOT the
        # receiver's type and its members must not be judged.* **Only imports of names this project does NOT declare
        # are treated as external; an import of a project type (`import io.godstone...MessageStore`) is unchanged, and
        # an import naming a simple name that a project class shadows IN THE SAME FILE is left alone (the resolver's
        # existing scoping already picks the nearest declaration).**
        pkg_match = PACKAGE_DECL.search(src)
        decl_pkg = pkg_match.group(1) if pkg_match else ""
        local_decls = {m.group(1) for m in decls}

        def resolve_type(text: str) -> str | None:
            """Resolve an ARM TYPE to a UNIQUE project identity, or None.

            A smart cast may be justified ONLY by a declaration identity that is UNIQUE.
            Main's `ambiguous_unqualified_cast` witness: an unqualified `is A` where `A`
            existeth in BOTH package `a` (declaring `special`) and package `b` (declaring
            nothing) MUST NOT consume the merged `A` (which carrieth `special`); the type
            is ambiguous, so NO cast is granted. Supertypes use `resolve_qualified_type`
            directly and are unchanged.
            """
            if '.' in text:
                return resolve_qualified_type(text, decl_pkg, declared, type_packages,
                                              top_level, identity_count)
            if not text or not text[0].isupper() or text not in declared:
                return None
            pkgs = type_packages.get(text, set())
            if len(pkgs) != 1:
                return None                 # declared in more than one package: ambiguous
            pkg = next(iter(pkgs))
            if identity_count.get((pkg, text), 1) != 1:
                return None                 # more than one declaration in that package
            return text

        external_imports: set[str] = set()
        for im in IMPORT_DECL.finditer(src):
            target, alias = im.group(1), im.group(2)
            if target.endswith(".*"):
                continue
            simple = alias or target.rsplit(".", 1)[-1]
            # an import naming a type THIS FILE declares is the same-module type (leave it judged);
            # an import whose FQN lives in a package THIS PROJECT declares is a project type (leave it judged);
            # otherwise the simple name bindeth to the imported package's type, which is external.
            import_pkg = target.rsplit(".", 1)[0] if "." in target else ""
            if simple in local_decls and not alias:
                continue
            if import_pkg in PROJECT_PACKAGES:
                continue
            external_imports.add(simple)

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
                known = set(own_names) | set(ANY_OVERRIDABLE)
                if any(dm.group(1) == m.group(1) for dm in DATA_CLASS.finditer(src)):
                    known |= DATA_SYNTHETIC
                for base in supers.get(m.group(1), []):
                    known |= all_members(base, members, supers)
                parsed = members.get(m.group(1), set())
                if (own_names - parsed) or (parsed - known):
                    # a member MISSING from the type, or a member that belongeth to
                    # somebody else: either way the set is not to be trusted
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
            # comment/string-blanked view of THIS scope for the `when` structural scan
            arm_mask = code_mask(scope_src)
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
            # LEXICAL SCOPING: a declaration is visible at a call only when its own
            # innermost enclosing block CONTAINETH the call. Without this, a property of
            # one class typed a receiver inside another (`val node: ComposedNode` beside
            # `val node: MeshNode`), which produced the last five false positives at the
            # audited SHA. The brace structure is read from the COMMENT/STRING-BLANKED mask
            # so a brace inside a literal (`println("${"{"}")`) cannot forge a block
            # boundary and shift a receiver's scope (round-3 finding c).
            pairs = brace_pairs(arm_mask)
            # D4: the branches in which a SMART CAST maketh another type available. The
            # brace structure cometh from the mask, so a literal brace cannot shift a cast
            # span (round-3 finding c).
            cast_spans = []
            for cast in SMART_CAST.finditer(arm_mask):
                opening = arm_mask.find(chr(123), cast.end())
                # (a) GS-CTRL-002: an if-EXPRESSION without braces (`if (x is T) x.m()`)
                # maketh the cast available to the end of its LINE
                line_end = arm_mask.find(chr(10), cast.end())
                if line_end == -1:
                    line_end = len(arm_mask)
                if opening == -1 or opening > line_end:
                    opening, closing = cast.end(), line_end
                    cast_spans.append((cast.start(), opening, closing,
                                       cast.group(1), cast.group(2)))
                    continue
                closing = matching_brace(arm_mask, opening)
                if closing == -1:
                    continue
                cast_spans.append((cast.start(), opening, closing, cast.group(1), cast.group(2)))
            for call in CALL.finditer(scope_src):
                recv, method = call.group(1), call.group(2)
                # A CHAINED receiver (`a.node.dispatchDirect(...)`) is not judgeable: the
                # resolver modellth no FIELD types, so `node` here is a property of `a` and
                # not the `node` declared anywhere in scope. Treating it as the latter is
                # how the last five false positives at the audited SHA were born.
                before = scope_src[max(0, call.start() - 3):call.start()]
                if before.rstrip().endswith(('.', '?.')) or before.strip().endswith('.'):
                    continue
                call_span = enclosing_span(pairs, call.start())
                visible = []
                for entry in declarations:
                    if entry[1] != recv or entry[0] >= call.start():
                        continue
                    span = enclosing_span(pairs, entry[0])
                    if span is None or call_span is None or span == call_span \
                            or (span[0] <= call.start() <= span[1]):
                        visible.append(entry)
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
                # *** AN EXPLICITLY-IMPORTED EXTERNAL TYPE IS UNKNOWABLE: THE IMPORT WINNETH OVER A SAME-NAMED PROJECT CLASS. ***
                # *In Kotlin an explicit import bindeth the simple name to that package's type, so a project class
                # elsewhere that shareth the name (`Cursor`) is NOT the receiver's type -- judging it against the
                # project class's members reported a FALSE UNRESOLVED (`cursor.use()`). The receiver's members live
                # outside the project, so it is SKIPPED (a visible limitation, like an incomplete chain).*
                if t in external_imports:
                    SKIPPED_INCOMPLETE.add(t)
                    continue
                if t in INCOMPLETE_PARSED or t in truncated:
                    # the type's declaration was NOT read in full, so its member set is
                    # known to be incomplete: SKIP, and count the limitation
                    SKIPPED_INCOMPLETE.add(t)
                    continue
                # (g)+(h) GS-CTRL-002: a `when (x) { is T -> x.m() }` branch maketh T's
                # members available on `x` inside that branch, just as an `if (x is T)`
                # doth. *The resolver modelled the `is`-check form but not the `when`-subject
                # form, so `store.commitInboundWithObligationAtWithFault(...)` under
                # `when (store) { is SqliteMessageStore -> ... }` was judged against the
                # INTERFACE `MessageStore` (which declares no such member) and reported a
                # FALSE UNRESOLVED on source the compiler accepts.*
                cast_candidates = {t}
                cast_candidates |= when_branch_types(arm_mask, pairs, recv, call.start(),
                                                     resolve_type)
                for span_start, opening, closing, cast_recv, cast_type in cast_spans:
                    if cast_recv == recv and opening <= call.start() <= closing:
                        cast_candidates.add(cast_type)
                # each candidate is a SINGLE type (comma arms contribute none), so the
                # member is present when ANY candidate carrieth it
                if any(method in all_members(c, members, supers) for c in cast_candidates):
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
    3. Runs the synthetic acceptance/refusal pairs (each in its own temp tree): the four
       hosted-rc15 legal Kotlin shapes (which must NOT be reported -- the failure was a
       false POSITIVE) plus the reviewer's false-NEGATIVE guards (a `!is` arm, a value-arm
       boundary, a string/nested-comment/interpolation brace leak, a shadowed subject, a
       comma arm and its blank-line continuation, an expression-bodied local parameter, a
       call in a later arm's condition, and an unverified / ambiguous / nested /
       function-local qualified name) and their legal counterparts.
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

    synthetic = _synthetic_controls()
    clean = resolve(root)
    print(f"  restored tree: {len(clean)} unresolved "
          f"({'OK' if not clean else 'BROKEN'})")
    return 0 if (caught and gate_caught and synthetic and not clean) else 1


# Each synthetic control is (label, expect, source). A LEGAL shape must yield no finding
# (a false POSITIVE would redden it); an ILLEGAL shape must yield exactly one. They are
# run against a THROWAWAY tree, never the live one, so the gate proof stayeth offline of
# any real file. The four legal shapes were each mis-read by a pre-rc16 resolver and
# produced the hosted Invariant F failure this control now guards.
SYNTHETIC_CONTROLS = (
    ("braceless-decl", "legal", """
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
"""),
    ("qualified-supertype", "legal", """
package io.t
interface Composed { fun f(): Int }
interface Wipe : io.t.Composed { fun g(): Int }
class Prod : io.t.Composed, Wipe {
    override fun f(): Int = 1
    override fun g(): Int = 2
}
"""),
    ("when-subject-cast", "legal", """
package io.t
interface Store { fun common(): Int }
class SqlStore : Store { fun specialized(): Int = 1 }
class StoreUser {
    fun run(s: Store) {
        when (s) {
            is SqlStore -> s.specialized()
            else -> s.common()
        }
    }
}
"""),
    ("qualified-anon-object", "legal", """
package io.t
interface Iface { fun f(): Int }
interface Owner { fun g(): Int }
class Outer : Owner {
    val x = object : io.t.Iface {
        override fun f(): Int = 1
    }
    override fun g(): Int = 2
}
"""),
    ("missing-member", "illegal", """
package io.t
class Widget { fun ok(): Int = 1 }
class WidgetUser {
    fun use(w: Widget) { w.missing() }
}
"""),
    ("stray-override", "illegal", """
package io.t
interface Base { fun f(): Int }
class Impl : Base {
    override fun nope(): Int = 1
}
"""),
    ("when-arm-scope", "illegal", """
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
"""),
    ("qualified-stray-override", "illegal", """
package io.t
interface Composed { fun f(): Int }
interface Wipe : io.t.Composed { fun g(): Int }
class Prod2 : io.t.Composed, Wipe {
    override fun f(): Int = 1
    override fun h(): Int = 2
}
"""),
    ("negative-is-arm", "illegal", """
package io.t
interface CtrlNegStore { fun common(): Int }
class CtrlNegA : CtrlNegStore { fun spec(): Int = 1 }
class CtrlNegRunner {
    fun run(s: CtrlNegStore) {
        when (s) {
            !is CtrlNegA -> s.spec()
            else -> s.common()
        }
    }
}
"""),
    ("value-arm-boundary", "illegal", """
package io.t
interface CtrlValStore { fun common(): Int }
class CtrlValA : CtrlValStore { fun spec(): Int = 1 }
class CtrlValOther : CtrlValStore
class CtrlValRunner {
    fun run(s: CtrlValStore) {
        when (s) {
            is CtrlValA -> s.common()
            CtrlValOther -> s.spec()
            else -> s.common()
        }
    }
}
"""),
    ("string-brace-leak", "illegal", """
package io.t
interface CtrlStrStore { fun common(): Int }
class CtrlStrA : CtrlStrStore { fun spec(): Int = 1 }
class CtrlStrRunner {
    fun run(s: CtrlStrStore) {
        when (s) {
            is CtrlStrA -> println("{")
            else -> Unit
        }
        s.spec()
    }
}
"""),
    ("shadowed-subject", "illegal", """
package io.t
interface CtrlShStore { fun common(): Int }
class CtrlShA : CtrlShStore { fun spec(): Int = 1 }
class CtrlShB : CtrlShStore
class CtrlShRunner {
    fun run(s: CtrlShStore, other: CtrlShStore) {
        when (s) {
            is CtrlShA -> {
                val s: CtrlShStore = other
                when (s) {
                    is CtrlShB -> s.spec()
                    else -> s.common()
                }
            }
            else -> s.common()
        }
    }
}
"""),
    ("unrelated-qualified-base", "illegal", """
package io.t
open class CtrlBase { fun projectOnly(): Int = 1 }
class CtrlChild : absent.CtrlBase() {
    fun own(): Int = 2
}
class CtrlBaseUser {
    fun use(c: CtrlChild) { c.projectOnly() }
}
"""),
    ("qualified-arm-unmatched", "illegal", """
package io.t
interface CtrlQStore { fun common(): Int }
class CtrlQA : CtrlQStore { fun spec(): Int = 1 }
class CtrlQRunner {
    fun run(s: CtrlQStore) {
        when (s) {
            is absent.CtrlQA -> s.spec()
            else -> s.common()
        }
    }
}
"""),
    ("comma-arm-no-cast-illegal", "illegal", """
package io.t
interface CtrlMultiStore { fun common(): Int }
class CtrlMultiA : CtrlMultiStore { fun spec(): Int = 1 }
class CtrlMultiB : CtrlMultiStore { fun spec(): Int = 2 }
class CtrlMultiRunner {
    fun run(s: CtrlMultiStore) {
        when (s) {
            is CtrlMultiA, is CtrlMultiB -> s.spec()
            else -> s.common()
        }
    }
}
"""),
    ("comma-arm-shared-supertype-legal", "legal", """
package io.t
interface CtrlSupStore { fun shared(): Int }
class CtrlSupA : CtrlSupStore
class CtrlSupB : CtrlSupStore
class CtrlSupRunner {
    fun run(s: CtrlSupStore) {
        when (s) {
            is CtrlSupA, is CtrlSupB -> s.shared()
            else -> s.shared()
        }
    }
}
"""),
    ("verified-qualified-base-legal", "legal", """
package io.t
open class CtrlGoodBase { fun projectOnly(): Int = 1 }
class CtrlGoodChild : io.t.CtrlGoodBase() {
    fun own(): Int = 2
}
class CtrlGoodUser {
    fun use(c: CtrlGoodChild) { c.projectOnly() }
}
"""),
    ("next-arm-condition-call", "illegal", """
package io.t
interface CtrlCondStore { fun common(): Int }
class CtrlCondA : CtrlCondStore { fun special(): Int = 1 }
class CtrlCondRunner {
    fun run(s: CtrlCondStore) {
        when (s) {
            is CtrlCondA -> Unit; s.special() -> Unit; else -> Unit
        }
    }
}
"""),
    ("multi-line-comma-condition", "illegal", """
package io.t
interface CtrlMlStore { fun common(): Int }
class CtrlMlA : CtrlMlStore
class CtrlMlB : CtrlMlStore { fun special(): Int = 1 }
class CtrlMlRunner {
    fun run(s: CtrlMlStore) {
        when (s) {
            is CtrlMlB -> s.common()
            is CtrlMlA,
            is CtrlMlB -> s.special()
            else -> s.common()
        }
    }
}
"""),
    ("string-interpolation-brace", "illegal", """
package io.t
interface CtrlInterpStore { fun common(): Int }
class CtrlInterpA : CtrlInterpStore { fun special(): Int = 1 }
class CtrlInterpRunner {
    fun run(s: CtrlInterpStore) {
        when (s) {
            is CtrlInterpA -> println("${"{"}")
            else -> Unit
        }
        s.special()
    }
}
"""),
    ("duplicate-qualified-basename", "illegal", {
        "Shared.kt": "package shared\ninterface Store { fun common(): Int }\n",
        "A.kt": "package a\nclass Base : shared.Store { fun special(): Int = 1 }\n",
        "B.kt": "package b\nclass Base : shared.Store\n",
        "U.kt": ("package u\nimport shared.Store\nclass U {\n"
                 "    fun run(s: Store) {\n        when (s) {\n"
                 "            is b.Base -> s.special()\n"
                 "            else -> s.common()\n        }\n    }\n}\n"),
    }),
    ("unique-qualified-basename-legal", "legal", {
        "Shared.kt": "package shared\ninterface Store { fun common(): Int }\n",
        "A.kt": "package a\nclass OnlyBase : shared.Store { fun special(): Int = 1 }\n",
        "U.kt": ("package u\nimport shared.Store\nclass U {\n"
                 "    fun run(s: Store) {\n        when (s) {\n"
                 "            is a.OnlyBase -> s.special()\n"
                 "            else -> s.common()\n        }\n    }\n}\n"),
    }),
    ("expired-inner-binding-legal", "legal", """
package io.t
interface CtrlExpStore { fun common(): Int }
class CtrlExpA : CtrlExpStore { fun special(): Int = 1 }
class CtrlExpRunner {
    fun run(s: CtrlExpStore, other: CtrlExpStore, flag: Boolean) {
        when (s) {
            is CtrlExpA -> {
                if (flag) { val s: CtrlExpStore = other; s.common() }
                s.special()
            }
            else -> s.common()
        }
    }
}
"""),
    ("local-param-shadows-subject", "illegal", """
package io.t
interface CtrlParStore { fun common(): Int }
class CtrlParA : CtrlParStore { fun special(): Int = 1 }
class CtrlParB : CtrlParStore
class CtrlParRunner {
    fun run(s: CtrlParStore) {
        when (s) {
            is CtrlParA -> {
                fun local(s: CtrlParStore) {
                    when (s) {
                        is CtrlParB -> s.special()
                        else -> s.common()
                    }
                }
                local(s)
            }
            else -> s.common()
        }
    }
}
"""),
    ("nested-comment-brace", "illegal", """
package io.t
interface CtrlNcStore { fun common(): Int }
class CtrlNcA : CtrlNcStore { fun special(): Int = 1 }
class CtrlNcRunner {
    fun run(s: CtrlNcStore) {
        when (s) {
            is CtrlNcA -> println(0) /* outer /* inner */ { */; else -> Unit
        }
        s.special()
    }
}
"""),
    ("blank-line-comma-continuation", "illegal", """
package io.t
interface CtrlBlStore { fun common(): Int }
class CtrlBlA : CtrlBlStore
class CtrlBlB : CtrlBlStore { fun special(): Int = 1 }
class CtrlBlC : CtrlBlStore
class CtrlBlRunner {
    fun run(s: CtrlBlStore) {
        when (s) {
            is CtrlBlC -> Unit
            is CtrlBlA,

            // an explanation between alternatives
            is CtrlBlB -> s.special()
            else -> s.common()
        }
    }
}
"""),
    ("expression-bodied-local-param", "illegal", """
package io.t
interface CtrlEbStore { fun common(): Int }
class CtrlEbA : CtrlEbStore { fun special(): Int = 1 }
class CtrlEbRunner {
    fun run(s: CtrlEbStore) {
        when (s) {
            is CtrlEbA -> {
                fun local(s: CtrlEbStore) = s.special()
                local(s)
            }
            else -> Unit
        }
    }
}
"""),
    ("package-tail-nested-class", "illegal", """
package io.t
open class CtrlNsStore { fun common(): Int = 0 }
class CtrlNsOuter {
    class CtrlNsA : CtrlNsStore() { fun special(): Int = 1 }
}
class CtrlNsUser {
    fun run(s: CtrlNsStore) {
        when (s) {
            is io.t.CtrlNsA -> s.special()
            else -> s.common()
        }
    }
}
"""),
    ("qualified-top-level-legal", "legal", """
package io.t
open class CtrlTlStore { fun common(): Int = 0 }
class CtrlTlA : CtrlTlStore() { fun special(): Int = 1 }
class CtrlTlUser {
    fun run(s: CtrlTlStore) {
        when (s) {
            is io.t.CtrlTlA -> s.special()
            else -> s.common()
        }
    }
}
"""),
    ("ambiguous-top-and-nested", "illegal", """
package io.t
open class CtrlAmStore { fun common(): Int = 0 }
class CtrlAmA : CtrlAmStore()
class CtrlAmOuter {
    class CtrlAmA : CtrlAmStore() { fun special(): Int = 1 }
}
class CtrlAmUser {
    fun run(s: CtrlAmStore) {
        when (s) {
            is io.t.CtrlAmA -> s.special()
            else -> s.common()
        }
    }
}
"""),
    ("function-local-qualified", "illegal", {
        "S.kt": "package io.t\ninterface CtrlFlStore {\n    fun common(): Int\n}\n",
        "L.kt": ("package io.t\nfun ctrlFlMake() {\n    println(\"}\")\n"
                 "    class CtrlFlLocal : CtrlFlStore {\n"
                 "        fun special(): Int = 1\n"
                 "        override fun common(): Int = 0\n"
                 "    }\n}\n"),
        "U.kt": ("package io.t\nclass CtrlFlUser {\n"
                 "    fun run(s: CtrlFlStore) {\n        when (s) {\n"
                 "            is io.t.CtrlFlLocal -> s.special()\n"
                 "            else -> s.common()\n        }\n    }\n}\n"),
    }),
    ("ambiguous-unqualified-cast", "illegal", {
        "C.kt": "package c\nopen class Store {\n    fun common(): Int = 0\n}\n",
        "A1.kt": ("package a\nimport c.Store\n"
                  "class AmbA : Store() {\n    fun special(): Int = 1\n}\n"),
        "A2.kt": ("package b\nimport c.Store\n"
                  "class AmbA : Store() {\n}\n"),
        "U.kt": ("package b\nimport c.Store\nclass AmbUser {\n"
                 "    fun run(s: Store) {\n        when (s) {\n"
                 "            is AmbA -> s.special()\n"
                 "            else -> s.common()\n        }\n    }\n}\n"),
    }),
    ("reassigned-subject-cast", "illegal", """
package io.t
open class CtrlRStore { fun common(): Int = 0 }
class CtrlRA : CtrlRStore() { fun special(): Int = 1 }
class CtrlRUser {
    fun run(other: CtrlRStore) {
        var s: CtrlRStore = CtrlRA()
        when (s) {
            is CtrlRA -> {
                s = other
                s.special()
            }
            else -> s.common()
        }
    }
}
"""),
    ("nested-live-binding-write", "illegal", """
package io.t
interface CtrlNwStore { fun common(): Int }
class CtrlNwA : CtrlNwStore { fun special(): Int = 1 }
class CtrlNwRunner {
    fun run(s: CtrlNwStore, other: CtrlNwStore, flag: Boolean) {
        when (s) {
            is CtrlNwA -> {
                if (flag) {
                    s = other
                    s.special()
                }
            }
            else -> s.common()
        }
    }
}
"""),
    ("closed-block-outer-write", "illegal", """
package io.t
interface CtrlCwStore { fun common(): Int }
class CtrlCwA : CtrlCwStore { fun special(): Int = 1 }
class CtrlCwRunner {
    fun run(s: CtrlCwStore, other: CtrlCwStore, flag: Boolean) {
        when (s) {
            is CtrlCwA -> {
                if (flag) { s = other }
                s.special()
            }
            else -> s.common()
        }
    }
}
"""),
    ("write-after-statement", "illegal", """
package io.t
interface CtrlAsStore { fun common(): Int }
class CtrlAsA : CtrlAsStore { fun special(): Int = 1 }
class CtrlAsRunner {
    fun run(s: CtrlAsStore, other: CtrlAsStore) {
        when (s) {
            is CtrlAsA -> {
                s.common()
                s = other
                s.special()
            }
            else -> s.common()
        }
    }
}
"""),
    ("braceless-if-write", "illegal", """
package io.t
interface CtrlBiStore { fun common(): Int }
class CtrlBiA : CtrlBiStore { fun special(): Int = 1 }
class CtrlBiRunner {
    fun run(s: CtrlBiStore, other: CtrlBiStore) {
        when (s) {
            is CtrlBiA -> {
                if (true) s = other
                s.special()
            }
            else -> s.common()
        }
    }
}
"""),
    ("expired-inner-write-legal", "legal", """
package io.t
interface CtrlEwStore { fun common(): Int }
class CtrlEwA : CtrlEwStore { fun special(): Int = 1 }
class CtrlEwRunner {
    fun run(s: CtrlEwStore, other: CtrlEwStore, flag: Boolean) {
        when (s) {
            is CtrlEwA -> {
                if (flag) { var s: CtrlEwStore = other; s = other; s.common() }
                s.special()
            }
            else -> s.common()
        }
    }
}
"""),
    ("named-argument-not-a-write", "legal", """
package io.t
interface CtrlNaStore { fun common(): Int }
class CtrlNaA : CtrlNaStore { fun special(): Int = 1 }
class CtrlNaRunner {
    fun run(s: CtrlNaStore, other: CtrlNaStore) {
        when (s) {
            is CtrlNaA -> {
                ctrlNaInspect(s = other)
                s.special()
            }
            else -> s.common()
        }
    }
}
fun ctrlNaInspect(s: CtrlNaStore) {}
"""),
)


def _synthetic_controls() -> bool:
    """Run the synthetic acceptance/refusal pairs, each in its OWN temp tree.

    A control's `source` is either one Kotlin file's text or a {relative-path: text} map
    (for the cross-package identity controls). Each control getteth a fresh tree so a
    same-named type in one control cannot merge with another's (the type registry is
    global by simple name, so controls MUST be isolated to be deterministic).
    """
    print("\nSELFTEST -- synthetic acceptance/refusal pairs (the hosted rc15 shapes)\n")
    ok = True
    for label, expect, source in SYNTHETIC_CONTROLS:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "android" / "_selftest").mkdir(parents=True)
            if isinstance(source, dict):
                for rel, text in source.items():
                    target = root / "android" / "_selftest" / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(text, encoding="utf-8")
            else:
                (root / "android" / "_selftest" / f"{label}.kt").write_text(
                    source, encoding="utf-8")
            found = resolve(root)
        hits = list(found)
        good = (not hits) if expect == "legal" else (len(hits) == 1)
        ok = ok and good
        print(f"  {label:34s} {'OK' if good else 'BROKEN'} ({expect}, {len(hits)} finding(s))")
    return ok


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
