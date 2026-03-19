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
  "jyhl/sift.nvim",
  dependencies = {
    "lewis6991/gitsigns.nvim", -- optional, but recommended
  },
  cmd = {
    "SiftStart",
    "SiftStop",
    "SiftPrompt",
    "SiftPanelToggle",
    "SiftAcceptHunk",
    "SiftRejectHunk",
    "SiftAcceptFile",
    "SiftRejectFile",
    "SiftAcceptAll",
    "SiftRejectAll",
    "SiftNextHunk",
    "SiftPrevHunk",
    "SiftRefresh",
  },
  config = function()
    require("sift").setup()
  end,
}
```

`gitsigns.nvim` is optional. Without it, sift keeps working, but custom-base diff preview integration is disabled. Command-based lazy loading via `cmd = { ... }` works well for sift.

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

## Suggested Keymaps

`sift.nvim` does not define global keymaps by default. That is intentional: many Neovim setups already use `<leader>s` for search or substitute workflows.

If you want a Zed-like review flow, this is a good starting point:

```lua
vim.keymap.set("n", "<leader>ss", "<cmd>SiftStart<cr>", { desc = "Sift start" })
vim.keymap.set("n", "<leader>sx", "<cmd>SiftStop<cr>", { desc = "Sift stop" })
vim.keymap.set("n", "<leader>sp", "<cmd>SiftPrompt<cr>", { desc = "Sift prompt" })
vim.keymap.set("n", "<leader>st", "<cmd>SiftPanelToggle<cr>", { desc = "Sift panel" })
vim.keymap.set("n", "<leader>sr", "<cmd>SiftRefresh<cr>", { desc = "Sift refresh" })

vim.keymap.set("n", "]s", "<cmd>SiftNextHunk<cr>", { desc = "Sift next hunk" })
vim.keymap.set("n", "[s", "<cmd>SiftPrevHunk<cr>", { desc = "Sift prev hunk" })

vim.keymap.set("n", "<leader>sa", "<cmd>SiftAcceptHunk<cr>", { desc = "Sift accept hunk" })
vim.keymap.set("n", "<leader>sd", "<cmd>SiftRejectHunk<cr>", { desc = "Sift reject hunk" })
vim.keymap.set("n", "<leader>sA", "<cmd>SiftAcceptFile<cr>", { desc = "Sift accept file" })
vim.keymap.set("n", "<leader>sD", "<cmd>SiftRejectFile<cr>", { desc = "Sift reject file" })
vim.keymap.set("n", "<leader>s<CR>", "<cmd>SiftAcceptAll<cr>", { desc = "Sift accept all" })
vim.keymap.set("n", "<leader>s-", "<cmd>SiftRejectAll<cr>", { desc = "Sift reject all" })
```

Inside the sift panel:

- `q` closes the panel
- `<CR>` opens `:SiftPrompt`

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
