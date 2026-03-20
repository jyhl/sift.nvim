# sift.nvim

`sift.nvim` is a Neovim plugin for a Codex-driven agent workflow with:

- a session panel for prompts and backend logs
- a right-side panel-first workflow for prompting and review
- a multi-line panel composer with project-file references
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
    auto_start = true,
    height = 12,
    position = "right",
    width = 50,
  },
  logging = {
    notify = false,
    level = vim.log.levels.INFO,
  },
})
```

By default, sift logs to its panel and keeps `vim.notify()` quiet. Set `logging.notify = true` if you want notifications for warnings and errors.

The panel opens in a right-side vertical split by default. `:SiftPanelToggle` opens the panel and starts a session automatically when `panel.auto_start = true`.

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
- `<CR>` sends the current prompt, or opens the pending file / pending hunk / referenced file under the cursor
- `<S-CR>` adds a new line to the prompt composer
- `<C-j>` is kept as a fallback when the terminal does not send a distinct `Shift+Enter`
- `<Tab>` completes `@file` references
- `za` toggles referenced-file payloads in the transcript
- `gf` opens the pending file / pending hunk / referenced file under the cursor
- `]s` / `[s` jump to the next or previous pending hunk
- `gr` refreshes review state
- `gA` accepts all pending changes
- `gR` rejects all pending changes

## Workflow

1. Open a tracked file inside a git repository.
2. Open the panel with `:SiftPanelToggle` or a keymap like `<leader>st`.
3. If no session is active, sift starts one automatically and creates the session baseline ref.
4. Type a prompt in the panel. Use `<S-CR>` for a new line and `<CR>` to send it to Codex.
5. Use `@path/to/file.lua` in the panel prompt to reference tracked project files. Press `<Tab>` to complete `@file` references.
6. Review pending hunks with `:SiftNextHunk` and `:SiftPrevHunk`.
7. Run `:SiftRefresh` if you want to force a rescan against the session baseline.
8. Keep changes with `:SiftAcceptHunk`, `:SiftAcceptFile`, or `:SiftAcceptAll`.
9. Restore from the baseline with `:SiftRejectHunk`, `:SiftRejectFile`, or `:SiftRejectAll`.

`Accept` keeps the current workspace text and removes the change from sift's pending-review UI. `Reject` restores text from the session baseline and then refreshes the review state.

The panel also shows a live activity line while Codex is starting, working, streaming output, and refreshing review state after a run. Runs are grouped in the transcript, referenced-file payloads are collapsed by default, and the panel includes a pending-review section that lets you jump directly to changed files and hunks while keeping the panel pinned on the right. The panel also shows a short "pending files after this run" summary after each completed Codex turn.

## MVP limits

- Fully supports tracked files only.
- File and all-level reject use `git restore --source=<baseline-ref>`, so they operate at file granularity.
- Hunk reject is implemented by replacing the current hunk region with baseline-equivalent text and refreshing.
