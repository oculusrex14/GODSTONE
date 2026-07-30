#!/usr/bin/env python3
"""Verify that every place Godstone writes down its tier table agrees.

The tier numbers are duplicated across four files, because each is consumed by
a different toolchain that cannot read the others:

    content/ingest/build_archive.py                the TIERS dict
    android/app/build.gradle.kts                   the product flavours
    ios/Godstone/Sources/GodstoneCore/Tier.swift   the Tier enum
    docs/packaging/TIERS.md                        the published table

Duplication is the price of not writing a code generator for twelve numbers.
The price of the duplication is this script, run by the constraint audit job
in .github/workflows/build.yml on every push.

A disagreement here is not cosmetic. If Gradle ships a flavour asking for
qwen3-1.7b-q4km.gguf while the archive builder wrote qwen3-0.6b-q4km.gguf, the
app installs, launches, and then cannot find its model on a device that by
definition cannot download the right one (C1). That is a bricked install that
no over-the-air fix can reach.

Exits 0 when every available source agrees, 1 otherwise. Imports nothing
outside the standard library so it can run before pip, and touches no network.
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BUILD_ARCHIVE = ROOT / "content" / "ingest" / "build_archive.py"
GRADLE = ROOT / "android" / "app" / "build.gradle.kts"
TIERS_MD = ROOT / "docs" / "packaging" / "TIERS.md"
TIER_SWIFT = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneCore" / "Tier.swift"

TIERS = ("LIGHT", "MEDIUM", "LARGE")

# Only fields that more than one source actually states are comparable. Gradle
# also carries TOP_K_CHUNKS and the markdown carries install sizes; neither is
# duplicated anywhere else, so neither is checked here.
FIELDS = ("model_file", "db_name", "context_tokens", "embed_dim")


class Findings:
    """Collects errors and warnings so one run reports every problem at once."""

    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, msg: str) -> None:
        self.errors.append(msg)
        print("::error::" + msg, file=sys.stderr)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)
        print("::warning::" + msg, file=sys.stderr)


def read_build_archive(f: Findings) -> dict | None:
    """Pull the TIERS dict out of build_archive.py without importing it.

    Importing would drag in yaml and the embedder, which would make the
    constraint audit depend on pip having run. Parsing the AST and
    literal_eval-ing the assignment keeps this job dependency-free.
    """
    if not BUILD_ARCHIVE.exists():
        f.error("missing " + str(BUILD_ARCHIVE.relative_to(ROOT)))
        return None

    tree = ast.parse(BUILD_ARCHIVE.read_text(encoding="utf-8"))
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if "TIERS" not in names:
            continue
        try:
            raw = ast.literal_eval(node.value)
        except ValueError:
            f.error("TIERS in build_archive.py is not a literal dict")
            return None
        out = {}
        for tier in TIERS:
            if tier not in raw:
                f.error("build_archive.py TIERS has no " + tier + " entry")
                continue
            spec = raw[tier]
            out[tier] = {
                "model_file": spec.get("model_file"),
                "db_name": spec.get("db_name"),
                "context_tokens": spec.get("context_tokens"),
                "embed_dim": spec.get("embed_dim"),
            }
        return out

    f.error("no TIERS assignment found in build_archive.py")
    return None


def read_gradle(f: Findings) -> dict | None:
    """Read the product flavours.

    Rather than trying to parse Kotlin DSL blocks, this walks the file in order
    and attributes each buildConfigField to the most recent TIER declaration.
    That is exactly how the file reads to a human and it survives reformatting.
    """
    if not GRADLE.exists():
        f.error("missing " + str(GRADLE.relative_to(ROOT)))
        return None

    field = re.compile(
        r'buildConfigField\(\s*"(?:String|int)"\s*,\s*"(\w+)"\s*,\s*"(.*?)"\s*\)'
    )

    out: dict = {}
    current: str | None = None

    for line in GRADLE.read_text(encoding="utf-8").splitlines():
        m = field.search(line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        # String fields arrive double-escaped: \"LIGHT\" -> LIGHT
        value = value.replace('\\"', '"').strip('"')

        if key == "TIER":
            current = value.upper()
            out.setdefault(current, {})
        elif current is None:
            continue
        elif key == "MODEL_FILE":
            out[current]["model_file"] = value
        elif key == "ARCHIVE_FILE":
            out[current]["db_name"] = value
        elif key == "CTX_TOKENS":
            out[current]["context_tokens"] = int(value)

    for tier in TIERS:
        if tier not in out:
            f.error("build.gradle.kts has no product flavour for " + tier)

    return out


def read_tiers_md(f: Findings) -> dict | None:
    """Read the two numeric rows of the published markdown table.

    The doc states context window and embedding dims as numbers; model files
    appear only as approximate sizes, so those are not comparable.
    """
    if not TIERS_MD.exists():
        f.error("missing " + str(TIERS_MD.relative_to(ROOT)))
        return None

    wanted = {"context window": "context_tokens", "embedding dims": "embed_dim"}
    out: dict = {t: {} for t in TIERS}

    for line in TIERS_MD.read_text(encoding="utf-8").splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 4:
            continue
        label = cells[0].lower()
        if label not in wanted:
            continue
        for tier, cell in zip(TIERS, cells[1:]):
            m = re.search(r"\d+", cell.replace(",", ""))
            if m:
                out[tier][wanted[label]] = int(m.group(0))

    for tier in TIERS:
        for field in wanted.values():
            if field not in out[tier]:
                f.warn("TIERS.md has no " + field + " for " + tier)

    return out


def read_tier_swift(f: Findings, require: bool) -> dict | None:
    """Check the Swift enum, if it exists yet.

    Tier.swift is referenced by AppContainer.swift (tab 06) but is not emitted
    by any tab, so on a clean checkout it is absent. Treating that as a hard
    failure would make this job red for a reason it was not written to catch,
    which trains people to ignore it. It is a warning by default; pass
    --require-swift once the file lands to make it binding.

    The parse is deliberately loose: it asserts the expected literals are
    present somewhere in the file rather than assuming a particular enum shape.
    """
    if not TIER_SWIFT.exists():
        msg = ("Tier.swift not found at "
               + str(TIER_SWIFT.relative_to(ROOT))
               + " - iOS tier table unverified")
        if require:
            f.error(msg)
        else:
            f.warn(msg)
        return None

    text = TIER_SWIFT.read_text(encoding="utf-8")
    out: dict = {t: {} for t in TIERS}

    for tier in TIERS:
        for pattern, field in (
            (r'"(qwen3-[\w.-]+\.gguf)"', "model_file"),
            (r'"(archive_\w+\.db)"', "db_name"),
        ):
            for value in re.findall(pattern, text):
                if tier.lower() in value.lower() or tier.lower() in value:
                    out[tier][field] = value

    ctx = [int(n) for n in re.findall(r"contextTokens[^0-9]{0,20}(\d{3,5})", text)]
    if len(ctx) == 3:
        for tier, value in zip(TIERS, ctx):
            out[tier]["context_tokens"] = value

    return out


def compare(sources: dict, f: Findings) -> None:
    """Report every field on which two sources that both state it disagree."""
    for tier in TIERS:
        for field in FIELDS:
            stated = {}
            for name, table in sources.items():
                if table and tier in table and table[tier].get(field) is not None:
                    stated[name] = table[tier][field]

            if len(stated) < 2:
                continue

            values = set(stated.values())
            if len(values) == 1:
                continue

            detail = ", ".join(
                name + "=" + repr(value) for name, value in sorted(stated.items())
            )
            f.error(tier + "." + field + " disagrees: " + detail)


def main() -> int:
    parser = argparse.ArgumentParser(description="cross-check Godstone tier tables")
    parser.add_argument(
        "--require-swift",
        action="store_true",
        help="fail if GodstoneCore/Tier.swift is absent instead of warning",
    )
    args = parser.parse_args()

    f = Findings()

    sources = {
        "build_archive.py": read_build_archive(f),
        "build.gradle.kts": read_gradle(f),
        "TIERS.md": read_tiers_md(f),
        "Tier.swift": read_tier_swift(f, args.require_swift),
    }

    compare(sources, f)

    present = [name for name, table in sources.items() if table]
    print("checked " + str(len(present)) + " of 4 sources: " + ", ".join(present))

    for tier in TIERS:
        table = sources["build_archive.py"]
        if not table or tier not in table:
            continue
        spec = table[tier]
        print("  " + tier.ljust(6)
              + " " + str(spec["model_file"]).ljust(24)
              + " " + str(spec["db_name"]).ljust(20)
              + " ctx=" + str(spec["context_tokens"]).ljust(6)
              + " dim=" + str(spec["embed_dim"]))

    if f.errors:
        print("")
        print("FAIL: " + str(len(f.errors)) + " tier disagreement(s)", file=sys.stderr)
        return 1

    if f.warnings:
        print("ok: sources checked agree (" + str(len(f.warnings)) + " warning(s))")
    else:
        print("ok: all four tier tables agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
