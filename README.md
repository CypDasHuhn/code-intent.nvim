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
      intentMeanings = {
        Logging = "CONCEAL",
        ErrorHandling = "SHOW",
        UNTAGGED = "SHOW",
      },
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
        Logging = { bg = "#1f2d1f", priority = 10 },
        ErrorHandling = { bg = "#2d1f1f", priority = 50 },
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
| `:SCPainterInfo` | show config |

## Configuration

```lua
require("semantic_code_painter").setup({
  artifact = "tags.json",
  root_markers = { ".git" },
  root = nil,
  auto_render = false,
  expand_on_cursor = true,
  handlers = { "color" },

  intentMeanings = {
    Logging = "CONCEAL",
    ErrorHandling = "SHOW",
    UNTAGGED = "SHOW",
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
    Logging = { bg = "#1f2d1f", priority = 10 },
    ErrorHandling = { bg = "#2d1f1f", priority = 50 },
  },
})
```

- `intentMeanings[intent]` assigns the client-side meaning.
- `resolve.precedence` picks the effective meaning from a set (first present wins);
  `resolve.default` covers empty/unknown sets. `UNTAGGED` participates like any
  other intent.
- `rules[meaning]` selects the rendering rule. Defaults: `CONCEAL` hides whole
  lines, `SHOW`/`HIGHLIGHT` applies a background, `IGNORE` dims the text.
- `tags[tag]` supplies `bg`/`color` and `priority`. Highlight color comes from
  the highest-priority tag in the span's `intents`.
- `tags[tag]` remains the fallback for old artifacts without `intents`.

To switch styles on the fly, change `intentMeanings` (for example
`Logging = "IGNORE"`) and re-render; the artifact stays valid.

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
