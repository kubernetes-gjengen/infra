---
name: technical-documentation
description: >
  Write or clean up technical documentation (README.md, docs/ trees, API
  references, troubleshooting guides, architecture notes) using principles from
  aerospace documentation standards: controlled language (ASD-STE100), stable
  placement (ATA 100) and typed, self-contained modules (S1000D). Use when the
  user asks for documentation, a README or docs, or says "dokumenter dette",
  "skriv om denne READMEen", "skriv dokumentasjon", "document this", "write
  documentation", or when a documentation file needs review for clarity and
  structure.
---

# Technical documentation

Three principles, taken from standards that exist because ambiguous
documentation hurt people.
They solve the same problems in software.

1. **Controlled language.**
   One term per concept, short sentences, active imperative.
   The reader must never wonder whether two words mean the same thing.
2. **Stable placement.**
   The same information sits in the same place in every repo.
   The reader must know where something is before searching for it.
3. **Typed modules.**
   Each section answers one kind of question and stands on its own.
   Never mix explanation, procedure and reference in one block.

If you remember only one rule: **never mix information types in one module.**
That single mistake makes more documentation unreadable than anything else.

## Workflow

### 1. Decide the information type before writing

| Type | Answers | Form |
| --- | --- | --- |
| Concept | What is this, why does it exist | Prose. No steps. |
| Procedure | How do I do X | Prerequisites, numbered steps, verification |
| Reference | What are the exact values | Tables. Exhaustive. No prose. |
| Troubleshooting | It does not work | Symptom, cause, fix |

If the text answers two of these, it is two modules.

### 2. Place it predictably

For `README.md`: use the canonical section order.
Skip sections that do not apply, but **never reorder them**.
The order is what makes placement predictable.

For larger documentation: numbered directories under `docs/`, identical in every repo.

Both are described in `references/structure.md`, with templates.

### 3. Follow the language rules

The short version. Full list with examples in `references/language.md`:

- One term per concept. Never synonyms.
  Alternating between "flag", "option" and "switch" gives the reader three
  things to track instead of one.
- Maximum 20 words per sentence in procedures, 25 in descriptions.
- Maximum 6 sentences per paragraph.
- One instruction per step.
- Active imperative in procedures: "Run `make build`", not "The build can be run".
- Present tense. No "will", no conditional.
- Warnings go **before** the step they apply to, phrased as a command.
- Keep the articles. "Delete the file", not "Delete file".

### 4. Check against the list before finishing

- [ ] Every module has one information type
- [ ] Sections are in canonical order
- [ ] Every concept has exactly one name throughout the document
- [ ] No sentence exceeds 25 words
- [ ] Every procedure has a verification step: how does the reader know it worked
- [ ] Every command is copy-pasteable as written, with no editing
- [ ] Nothing is documented that the code already states clearly

## Limits

**Do not document what can be read from the code.**
Directory trees, dependency lists and function signatures go stale and then have
negative value.
Document what is not obvious: why something is the way it is, what goes wrong,
and which assumptions hold.

**Do not rewrite for the sake of rewriting.**
When improving existing documentation, rank the findings: mixed information
types and wrong commands first, language polish last.

**Language.**
The rules apply to both English and Norwegian.
The ASD-STE100 word list is English-specific, but the principle (one term per
concept, short sentences, active imperative) is language independent.
