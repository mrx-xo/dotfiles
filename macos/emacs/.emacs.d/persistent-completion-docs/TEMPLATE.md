# [Feature Name]

> **TEMPLATE INSTRUCTIONS (delete this entire blockquote before submitting)**
>
> This template is optimized for AI agent handoff based on how LLMs process instructions.
>
> **Core principles baked into the structure:**
>
> 1. **Structure over prose** — LLMs parse lists, code blocks, and key-value pairs far more
>    reliably than narrative paragraphs. Every section uses structured formats.
> 2. **Front-load constraints** — Attention mechanisms weight earlier content more heavily.
>    Scope, non-goals, and hard constraints appear before implementation details so the
>    agent internalizes limits before it starts building.
> 3. **Explicit over implicit** — "Make it fast" means nothing. "Response under 200ms at p95"
>    is actionable. Every requirement must be concrete and testable.
> 4. **Consistent terminology** — Pick ONE term per concept. "Collection" in one place and
>    "playlist" in another will produce two features. Define your glossary and stick to it.
> 5. **Anti-patterns are as valuable as requirements** — LLMs over-engineer by default.
>    Telling them what NOT to do prevents scope creep and wasted work.
> 6. **Self-contained sections** — Each section should be understandable on its own. If
>    understanding a requirement forces cross-referencing three other sections, the agent
>    is more likely to miss something.
> 7. **Examples beat specification** — Concrete input/output examples, before/after states,
>    and code snippets communicate intent faster than abstract descriptions.
> 8. **Verifiable success criteria** — Every requirement needs a way to verify it. LLMs
>    work best when they can self-check against concrete, binary pass/fail criteria.
>
> **How to use:**
> - Fill in each section. Delete the `> TEMPLATE GUIDANCE` blocks and placeholder text.
> - If a section doesn't apply, delete it entirely — don't leave it empty.
> - Sections marked `[REQUIRED]` must be filled in. `[RECOMMENDED]` sections are high-value
>   but optional. `[OPTIONAL]` sections add precision when relevant.
> - Keep the total document under ~3000 lines. Beyond that, split into sub-PRDs that
>   reference each other.


## Metadata [REQUIRED]

- **Version**: 1.0
- **Created**: YYYY-MM-DD
- **Status**: Draft | In Review | Approved | In Progress | Complete
- **Priority**: P0 (must ship) | P1 (should ship) | P2 (nice to have)


## Problem Statement [REQUIRED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> 2-4 sentences max. Answer: What is broken, missing, or suboptimal TODAY?
> Do not describe the solution here. Do not describe the desired future state.
> Just the problem as it exists right now.
>
> Why this matters for agents: LLMs make better architectural decisions when they
> understand the "why" behind a feature. Without this, they optimize for the letter
> of the spec rather than the spirit of it.

[Describe the problem concisely]


## Goal [REQUIRED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> 1-3 sentences. What does success look like when this is done?
> This is the north star the agent should optimize toward when making judgment
> calls not covered by the spec.

[What the world looks like when this is shipped]


## Glossary [RECOMMENDED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Define every domain-specific term used in this PRD. Use these exact terms
> consistently throughout — never swap in synonyms.
>
> Why this matters for agents: LLMs treat different words as different concepts.
> If you call something a "recommendation" here and a "suggestion" later, the
> agent may treat them as separate features. One term, used everywhere,
> eliminates an entire class of bugs.

- **Term**: Definition
- **Term**: Definition


## Scope [REQUIRED]

### In Scope

> **TEMPLATE GUIDANCE (delete before submitting):**
> Bulleted list of what this feature DOES include. Be specific.
> "User authentication" is too vague.
> "Email/password login with bcrypt hashing and JWT session tokens" is clear.

- [Specific capability 1]
- [Specific capability 2]
- [Specific capability 3]

### Out of Scope (Non-Goals)

> **TEMPLATE GUIDANCE (delete before submitting):**
> This is one of the highest-value sections in the entire PRD.
>
> LLMs aggressively over-engineer. Without explicit boundaries, they will:
> - Add error handling for impossible scenarios
> - Build abstractions for single-use code
> - Add configuration for things that should be hardcoded
> - Implement "nice to have" features that seem related
>
> List everything that someone might ASSUME is included but IS NOT.

- [Thing that seems related but is explicitly excluded]
- [Future enhancement that is NOT part of this work]
- [Adjacent feature that should NOT be touched]


## User Stories & Acceptance Criteria [REQUIRED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Each story must have concrete, testable acceptance criteria. The agent will
> use these as a self-check to verify its own work.
>
> Bad:  "User should have a good search experience"
> Good: "When user types 3+ characters, results appear within 300ms.
>        Results are ordered by relevance score descending.
>        Maximum 20 results displayed per page."

### Story 1: [Short descriptive title]

**As a** [user role], **I want** [action] **so that** [outcome].

**Acceptance Criteria:**
- [ ] [Concrete, testable condition]
- [ ] [Concrete, testable condition]
- [ ] [Concrete, testable condition]

### Story 2: [Short descriptive title]

**As a** [user role], **I want** [action] **so that** [outcome].

**Acceptance Criteria:**
- [ ] [Concrete, testable condition]
- [ ] [Concrete, testable condition]


## Technical Specification [REQUIRED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> This is where you pre-make architectural decisions so the agent doesn't have
> to guess. The more decisions you make here, the less the agent will invent
> on its own.
>
> Include ONLY the subsections relevant to your feature. Delete the rest.

### Data Model / Schema Changes [if applicable]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Spell out exact fields, types, relations, and constraints. LLMs are excellent
> at implementing a well-defined schema but will make poor guesses if you leave
> it open-ended.

```
[Model/table name]
  - field_name: type (constraints) — description
  - field_name: type (constraints) — description
  - [relation]: relation_type to OtherModel
```

### API / Interface Contracts [if applicable]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Define inputs, outputs, and error cases explicitly. Include actual schema
> additions, endpoint signatures, or type definitions. Don't describe them
> in prose — show them in code.

```
[Endpoint/Query/Mutation signature]

Input:
  - param: type (required/optional) — description

Output:
  - field: type — description

Errors:
  - [Error case]: [What happens]
```

### UI/UX Specifications [if applicable]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Reference existing components and patterns by file path. Instead of "create
> a modal," say "use the existing Dialog component with the same pattern as
> src/components/ui/dialog.tsx." LLMs work best when they can pattern-match
> against existing code.
>
> Describe WHAT the user sees and does, not pixel-level layout (unless layout
> is critical to the feature).

- [Component/screen]: [What it shows, how it behaves]
- **Follows pattern of**: [existing component/page file path to reference]

### State Management [if applicable]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Where does state live? How does it flow? What gets cached? Specify which
> existing patterns to follow.

- [State concern]: [Where it lives, how it's managed]


## Constraints & Decisions [RECOMMENDED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Pre-make decisions the agent would otherwise have to guess at. Every decision
> you make here prevents a wrong guess. These are hard constraints — not
> preferences, not suggestions. The agent MUST follow these.

### Technical Constraints

- [MUST use X library/pattern, not Y]
- [MUST follow existing pattern in `path/to/file.ts`]
- [MUST NOT introduce new dependencies for this]
- [Performance: must meet X threshold]

### Decisions Already Made

> **TEMPLATE GUIDANCE (delete before submitting):**
> If you considered multiple approaches and chose one, state which and briefly
> why. This prevents the agent from "helpfully" switching to an alternative.

- **Decision**: [What was decided]
  - **Why**: [Brief rationale]
  - **Rejected alternative**: [What was NOT chosen and why]


## Edge Cases & Error Handling [RECOMMENDED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Enumerate specific edge cases. Without this list, the agent will either:
>   a) Ignore edge cases entirely, or
>   b) Go overboard adding handling for impossible scenarios
>
> A curated list keeps them focused on what actually matters. For each edge
> case, specify the EXPECTED BEHAVIOR — don't leave it to the agent to decide.

- **[Edge case description]**: [Expected behavior]
- **[Edge case description]**: [Expected behavior]
- **[Error scenario]**: [How the system should respond]


## Dependencies & Ordering [RECOMMENDED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> If tasks must happen in a specific order, say so explicitly. LLMs don't
> always infer correct ordering from context. Mark which steps block others.

1. [First step — blocks steps 2 and 3]
2. [Second step — depends on step 1]
3. [Third step — depends on step 1, can parallel with step 2]
4. [Fourth step — depends on steps 2 and 3]


## Files to Modify [RECOMMENDED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> List the files that WILL be changed and what changes in each. This scopes
> the blast radius and prevents the agent from wandering into unrelated parts
> of the codebase. Also list files to READ for context/patterns but NOT modify.

### Files to Change

- `path/to/file.ts` — [What changes]
- `path/to/file.ts` — [What changes]

### Files to Reference (read-only, for patterns)

- `path/to/file.ts` — [Why: pattern to follow for X]
- `path/to/file.ts` — [Why: existing implementation of similar feature]


## Testing Strategy [RECOMMENDED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Without this, you'll either get no tests or tests that assert implementation
> details rather than behavior. Specify WHAT to test and HOW, not just "add tests."

### Automated Tests

- [What to test]: [How — unit test, integration test, e2e test]
- [What to test]: [How]

### Manual Verification

- [ ] [Step-by-step manual check 1]
- [ ] [Step-by-step manual check 2]


## Success Criteria [REQUIRED]

> **TEMPLATE GUIDANCE (delete before submitting):**
> The definitive checklist for "is this done?" The agent should go through this
> list and verify every item before considering the work complete. Every item
> must be binary — yes/no, pass/fail. No subjective criteria like "feels good"
> or "looks nice."

- [ ] [Objectively verifiable criterion]
- [ ] [Objectively verifiable criterion]
- [ ] [Objectively verifiable criterion]
- [ ] Type-checks pass (`pnpm type-check`)
- [ ] Linting passes (`pnpm lint`)
- [ ] No console errors in browser


## Examples [OPTIONAL]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Concrete examples of inputs/outputs, before/after states, or user flows.
> These communicate intent faster than any amount of abstract specification.
> Show, don't tell.

### Before (current behavior)

```
[What happens now]
```

### After (expected behavior)

```
[What should happen after implementation]
```


## Anti-Patterns [OPTIONAL]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Explicit things the agent should NOT do. LLMs respond very well to direct
> prohibitions. This section catches the most common failure modes specific
> to your feature.

- Do NOT [specific thing the agent might be tempted to do]
- Do NOT [common over-engineering pattern to avoid]
- Do NOT [adjacent change that should be a separate PR]


## Open Questions [OPTIONAL]

> **TEMPLATE GUIDANCE (delete before submitting):**
> Unresolved decisions that need human input before implementation. If this
> section has items, the agent should ASK before proceeding — not guess.
>
> Remove this section entirely once all questions are resolved. An empty
> Open Questions section signals the PRD is fully decided.

- [ ] [Question that needs answering before work begins]
- [ ] [Decision that requires human judgment]
