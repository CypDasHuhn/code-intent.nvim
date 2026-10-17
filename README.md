# nvim-renderer

Neovim plugin that paints the artifact produced by
[`analysis-engine`](../analysis-engine) — background tints + gutter signs,
coloring code by **intent** instead of syntax.

## How it works

It reads a JSON artifact (`tags.json`) from the project root, matches spans to
the current buffer's path relative to that root, and applies extmarks.

New artifacts carry `role`, `intents`, and a resolved `meaning` per span. The
engine has already merged multiple intents into one meaning (for example
`{Logging, ErrorHandling} -> SHOW`); the renderer only maps that meaning to
visuals.

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
      meanings = {
        CONCEAL = { conceal = { lines = true } },
        SHOW = { color = { bg = "#3a1f1f", sign = "#bf7f7f", icon = "!" } },
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
  meanings = {
    CONCEAL = { conceal = { lines = true } },
    SHOW = {},
  },
  tags = {},
})
```

- `meanings[meaning]` is used for new artifacts. Defaults: `CONCEAL` hides whole
  lines, `SHOW` draws nothing.
- `tags[tag]` remains as a fallback for old artifacts or spans without a
  `meaning`.

## Handlers

How an annotation renders is decided by its meaning (or legacy tag) through
**handlers**. The entry maps handler name to its options; the presence of a
handler enables it.

```lua
meanings = {
  CONCEAL = { conceal = { lines = true } },
  SHOW = { color = true, sign = true },
}
```

| handler | effect | options |
|---|---|---|
| `color` | background tint + gutter sign | `bg`, `sign`, `icon` |
| `conceal` | replace text with a char, or hide whole lines | `char`, `lines` |

- A meaning/tag with no entry falls back to the top-level `handlers` list.
- Set a handler to `true` for defaults, or `false` to disable it:

```lua
meanings = {
  CONCEAL = { color = false, conceal = { lines = true } },
}
```

`color` falls back to the built-in palette per meaning/tag name. `conceal` sets
the window's `conceallevel` to 2 if it is 0, and can be paired with `color` on
the same span.

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
