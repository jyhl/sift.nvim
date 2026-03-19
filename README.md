# sift.nvim

`sift.nvim` is a Neovim plugin for a Codex-driven agent workflow with:

- a session panel for prompts and backend logs
- `codex exec --json` as the backend
- a git baseline ref at `refs/sift/<session-id>`
- plugin-owned review state
- pending hunk UI with inline highlights and signs
- accept/reject actions at hunk, file, and session scope

The baseline stays fixed for the whole session. Accepting a change does not touch git staging or the index; it only clears that change from sift's pending-review state.

## Requirements

- Neovim 0.9+
- `git`
- `codex` CLI authenticated via ChatGPT login
- `gitsigns.nvim` recommended for custom diff base handling and inline hunk preview

## Install

Example with `lazy.nvim`:

```lua
{
  dir = "~/code/sift.nvim",
  dependencies = { "lewis6991/gitsigns.nvim" },
  config = function()
    require("sift").setup()
  end,
}
```

`gitsigns.nvim` is optional. Without it, sift keeps working, but custom-base diff preview integration is disabled.

## Setup

```lua
require("sift").setup({
  codex = {
    bin = "codex",
    sandbox = "workspace-write",
    model = nil,
    profile = nil,
    extra_args = {},
    config_overrides = {
      model_reasoning_effort = "medium",
    },
  },
  panel = {
    height = 12,
  },
  logging = {
    notify = false,
    level = vim.log.levels.INFO,
  },
})
```

By default, sift logs to its panel and keeps `vim.notify()` quiet. Set `logging.notify = true` if you want notifications for warnings and errors.

## Commands

- `:SiftStart`
- `:SiftStop`
- `:SiftPrompt`
- `:SiftPanelToggle`
- `:SiftNextHunk`
- `:SiftPrevHunk`
- `:SiftRefresh`
- `:SiftAcceptHunk`
- `:SiftRejectHunk`
- `:SiftAcceptFile`
- `:SiftRejectFile`
- `:SiftAcceptAll`
- `:SiftRejectAll`

## Workflow

1. Open a tracked file inside a git repository.
2. Run `:SiftStart` to create the session baseline ref.
3. Run `:SiftPrompt` to send a prompt to Codex.
4. Review pending hunks with `:SiftNextHunk` and `:SiftPrevHunk`.
5. Run `:SiftRefresh` if you want to force a rescan against the session baseline.
6. Keep changes with `:SiftAcceptHunk`, `:SiftAcceptFile`, or `:SiftAcceptAll`.
7. Restore from the baseline with `:SiftRejectHunk`, `:SiftRejectFile`, or `:SiftRejectAll`.

`Accept` keeps the current workspace text and removes the change from sift's pending-review UI. `Reject` restores text from the session baseline and then refreshes the review state.

## MVP limits

- Fully supports tracked files only.
- File and all-level reject use `git restore --source=<baseline-ref>`, so they operate at file granularity.
- Hunk reject is implemented by replacing the current hunk region with baseline-equivalent text and refreshing.
