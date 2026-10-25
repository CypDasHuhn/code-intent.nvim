# code-intent.nvim

Neovim client for [CodeIntent](https://github.com/CypDasHuhn/code-intent).
Paints code by **intent** instead of syntax: tints, gutter signs, conceal,
intent hover, and AI candidate review.

- Engine, analysis, and protocol: <https://github.com/CypDasHuhn/code-intent>
- This client: <https://github.com/CypDasHuhn/code-intent.nvim>
- Full reference: `:help cint` (or [`doc/cint.txt`](doc/cint.txt))

## Requirements

- Neovim stable (Unix domain sockets required)
- CodeIntent engine binaries from the engine repository
- Kotlin, C, JavaScript, TypeScript, Vue, or C# sources

## Install

Install the engine first:

```sh
git clone https://github.com/CypDasHuhn/code-intent
cd code-intent
just install
```

Put `cint-server` on `PATH`, or set `server_cmd` to its absolute path.

Install the plugin with your plugin manager, for example lazy.nvim:

```lua
{
  "CypDasHuhn/code-intent.nvim",
  config = function()
    require("cint").setup({ auto_render = true })
  end,
}
```

For local development use `dir = "~/repos/code-intent.nvim"` instead of the
repository spec. Then open a supported file and run `:CintRender`.

## Protocol

The client pins engine protocol **5** and its schema fingerprint in
[`lua/cint/protocol.lua`](lua/cint/protocol.lua). The engine publishes the
schema at `analysis-engine/ipc/protocol.schema.json` and the contract at
`docs/ipc/PROTOCOL.md`. Refresh the pin after an intentional protocol change.

Engine releases are packaged with `just release`:

```sh
cd ../code-intent
just release
# build/release/cint-engine-0.1.0.tar.gz
```

## Common commands

| command                                             | effect                                     |
| --------------------------------------------------- | ------------------------------------------ |
| `:CintRender` / `:CintClear` / `:CintToggle`        | render, clear, or toggle annotations       |
| `:CintRefresh` / `:CintAnalyze`                     | reconnect and re-analyze                   |
| `:CintHover` / `:CintIntentLabels` / `:CintStripes` | inspect and decorate spans                 |
| `:CintProfile` / `:CintShard`                       | switch display profiles or shards          |
| `:CintAnnotate` / `:CintUnannotate`                 | edit user annotations (`PURE`, `READONLY`) |
| `:CintReview` / `:CintSuggest`                      | review and request AI candidates           |
| `:CintServerStatus` / `:CintServerStop`             | manage the live daemon                     |

Every command, option, handler, profile, and API entry is documented in
`:help cint` and [`doc/cint.txt`](doc/cint.txt).
