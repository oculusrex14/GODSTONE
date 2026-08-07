#!/usr/bin/env python3
"""Verify that every place Godstone writes down its tier table agrees with the
canonical config/tiers.json -- the SINGLE SOURCE OF TRUTH for the tier invariant
(check_parity Invariant E).

The tier numbers are duplicated across four files, because each is consumed by
a different toolchain that cannot read the others:

    config/tiers.json                              the canonical table (source of truth)
    content/ingest/build_archive.py                the TIERS dict (builds archives for every tier)
    android/app/build.gradle.kts                   the product flavours (SHIPS the shipping tiers)
    ios/Godstone/Sources/GodstoneCore/Tier.swift   the Tier enum (models every tier)
    docs/packaging/TIERS.md                        the published table

RESEARCH vs SHIPPING. config/tiers.json marks each tier `shipping: true|false`.
A shipping tier may be declared as an Android product flavour and installed by a
store build; a research-only tier (MEDIUM, LARGE today) is built (its archive is
producible) and modelled in the enum / docs, but has no store-compatible asset
delivery design and MUST NOT ship as a product flavour. This is the executable
form of the "LIGHT-only shipping" contract -- it lives in tiers.json and is
enforced here, not in a comment.

So the rules are:

  build_archive.py  must declare every canonical tier; comparable fields match.
  Tier.swift        must declare every canonical tier; comparable fields match.
  TIERS.md          comparable fields (context_tokens, embed_dim) match for every tier.
  build.gradle.kts  must declare EXACTLY the shipping tiers; each matches. Declaring a
                    non-shipping tier is a shipping-truth violation (a brickable install
                    no over-the-air fix can reach). Omitting a shipping tier is a drift error.

A disagreement here is not cosmetic. If Gradle ships a flavour asking for
qwen3-1.7b-q4km.gguf while the archive builder wrote qwen3-0.6b-q4km.gguf, the
app installs, launches, and then cannot find its model on a device that by
definition cannot download the right one (C1). If Gradle ships a research-only
tier, it ships a build with no asset delivery design. Both are caught here.

Exits 0 when every available source agrees with config/tiers.json, 1 otherwise.
Imports nothing outside the standard library so it can run before pip, and
touches no network.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

TIERS_JSON = ROOT / "config" / "tiers.json"
BUILD_ARCHIVE = ROOT / "content" / "ingest" / "build_archive.py"
GRADLE = ROOT / "android" / "app" / "build.gradle.kts"
TIERS_MD = ROOT / "docs" / "packaging" / "TIERS.md"
TIER_SWIFT = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneCore" / "Tier.swift"

# Only fields that more than one source actually states are comparable. Gradle
# also carries TOP_K_CHUNKS and the markdown carries install sizes; neither is
# duplicated in tiers.json, so neither is checked here.
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


def load_canonical(f: Findings) -> dict | None:
    """Load config/tiers.json -- the canonical tier table."""
    if not TIERS_JSON.exists():
        f.error("missing " + str(TIERS_JSON.relative_to(ROOT)))
        return None
    try:
        data = json.loads(TIERS_JSON.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        f.error(f"config/tiers.json is not valid JSON: {exc}")
        return None
    tiers = data.get("tiers")
    if not isinstance(tiers, dict) or not tiers:
        f.error("config/tiers.json has no 'tiers' object")
        return None
    return tiers


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
        for tier, spec in raw.items():
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
        elif key == "EMBED_DIM":
            out[current]["embed_dim"] = int(value)

    return out


def read_tiers_md(f: Findings) -> dict | None:
    """Read the two numeric rows of the published markdown table.

    The doc states context window and embedding dims as numbers; model files
    appear only as approximate sizes, so those are not comparable. The table
    header row defines the tier column order, so numeric rows attribute to the
    right tier regardless of column reordering.
    """
    if not TIERS_MD.exists():
        f.error("missing " + str(TIERS_MD.relative_to(ROOT)))
        return None

    wanted = {"context window": "context_tokens", "embedding dims": "embed_dim"}
    out: dict = {}
    tier_order: list[str] = []

    for line in TIERS_MD.read_text(encoding="utf-8").splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 4:
            continue
        label = cells[0].lower()
        if not tier_order:
            # First 4-cell row is the header: | | LIGHT | MEDIUM | LARGE |
            if label == "":
                tier_order = [c.upper() for c in cells[1:]]
                out = {t: {} for t in tier_order}
            continue
        if label not in wanted:
            continue
        for tier, cell in zip(tier_order, cells[1:]):
            m = re.search(r"\d+", cell.replace(",", ""))
            if m:
                out[tier][wanted[label]] = int(m.group(0))

    return out


def read_tier_swift(f: Findings, require: bool) -> dict | None:
    """Check the Swift enum, if it exists yet.

    Tier.swift is referenced by AppContainer.swift (tab 06) but is not emitted
    by any tab, so on a clean checkout it may be absent. Treating that as a hard
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
    out = {t: {} for t in ("LIGHT", "MEDIUM", "LARGE")}

    for tier in ("LIGHT", "MEDIUM", "LARGE"):
        for pattern, field in (
            (r'"(qwen3-[\w.-]+\.gguf)"', "model_file"),
            (r'"(archive_\w+\.db)"', "db_name"),
        ):
            for value in re.findall(pattern, text):
                if tier.lower() in value.lower() or tier.lower() in value:
                    out[tier][field] = value

    # Parse the switch bodies directly; the tuple regex above is intentionally
    # not used as data because Swift contains several three-case integer switches.
    for property_name, field in (("contextTokens", "context_tokens"), ("embedDim", "embed_dim")):
        m = re.search(rf"var {property_name}: Int \{{(.*?)\n    \}}", text, re.S)
        if not m:
            continue
        body = m.group(1)
        patterns = {
            "LIGHT": r"case \.light(?:, \.medium)?:\s*return (\d+)",
            "MEDIUM": r"case \.medium:\s*return (\d+)",
            "LARGE": r"case \.large:\s*return (\d+)",
        }
        # Combined light/medium case is valid for embedDim.
        combined = re.search(r"case \.light, \.medium:\s*return (\d+)", body)
        if combined:
            out["LIGHT"][field] = int(combined.group(1))
            out["MEDIUM"][field] = int(combined.group(1))
        for tier, pattern in patterns.items():
            found = re.search(pattern, body)
            if found:
                out[tier][field] = int(found.group(1))

    return out


def _check_fields(name: str, stated: dict, canonical_spec: dict, tier: str,
                  f: Findings, fields: tuple = FIELDS) -> None:
    """Error on any comparable field [name] states for [tier] that disagrees
    with the canonical spec."""
    for field in fields:
        if field in stated and stated[field] is not None:
            if stated[field] != canonical_spec.get(field):
                f.error(
                    f"{name}.{tier}.{field} disagrees: "
                    f"{name}={stated[field]!r} tiers.json={canonical_spec.get(field)!r}"
                )


def compare(canonical: dict, sources: dict, f: Findings) -> None:
    """Validate each derived source against config/tiers.json."""
    shipping = {t for t, spec in canonical.items() if spec.get("shipping") is True}

    # build_archive.py: must declare every canonical tier; fields match.
    ba = sources.get("build_archive.py")
    if ba is not None:
        for tier, spec in canonical.items():
            if tier not in ba:
                f.error(f"build_archive.py TIERS has no {tier} entry")
                continue
            _check_fields("build_archive.py", ba[tier], spec, tier, f)

    # Tier.swift: must declare every canonical tier; fields match.
    ts = sources.get("Tier.swift")
    if ts is not None:
        for tier, spec in canonical.items():
            if tier not in ts or not ts[tier]:
                f.error(f"Tier.swift has no {tier} case values")
                continue
            _check_fields("Tier.swift", ts[tier], spec, tier, f)

    # TIERS.md: comparable numeric fields match for every tier.
    md = sources.get("TIERS.md")
    if md is not None:
        md_fields = ("context_tokens", "embed_dim")
        for tier, spec in canonical.items():
            if tier not in md:
                f.warn(f"TIERS.md has no {tier} column")
                continue
            _check_fields("TIERS.md", md[tier], spec, tier, f, fields=md_fields)

    # build.gradle.kts: must declare EXACTLY the shipping tiers; fields match.
    gr = sources.get("build.gradle.kts")
    if gr is not None:
        declared = set(gr)
        for tier in shipping:
            if tier not in gr:
                f.error(f"build.gradle.kts omits shipping tier {tier} "
                        f"(tiers.json says it ships)")
                continue
            _check_fields("build.gradle.kts", gr[tier], canonical[tier], tier, f)
        for tier in declared - shipping:
            f.error(f"build.gradle.kts declares {tier} as a product flavour but "
                    f"tiers.json marks it shipping=false -- a research-only tier "
                    f"must not ship (brickable install, no OTA fix)")


def main() -> int:
    parser = argparse.ArgumentParser(description="cross-check Godstone tier tables against config/tiers.json")
    parser.add_argument(
        "--require-swift",
        action="store_true",
        help="fail if GodstoneCore/Tier.swift is absent instead of warning",
    )
    args = parser.parse_args()

    f = Findings()

    canonical = load_canonical(f)
    if canonical is None:
        print("FAIL: could not load config/tiers.json", file=sys.stderr)
        return 1

    sources = {
        "build_archive.py": read_build_archive(f),
        "build.gradle.kts": read_gradle(f),
        "TIERS.md": read_tiers_md(f),
        "Tier.swift": read_tier_swift(f, args.require_swift),
    }

    compare(canonical, sources, f)

    present = [name for name, table in sources.items() if table]
    print("checked " + str(len(present)) + " of 4 derived sources against config/tiers.json: "
          + ", ".join(present))

    for tier, spec in canonical.items():
        flag = "shipping" if spec.get("shipping") else "research"
        print("  " + tier.ljust(6)
              + " " + str(spec["model_file"]).ljust(24)
              + " " + str(spec["db_name"]).ljust(20)
              + " ctx=" + str(spec["context_tokens"]).ljust(6)
              + " dim=" + str(spec["embed_dim"]).ljust(5)
              + " [" + flag + "]")

    if f.errors:
        print("")
        print("FAIL: " + str(len(f.errors)) + " tier disagreement(s)", file=sys.stderr)
        return 1

    if f.warnings:
        print("ok: derived sources agree with config/tiers.json ("
              + str(len(f.warnings)) + " warning(s))")
    else:
        print("ok: all four derived tier tables agree with config/tiers.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())