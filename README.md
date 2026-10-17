# nvim-renderer

Neovim plugin that paints the artifact produced by
[`analysis-engine`](../analysis-engine) — background tints + gutter signs,
coloring code by **intent** instead of syntax.

## How it works

It reads a JSON artifact (`tags.json`) from the project root, matches spans to
the current buffer's path relative to that root, and applies extmarks.

The engine emits `role` and `intents` per span. The renderer resolves the intent
set to a meaning on every render (`Logging -> CONCEAL`, `ErrorHandling -> SHOW`,
etc.) and maps that meaning to a rule. Changing meanings or rule precedence does
not require regenerating the artifact.

Each file entry carries a content `hash`. If the buffer's content no longer
matches that hash, the renderer refuses to paint (and warns) rather than
applying stale line numbers — regenerate the artifact after edits.

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
        Logging = { meaning = "CONCEAL", bg = "#1f2d1f", priority = 10 },
        ErrorHandling = { meaning = "SHOW", bg = "#2d1f1f", priority = 50 },
        UNTAGGED = { meaning = "SHOW" },
      },
    })
  end,
}
```

## Usage

1. Generate the artifact with the CLI:

   ```sh
   cd ~/repos/semantic-code-painter/analysis-engine
   ./gradlew :cli:run --args="/path/to/repo --out /path/to/repo/tags.json"
   ```

2. Open a tagged file and render:

   ```
   :SCPainterRender
   ```

## Commands

| command | effect |
|---|---|
| `:SCPainterRender` | render annotations for the current buffer |
| `:SCPainterClear` | remove decorations |
| `:SCPainterToggle` | toggle decorations |
| `:SCPainterRefresh` | drop cache and re-render |
| `:SCPainterInfo` | show config and active profile |
| `:SCPainterProfile` | pick a profile |
| `:SCPainterProfile <name>` | set current buffer (or global if it has no rendered artifact) |
| `:SCPainterProfile! <name>` | set global and clear buffer overrides |
| `:SCPainterProfileEdit [name]` | edit project profiles in a Lua buffer |
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

## Configuration

```lua
require("semantic_code_painter").setup({
  artifact = "tags.json",
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  live = false,
  live_lsp = true,
  server_cmd = { "semantic-code-painter-server" },
  server_log = nil,
  debounce_ms = 150,
  expand_on_cursor = true,
  handlers = { "color" },

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
    Logging = { meaning = "CONCEAL", bg = "#1f2d1f", priority = 10 },
    ErrorHandling = { meaning = "SHOW", bg = "#2d1f1f", priority = 50 },
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

- `tags[intent].meaning` assigns the client-side meaning (`Logging = "CONCEAL"`).
- `resolve.precedence` picks the effective meaning from a set (first present wins);
  `resolve.default` covers empty/unknown sets. `UNTAGGED` participates like any
  other intent.
- `rules[meaning]` selects the rendering rule. Defaults: `CONCEAL` hides whole
  lines, `SHOW`/`HIGHLIGHT` applies a background, `IGNORE` dims the text.
- `tags[tag]` also supplies `bg`/`color` and `priority`. Highlight color comes
  from the highest-priority tag in the span's `intents`.
- The old `tags[tag].conceal/highlight` handler keys are only a legacy fallback
  for artifacts without `intents`; generated profiles no longer include them.

To switch styles on the fly, change `tags.Logging.meaning` (for example
`"IGNORE"`) and re-render; the artifact stays valid.

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
      Logging = { meaning = "CONCEAL" },
      ErrorHandling = { meaning = "SHOW" },
      UNTAGGED = { meaning = "SHOW" },
    },
  },
  review = {
    extends = "base",
    tags = { Logging = { meaning = "IGNORE" } },
  },
  focus = {
    extends = "base",
    tags = { Logging = { meaning = "HIGHLIGHT" }, ErrorHandling = { meaning = "HIGHLIGHT" } },
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
:SCPainterProfileEdit      " edit project profiles
```

Profile editing uses a normal Lua buffer at `<project>/.scpainter/profiles.lua`.
Saving reloads profiles and re-renders. No artifact regeneration and no engine
run are needed.

Optional `<Plug>` mappings: `<Plug>(SCPainterProfilePick)`,
`<Plug>(SCPainterProfileEdit)`, and `<Plug>(SCPainterShardPick)`.

## Shards

A shard is a one-shot patch applied **on top of** the current profile. Applying a
shard appends it to the history; the effective config is the profile with the
history folded in order (last applied wins). There is no active-set UI.

```lua
shards = {
  conceal_logging = { tags = { Logging = { meaning = "CONCEAL" } } },
  highlight_logging = { tags = { Logging = { meaning = "HIGHLIGHT" } } },
}
```

- `:SCPainterShard` picks a shard to apply now.
- `:SCPainterShard <name>` appends to the buffer history; `!` appends globally.
- `:SCPainterShardUndo` pops the last shard; `:SCPainterShardReset` clears it.
- `:SCPainterShardHistory` shows what was applied, oldest → newest.
- Changing the profile **discards the shard history** and applies the new profile
  directly.

## Live mode

With `live = true`, the plugin starts a per-project analysis daemon and talks to
it over a Unix socket:

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
- If the server is unavailable, the client falls back to the `tags.json`
  artifact.

Server status: `:SCPainterServerStatus`. Disconnect: `:SCPainterServerDisconnect`.
The daemon is reusable; it is not killed on disconnect.

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

Runs a headless Neovim test that loads the plugin against a temp artifact and
asserts extmarks and signs are applied.

See `doc/semantic_code_painter.txt` for full help.
