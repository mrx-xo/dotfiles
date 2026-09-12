# SYZYGY New Chat implementation plan

> Execution: implement in this session, using test-driven development and focused review. The user approved the Figma mockup and authorized implementation.

**Goal:** Launch a chat with independently chosen project, agent, model, permission mode, and effort, optionally starting from a preset.

**Architecture:** Preserve existing HTML/Go/Emacs boundaries. A new launch-options bridge supplies configured agents and their advertised choices. A validated explicit settings payload starts the selected agent and confirms its settings before sending the first prompt. Legacy preset and clone callers remain supported.

**Tech stack:** Vanilla HTML/CSS/JavaScript, embedded assets, Go HTTP handlers, Emacs Lisp.

**Design:** Figma file `iUV2tD2yHjWE1sU5eEjcPb`, page `05 New Chat exploration`; main `31:208`, project `31:220`, agent `31:232`, model `31:244`, permissions `31:256`, modified preset `35:244`.

## Constraints

- Centered titles; left-side back/close icons; icon actions with accessible names and minimum 44px targets.
- Existing Gruvbox variables and the actual web font, Iosevka Term Slab.
- Preserve drafts between picker views and cancel/reopen. Search text never becomes a directory implicitly.
- Applying a preset fills settings; changing one field preserves other compatible fields. Switching agents clears incompatible choices visibly.
- No hard require of agent-shell from standalone Lisp modules; no main-daemon restart.
- Work in the clean existing checkouts: acp-mobile `syzygy` and dotfiles `main`, following the machine's day-to-day branching convention.

## Task 1: Explicit launch contract

Files: acp-mobile `launch.go`, `launch_test.go`, `main.go`; dotfiles `lisp/syzygy/syzygy-launch.el`, `syzygy-launch-test.el`, `syzygy.el`.

Interfaces:

```json
{"cwd":"/project","name":"","task":"","settings":{"agent":"codex","model":"gpt-6-astra","mode":"agent-full-access","effort":"high"}}
```

`POST /api/launch-options` calls `syzygy-launch-options-json`. Reply contains `agents` (id, name, models, modes, efforts, defaults) and `defaultAgent`. Choice objects contain id, name, description. `POST /api/spawn` with settings calls `syzygy-launch-json` with base64 JSON and returns `ok`, `bufferName`, or a concrete error. Without settings, preserve legacy behavior.

- [x] Add failing Go tests: explicit settings are forwarded losslessly, malformed settings rejected before bridge invocation, exact buffer name returned, clone/settings conflict rejected.
- [x] Add failing ERT tests: capabilities include live models beyond presets, unknown agent/model/mode rejected before spawn, effort confirmation precedes first prompt, failed settings never send a prompt.
- [x] Implement discovery from rig presets and live agent state, with a process-local last-known capabilities cache. Validate against real choices, not client-supplied constructor names.
- [x] Launch with pinned model/mode, wait for initialization, set advertised effort, confirm state, then submit the first prompt. Return the exact created buffer.
- [x] Run `go test ./... -run 'TestLaunch|TestSpawn'` and batch ERT for `syzygy-launch-test.el`.

## Task 2: Approved screen and picker behavior

Files: acp-mobile `index.html`, `new_chat_ui_test.go`, `assets/new-chat/*.svg`.

- [x] Add failing browser tests using the existing CDP harness: preset override/reset, incompatible agent switch, draft preservation, explicit path selection, launch payload and exact-session selection, API error retention, keyboard and narrow-screen geometry.
- [x] Download the actual exported Figma SVG assets. Use existing source font and CSS variables.
- [x] Replace the spawn sheet with one full-height dialog, centered header, scrollable body, pinned action footer, and nested picker views.
- [x] Add project pins/recents and saved presets in device-local storage; keep rig presets read-only. Add search, model/permission/effort pickers, custom path entry, and chat-name options.
- [x] Render every label with textContent; icon buttons use title/aria-label. Add focus restoration, Escape/back behavior, and dialog focus containment.
- [x] Match created sessions using returned bufferName; preserve legacy clone fallback.
- [x] Run focused browser tests at phone, narrow phone, and keyboard-height viewports.

## Task 3: Integration and verification

- [x] Run full Go/browser suite, Node suite, focused ERT, and configuration smoke checks if the loaded configuration changes.
- [x] Inspect actual phone-sized browser screenshots against the approved Figma frames.
- [x] Review launch validation and first-prompt sequencing, then fix findings and rerun affected tests.
- [x] Load the standalone Lisp module live; build and replace only acp-mobile using its launchd service. Verify health without starting paid agent turns.
- [x] Record implementation/validation in existing SYZYGY documentation and report the finished behavior and any tested limits.

## Delivery evidence

- App commit `733378abc55d68fcbabde23c760dc9c8dc0d6046`, pushed to `fork syzygy`.
- Full Go/browser suite passed in 73.251s. After review fixes, focused New Chat and Mermaid browser checks passed in 12.308s.
- All 55 Node tests, 8 launch ERT tests, and 150 configuration smoke tests passed; tangled configuration remains synchronized.
- Independent review found implicit permission fallback, empty capability handling, and a trapped recovery draft. All three were fixed with regression coverage.
- Reviewed main/project/model/permissions screenshots at 393x852; browser geometry checked at 320px width and 430px keyboard-height layout. Real iPhone Safari was not exercised in this session.
- Loaded the standalone launch module in the running daemon without restarting it. Built and installed acp-mobile, restarted only its launchd service, and verified public health plus authentication enforcement. No paid agent turns were started during verification.
- Setup and verification notes live in the existing `macos/syzygy/README.md`.
