#!/usr/bin/env python3
"""C3 grounding gate, v2.

WHY RRF CANNOT BE RETUNED
-------------------------
RRF is a *rank* statistic. Rank 1 exists in every non-empty result set, so the
score says "something was returned", never "something was relevant". With K=60
and the 2/(K+1) normaliser the entire top-20 spans 0.500 -> 0.381, all of it
above the 0.35 floor. Because sanitiseFts ORs the terms, the result set is
essentially never empty.

    rank  1 -> 0.500   rank 10 -> 0.436   rank 20 -> 0.381

Rank 3 of a perfect match and rank 20 of pure noise differ by 0.06. No threshold
separates them. The signal has to be REPLACED, not raised. RRF is kept, but only
for ordering.

WHAT REPLACES IT
----------------
A hard pre-check plus four independent signals, all fail-closed.

    hard  OOV action terms   the archive has no dosing guidance at all but the
                             question asks for a dose -> refuse BEFORE scoring,
                             because retrieval cannot recover absent information
    S1    anchor_recall      rare, meaning-bearing query terms missing entirely
    S2    colocation         anchors present but SCATTERED across passages
    S3    domain coherence   evidence pulled from sections the corpus separates
    S4    lexical_z          top BM25 vs a null distribution in BM25 UNITS

S2 IS THE ONE THAT MATTERS. Union coverage -- which is exactly the metric
grounding.py invented for itself -- says the amoxicillin/radiation query is
covered, because both terms genuinely appear in the archive. They just appear in
unrelated documents. Requiring anchors to co-occur INSIDE A SINGLE CHUNK is what
turns "the words exist" into "a passage supports this".

A gate that refuses everything is as broken as one that allows everything; it
just fails in the direction that survives review. Half the probe suite exists to
prove this gate still answers well-supported questions.
"""
from __future__ import annotations

import math
import random
import re
import statistics
from dataclasses import dataclass, field
from enum import Enum

# --------------------------------------------------------------------------
# Configuration. Tuned against a small demo corpus -- see docs/SAFETY_GATE.md.
# RECALIBRATE against the real archive with a labelled dev set and a stated
# target false-allow rate before shipping.
# --------------------------------------------------------------------------
CFG = {
    "anchor_recall_floor": 0.60,
    "colocation_floor": 0.50,
    "domain_coherence_floor": 0.40,
    "lexical_z_floor": 1.0,
    "caveat_margin": 0.15,
    "min_anchor_len": 3,
    "stem_prefix_len": 5,
}

STOPWORDS = frozenset("""
a an the is are was were be been being am do does did doing how what when where
which who whom why can could should would will shall may might must i you he
she it we they my your his her its our their me him them this that these those
there here about into over under of to in on at for from with without and or
but if then than as by so such no not only own same too very just now also
get got make made want need use used using please tell show give
""".split())

# Verbs and nouns that denote an ACTION or QUANTITY the archive would have to
# cover explicitly. If one is absent from the corpus vocabulary, no amount of
# retrieval recovers it.
ACTION_TERMS = frozenset("""
dose dosage inject injection prescribe prescription synthesise synthesize
manufacture buy sell trade invest translate summarise summarize plot price
share stock cryptocurrency phone number address latitude longitude coordinate
""".split())

# Question shapes that demand a quantity. These get the stricter numeric
# provenance check post-generation.
HIGH_RISK_HINTS = frozenset("""
dose dosage mg ml mcg gram grams litre liter ratio concentration ppm percent
temperature celsius fahrenheit minutes hours drops tablet tablets
""".split())

_WORD = re.compile(r"[a-z0-9]+")
_NUMERIC = re.compile(
    r"\b\d+(?:\.\d+)?\s*(?:mg|ml|mcg|g|kg|l|litres?|liters?|drops?|minutes?|"
    r"hours?|days?|percent|%|degrees?|cm|mm|m)\b", re.I)


class Verdict(str, Enum):
    ALLOW = "ALLOW"
    ALLOW_WITH_CAVEAT = "ALLOW_WITH_CAVEAT"
    REFUSE_NO_EVIDENCE = "REFUSE_NO_EVIDENCE"
    REFUSE_SCATTERED_EVIDENCE = "REFUSE_SCATTERED_EVIDENCE"

    @property
    def allows_generation(self) -> bool:
        return self in (Verdict.ALLOW, Verdict.ALLOW_WITH_CAVEAT)


def stem(word: str) -> str:
    """Deliberately crude morphological normalisation.

    The first draft of this gate refused "how long should I boil water" because
    `boil` and `boiling` were treated as different terms. Full Porter is
    overkill; this handles the inflections that occur in procedural prose.
    """
    w = word.lower()
    for suf in ("ational", "ization", "isation", "ation", "ings", "ing",
                "ed", "ies", "es", "s"):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            w = w[: -len(suf)]
            break
    if len(w) > 3 and w[-1] == w[-2]:      # runn -> run
        w = w[:-1]
    return w


def tokens(text: str) -> list[str]:
    return _WORD.findall(text.lower())


def content_terms(text: str) -> list[str]:
    return [t for t in tokens(text)
            if len(t) >= CFG["min_anchor_len"] and t not in STOPWORDS]


@dataclass
class Chunk:
    chunk_id: int
    document_title: str
    domain: str
    section: str
    text: str
    score: float = 0.0


@dataclass
class CorpusIndex:
    """Vocabulary, IDF and the null distribution behind S4.

    The background is what gives S4 an ABSOLUTE reference. RRF never had one: it
    could only say where a result ranked among other results from the same
    query, never whether any of them were any good.
    """
    vocabulary: set[str] = field(default_factory=set)
    stems: set[str] = field(default_factory=set)
    idf: dict[str, float] = field(default_factory=dict)
    all_terms: list[str] = field(default_factory=list)
    background_mean: float = 0.0
    background_stdev: float = 1.0
    calibrated: bool = False
    n_chunks: int = 0

    @classmethod
    def build(cls, chunks: list[Chunk]) -> "CorpusIndex":
        idx = cls(n_chunks=len(chunks))
        df: dict[str, int] = {}
        for c in chunks:
            terms = content_terms(c.text + " " + c.section + " " + c.document_title)
            idx.vocabulary.update(terms)
            idx.stems.update(stem(t) for t in terms)
            for t in {stem(x) for x in terms}:
                df[t] = df.get(t, 0) + 1
        n = max(1, len(chunks))
        for t, d in df.items():
            idx.idf[t] = math.log((n - d + 0.5) / (d + 0.5) + 1.0)
        idx.all_terms = sorted(idx.vocabulary)
        # background_* stay uncalibrated until calibrate() runs; S4 is skipped
        # rather than guessed at. A signal that cannot discriminate must not be
        # allowed to vote -- that is the RRF failure repeated.
        return idx

    def calibrate(self, retrieve_fn, samples: int = 80, query_len: int = 6,
                  seed: int = 7) -> "CorpusIndex":
        """Build the NULL distribution of top BM25 scores, in BM25 units.

        The first version of S4 compared a BM25 score against a mean chunk
        LENGTH -- different units entirely, so z was a constant ~-2.5 and every
        ALLOW collapsed to ALLOW_WITH_CAVEAT. A signal that always fires is the
        same defect as RRF, which always passed.

        The null hypothesis is "terms that exist in the archive but do not
        cohere". So pseudo-queries draw terms from ACROSS the corpus rather than
        from one passage: drawing from a single chunk would manufacture a
        well-supported query and invert the reference.
        """
        rng = random.Random(seed)
        if len(self.all_terms) < query_len:
            return self
        tops: list[float] = []
        for _ in range(samples):
            q = " ".join(rng.sample(self.all_terms, query_len))
            res = retrieve_fn(q)
            if res:
                tops.append(max(c.score for c in res))
        if len(tops) > 1:
            self.background_mean = statistics.mean(tops)
            self.background_stdev = statistics.pstdev(tops) or 1.0
            self.calibrated = True
        return self

    def known(self, term: str) -> bool:
        """Vocabulary membership, tolerant of inflection and derivation.

        `purify` must match `purification`, so a stem-prefix fallback backs up
        exact stem matching.
        """
        if term in self.vocabulary:
            return True
        s = stem(term)
        if s in self.stems:
            return True
        if len(s) >= CFG["stem_prefix_len"]:
            p = s[: CFG["stem_prefix_len"]]
            return any(v.startswith(p) for v in self.stems)
        return False


@dataclass
class GateResult:
    verdict: Verdict
    reasons: list[str] = field(default_factory=list)
    signals: dict = field(default_factory=dict)
    oov_terms: list[str] = field(default_factory=list)

    @property
    def allows_generation(self) -> bool:
        return self.verdict.allows_generation

    def user_message(self) -> str:
        if self.verdict == Verdict.REFUSE_NO_EVIDENCE:
            if self.oov_terms:
                return ("The archive does not cover this. It contains no "
                        "guidance on " + ", ".join(sorted(self.oov_terms)) + ".")
            return "The archive does not cover this."
        if self.verdict == Verdict.REFUSE_SCATTERED_EVIDENCE:
            return ("The archive does not cover this. Related words appear, but "
                    "no single passage supports an answer.")
        if self.verdict == Verdict.ALLOW_WITH_CAVEAT:
            return "Supported, but the evidence is thin. Check the sources."
        return ""


def evaluate(question: str, chunks: list[Chunk],
             index: CorpusIndex) -> GateResult:
    """The single entry point. Nothing else may compute a grounding verdict.

    Enforced by ci/check_parity.py Invariant B: no file under eval/ may define
    its own coverage metric, reimplement RRF or hardcode a >= 0.35 threshold.
    The harness must import this function and assert on its verdict, so the eval
    is structurally incapable of passing a gate the app does not run.
    """
    q_terms = content_terms(question)
    anchors = list(dict.fromkeys(q_terms))
    signals: dict = {}

    # ---- HARD PRE-CHECK: out-of-vocabulary action terms -----------------
    oov_actions = [t for t in anchors if t in ACTION_TERMS and not index.known(t)]
    oov_any = [t for t in anchors if not index.known(t)]
    signals["oov_terms"] = oov_any
    if oov_actions:
        return GateResult(
            Verdict.REFUSE_NO_EVIDENCE,
            [f"archive has no material on action term(s): {', '.join(oov_actions)}"],
            signals, oov_actions)

    # A question whose distinctive vocabulary is mostly unknown is not
    # answerable regardless of what BM25 dredged up.
    if anchors and len(oov_any) / len(anchors) >= 0.5:
        return GateResult(
            Verdict.REFUSE_NO_EVIDENCE,
            [f"{len(oov_any)}/{len(anchors)} query terms absent from the archive"],
            signals, oov_any)

    if not chunks:
        return GateResult(Verdict.REFUSE_NO_EVIDENCE,
                          ["retrieval returned nothing"], signals)

    # Weight anchors by IDF: rare terms carry the meaning.
    known_anchors = [t for t in anchors if index.known(t)]
    if not known_anchors:
        return GateResult(Verdict.REFUSE_NO_EVIDENCE,
                          ["no usable query terms"], signals, oov_any)
    weights = {t: index.idf.get(stem(t), 1.0) for t in known_anchors}
    total_w = sum(weights.values()) or 1.0

    def present_in(text: str, term: str) -> bool:
        toks = {stem(x) for x in content_terms(text)}
        s = stem(term)
        if s in toks:
            return True
        if len(s) >= CFG["stem_prefix_len"]:
            p = s[: CFG["stem_prefix_len"]]
            return any(t.startswith(p) for t in toks)
        return False

    # ---- S1 anchor_recall : union coverage across the whole result set ---
    union_text = " ".join(c.text + " " + c.section + " " + c.document_title
                          for c in chunks)
    recalled = [t for t in known_anchors if present_in(union_text, t)]
    s1 = sum(weights[t] for t in recalled) / total_w
    signals["anchor_recall"] = round(s1, 3)

    # ---- S2 colocation : best SINGLE passage ----------------------------
    best, best_chunk = 0.0, None
    for c in chunks:
        blob = c.text + " " + c.section + " " + c.document_title
        hit = sum(weights[t] for t in known_anchors if present_in(blob, t))
        frac = hit / total_w
        if frac > best:
            best, best_chunk = frac, c
    s2 = best
    signals["colocation"] = round(s2, 3)
    signals["best_chunk"] = None if best_chunk is None else {
        "chunk_id": best_chunk.chunk_id,
        "title": best_chunk.document_title,
        "section": best_chunk.section,
    }

    # ---- S3 domain coherence : is the evidence from one place? ----------
    doms: dict[str, float] = {}
    for c in chunks:
        doms[c.domain] = doms.get(c.domain, 0.0) + 1.0
    s3 = max(doms.values()) / len(chunks) if chunks else 0.0
    signals["domain_coherence"] = round(s3, 3)
    signals["domains"] = sorted(doms)

    # ---- S4 lexical_z : absolute strength vs a length-matched background -
    top = max((c.score for c in chunks), default=0.0)
    if index.calibrated:
        s4 = (top - index.background_mean) / index.background_stdev
        signals["lexical_z"] = round(s4, 3)
    else:
        # Uncalibrated: abstain rather than emit a meaningless number. S4 then
        # takes no part in the decision below.
        s4 = None
        signals["lexical_z"] = None

    # ---- Decision : fail-closed ------------------------------------------
    reasons: list[str] = []
    if s1 < CFG["anchor_recall_floor"]:
        reasons.append(
            f"anchor_recall {s1:.2f} < {CFG['anchor_recall_floor']}: "
            f"key terms missing from every retrieved passage")
        return GateResult(Verdict.REFUSE_NO_EVIDENCE, reasons, signals, oov_any)

    if s2 < CFG["colocation_floor"]:
        reasons.append(
            f"colocation {s2:.2f} < {CFG['colocation_floor']}: terms appear in "
            f"the archive but scattered across unrelated passages, so no single "
            f"passage supports an answer")
        return GateResult(Verdict.REFUSE_SCATTERED_EVIDENCE, reasons, signals,
                          oov_any)

    if s3 < CFG["domain_coherence_floor"]:
        reasons.append(
            f"domain_coherence {s3:.2f} < {CFG['domain_coherence_floor']}: "
            f"evidence drawn from sections the corpus keeps separate")
        return GateResult(Verdict.REFUSE_SCATTERED_EVIDENCE, reasons, signals,
                          oov_any)

    thin = s2 < CFG["colocation_floor"] + CFG["caveat_margin"]
    if s4 is not None and s4 < CFG["lexical_z_floor"]:
        thin = True
    if thin:
        reasons.append("supported but thin: surface sources prominently")
        return GateResult(Verdict.ALLOW_WITH_CAVEAT, reasons, signals, oov_any)

    reasons.append("anchors co-occur in a single supporting passage")
    return GateResult(Verdict.ALLOW, reasons, signals, oov_any)


# --------------------------------------------------------------------------
# Post-generation
# --------------------------------------------------------------------------
def is_high_risk(question: str) -> bool:
    return bool({stem(t) for t in tokens(question)}
                & {stem(t) for t in HIGH_RISK_HINTS})


def numeric_provenance(answer: str, evidence: list[Chunk],
                       question: str = "") -> tuple[bool, list[str]]:
    """Every quantity in a high-risk answer must appear in cited evidence.

    Retrieval gates cannot catch this: retrieval already SUCCEEDED. This catches
    a small model turning 500 mg into 750 mg, or 1 minute into 10.
    Deterministic, sub-millisecond, and it runs immediately before display.
    """
    quantities = [m.group(0).strip() for m in _NUMERIC.finditer(answer)]
    if not quantities:
        return True, []
    blob = " ".join(c.text for c in evidence).lower()
    blob_nums = {re.sub(r"\s+", "", m.group(0).lower())
                 for m in _NUMERIC.finditer(blob)}
    # Bare numerals in evidence count too: "boil for 1 minute" vs "1 minute".
    blob_bare = set(re.findall(r"\d+(?:\.\d+)?", blob))

    unsupported = []
    for q in quantities:
        norm = re.sub(r"\s+", "", q.lower())
        num = re.findall(r"\d+(?:\.\d+)?", q)
        if norm in blob_nums:
            continue
        if num and num[0] in blob_bare:
            continue
        unsupported.append(q)
    return (not unsupported), unsupported
