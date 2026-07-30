"""Heading-aware chunker.

Fixed-size sliding windows are the usual approach and they are wrong here. A
window that splits 'apply the tourniquet 5-7 cm above the wound' from 'never
over a joint' produces a retrievable passage that is actively dangerous. So the
chunker respects document structure first and only falls back to splitting
inside a section when a section is genuinely too long.

Rules, in priority order:

  1. Never merge across a heading. A chunk belongs to exactly one section.
  2. Never split a numbered or bulleted list. Procedures are lists; half a
     procedure is worse than no procedure.
  3. Never split a fenced code or dosage block.
  4. Only then, pack paragraphs up to max_tokens with overlap between chunks.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# Token estimate. The real tokenizer lives in the GGUF model and calling it per
# paragraph would make the build minutes slower for an accuracy that does not
# change the outcome; 4 characters per token is close enough for budgeting and
# is deliberately conservative.
CHARS_PER_TOKEN = 4

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
LIST_ITEM_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
FENCE_RE = re.compile(r"^\s*```")


@dataclass
class Chunk:
    section: str
    text: str
    token_count: int
    chunk_id: int = 0
    document_id: int = 0


@dataclass
class Block:
    """A paragraph, list or code fence - the smallest unit never split."""
    section: str
    text: str
    atomic: bool = False
    tokens: int = field(default=0)

    def __post_init__(self) -> None:
        self.tokens = estimate_tokens(self.text)


def estimate_tokens(text: str) -> int:
    return max(1, len(text) // CHARS_PER_TOKEN)


def split_blocks(body: str) -> list[Block]:
    """Walk the markdown once, tracking the heading path as we go."""
    blocks: list[Block] = []
    heading_stack: list[str] = []
    buffer: list[str] = []
    in_fence = False
    in_list = False

    def section_path() -> str:
        return " > ".join(heading_stack) if heading_stack else "Introduction"

    def flush(atomic: bool = False) -> None:
        nonlocal buffer
        text = "\n".join(buffer).strip()
        if text:
            blocks.append(Block(section=section_path(), text=text, atomic=atomic))
        buffer = []

    for line in body.splitlines():
        if FENCE_RE.match(line):
            if in_fence:
                buffer.append(line)
                flush(atomic=True)
                in_fence = False
            else:
                flush(atomic=in_list)
                in_list = False
                buffer.append(line)
                in_fence = True
            continue

        if in_fence:
            buffer.append(line)
            continue

        m = HEADING_RE.match(line)
        if m:
            flush(atomic=in_list)
            in_list = False
            depth = len(m.group(1))
            title = m.group(2).strip()
            del heading_stack[depth - 1:]
            heading_stack.append(title)
            continue

        if LIST_ITEM_RE.match(line):
            if not in_list:
                flush()
                in_list = True
            buffer.append(line)
            continue

        if not line.strip():
            # Blank line ends a paragraph, but not a list: lists routinely have
            # blank lines between items and must survive intact.
            if not in_list:
                flush()
            else:
                buffer.append(line)
            continue

        if in_list and line.startswith(("  ", "\t")):
            buffer.append(line)          # continuation of the previous item
            continue

        if in_list:
            flush(atomic=True)
            in_list = False

        buffer.append(line)

    flush(atomic=in_list or in_fence)
    return blocks


def chunk_document(body: str, max_tokens: int = 320,
                   overlap_tokens: int = 48) -> list[Chunk]:
    blocks = split_blocks(body)
    chunks: list[Chunk] = []

    current: list[Block] = []
    current_tokens = 0
    current_section: str | None = None

    def emit() -> None:
        nonlocal current, current_tokens
        if not current:
            return
        text = "\n\n".join(b.text for b in current).strip()
        chunks.append(Chunk(section=current[0].section,
                            text=text,
                            token_count=estimate_tokens(text)))
        current = []
        current_tokens = 0

    for block in blocks:
        # Rule 1: a heading change always closes the chunk.
        if current_section is not None and block.section != current_section:
            emit()
        current_section = block.section

        # Rules 2 and 3: an oversized atomic block is emitted whole. A 600 token
        # procedure exceeding the budget is correct and retrievable; the same
        # procedure cut in half is neither.
        if block.atomic and block.tokens > max_tokens:
            emit()
            chunks.append(Chunk(section=block.section, text=block.text,
                                token_count=block.tokens))
            continue

        if current_tokens + block.tokens > max_tokens and current:
            tail = carry_overlap(current, overlap_tokens)
            emit()
            current = list(tail)
            current_tokens = sum(b.tokens for b in current)

        current.append(block)
        current_tokens += block.tokens

    emit()
    return [c for c in chunks if c.text.strip()]


def carry_overlap(blocks: list[Block], overlap_tokens: int) -> list[Block]:
    """Trailing blocks to repeat at the head of the next chunk.

    Overlap is by whole blocks, never by a token window, so a repeated fragment
    is always a complete sentence or list item. Atomic blocks are never carried:
    duplicating an entire procedure would let the same instruction be cited
    twice with two different chunk ids.
    """
    out: list[Block] = []
    total = 0
    for block in reversed(blocks):
        if block.atomic:
            break
        if total + block.tokens > overlap_tokens:
            break
        out.insert(0, block)
        total += block.tokens
    return out
