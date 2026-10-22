# nvim-renderer

Neovim plugin that paints annotations from
[`analysis-engine`](../analysis-engine) — background tints + gutter signs,
coloring code by **intent** instead of syntax.

## How it works

The renderer is socket-only. It starts (or attaches to) a per-project analysis
daemon, sends buffer text and versions over a Unix socket, and renders the
annotations the daemon publishes. There is no artifact or offline mode.

The engine emits `role` and `intents` per span. The renderer resolves the intent
set to a meaning on every render (`LOGGING -> CONCEAL`, `ERROR_HANDLING -> SHOW`,
etc.) and maps that meaning to a rule. Changing meanings or rule precedence does
not require re-running analysis.

A scaffold with more than one intent never receives a single tag color. Color
handlers are skipped for it, while `IGNORE`/`CONCEAL` still apply, and the inner
spans keep their own styling.

The daemon publishes the analyzed version and content hash with each result. The
client ignores tags for outdated buffer versions and keeps the previous marks
visible until the matching version arrives. Candidate suggestions arrive on a
separate channel and render non-destructively; see [Candidates](#candidates).

## Install (dev)

Point your plugin manager at this directory:

```lua
{
  dir = "~/repos/code-intent/nvim-renderer",
  config = function()
    require("cint").setup({
      auto_render = true,
      resolve = {
        precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" },
        default = "SHOW",
      },
      rules = {
        CONCEAL = { conceal = { lines = true } },
        HIGHLIGHT = { highlight = true },
        SHOW = false,
        IGNORE = { ignore = true },
      },
      tags = {
        LOGGING = { meaning = "CONCEAL", bg = "#1f2d1f", priority = 10 },
        ERROR_HANDLING = { meaning = "SHOW", bg = "#2d1f1f", priority = 50 },
        UNTAGGED = { meaning = "SHOW" },
      },
    })
  end,
}
```

## Usage

1. Install the engine server binary:

   ```sh
   cd ~/repos/code-intent/analysis-engine
   ./gradlew :server:installDist
   ```

   Ensure `cint-server` is on `PATH`, or set `server_cmd`.

2. Open a supported file and render:

   ```
   :CintRender
   ```

The plugin starts the daemon on demand, or attaches to the existing per-project
daemon. Supported languages are Kotlin, JavaScript, TypeScript, Vue, and C#;
configure the mapping with `languages` if your filetypes differ.

## Commands

| command | effect |
|---|---|
| `:CintRender` | render annotations for the current buffer |
| `:CintClear` | remove decorations |
| `:CintToggle` | toggle decorations |
| `:CintRefresh` | reconnect and re-analyze the current buffer |
| `:CintInfo` | show config and active profile |
| `:CintProfile` | pick a profile |
| `:CintProfile <name>` | set current buffer (or global if the buffer is not rendered) |
| `:CintProfile! <name>` | set global and clear buffer overrides |
| `:CintProfileEdit [name]` | edit profiles in a Lua buffer |
| `:CintProfileReload` | reload profiles and re-render |
| `:CintShard` | pick a shard to apply now |
| `:CintShard <name>` | append to the buffer shard history |
| `:CintShard! <name>` | append to the global shard history |
| `:CintShardUndo` | undo the last applied shard |
| `:CintShardReset` | clear shard history |
| `:CintShardHistory` | show applied shard history |
| `:CintAnalyze` | request a live re-analysis |
| `:CintIntentLabels` | toggle virtual intent labels above every annotation |
| `:CintHover` | show the intents under the cursor in a floating window |
| `:CintStripes` | toggle active-span mixed-intent color striping |
| `:CintSuggest` | request AI intent candidates for the current buffer |
| `:CintReview` | toggle candidate review mode for the current buffer |
| `:CintReviewAccept [intent]` | confirm the candidate under the cursor, optionally by intent |
| `:CintReviewDeny` | reject every alternative in the group under the cursor |
| `:CintAnnotate <INTENT>[,<INTENT>] [note]` | write a user annotation for the symbol under the cursor |
| `:'<,'>CintAnnotate <INTENT>[,<INTENT>] [note]` | write a user annotation for the selected range |
| `:CintUnannotate` | remove the user annotation for the symbol or range under the cursor |
| `:CintAnnotations` | inspect the user annotations loaded for the current buffer |
| `:CintAnnotationsReload` | reload `.cint/user-annotations.json` |
| `:CintConfigAdd` | append the word under the cursor to a rulepack config field |
| `:CintConfigRemove` | pick and remove a user config overlay value |
| `:CintLiveTags` | inspect the server's live tags for this buffer |
| `:CintServerStatus` | show live server status |
| `:CintServerDisconnect` | disconnect from the live server |
| `:CintServerStop` | stop the live server daemon |
| `:CintServerRestart` | stop and respawn the live server daemon |

## User annotations

`:CintAnnotate` writes to `.cint/user-annotations.json`; the engine resolves the
record against the current syntax tree and merges it with pack output as a
`user` source. The intent argument is completed for the built-in user
directives:

- `PURE` — the function has no side effects and is deterministic.
- `READONLY` — the function does not write state, but may read external state.

Both make calls to the annotated function count as side-effect-free reads for
derivative-use and validation composition. `PURE` additionally participates in
the pure-function derivative path. The directives also stay visible in the
annotation's intent set and provenance.

```vim
"CintAnnotate PURE"
"CintAnnotate READONLY"
:CintAnnotate PURE,READONLY
"'<,'>CintAnnotate READONLY"
```

## Mixed-intent stripes

`:CintStripes` toggles an experimental ABABAB treatment for the multi-intent
span under the cursor. Only the active span is segmented (word/token-level,
capped at 40 segments), so mixed scaffolds get a visible color treatment without
creating marks for the whole buffer. It is off by default and leaves
single-intent spans unchanged.

## Intent labels

`:CintIntentLabels` toggles a global overlay that adds a virtual line above each
rendered annotation with its intent name(s). It re-renders already visible
buffers and applies to newly published annotations while enabled.

## Intent hover

`:CintHover` opens a non-focusable floating window next to the cursor listing the
distinct intents of the innermost published span under the caret, one intent per
line. The reserved `UNTAGGED` marker is omitted, and `UNTAGGED`-only spans are
ignored when choosing the innermost span. Intents are combined only when span
bounds coincide; when multiple non-coincident spans share the smallest size, the
earliest annotation in annotation order wins. A larger function or block
scaffold does not contribute its intents when a nested span is under the caret. Each line uses the intent's
tag color (background) and sign color (foreground), with the neutral fallback
palette for unconfigured intents. The window closes as soon as the cursor moves,
the buffer/window is left, the text changes, a window is scrolled, or the editor
is resized. It never takes focus, wraps, or shows a cursorline.

The same hover also appears on `CursorHold`/`CursorHoldI` by default. Bind an
explicit key with `<Plug>(CintHover)`:

```vim
nmap K <Plug>(CintHover)
```

Set `hover.on_cursor_hold = false` to keep only the explicit command and
`<Plug>` mapping, or `hover.enabled = false` to disable both the command and the
automatic trigger. The plugin does not change `updatetime`.

## Candidates

Candidates are review-only suggestions published alongside established tags;
they never replace or conceal annotations. Outside review mode each deterministic
candidate renders non-destructively with a dotted undercurl and a muted `?` sign.
An AI candidate (`source` starting with `ai:`) uses a purple `CintAiCandidate`
undercurl, a purple bold `AI` sign, and one ` AI` badge at end of line per
affected line. The status count reads `CodeIntent: N unsure`, or
`CodeIntent: N unsure (M AI)` when AI candidates are present. When a publish
increases the AI candidate count, the renderer notifies
`cint: AI added N candidate(s); :CintReview to inspect` once; repeated
republishes at the same count stay quiet.

`:CintSuggest` requests an enrichment pass for the current buffer and notifies
`requesting AI suggestions` when it starts. When the live document and published
tags already match the current buffer version it reuses that analysis instead of
republishing it, so existing AI badges are not cleared and re-added. If the pass
finds no new candidates it reports that instead of repeating the arrival
notification; `AI suggestion pass already running` means the server is busy, and
disabled or otherwise unaccepted passes are not reported as no-result.
`:CintReview` toggles buffer-local review mode. While active, every candidate
range uses the visible `CintCandidateReview` highlight and a virtual line above
the range shows the intent name(s), confidence, source/reason, and a concise
rationale. Toggling review off restores the passive rendering.

`:CintReviewAccept [intent]` and `:CintReviewDeny` act on the candidate range
under the caret. If multiple alternatives cover the caret, Accept opens a picker (ordered by
confidence) unless the optional intent selects a specific alternative. Deny rejects every alternative in that group so the group clears.
If no candidate covers the caret, the command reports it. Both commands keep
review mode active and let the server republish update the marks.

Confirm writes the intent as a user annotation under the shared
`.cint/user-annotations.json.lock` lock directory (also used by the engine
writer), and the next analysis shows it as established; because it resolves the
whole anchor group, sibling alternatives are no longer published or
confirmable. Deny persists suppression for each alternative in
`.cint/suggestions.json`; skip remains a protocol-level, per-client/session
decision. Confirm and reject are project-global: the daemon republishes the URI
to every client that has it open, so all owners of the same URI drop the resolved
group or suppressed candidate. The daemon still republishes candidates after a
decision, with empty groups when nothing remains. If the confirmed user
annotation is later removed, the next analysis re-proposes the candidate unless
it was rejected. Candidate marks clear when the buffer closes or the candidate
list is republished.

A pass can be cancelled; a provider timeout interrupts the pass and returns
`cancelled: true` with `timeout: true` without publishing partial candidates.
Both behaviours surface as no candidate update.

Candidate features require a protocol-3 daemon whose `initialize.suggestions`
descriptor has `enabled` not `false`. `:CintSuggest` distinguishes the failure
modes and sends no `cint/suggest` request when gated: a protocol below 3 asks to
restart/rebuild the live server, a missing descriptor does the same, and
`suggestions.enabled: false` in `.cint/suggestions.yml` names the setting and is
never auto-enabled. Pack candidates still publish when AI is disabled;
`.cint/suggestions.yml` controls the manual enrichment pass. The default provider
is DeepSeek (`deepseek-chat`);
it can be selected explicitly with `provider`, and `model` overrides the model.
`timeoutMs` (default 4000), `workerThreads` (default 2), `maxCandidates`,
`promptVersion`, `maxTokens` (default 512), `maxConfidence` (default 0.84,
clamped to at most 0.84), `baseUrl`, `apiKeyEnv`, `excerptRadiusBytes` (default
400), `allowGlobs`, and `redactPatterns` are also accepted. `allowGlobs` gates
which paths are sent; an empty list allows all, and `redactPatterns` are regexes
applied to the excerpt before sending.

The server resolves config, injects the key lookup, and orchestrates the pass.
`:suggest` owns the DeepSeek provider and its remote transport (JDK
`HttpClient`), so the daemon performs one HTTP attempt per eligible candidate and
does not retry. The key is read server-side from `DEEPSEEK_CHAT_KEY` by default
(or `apiKeyEnv`) and must never be printed or logged. AI candidates carry
`source = ai:deepseek` plus provider/model/promptVersion/rationale diagnostics;
their confidence is diagnostic and capped, while candidate-only is structural:
nothing becomes an established annotation without Confirm. A missing key or a
provider failure leaves the deterministic tags and candidates untouched.

## Configuration

```lua
require("cint").setup({
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  live_lsp = true,
  scope = "project",
  server_cmd = { "cint-server" },
  server_log = nil,
  debounce_ms = 150,
  expand_on_cursor = true,
  hover = { enabled = true, on_cursor_hold = true },
  handlers = { "color" },
  languages = {
    { language = "kotlin", filetypes = { "kotlin" }, extensions = { ".kt", ".kts" } },
    {
      language = "javascript",
      filetypes = { "javascript", "javascriptreact" },
      extensions = { ".js", ".jsx", ".mjs", ".cjs" },
    },
    { language = "typescript", filetypes = { "typescript" }, extensions = { ".ts", ".mts", ".cts" } },
    { language = "vue", filetypes = { "vue" }, extensions = { ".vue" } },
    { language = "csharp", filetypes = { "cs", "csharp" }, extensions = { ".cs" } },
  },

  resolve = {
    precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" },
    default = "SHOW",
  },
  rules = {
    CONCEAL = { conceal = { lines = true } },
    HIGHLIGHT = { highlight = true },
    SHOW = false,
    IGNORE = { ignore = true },
  },
  tags = {
    LOGGING = { meaning = "CONCEAL", bg = "#1f2d1f", priority = 10 },
    ERROR_HANDLING = { meaning = "SHOW", bg = "#2d1f1f", priority = 50 },
    UNTAGGED = { meaning = "SHOW" },
  },

  profile = "base",
  profiles = {},
  shards = {},
  keymaps = {
    pick = "<leader>pp",
    edit = "<leader>pe",
    shard = "<leader>ps",
  },
})
```

- `tags[intent].meaning` assigns the client-side meaning (`LOGGING = "CONCEAL"`).
- `hover.enabled` turns the intent hover command on or off; `hover.on_cursor_hold`
  controls the `CursorHold`/`CursorHoldI` trigger.
- `resolve.precedence` picks the effective meaning from a set (first present wins);
  `resolve.default` covers empty/unknown sets. `UNTAGGED` participates like any
  other intent.
- `rules[meaning]` selects the rendering rule. Defaults: `CONCEAL` hides whole
  lines, `HIGHLIGHT` applies a background, `SHOW` is a no-op (normal display),
  `IGNORE` dims the text.
- `tags[tag]` also supplies `bg`/`color` and `priority`. Highlight color comes
  from the highest-priority tag in the span's `intents`, falling back to the
  neutral `colors.fallback` color.
- `languages` maps Neovim filetypes and/or path extensions to engine language
  ids. The first matching filetype wins; extensions are the fallback.
- `scope` controls profile and shard storage and selection. `"project"` loads
  `<root>/.cint/profiles.lua` and allows buffer-local profile/shard history.
  `"global"` loads `stdpath("config")/cint/profiles.lua`, ignores
  project files, and forces global profile/shard selection.

To switch styles on the fly, change `tags.LOGGING.meaning` (for example
`"IGNORE"`) and re-render; no re-analysis is needed.

## Profiles

A profile is a named partial override of the presentation config:

```lua
profiles = {
  base = {
    rules = {
      CONCEAL = { conceal = { lines = true } },
      SHOW = { highlight = true },
      IGNORE = { ignore = true },
    },
    tags = {
      LOGGING = { meaning = "CONCEAL" },
      ERROR_HANDLING = { meaning = "SHOW" },
      UNTAGGED = { meaning = "SHOW" },
    },
  },
  review = {
    extends = "base",
    tags = { LOGGING = { meaning = "IGNORE" } },
  },
  focus = {
    extends = "base",
    tags = { LOGGING = { meaning = "HIGHLIGHT" }, ERROR_HANDLING = { meaning = "HIGHLIGHT" } },
    resolve = { precedence = { "HIGHLIGHT", "SHOW", "IGNORE", "CONCEAL" } },
    rules = { HIGHLIGHT = { highlight = true }, SHOW = { highlight = true } },
  },
}
```

- `extends` chains; children deep-merge over parents.
- `false` disables a rule/handler, `nil` inherits. Lists replace.
- Profiles can change `tags` (including meanings), `resolve`, `rules`,
  `handlers`, `hover`, and `expand_on_cursor`.

Switch at runtime with:

```vim
:CintProfile          " picker (vim.ui.select, picker plugins work)
:CintProfile review   " buffer-local
:CintProfile! review  " global
:CintProfileEdit      " edit profiles
```

Profile editing uses a normal Lua buffer. With `scope = "project"` the file is
`<project>/.cint/profiles.lua`; with `scope = "global"` it is
`stdpath("config")/cint/profiles.lua`. Saving reloads profiles
and re-renders. No engine run is needed.

Optional `<Plug>` mappings: `<Plug>(CintProfilePick)`,
`<Plug>(CintProfileEdit)`, and `<Plug>(CintShardPick)`.

## Shards

A shard is a one-shot patch applied **on top of** the current profile. Applying a
shard appends it to the history; the effective config is the profile with the
history folded in order (last applied wins). There is no active-set UI.

```lua
shards = {
  conceal_logging = { tags = { LOGGING = { meaning = "CONCEAL" } } },
  highlight_logging = { tags = { LOGGING = { meaning = "HIGHLIGHT" } } },
}
```

- `:CintShard` picks a shard to apply now.
- `:CintShard <name>` appends to the buffer history; `!` appends globally.
- `:CintShardUndo` pops the last shard; `:CintShardReset` clears it.
- `:CintShardHistory` shows what was applied, oldest → newest.
- Changing the profile **discards the shard history** and applies the new profile
  directly.

## Socket protocol

The plugin starts a per-project analysis daemon and talks to it over a Unix
socket using protocol `3`:

- `initialize` carries `{protocol = 3, root, client = "nvim"}` and returns the
  server protocol, root, supported languages, `config` with cached pack
  descriptors and the current overlay, and a secret-free `suggestions`
  descriptor (`enabled`, `trigger`, `provider`, `model`, `knownIntents`). Config
  features are gated on the returned protocol: against a protocol-1 daemon the
  cache stays empty and no `cint/config/*` request is sent. Candidate features
  additionally require a returned protocol of at least 3 and
  `suggestions.enabled ~= false`.
- `textDocument/didOpen` / `didChange` / `didClose` send buffer text + version.
- The server re-runs tree-sitter + the block engine and publishes tags carrying
  the analyzed version, content hash, config `revision`, `analysisRevision`, and
  annotations, followed by `cint/publishCandidates` with the document version,
  both revisions, flat `candidates`, and `groups` of alternatives for one
  anchored span. Candidate payloads include `candidateId`, `path`,
  `contentHash`, intents/source/confidence/reason/`aiEligible`, span/positions,
  and optional rationale/prompt/provider/model. A config mutation bumps the
  revision even when the text hash is unchanged, so open buffers re-render. The
  analysis, config snapshot, and new `analysisRevision` are allocated under the
  server's global lock, so revision order matches analysis order; candidate
  publishes older than the cached analysis or the last published candidates are
  dropped. The server also republishes candidates after a decision, with empty
  groups when the anchor group is resolved.
- `cint/suggest` takes `{uri, version, requestId}` and runs one asynchronous pass
  per document; it returns `{accepted, cancelled, count}` or a disabled/stale/
  busy result. A provider timeout returns `cancelled: true` with `timeout: true`
  and publishes nothing. `cint/suggest/cancel` takes `{uri?, requestId?}`.
  `cint/candidates/decide` takes `{uri, version, candidateId, decision}` with
  `confirm`, `reject`, or `skip`; confirming an alternative resolves the whole
  anchor group. Confirm and reject republish the URI to every client that has it
  open, while skip stays client/session-local.
- The client discards tags and candidates for an outdated version and stale
  out-of-order publishes whose revisions are older than the last accepted ones
  (`analysisRevision`, with config `revision` as a tiebreaker), but keeps the
  previous marks visible until the matching version arrives, so editing does not
  blank the buffer while analysis is pending.
- Analysis and revision sampling are serialized under the server's global lock;
  socket writes and config republishes happen outside it.
- Strong logger heuristics skip LSP; live hover queries are capped at 750ms and
  fall back to heuristics on timeout.
- Client changes request a fresh run on a debounce; `BufWritePost` and
  `:CintAnalyze` request an immediate run.
- Profiles and shards stay client-side; changing them only re-renders cached
  annotations and never re-runs the engine.
- The renderer has no artifact fallback: if the daemon is unavailable it reports
  the failure and leaves the buffer unchanged.

Server status: `:CintServerStatus`. Disconnect: `:CintServerDisconnect`.
The daemon is reusable; it is not killed on disconnect or when nvim exits.
Use `:CintServerStop` to reload project/engine config or a rebuilt server
binary; config-overlay changes reload packs in place and do not need a restart.

Daemon output is appended to `server_log`, which defaults to
`stdpath("log")/cint-live.log`. Set `server_log = false` to
inherit the daemon's streams instead. If the LSP oracle fails, the daemon logs
the stack and falls back to heuristic facts, so live tagging keeps working.
`:CintLiveTags` shows the annotations the server actually published.

### Config overlay

`:CintConfigAdd` appends the word under the cursor to a field on a selected
pack; `:CintConfigRemove` picks an existing user overlay value to remove. The
picker lists only `STRINGS` and `STRING_LIST` fields that apply to the current
buffer language and labels each choice with its pack, owning rule ids/intents,
and field key. Removal only touches values in the user overlay; pack defaults and
project config are left alone. The daemon owns the write to
`<root>/.cint/config.overlay.yml`, applies it, and reloads packs without a
restart. Additive overlay is opt-in through
`ConfigurableRulePack.configureAdditive`/`ConfigSchema.decodeAdditive`: for
those packs string lists/sets union with the effective value, string-set maps
recurse, and scalars from the overlay win. All bundled packs use
`SingleIntentPack` and support it. For a non-opt-in or legacy-configured pack
the server reports an error and rolls the overlay back; the pack keeps its
project/default values. The overlay never creates source annotations or
contributions.

## Handlers

How an annotation renders is decided by its resolved meaning through
**handlers**. The entry maps handler name to options; the presence of a handler
enables it.

```lua
rules = {
  CONCEAL = { conceal = { lines = true } },
  SHOW = { highlight = true },
  IGNORE = { ignore = { fg = "#555555" } },
}
```

| handler | effect | options |
|---|---|---|
| `highlight` | background color from the chosen tag | `bg`, `color` |
| `ignore` | dark-gray foreground | `fg`, `color` |
| `color` | background tint + gutter sign | `bg`, `sign`, `icon` |
| `conceal` | replace text with a char, or hide whole lines | `char`, `lines` |

- A meaning with no entry falls back to the top-level `handlers` list.
- Set a handler to `true` for defaults, or `false` to disable it:

```lua
rules = {
  CONCEAL = { color = false, conceal = { lines = true } },
}
```

`conceal` sets the window's `conceallevel` to 2 if it is 0, and can be paired
with `color` on the same span.

`conceal.lines = true` is the **vertical** mode: the span's lines are not drawn
at all (they take no height), collapsing to the next visible line. `char`
without `lines` is the inline mode, replacing the span's text with a character.

With `expand_on_cursor = true` (default), moving the cursor into a vertically
concealed block reveals the **entire block**; leaving it re-conceals.

## Test

```sh
./tests/run.sh
```

Runs headless Neovim tests. `render_spec.lua` stubs published tags and asserts
extmarks, signs, profiles, and language/filetype mapping. `live_spec.lua` drives
the Unix-socket transport against an in-process fake daemon, covering writes,
framing, publishes, errors, and disconnects without spawning `cint-server`.
`candidates_spec.lua` covers candidate publish/revision gating, suggest, review
mode marks and virtual lines, caret selection, accept with and without an intent,
deny groups, passive restore, review cleanup, deterministic versus AI passive
rendering (sign, highlight, badge), AI status counts, arrival notification
deduplication, repeat-suggest reuse, busy/disabled replies, suggest start and
no-result messages, and the `:CintSuggest` gate messages.
`hover_spec.lua` covers position-aware intent lookup, the cursor-relative
non-focusable window, tag and fallback colors, close-on-cursor-move, the empty
cases, and the hover config gates.

See `doc/cint.txt` for full help.
