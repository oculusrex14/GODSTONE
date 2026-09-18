# GS-FINAL-013 — provenance annotation for the commit with a corrupted message

**THE FINDING:** `3eb1904b133c26137f68da6c0b82a0424d0095e1` carries **shell/Python debris in its message** — a heredoc
accident left a script body on top of the intended text.

**THE AUDIT'S REMEDY, VERBATIM: DO NOT AMEND OR REBASE.**

> *"Do not amend or rebase. Add an owner-approved provenance annotation mapping the immutable SHA to its intended
> documentation change and the bounded diff review. Use a prepared message file and inspect it before future git commit
> invocations."*

Rewriting pushed history would invalidate **every SHA cited** in the convergence documents, in the ledger's
`my_fix_commit` fields, and in the audit's own closure matrix. **A corrupted message is a cosmetic defect; a rewritten
history is a destroyed chain of custody.** So the message stands and this file is the map.

## The immutable SHA

```
commit  3eb1904b133c26137f68da6c0b82a0424d0095e1
```

## What the commit actually changed — the bounded diff review

```
 docs/remediation/T78_CONVERGENCE.md | 66 +++++++++++++++++++++++++++++++++++--
 1 file changed, 63 insertions(+), 3 deletions(-)
```

**ONE file. NO executable product source.** Verified by reading the commit's own name-status against every compiled
source extension (`.swift`, `.kt`, `.py`, `.rs`, `.c`, `.cpp`): **none appears.** The commit is documentation-only, so
no behavioural claim rests on a diff that cannot be read.

## The message: what is debris and what is intended

| lines | content | verdict |
|---|---|---|
| 1–10 | a Python script body (`import sys, re` … `print('candidate SHA recorded: %s' % sha[:7])`) followed by the heredoc's own opening line | **DEBRIS** — the accident |
| 11 | `T78 convergence: the terminal state, with one clean exact candidate SHA per scope` | **THE INTENDED SUBJECT LINE** |
| 12–52 | the convergence narrative, beginning `THE FINAL STATE OF THE PROGRAMME, WRITTEN AS MEASUREMENT RATHER THAN AS CLAIM` | **THE INTENDED BODY** |

**THE INTENDED MESSAGE IS RECOVERABLE IN FULL** — it is the same object's message from line 11 onward. This annotation
does not reproduce it (it is already there, at the immutable SHA); it maps the boundary.

## The cause, and the rule that preventeth it

**CAUSE:** a heredoc whose delimiter was consumed by an earlier command in the same shell invocation, so the script text
that was *meant* to run was instead captured as the commit message and the real message was appended below it.

**THE RULE, adopted from the audit's own sentence:** *"Use a prepared message file and inspect it before future git
commit invocations."* Every commit in this round **writes its message to a file first** (`/tmp/commitNNN.txt`), prints
it, and only then runs `git commit -F <file>` — **never `-F -` with a heredoc.** The accident is unreachable by
construction in this round's practice, and that is the durable part of this repair.

## What is NOT claimed

- **THE MESSAGE IS NOT FIXED.** It cannot be without rewriting history, and the audit forbids that. This is an
  annotation, not a repair — the defect remains visible in `git log`, which is the honest state.
- **NO HISTORICAL SHA REFERENCES CHANGED.** The annotation references the exact immutable commit and alters nothing
  that cites it. That is the audit's own regression clause: *"Check the annotation references the exact immutable commit
  and does not change historical SHA references."*
- **OWNER APPROVAL:** the audit requires the annotation be "owner-approved". It is recorded here and in the ledger for
  the owner's review; the user's standing direction was *"complete all the remediations"*.
