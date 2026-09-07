#!/usr/bin/env python3
"""Compose the evil keymap survey from the dumps in $EKS_DIR.

Usage: compose.py [--full] [outfile]
  default   brief report (gotchas + free leader keys) on stdout
  --full    full report, including the stock-evil diff and every dump
"""
import os, re, string, sys, datetime

D = os.environ.get("EKS_DIR", "/tmp/eks")
args = sys.argv[1:]
FULL = "--full" in args
args = [a for a in args if a != "--full"]
OUT = args[0] if args else None

def tsv(path):
    d, own = {}, {}
    with open(path) as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            d[(p[0], p[1])] = p[2]
            own[(p[0], p[1])] = p[3] if len(p) > 3 else ""
    return d, own

live, owner = tsv(f"{D}/live.tsv")
trees = open(f"{D}/trees.md").read()
varmap = dict(l.rstrip("\n").split("\t") for l in open(f"{D}/vars.txt"))
survival = [l.rstrip("\n").split("\t") for l in open(f"{D}/leader-survival.txt")]
van = tsv(f"{D}/vanilla.tsv")[0] if os.path.exists(f"{D}/vanilla.tsv") else {}

STATES = ("normal", "visual", "insert")
ALPHA = (list(string.ascii_lowercase) + list(string.ascii_uppercase)
         + [str(d) for d in range(10)]
         + list("`~!@#$%^&*()-_=+[]{}\\|;:'\",<.>/?"))

def var(name):
    return varmap.get(name, "UNBOUND")

def top_level(state):
    rows = [(k, live[(s, k)]) for (s, k) in live if s == state]
    return ([(k, c) for k, c in rows if c != "nil"],
            [k for k, c in rows if c == "nil"])

def keylist(keys):
    if not keys:
        return "_(none)_"
    return " ".join("`` ` ``" if k == "`" else f"`{k}`" for k in keys)

def fence(pairs):
    return "```\n" + "\n".join(f"{k:<12} {c}" for k, c in pairs) + "\n```"

def shadow_count(mode, state="normal"):
    path = f"{D}/live-{mode}.tsv"
    if not os.path.exists(path):
        return "?"
    md = tsv(path)[0]
    return sum(1 for (s, k) in md if s == state
               and live.get((state, k), "nil") != md[(state, k)])

# --- leader keys -------------------------------------------------------------
spc_sec = trees.split("## Prefix `SPC`")[1].split("\n## ")[0]
spc_taken = {}
for line in spc_sec.splitlines():
    m = re.match(r"^SPC (\S+)\s{2,}(.+)$", line)
    if m:
        spc_taken[m.group(1)] = m.group(2).strip()
spc_free = [k for k in ALPHA if k not in spc_taken]

nb, nf = top_level("normal")
vb, vf = top_level("visual")
ib, ifree = top_level("insert")

PROBE = ('emacsclient --eval \'(with-current-buffer (get-buffer-create " *kb*") \\\n'
         '  (fundamental-mode) (evil-local-mode 1) (evil-normal-state) \\\n'
         '  (prog1 (format "%s" (key-binding (kbd "SPC k") t)) (kill-buffer)))\'')

brief = f"""# Evil keymap survey (live daemon)

Generated {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')} by
`macos/scripts/evil-key-survey.sh`, straight from the running Emacs. Nothing
here is checked in — regenerate it, never trust a saved copy.

Effective bindings after evil + evil-collection ({var('evil-collection-mode-list-length')} modes)
+ evil-snipe + evil-org + general + this config's overrides, measured in a plain
`fundamental-mode` buffer.

## Where free real estate exists

- **Normal state top level: nothing usable is free.** Every printable ASCII key
  and every `C-<letter>` is bound. Unbound: {keylist(nf)} — GUI-only variants of
  keys that are already taken, so they are bad choices.
- **`SPC <key>` free ({len(spc_free)}):** {keylist(spc_free)}
- **`SPC <key>` taken ({len(spc_taken)}):** {keylist(sorted(spc_taken))}
- New feature bindings belong under `SPC`: a free leader key, or a new key
  inside an existing `SPC` group. `general-override-mode` is
  `{var('general-override-mode')}`, so the leader wins over every major mode.

Check one specific key (`"nil"` means free):

```bash
{PROBE}
```

Full map, including every prefix tree and per-mode shadowing:

```bash
~/.dotfiles/macos/scripts/evil-key-survey.sh --full
```

## Gotchas

Traps that a single-key probe will not warn you about.

### 1. evil-snipe owns the find/repeat keys

`s S f F t T ; ,` in normal AND visual state are `evil-snipe-*`, not
`evil-substitute` / `evil-find-char` / `evil-repeat-find-char`. `s` and `S` are
NOT substitute / change-whole-line. `evil-snipe-scope` is `{var('evil-snipe-scope')}`;
`evil-snipe-override-evil-repeat-keys` is `{var('evil-snipe-override-evil-repeat-keys')}`, which is why `;` and `,` moved.

evil-collection hands `f F ,` back to vanilla evil inside dired, so the same key
is a different command depending on the buffer.

### 2. `U` is deliberately dead

`U` is bound to `undefined` in normal state. Not free — evil disables it on
purpose, and it reads as available in a careless check.

### 3. `<escape>` and `C-g` are both `mr-x/escape-quit`

Not `evil-force-normal-state` / `keyboard-quit`. Anything assuming stock escape
behaviour (transient states, hydra exits, popup dismissal) routes through this
config's function instead.

### 4. `TAB` is not `evil-jump-forward`

`evil-want-C-i-jump` is `{var('evil-want-C-i-jump')}`, so `TAB` / `C-i` is
`indent-for-tab-command`. `C-o` still jumps backward; nothing jumps forward.

### 5. `TAB` and `<tab>` are different keys

In a plain buffer `<tab>` is unbound while `TAB` is bound. In org-mode both are
`org-cycle`; in vterm both are `vterm-send-tab`. Claiming `<tab>` because it
looks free breaks in every mode that binds the GUI variant. Same trap for `RET`
vs `<return>`.

### 6. Several stock control keys mean something else here

- `C-s` is `consult-line`, not `isearch-forward` — normal, visual AND insert.
- `C-u` is `evil-scroll-up` in normal/visual (`evil-want-C-u-scroll` is
  `{var('evil-want-C-u-scroll')}`), so it is NOT `universal-argument` there. In insert state it is.
- `<prior>` / `<next>` are `pixel-scroll-interpolate-*`.

### 7. Visual state inherits nearly all of normal state

Only `A I O R U X a i g o u` and `SPC` are visual-specific. Everything else
falls through to normal state, so a key that looks free in
`evil-visual-state-map` is usually not free at all.

### 8. Operator state is empty but unusable

Only `a` and `i` (text objects) are bound. The rest is "free" only because
operator state is transient — a binding there fires mid-operator.

### 9. Insert state has no room

Every printable key is `self-insert-command`, so only control keys are
candidates, and evil plus this config have taken all of them. The only unbound
keys are {keylist(ifree)}, which are GUI variants of keys that already act.

### 10. Major modes shadow aggressively

dired shadows {shadow_count('dired-mode')} normal-state keys; org-mode shadows
{shadow_count('org-mode')}, rebinding motion and editing to `evil-org-*`. A key free in
`fundamental-mode` may already mean something in the mode you are targeting.

### 11. The minibuffer is a different world

`evil-collection-setup-minibuffer` is `{var('evil-collection-setup-minibuffer')}`, so the minibuffer runs in
Emacs state with Vertico's map. Normal-state bindings do not apply; bind in
`minibuffer-local-map` / `vertico-map`.

### 12. Evil semantics that differ from vim

- `evil-undo-system` is `{var('evil-undo-system')}`.
- `evil-search-module` is `{var('evil-search-module')}`, so `/` is isearch-based.
- `evil-want-Y-yank-to-eol` is `{var('evil-want-Y-yank-to-eol')}`, so `Y` yanks the whole line.
- `evil-respect-visual-line-mode` is `{var('evil-respect-visual-line-mode')}`.
- `which-key-mode` is `{var('which-key-mode')}`, so a new prefix needs a which-key name or it
  shows up unlabelled.

## Leader and special keys, per major mode

```
{chr(10).join(f"{m:<20} {rest}" for m, rest in survival)}
```
"""

def diff_block(state):
    rows = []
    for (s, k) in live:
        if s != state:
            continue
        v, l = van.get((state, k), "nil"), live[(s, k)]
        if v != l:
            rows.append((k, v, l, owner.get((s, k), "")))
    rows.sort(key=lambda r: ALPHA.index(r[0]) if r[0] in ALPHA else 999)
    body = "\n".join(f"{k:<10} stock evil: {v:<32} -> {l}"
                     + (f"   [{o}]" if o else "") for k, v, l, o in rows)
    return len(rows), "```\n" + body + "\n```"

def mode_blocks():
    out = []
    for fn in sorted(os.listdir(D)):
        m = re.match(r"^live-(.+)\.tsv$", fn)
        if not m:
            continue
        md = tsv(f"{D}/{fn}")[0]
        out.append(f"### {m.group(1)}\n")
        for state in STATES:
            rows = [(k, live.get((state, k), "nil"), md[(state, k)])
                    for (s, k) in md if s == state
                    and live.get((state, k), "nil") != md[(state, k)]]
            rows = [r for r in rows if "self-insert-command" not in (r[1], r[2])]
            if not rows:
                continue
            rows.sort(key=lambda r: ALPHA.index(r[0]) if r[0] in ALPHA else 999)
            out.append(f"{state} state, {len(rows)} keys shadowed:\n```")
            out += [f"{k:<10} plain: {b:<34} -> {v}" for k, b, v in rows]
            out.append("```\n")
    return "\n".join(out)

doc = brief
if FULL:
    nd, ndb = diff_block("normal")
    vd, vdb = diff_block("visual")
    idf, idb = diff_block("insert")
    doc += f"""
## Non-vanilla bindings (live config vs stock evil)

Same probe method on both sides, so these are real differences only.

### normal state ({nd} keys)

{ndb}

### visual state ({vd} keys)

{vdb}

### insert state ({idf} keys)

{idb}

## Major-mode shadowing

{mode_blocks()}

## Normal state, top level

{fence(nb)}

Unbound: {keylist(nf)}

## Visual state, top level

{fence(vb)}

Unbound: {keylist(vf)}

## Insert state, top level

{fence(ib)}

Unbound: {keylist(ifree)}

{trees}"""

if OUT:
    with open(OUT, "w") as fh:
        fh.write(doc)
    print(OUT)
else:
    sys.stdout.write(doc)
