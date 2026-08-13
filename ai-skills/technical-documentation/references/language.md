# Language: controlled writing

## Background

ASD-STE100 was created in 1986 because aircraft maintenance documentation was
read by technicians who did not speak English natively, under time pressure,
where a misreading could cost lives.
The solution was an approved word list of roughly 900 words, each with one
meaning and one part of speech, plus a set of writing rules.

You do not need the word list.
You need the disciplines it enforces.

## One term per concept

The most important rule.
Pick one word for each thing and use only that word.

| Instead of alternating between | Pick one |
| --- | --- |
| flag, option, switch, parameter | one of them, throughout the document |
| directory, folder | one of them |
| delete, remove, destroy | one per operation, and separate them if they differ |
| user, client, consumer | one of them |

Synonyms read as variation to a fluent native reader and as *different things*
to someone reading fast or in a second language.
If the project has more than ten such terms, write a glossary and link to it.

STE goes one step further: a word also has only one part of speech.
"Test" is a noun, so you write "do a test", not "test the unit".
The rule is strict for software, but worth borrowing where a word is ambiguous
in both roles.

## Sentence and paragraph limits

| Context | Limit |
| --- | --- |
| Sentence in a procedure | 20 words |
| Sentence in a description | 25 words |
| Paragraph in a description | 6 sentences |
| Instructions per step | 1 |

These limits are not aesthetics.
A 40-word sentence with two subordinate clauses forces the reader to hold state
in their head while reading.

## Active imperative

```
No:   The configuration file should be placed in the config directory.
Yes:  Put the configuration file in the config directory.

No:   It is recommended that you run the migration before deploying.
Yes:  Run the migration before you deploy.

No:   Errors will be logged to stderr.
Yes:  The program writes errors to stderr.
```

Passive voice hides who does what.
In a procedure it is always the reader, so the sentence should start with the verb.

## Present tense

```
No:   The server will start on port 8080.
Yes:  The server starts on port 8080.
```

Future tense in documentation describes something that is already true.

## Warnings before the action

```
No:
  3. Run `make reset`.
     Note: this deletes the local database.

Yes:
  > **Warning:** `make reset` deletes the local database. Back it up first.
  3. Run `make reset`.
```

A warning after the step is an autopsy.
Phrase it as a command, with the consequence first.

## Keep the articles

```
No:   Delete file and restart service.
Yes:  Delete the file and restart the service.
```

Telegraphic style saves two words and costs the reader an inference: one
specific file, or any file?

## Avoid gerunds where a simple verb works

```
No:   Running the tests requires installing the dev dependencies.
Yes:  To run the tests, first install the dev dependencies.
```

## One instruction per step

```
No:
  1. Clone the repo, install the dependencies, and run the build.

Yes:
  1. Clone the repository.
  2. Install the dependencies.
  3. Run the build.
```

The reader does one step at a time and looks away from the screen between them.
Three actions on one line means losing their place.

## Words that can almost always be cut

`simply`, `just`, `easy`, `obviously`, `of course`, `basically`, `note that`,
`please`.

They add no information, and "simply run" makes a reader who is stuck feel
stupid rather than informed.

## Commands must be copy-pasteable

```
No:   Run the build command with your environment name.
Yes:  Run `make build ENV=staging`. Replace `staging` with your environment.
```

Every command in the documentation must be selectable, pasteable and runnable.
If the reader has to guess a value, show the command with a concrete placeholder
and explain it on the line below.
