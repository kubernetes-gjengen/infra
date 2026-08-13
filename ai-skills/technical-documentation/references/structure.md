# Structure: stable placement and typed modules

## Background: why stable placement works

In ATA 100, chapter 32 is always the landing gear.
Any manufacturer, any aircraft type, any year.
A technician who needs landing gear information opens chapter 32 without
searching, without reading a table of contents, and without learning a new
system for each aircraft type.

The value is not in the number. It is that *the address is stable*.
Applied to software: if `docs/40-reference/` means the same thing in all your
repos, you stop searching.

This is the same principle as numbered folders in an Obsidian vault, or
`src/`, `tests/`, `docs/` in any project, taken further.

## Canonical README order

Skip what does not apply. Never reorder.

| # | Section | Information type | Content |
| --- | --- | --- | --- |
| 1 | Name and one sentence | Concept | What this is, for whom. One sentence. |
| 2 | Status | Reference | Version, platforms, stability. Only if non-obvious. |
| 3 | Install | Procedure | Copy-pasteable commands. Prerequisites first. |
| 4 | Quick start | Procedure | Smallest example that actually works, end to end. |
| 5 | Configuration | Reference | Table: name, type, default, effect. |
| 6 | Usage | Procedure | Common tasks, one per subsection. |
| 7 | Reference | Reference | API or CLI, exhaustive, in tables. |
| 8 | Troubleshooting | Troubleshooting | Symptom, cause, fix. |
| 9 | Development | Procedure | Build, test, contribute. |
| 10 | License | Reference | One line. |

**Section 4 matters most.**
A quick start that works unchanged, pasted straight into a terminal, decides
whether the reader continues.
Test it before you finish.

Most READMEs need only 1, 3, 4 and 10.
A README that needs all ten should probably be a `docs/` directory.

## docs/ layout

Numbered, identical in every repo:

```
docs/
├── 00-overview.md        Concept: what the system is, how the parts connect
├── 10-install.md         Procedure
├── 20-configuration.md   Reference
├── 30-howto/             Procedures, one file per task
├── 40-reference/         Reference, one file per surface (API, CLI, schema)
├── 50-troubleshooting.md Troubleshooting
├── 90-development.md     Procedure: build, test, release
└── adr/                  Architecture Decision Records
```

Steps of ten leave room to insert new files without renumbering.
If a repo has no content for a level, leave the number unused.
The gap is information in itself.

`adr/` sits outside the numbering because it follows different rules.
The numbered files describe the current state and are kept up to date.
An ADR records one decision at one point in time and is never edited after it is
accepted.
Decisions and their reasoning belong there, not in `00-overview.md`.
Use the `adr` skill to write them.

## Modules: one type per file

S1000D splits documentation into data modules: the smallest self-contained unit
of information, with a type that determines its structure.
A procedural module and a descriptive module have different required forms, and
they are never mixed.

Software arrived at the same split independently through Diátaxis (tutorial,
how-to, reference, explanation).
Two fields converging is good evidence that the split is real.

### Concept

```markdown
# <Name>

<What it is, in one sentence.>

<Why it exists, which problem it solves.>

<How it relates to neighbouring parts. Link, do not repeat.>
```

No steps.
If the reader needs to do something, link to the procedure.

### Procedure

```markdown
# <Verb plus object: "Deploy the scheduler">

Prerequisites:
- <what must be in place>

> **Warning:** <consequence>. <What to do to avoid it.>

1. <One instruction. Imperative. Copy-pasteable command.>
2. <One instruction.>

Verification: <how the reader sees that it worked. Concrete output, not
"it should work now".>
```

Warnings go before the step they apply to.
A warning placed after the step is an autopsy.

### Reference

```markdown
# <Name of the surface>

| Name | Type | Default | Effect |
| --- | --- | --- | --- |
```

Exhaustive, sorted alphabetically or logically.
No explanatory prose.
If something needs explaining, it belongs in a concept module.

### Troubleshooting

```markdown
## <The symptom, as the user experiences it>

**Cause:** <why it happens>

**Fix:** <what to do>
```

The heading is the symptom, not the cause.
The reader searches for the error message they see, not for a diagnosis they do
not have yet.
