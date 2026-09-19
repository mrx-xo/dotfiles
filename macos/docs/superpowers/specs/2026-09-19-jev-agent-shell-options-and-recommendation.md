# Jev for Agent Shell: Options, Feasibility, and Recommendation

Date: 2026-09-19
Status: Proposed; architecture recommendation ready for review

**Goal:** Decide whether and how to add TypeSafe AI's Jev decision model to
the full agent-shell lifecycle across providers and clients, while preserving
an immediate off switch, avoiding avoidable maintenance, and proving that the
system improves real work before it is allowed to influence execution.

## Executive recommendation

Do not build a Jev client and policy system from scratch. Do not treat MCP as
the lifecycle integration. Do not put another stateful ACP proxy behind the
one the rig already uses.

Use Jevwire as the decision and policy engine, add an optional generic policy
hook to the existing `acp-multiplex`, and keep a small Emacs control layer for
the parts that occur before an ACP session exists: provider/model routing,
mode selection, status, and user overrides.

The recommended shape is:

```text
new-session request
  -> agent-shell-jev.el chooses provider/model or declines to intervene
  -> agent-shell launches the provider through acp-multiplex

agent-shell or acp-mobile
  -> acp-multiplex
       -> optional lifecycle judgment through the Jevwire daemon
       -> ACP provider: Claude, Codex, OpenCode, Gemini, Goose, or another agent
```

This is not a claim that ACP provides Claude Code hook parity. It does not.
The design distinguishes two outcomes:

- **Full-lifecycle judgment:** Jev may inspect routing, prompt submission,
  permission requests, tool progress/results, and completion.
- **Boundary-limited enforcement:** Jev may delay a submitted prompt or reject
  an actual ACP permission request. It cannot reliably stop a tool that the
  provider executes without requesting permission, and it cannot force a
  provider to continue after that provider has already completed the turn.

The initial release should be `off` by default and run in `shadow` when
explicitly enabled. Active behavior should not ship until a measured shadow
trial shows useful decisions, acceptable latency, and a sufficiently low
false-positive rate. Even then, active mode should only enforce control points
ACP actually owns.

## What Jev is and is not

Jev is a fast decision model. The caller supplies state and bounded questions,
such as a choice among named routes, a yes/no check, or a score against an
explicit rubric. Jev returns typed answers and probability distributions over
the answer space. It is not a prose generator.

That makes it suitable for:

- selecting among known agents or models;
- deciding whether an operation fits an enumerated risk class;
- deciding whether evidence supports a bounded completion criterion;
- ranking a fixed set of candidates;
- applying the same decision rubric repeatedly across providers.

It is not suitable for:

- writing implementation plans or code;
- arithmetic, counting, or date comparison;
- open-ended reasoning that requires discovering an answer outside the
  supplied choices;
- serving as a security boundary against adversarial prompt or tool content;
- replacing deterministic checks where code can answer exactly.

Jev's expected value is therefore strongest in consistency and routing. Token
efficiency may improve when it prevents unnecessary frontier-model calls or
cuts unproductive retries. Accuracy may improve at the bounded decision being
judged, but Jev does not make the underlying coding model more capable.

## Required outcome

The desired system applies to all agent-shell activity, not only Syzygy and
not only Claude. A complete solution must address:

1. New-session routing before a provider is launched.
2. Every user prompt, including prompts submitted from acp-mobile.
3. Permission decisions that ACP delegates to the client.
4. Tool-call observations and post-tool findings.
5. Turn completion and incomplete-work warnings.
6. Global and per-buffer control with an obvious, immediate off state.
7. Failure isolation: Jev errors must not prevent ordinary agent work.
8. Privacy controls for prompts and tool data that should not leave the rig.
9. Observable cost, latency, decisions, and user overrides.
10. A dependency/update strategy that does not silently track moving model or
    integration behavior.

## Current system facts

The recommendation is based on the actual rig rather than a generic Emacs
setup.

### Agent-shell already exposes useful lifecycle events

Upstream `agent-shell.el` exposes initialization, prompt readiness,
`input-submitted`, tool-call updates, permission requests and responses,
turn completion, errors, and cleanup through `agent-shell-subscribe-to`.
The prompt send path converges on `agent-shell--send-command`, and permissions
can be owned by `agent-shell-permission-responder-function`.

This makes an Emacs adapter feasible, but it is not a complete cross-client
boundary. In particular, `input-submitted` currently carries no prompt body,
and a prompt submitted by acp-mobile does not pass through Emacs's
`agent-shell--send-command`.

Evidence:

- `~/.emacs.d/elpaca/repos/agent-shell/agent-shell.el`, event API near line
  5250.
- The same file, `agent-shell--send-command` near line 7049.
- The same file, permission responder handling near line 2874.

### `acp-multiplex` is already the shared session boundary

Claude, Codex, and OpenCode are currently launched through `acp-multiplex` in
`macos/emacs/.emacs.d/emacs.org` near lines 10209-10239. The multiplexer is a
locally maintained Go project at `~/src/acp-multiplex`, built at a pinned
commit by `macos/syzygy/build-acp-tools.sh`.

The multiplexer already:

- reads every message from the ACP agent;
- reads every request, notification, and response from every frontend;
- rewrites request IDs and preserves ownership;
- caches and broadcasts permission requests;
- makes the first frontend permission response win;
- synthesizes user and turn-boundary notifications for attached clients;
- keeps acp-mobile and agent-shell attached to the same live session.

Those behaviors are implemented in `~/src/acp-multiplex/proxy.go`, especially
`readFromAgent`, `routeReverseCall`, `readFromFrontends`, and
`handleFrontendRequest` near lines 259-557. A policy seam in this process can
see phone-originated prompts without adding another protocol hop.

Gemini and Goose are not both normalized through this boundary today. Making
the lifecycle policy universal requires routing every supported ACP provider
through the multiplexer when Jev integration is enabled.

### ACP exposes observation more broadly than enforcement

ACP agents report tool calls through `session/update`. The agent executes the
tool. Before execution, the agent **may** call `session/request_permission`;
the client may then select or reject one of the supplied options. Because the
permission request is optional, the client cannot assume it will receive a
veto point before every tool.

This is true in both current protocol generations:

- [ACP v1 tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls)
- [ACP v2 tool calls](https://agentclientprotocol.com/protocol/v2/tool-calls)

A `tool_call` notification may arrive while the operation is pending, but it
is still a notification, not a request that the client can reject. Sending
`session/cancel` after seeing a dangerous notification is best-effort and may
race with execution. It must not be presented as a security guarantee.

### Jevwire is reusable but young

[Brainwires/jevwire](https://github.com/Brainwires/jevwire) is MIT-licensed.
Its [license](https://github.com/Brainwires/jevwire/blob/main/LICENSE) permits
use, modification, redistribution, sublicensing, and sale as long as the
copyright and license notice remain with substantial copies.

At the reviewed `v0.5.2` source:

- TypeScript compilation succeeds.
- All 43 test files and 1,461 tests pass locally.
- It contains a Jev HTTP client, typed result validation, retry/backoff,
  budgets, policy thresholds, redaction, prefilters, deterministic tripwires,
  reporting, persistence, a local daemon, MCP tools, and Claude Code hooks.
- The Claude hook lifecycle covers prompt submission, pre-tool, post-tool,
  failure, stop, and session start/end.
- Its public library exports the decision model and pure `run*` operations,
  but not the complete Claude lifecycle dispatcher as a supported public API.
- Its npm installation instructions currently do not match registry reality:
  `npm view jevwire` returned `404` during this review.

The project is promising and unusually well tested for its age, but it does
not yet have the release history or installed-base evidence implied by the
word "mature." It should be pinned, isolated behind a local contract, and
treated as replaceable.

## Evaluation criteria

Each option is assessed against the same criteria:

- **Coverage:** Does it see Emacs and phone turns across providers?
- **Enforcement:** Which decisions can it actually enforce before effects?
- **Reuse:** How much tested Jev behavior can be retained?
- **Failure isolation:** Can agent-shell continue when Jev is unavailable?
- **Operational complexity:** How many processes, protocol boundaries, and
  configuration sources are added?
- **Maintenance:** How much code must be kept compatible with agent-shell,
  ACP, providers, and Jev?
- **Reversibility:** Can the integration be disabled without rebuilding the
  daily workflow?
- **Evidence path:** Can its value be measured before it changes behavior?
- **Privacy:** Can sensitive sessions bypass external judgment reliably?

## Option 0: Do nothing now and wait for the ecosystem

### What it involves

Keep the existing agent-shell workflow unchanged. Revisit Jev after its
package distribution, APIs, and community integrations have had time to
stabilize.

### Advantages

- No engineering or maintenance cost.
- No added latency, API spending, process dependency, or data egress.
- Avoids being an early integrator for a model and ecosystem released only
  days before this review.
- Later work may benefit from an official ACP integration or stable package.

### Disadvantages

- No evidence about whether Jev improves this workflow.
- Routing and permission decisions remain provider- and prompt-dependent.
- Waiting does not guarantee that someone else will build an agent-shell or
  ACP lifecycle integration.
- The rig loses the opportunity to shape an upstreamable ACP boundary while
  the ecosystem is young.

### Work estimate

No immediate work. A future reassessment would take several hours, plus
whatever implementation is selected then.

### Judgment

Reasonable if maintenance avoidance is more important than learning. It is not
the best choice if the goal is to determine Jev's real value rather than infer
it from documentation.

## Option 1: Expose Jevwire as MCP tools only

### What it involves

Configure Jevwire's MCP server for each agent that supports MCP. The agent
would receive tools for evaluation, ranking, verification, gating, and
next-step selection.

### Advantages

- Fastest working access to Jev's capabilities.
- Minimal agent-shell-specific code.
- Useful for explicit tasks such as "rank these files" or "verify these
  claims."
- Easy to remove from the MCP configuration.

### Disadvantages

- The agent decides whether to call the tool.
- It does not cover session routing, every prompt, every permission, or
  completion automatically.
- Models may use it inconsistently or spend more tokens deciding whether and
  how to invoke it.
- An optional model tool cannot act as a mandatory policy boundary.
- The result would look integrated while failing the core lifecycle goal.

### Work estimate

Several hours for configuration, credentials, a smoke test, and removal
instructions. More time would be needed to prompt each provider into using it
consistently, without making it mandatory.

### Judgment

Useful as a supplementary explicit tool. Not a solution to the stated goal
and not worth positioning as one.

## Option 2: Build the entire integration ourselves

### What it involves

Implement a native Jev client and all surrounding behavior: request schemas,
typed validation, retries, timeout handling, rate limits, budgets, threshold
policies, redaction, prefilters, deterministic safety checks, persistence,
calibration, reporting, asynchronous Emacs integration, and ACP lifecycle
translation.

This could be written mostly in Emacs Lisp, as a standalone helper, or as a
mixed Emacs/Go subsystem.

### Advantages

- Complete control over APIs, storage, UI, and lifecycle semantics.
- No dependency on Jevwire's release or packaging decisions.
- A pure Emacs version could avoid a Node runtime.
- Policies could be designed specifically around this rig.

### Disadvantages

- Reimplements substantial tested open-source work.
- Creates the largest security, correctness, and maintenance burden.
- A direct Emacs implementation makes robust asynchronous HTTP, retries,
  cancellation, and schema validation more difficult than necessary.
- Policy behavior would drift from upstream Jevwire improvements.
- Testing would need to cover both the decision engine and every harness
  boundary before active mode could be trusted.
- Ownership remains permanent even if Jev proves to have little value.

### Work estimate

Three to six focused weeks to approach Jevwire's present breadth and build the
agent-shell/ACP integration, followed by ongoing maintenance. A shorter build
would necessarily omit behavior already covered by Jevwire's tests.

### Judgment

Not worth it. The differentiation lies in ACP and agent-shell integration,
not in owning another Jev client, retry layer, policy library, or report store.

## Option 3: Use Jevwire behind an Emacs-only agent-shell adapter

### What it involves

Create `agent-shell-jev.el`. It would advise or subscribe to agent-shell's
lifecycle, invoke a pinned Jevwire bridge asynchronously, keep buffer-local
state, and render decisions in Emacs.

### Advantages

- Fastest serious path to shadow data.
- Direct access to buffer state, provider configuration, prompts, permission
  UI, and user overrides.
- Natural global and buffer-local `off`, `shadow`, `advisory`, and `active`
  controls.
- Jevwire retains responsibility for Jev transport, validation, policy, and
  reporting.
- A Jev failure need not sit in the ACP byte path.

### Disadvantages

- A phone-originated prompt does not pass through Emacs's send function.
- Emacs sees provider tool updates but cannot turn a notification into a
  protocol veto.
- `input-submitted` lacks the submitted prompt body, requiring advice or an
  upstream event enhancement.
- Logic tied to agent-shell cannot serve another ACP client.
- Permission ownership may race with acp-mobile because the first response
  wins in the multiplexer.
- Part of the adapter becomes redundant if lifecycle policy later moves into
  `acp-multiplex`.

### Work estimate

Two to four focused days for a shadow-only adapter. Approximately one week for
polished modes, UI, persistence, tests, and permission integration.

### Judgment

Worth using as a disposable feasibility probe or retaining as the thin control
and UI layer. Not sufficient as the permanent universal lifecycle boundary.

## Option 4: Build a separate Jevwire ACP proxy

### What it involves

Fork or extend Jevwire with `jevwire-acp`, a bidirectional NDJSON/JSON-RPC
proxy placed between the existing multiplexer and each ACP provider:

```text
agent-shell or phone
  -> acp-multiplex
  -> jevwire-acp
  -> provider
```

The proxy would translate `session/prompt`, `session/update`,
`session/request_permission`, prompt responses, and session setup/cleanup into
Jevwire lifecycle events.

### Advantages

- Clean separation from Emacs.
- Provider-neutral and reusable by ACP clients outside this rig.
- Natural candidate for contribution to Jevwire or publication as a generic
  package.
- Most Jevwire decision and policy code remains reusable.
- Every frontend behind `acp-multiplex` shares the same policy.

### Disadvantages

- Adds a second stateful protocol proxy in series.
- Both proxies must preserve request IDs, ordering, cancellation, permissions,
  streaming updates, errors, and process shutdown correctly.
- A crash or framing bug in the new proxy can disconnect the active agent
  session; it cannot truly fail open after its process has died.
- Session tracking, request correlation, and completion detection duplicate
  work already implemented in `acp-multiplex`.
- Troubleshooting becomes harder because every message crosses two rewrite
  and routing layers.
- ACP's enforcement limitations remain unchanged despite the added process.

### Work estimate

One to two focused weeks for shadow/advisory support. Two to four weeks for
cross-provider replay tests, permission handling, crash behavior, packaging,
and confidence suitable for daily use.

### Judgment

Worth considering only if the objective expands to publishing a general ACP
integration independent of this rig. It is excess infrastructure for the
current goal.

## Option 5: Use Jevwire through policy hooks in `acp-multiplex`

### What it involves

Add a small, generic policy interface to the existing multiplexer. The
multiplexer translates selected ACP boundaries into a stable local event
schema and calls a local policy endpoint with a strict deadline. Jevwire's
daemon provides the first policy implementation.

The hook must be generic rather than named after Jev. Its contract should be
small enough that another deterministic or model-backed policy engine could
replace Jevwire later.

An event would carry only the state required for the decision:

- event name and protocol version;
- session ID and working directory;
- provider/model/mode when known;
- prompt text for prompt submission;
- normalized tool name, kind, input, status, and result summary for tool
  events;
- permission options for a permission request;
- final assistant text, stop reason, and usage for completion;
- stable correlation IDs and a redaction marker.

The response would be similarly bounded:

- `observe`: record only;
- `annotate`: attach a finding for clients/logs;
- `reject`: choose an available reject option for an actual permission
  request;
- `escalate`: forward the permission to the human with the finding;
- `continue`: take no action.

It must not contain an `allow` decision. Jevwire deliberately makes automatic
allow unrepresentable because the content being judged may try to persuade
the judge. The ACP adapter should preserve that invariant.

### Advantages

- Reuses the rig's existing common ACP boundary.
- Covers prompts from agent-shell and acp-mobile.
- Avoids a second JSON-RPC proxy and duplicate request/session tracking.
- A timeout or unavailable Jevwire daemon can return immediately to ordinary
  ACP forwarding.
- The hook can be tested with the multiplexer's existing replay and
  multi-frontend permission machinery.
- The generic seam remains useful if Jevwire is replaced.
- The current pinned build process already knows how to build and install the
  local `acp-multiplex` fork.

### Disadvantages

- Requires coordinated changes in `acp-multiplex`, the dotfiles configuration,
  and the Jevwire deployment.
- A synchronous decision adds latency at prompt and permission boundaries.
- Asynchronous post-tool and completion judgments need a reporting path back
  to Emacs or the phone.
- Gemini and Goose must be normalized through the multiplexer for universal
  coverage.
- New-session provider routing still requires a small pre-ACP Emacs component.
- ACP still cannot provide a veto when no permission request exists.

### Work estimate

- Three to five focused days: stable hook schema, Jevwire mapping, deadlines,
  shadow logging, off mode, and replay tests.
- Five to ten additional days: permission rejection/escalation, Emacs UI,
  mode propagation, privacy controls, and provider compatibility tests.
- Approximately one additional week of ordinary use in shadow mode before an
  active permission policy should be considered.

### Judgment

Best fit and best value. It concentrates custom work on the genuinely unique
part of this system: translating ACP lifecycle state into a reusable decision
contract.

## Option 6: Provider-native lifecycle hooks

### What it involves

Install or write a separate Jev integration beneath ACP for every provider:
Claude Code hooks, Codex hooks or wrapper behavior, OpenCode plugins, and
provider-specific equivalents for Gemini and Goose.

### Advantages

- The only route to true pre-tool enforcement when a provider exposes native
  hooks before execution.
- May inject post-tool findings before the provider sends results back to its
  model.
- May block completion and ask the provider to continue where supported.
- Jevwire's existing Claude Code plugin can be used directly for Claude.

### Disadvantages

- No universal hook contract exists across the providers.
- Behavior, configuration, and failure modes differ by provider.
- Some providers do not expose equivalent lifecycle hooks.
- The same policy would need multiple adapters and conformance tests.
- Users would experience inconsistent behavior depending on which agent they
  launched.
- Provider updates can silently break individual integrations.

### Work estimate

At least one to two focused weeks per provider with a capable hook system,
plus indefinite compatibility maintenance. Providers without suitable hooks
cannot reach parity regardless of effort.

### Judgment

Not suitable as the foundation. Add a provider-native adapter later only for
a demonstrated high-value enforcement gap, and keep ACP policy as the common
baseline.

## Comparative conclusion

The options fall into four practical groups:

- **Too weak:** waiting and MCP-only integration do not establish whether a
  universal lifecycle policy works.
- **Too expensive:** a ground-up implementation and provider-by-provider
  hooks create more ownership than the expected benefit justifies.
- **Useful but incomplete:** an Emacs adapter is the fastest probe and remains
  useful for routing and UI, but it is not the shared phone/ACP boundary.
- **Architecturally clean but redundant:** a separate ACP proxy is attractive
  as a public product but duplicates the rig's multiplexer.
- **Proportionate:** Jevwire plus a generic policy seam in `acp-multiplex`
  reuses the most existing work and adds the fewest new moving parts.

The recommended option does not have the smallest initial diff. It has the
smallest durable system that covers both Emacs and phone turns without
pretending ACP offers controls it does not have.

## Recommended architecture

### 1. Emacs control plane

`agent-shell-jev.el` owns user-facing policy state:

- global default mode;
- buffer-local override;
- provider/model routing before session creation;
- a visible mode and last-decision indicator;
- commands to turn Jev off immediately, inspect the latest judgment, and
  switch a session among supported modes;
- transmission of the selected mode into the child/multiplexer environment;
- no direct implementation of Jev's HTTP protocol or probability policy.

Routing is necessarily here because an ACP proxy cannot choose which provider
process should have been launched after that process already exists.

### 2. ACP policy plane

`acp-multiplex` owns cross-client lifecycle interception:

- capture prompts from every frontend before forwarding them;
- observe normalized tool updates from the provider;
- hold actual permission requests long enough for a bounded policy judgment;
- forward, reject, or escalate the permission using options the provider
  supplied;
- observe completion responses and synthetic turn boundaries;
- correlate asynchronous policy findings with session and tool IDs;
- continue ordinary ACP behavior on policy timeout or error.

The policy client should not know Jev's question schema. It speaks a stable
local lifecycle contract. The Jevwire-side adapter owns the mapping from that
contract to Jev questions and thresholds.

### 3. Jevwire decision plane

A source-pinned Jevwire daemon owns:

- TypeSafe/OpenRouter communication;
- model version selection;
- retries, timeouts, validation, and budget limits;
- redaction and prefilters;
- deterministic tripwires;
- question definitions and probability thresholds;
- decision logging and calibration reports;
- response signing/authentication for the local hook endpoint.

The daemon should bind only to loopback or a private Unix socket. Credentials
remain outside the repository and outside command-line arguments.

## Lifecycle behavior

### New session

Emacs submits a compact routing state before creating a session. Jev selects
among explicit, available routes such as frontier orchestrator, cheaper worker,
bulk reader, local-private, or human review. In shadow mode, the user's normal
selection wins and the counterfactual route is logged. Active routing should
remain separately switchable from active permission gating.

### Prompt submission

The multiplexer sees prompts from Emacs and attached clients. Shadow mode logs
the judgment and forwards immediately after the bounded deadline. Advisory
mode may attach a visible finding. Active mode may reject only a narrowly
defined prompt class, such as an explicit privacy rule; ordinary ambiguity
should escalate or annotate rather than block.

### Tool activity

Tool notifications are observations. They can feed reporting, detect
injection-like content, and warn the user. They cannot be treated as a
pre-execution gate unless accompanied by `session/request_permission`.

### Permission request

This is ACP's reliable enforcement point. Jev may recommend escalation or
rejection. It may never auto-allow. If Jev is uncertain, unavailable, or over
deadline, the request proceeds to the normal human permission UI.

### Completion

Jev may judge whether the final assistant message and observed work satisfy a
bounded completion rubric. A negative finding is advisory in the universal ACP
layer because the provider has already ended the turn. Automatically submitting
a corrective prompt risks loops, surprise token use, and user-intent changes;
it is excluded from the initial design.

## Modes and off behavior

The mode hierarchy is:

1. Buffer-local override, when set.
2. Provider or project policy, when configured.
3. Global default.

Supported modes:

- `off`: no request leaves the rig and no policy behavior changes the session.
- `shadow`: evaluate and record, but never annotate, reject, reroute, or
  escalate.
- `advisory`: show findings and suggested choices; the existing flow continues.
- `active`: enforce only documented boundaries, initially permission rejection
  or escalation and optionally pre-session routing.

There are two forms of off:

- **Live off:** the current multiplexer remains in place but stops making
  policy calls and forwards ACP normally.
- **Structural off:** new sessions launch without enabling the policy hook at
  all. This is the recovery path if the integration itself is suspected.

The default for installation and upgrades is `off`. The first deliberate
rollout mode is `shadow`.

## Failure and safety model

### Jev API or daemon failure

Use a short deadline. On timeout, connection failure, malformed response,
authentication failure, rate limit, or overload, record one bounded diagnostic
and continue without Jev. Permission requests fall back to the normal human UI.

### Multiplexer failure

Because the policy seam is inside the already required multiplexer, it must not
introduce a new goroutine, lock, or request path that can stall all ACP traffic.
Policy work needs explicit cancellation, bounded queues, and replay tests.
Structural off must bypass policy initialization entirely.

### False confidence

Jev is not a security boundary. Deterministic secret/path/command checks remain
deterministic. A high Jev probability does not authorize an action. Active mode
may make behavior stricter by rejecting or escalating; it must never weaken the
provider's or user's existing permission policy.

### Data exposure

Prompts, tool inputs, tool results, paths, and final messages may contain
secrets or private material. The adapter must minimize fields before sending,
apply Jevwire redaction, and support an explicit local-private route that makes
no remote Jev call. Full raw transcripts are not an acceptable default state
payload.

### Feedback loops

Completion findings must not automatically submit another turn in the first
release. Routing must not recursively route its own routing request. A policy
finding injected into visible context must be marked as policy metadata and
excluded from later state where practical.

## Dependency and update policy

- Pin the Jevwire source to an exact reviewed tag or commit rather than a
  floating branch, `latest` model alias, or currently unavailable npm package.
- Retain Jevwire's MIT copyright and license notice.
- Pin the Jev model version used for thresholds. Model alias changes can shift
  probability distributions and invalidate calibration.
- Update Jevwire and the model independently. Each update reruns adapter
  conformance tests and a shadow comparison before becoming active.
- Keep the local lifecycle event schema versioned so either side can reject an
  incompatible contract and fail open.
- Use the existing pinned `build-acp-tools.sh` workflow for the multiplexer;
  add Jevwire installation only after its exact artifact and source provenance
  are decided.

## Testing required

### Jevwire boundary tests

- malformed, partial, and over-budget state;
- timeout, authentication, rate-limit, overload, and invalid typed answers;
- redaction of representative credential, path, and transcript content;
- exact model version and threshold loading;
- no output path capable of returning automatic allow.

### `acp-multiplex` tests

- prompt events from primary and attached frontends;
- phone-originated prompts receive the same shadow judgment as Emacs prompts;
- permission requests remain cached and first-response-wins behavior remains
  correct;
- rejection selects only a reject option actually offered by the provider;
- uncertain and failed judgments forward to the normal human UI;
- policy timeouts do not reorder ACP messages;
- cancel, agent exit, frontend exit, replay, and late responses remain correct;
- off mode produces the same observable protocol traffic as the current
  multiplexer.

### Emacs tests

- global default and buffer-local override precedence;
- off, shadow, advisory, and active status rendering;
- pre-session routing in shadow does not change the user's selected config;
- local-private sessions make no external decision call;
- mode propagation into newly launched providers;
- commands work without loading Jevwire or hard-requiring agent-shell during
  batch configuration startup.

### Cross-provider replay

Capture sanitized protocol fixtures for Claude, Codex, OpenCode, Gemini, and
Goose. Replay each fixture through off and shadow modes and assert that agent
traffic remains semantically identical in both modes. Active permission tests
are added only for providers that issue real ACP permission requests.

## Evidence gate before active mode

Run at least 200 representative turns in shadow mode, including Emacs and
phone submissions and more than one provider. Record:

- added latency at each lifecycle boundary, including p50 and p95;
- Jev input size, call count, and cost;
- route recommendation versus the route actually used;
- proposed permission rejection/escalation versus the human answer;
- completion warning versus whether the next user turn identified missing
  work;
- API failures, timeouts, redaction events, and skipped local-private turns;
- user rating or later review of high-confidence findings.

Promotion to advisory requires:

- no ACP ordering, replay, permission, or disconnect regressions;
- no observed unredacted secret transmission;
- p95 blocking-boundary latency below the configured budget;
- findings useful often enough to justify their cost and visual noise.

Promotion to active permission enforcement additionally requires:

- a reviewed threshold calibrated against the shadow sample;
- a low false-rejection rate at that threshold;
- an immediate manual override path;
- tests proving that timeout and uncertainty return control to the human rather
  than reject or allow automatically.

There is no automatic promotion. Shadow evidence is reviewed by a human.

## Work breakdown and realistic effort

The estimates assume one focused engineer familiar with the repositories.
They are engineering-time ranges, not calendar promises.

### Phase 1: Contract and shadow path — three to five days

- Define and version the generic policy event/response schema.
- Add disabled-by-default policy configuration to `acp-multiplex`.
- Map prompt, tool, permission, and completion traffic into events.
- Connect to a pinned Jevwire daemon with strict deadlines.
- Log shadow decisions without mutating ACP behavior.
- Add replay, timeout, malformed-response, and off-equivalence tests.

### Phase 2: Emacs control plane — two to four days

- Add `agent-shell-jev.el` with global and buffer-local modes.
- Propagate mode and session metadata into the multiplexer.
- Add pre-session routing in shadow mode.
- Display current mode, last decision, cost, and latency without transcript
  clutter.
- Add focused ERT tests and configuration smoke coverage.

### Phase 3: Shadow trial — at least 200 turns

- Exercise multiple providers and both Emacs and phone entry points.
- Label decisions and inspect high-confidence disagreements.
- Tune state minimization and thresholds.
- Decide whether measured value justifies advisory or active behavior.

This is roughly one week of ordinary usage, but turn count and coverage matter
more than elapsed days.

### Phase 4: Permission enforcement — five to ten days

- Add reject/escalate translation for actual ACP permission requests.
- Preserve first-response-wins semantics across attached clients.
- Add override UI and decision explanations.
- Test every provider that exposes permission requests.
- Keep automatic allow impossible.

### Optional Phase 5: Provider-native enforcement

Only after shadow evidence identifies a valuable decision ACP cannot enforce,
add the smallest provider-native hook for that single boundary. This is a new
design decision, not assumed follow-on work.

## What is deliberately excluded

- Replacing deterministic secret guards or command/path checks with Jev.
- Automatically approving any permission.
- Automatically resubmitting a prompt because completion looked weak.
- Sending entire transcripts to Jev by default.
- Making Jev mandatory for starting or continuing an agent session.
- Claiming a tool notification was blocked when it was merely observed.
- Supporting non-ACP shells in the first implementation.
- Publishing a general `jevwire-acp` product before the rig proves the value.
- Provider-native parity across every agent.

## Final recommendation

Proceed only with the recommended architecture's shadow stage:

1. Retain Jevwire as a pinned, replaceable decision engine.
2. Add a generic, fail-open policy seam to the existing `acp-multiplex` rather
   than adding another ACP proxy.
3. Add a thin `agent-shell-jev.el` control plane for pre-session routing,
   modes, UI, and an immediate off switch.
4. Collect 200 representative turns before allowing Jev to alter behavior.
5. If the evidence is positive, activate only permission rejection/escalation
   at first; keep tool and completion judgments advisory.

This approach captures the reusable work already present in Jevwire, fits the
rig's existing multi-client ACP architecture, limits the blast radius of an
immature dependency, and produces evidence before committing to the expensive
parts. It also remains honest about the central limitation: ACP can provide a
universal observation and policy layer, but universal pre-execution enforcement
requires cooperation from each provider.

## Sources reviewed

- [TypeSafe System One documentation](https://docs.typesafe.ai/concepts/system-one)
- [Brainwires/jevwire](https://github.com/Brainwires/jevwire)
- [Jevwire MIT license](https://github.com/Brainwires/jevwire/blob/main/LICENSE)
- [ACP v1 prompt lifecycle](https://agentclientprotocol.com/protocol/v1/prompt-turn)
- [ACP v1 tool calls](https://agentclientprotocol.com/protocol/v1/tool-calls)
- [ACP v2 prompt lifecycle](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle)
- [ACP v2 tool calls](https://agentclientprotocol.com/protocol/v2/tool-calls)
- `~/.emacs.d/elpaca/repos/agent-shell/agent-shell.el`
- `macos/emacs/.emacs.d/emacs.org`
- `~/src/acp-multiplex/proxy.go`
- `macos/syzygy/build-acp-tools.sh`
