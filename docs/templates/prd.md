# <Feature name> Design

Date: <YYYY-MM-DD>
Status: <Draft | Agreed | Building | Shipped YYYY-MM-DD | Superseded by ...>
Predecessor: <path to the spec or handoff this builds on, or "none">

**Goal:** One sentence. Who gets what, and why it matters. If it needs two
sentences, the scope is not clear yet.

## Decisions

Bold claim, then the reason. One bullet per decision that a future reader
could otherwise re-litigate. Include the options you rejected and why.

- **<Decision>.** <Reason. What breaks or gets worse if we chose otherwise.>
- **<Decision>.** <Reason.>

## Flow

The happy path as a text diagram, plus every early exit. Written so it can be
checked against the code line by line.

```text
<trigger>
  -> <check>?   no: stop
  -> <step>
  -> <side effect>
```

## Files

Exact paths. What each file owns. Where tests live and what they capture at
the boundary (process argv, JSON payloads, HTTP handlers, DOM state).

- `<path>`: <responsibility>.
- `<path>` (tests): <what the suite proves>.

## Verification

How "done" was proven, not how it was meant to be proven. Command lines and
observed results. Device or manual steps listed as steps, with who does them.

1. <command or action> -> <observed result>

## Gotchas

Things learned the hard way during this build that the next person would hit
again. Platform quirks, ordering constraints, cache traps. Date them.

- <gotcha> (<date>)

## Not in scope

What was consciously left out, so nobody mistakes it for an oversight.

- <item>

## Handoff prompt

Only when the work continues in a fresh chat. One paragraph the next chat can
be started with, naming this file and the step to start at.

<!--
Conventions:
- No emojis. Status in words.
- Register the doc in ~/ATLAS.md if it is canon for a subsystem; specs under
  macos/docs/superpowers/specs/ and plans under macos/docs/superpowers/plans/
  do not need an ATLAS entry each, the directory does.
- Every term this doc coins goes into docs/glossary.md in the same commit.
- Reference this template in a chat with @docs/templates/prd.md.
-->
