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
visible until the matching version arrives.

## Install (dev)

Point your plugin manager at this directory:

```lua
{
  dir = "~/repos/semantic-code-painter/nvim-renderer",
  config = function()
    require("semantic_code_painter").setup({
      auto_render = true,
      resolve = {
        precedence = { "SHOW", "HIGHLIGHT", "IGNORE", "CONCEAL" },
        default = "SHOW",
      },
      rules = {
        CONCEAL = { conceal = { lines = true } },
        SHOW = { highlight = true },
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
   cd ~/repos/semantic-code-painter/analysis-engine
   ./gradlew :server:installDist
   ```

   Ensure `semantic-code-painter-server` is on `PATH`, or set `server_cmd`.

2. Open a supported file and render:

   ```
   :SCPainterRender
   ```

The plugin starts the daemon on demand, or attaches to the existing per-project
daemon. Supported languages are Kotlin, JavaScript, TypeScript, Vue, and C#;
configure the mapping with `languages` if your filetypes differ.

## Commands

| command | effect |
|---|---|
| `:SCPainterRender` | render annotations for the current buffer |
| `:SCPainterClear` | remove decorations |
| `:SCPainterToggle` | toggle decorations |
| `:SCPainterRefresh` | reconnect and re-analyze the current buffer |
| `:SCPainterInfo` | show config and active profile |
| `:SCPainterProfile` | pick a profile |
| `:SCPainterProfile <name>` | set current buffer (or global if the buffer is not rendered) |
| `:SCPainterProfile! <name>` | set global and clear buffer overrides |
| `:SCPainterProfileEdit [name]` | edit profiles in a Lua buffer |
| `:SCPainterProfileReload` | reload profiles and re-render |
| `:SCPainterShard` | pick a shard to apply now |
| `:SCPainterShard <name>` | append to the buffer shard history |
| `:SCPainterShard! <name>` | append to the global shard history |
| `:SCPainterShardUndo` | undo the last applied shard |
| `:SCPainterShardReset` | clear shard history |
| `:SCPainterShardHistory` | show applied shard history |
| `:SCPainterAnalyze` | request a live re-analysis |
| `:SCPainterLiveTags` | inspect the server's live tags for this buffer |
| `:SCPainterServerStatus` | show live server status |
| `:SCPainterServerDisconnect` | disconnect from the live server |
| `:SCPainterServerStop` | stop the live server daemon |
| `:SCPainterServerRestart` | stop and respawn the live server daemon |

## Configuration

```lua
require("semantic_code_painter").setup({
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  live_lsp = true,
  scope = "project",
  server_cmd = { "semantic-code-painter-server" },
  server_log = nil,
  debounce_ms = 150,
  expand_on_cursor = true,
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
    SHOW = { highlight = true },
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
- `resolve.precedence` picks the effective meaning from a set (first present wins);
  `resolve.default` covers empty/unknown sets. `UNTAGGED` participates like any
  other intent.
- `rules[meaning]` selects the rendering rule. Defaults: `CONCEAL` hides whole
  lines, `SHOW`/`HIGHLIGHT` applies a background, `IGNORE` dims the text.
- `tags[tag]` also supplies `bg`/`color` and `priority`. Highlight color comes
  from the highest-priority tag in the span's `intents`.
- `languages` maps Neovim filetypes and/or path extensions to engine language
  ids. The first matching filetype wins; extensions are the fallback.
- `scope` controls profile and shard storage and selection. `"project"` loads
  `<root>/.scpainter/profiles.lua` and allows buffer-local profile/shard history.
  `"global"` loads `stdpath("config")/semantic-code-painter/profiles.lua`, ignores
  project files, and forces global profile/shard selection.
- The old `tags[tag].conceal/highlight` handler keys are only a legacy fallback
  for annotations without `intents`; generated payloads no longer include them.

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
  `handlers`, and `expand_on_cursor`.

Switch at runtime with:

```vim
:SCPainterProfile          " picker (vim.ui.select, picker plugins work)
:SCPainterProfile review   " buffer-local
:SCPainterProfile! review  " global
:SCPainterProfileEdit      " edit profiles
```

Profile editing uses a normal Lua buffer. With `scope = "project"` the file is
`<project>/.scpainter/profiles.lua`; with `scope = "global"` it is
`stdpath("config")/semantic-code-painter/profiles.lua`. Saving reloads profiles
and re-renders. No engine run is needed.

Optional `<Plug>` mappings: `<Plug>(SCPainterProfilePick)`,
`<Plug>(SCPainterProfileEdit)`, and `<Plug>(SCPainterShardPick)`.

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

- `:SCPainterShard` picks a shard to apply now.
- `:SCPainterShard <name>` appends to the buffer history; `!` appends globally.
- `:SCPainterShardUndo` pops the last shard; `:SCPainterShardReset` clears it.
- `:SCPainterShardHistory` shows what was applied, oldest → newest.
- Changing the profile **discards the shard history** and applies the new profile
  directly.

## Socket protocol

The plugin starts a per-project analysis daemon and talks to it over a Unix
socket:

- `textDocument/didOpen` / `didChange` / `didClose` send buffer text + version.
- The server re-runs tree-sitter + the block engine and publishes tags carrying
  the analyzed version and content hash.
- The client discards tags for an outdated version, but keeps the previous marks
  visible until the matching version arrives, so editing does not blank the
  buffer while analysis is pending.
- Strong logger heuristics skip LSP; live hover queries are capped at 750ms and
  fall back to heuristics on timeout.
- Client changes request a fresh run on a debounce; `BufWritePost` and
  `:SCPainterAnalyze` request an immediate run.
- Profiles and shards stay client-side; changing them only re-renders cached
  annotations and never re-runs the engine.
- The renderer has no artifact fallback: if the daemon is unavailable it reports
  the failure and leaves the buffer unchanged.

Server status: `:SCPainterServerStatus`. Disconnect: `:SCPainterServerDisconnect`.
The daemon is reusable; it is not killed on disconnect or when nvim exits.
Use `:SCPainterServerStop` to reload engine config or a rebuilt server binary.

Daemon output is appended to `server_log`, which defaults to
`stdpath("log")/semantic-code-painter-live.log`. Set `server_log = false` to
inherit the daemon's streams instead. If the LSP oracle fails, the daemon logs
the stack and falls back to heuristic facts, so live tagging keeps working.
`:SCPainterLiveTags` shows the annotations the server actually published.

## Handlers

How an annotation renders is decided by its resolved meaning (or legacy tag)
through **handlers**. The entry maps handler name to options; the presence of a
handler enables it.

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

- A meaning/tag with no entry falls back to the top-level `handlers` list.
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

Runs a headless Neovim test that stubs published tags and asserts extmarks and
signs are applied, plus language/filetype mapping.

See `doc/semantic_code_painter.txt` for full help.
