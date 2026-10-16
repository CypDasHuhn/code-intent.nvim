# nvim-renderer

Neovim plugin that paints the tag artifact produced by
[`analysis-cli`](../analysis-cli) — background tints + gutter signs, coloring
code by **intent** instead of syntax.

## How it works

It reads a JSON artifact (`tags.json`) from the project root, matches spans to
the current buffer's path relative to that root, and applies extmarks with a
highlight group and a gutter sign. One highlight group is generated per tag.

## Install (dev)

Point your plugin manager at this directory:

```lua
{
  dir = "~/repos/semantic-code-painter/nvim-renderer",
  config = function()
    require("semantic_code_painter").setup({ auto_render = true })
  end,
}
```

## Usage

1. Generate the artifact with the CLI:

   ```sh
   cd ~/repos/semantic-code-painter/analysis-cli
   ./gradlew run --args="/path/to/repo --out /path/to/repo/tags.json"
   ```

2. Open a tagged file and render:

   ```
   :SCPainterRender
   ```

## Commands

| command | effect |
|---|---|
| `:SCPainterRender` | render tags for the current buffer |
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
  handlers = { "color" },
  tags = {
    Logging = {
      color = { bg = "#1f2d1f", sign = "#7fbf7f", icon = "≡" },
      conceal = { char = "…" },
    },
    ["Business Logic"] = { conceal = { char = "▁" } },
  },
})
```

## Handlers

How a tag renders is decided per tag by **handlers**. `tags[tag]` maps handler
name to its options; the presence of a handler enables it.

| handler | effect | options |
|---|---|---|
| `color` | background tint + gutter sign | `bg`, `sign`, `icon` |
| `conceal` | replace text with a char, or hide whole lines | `char`, `lines` |

- A tag with no `tags` entry falls back to the top-level `handlers` list.
- Set a handler to `true` for its defaults, or `false` to disable it:

```lua
tags = {
  Logging = { color = true, conceal = false },
}
```

`color` falls back to the built-in palette per tag name. `conceal` sets the
window's `conceallevel` to 2 if it is 0, and can be paired with `color` on the
same span.

`conceal.lines = true` is the **vertical** mode: the span's lines are not drawn
at all (they take no height), collapsing to the next visible line. `char`
without `lines` is the inline mode, replacing the span's text with a character.

## Test

```sh
./tests/run.sh
```

Runs a headless Neovim test that loads the plugin against a temp artifact and
asserts extmarks and signs are applied.

See `doc/semantic_code_painter.txt` for full help.
