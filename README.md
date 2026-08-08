# nit.nvim

A Neovim plugin for leaving review comments in code and exporting them as structured feedback for AI agents.
test edit
- Comments rendered as virtual text with `[nit]` prefix
- Range comments via visual selection with highlighted line ranges
- Comments follow line movements automatically via extmarks
- Export all comments as LLM-optimized markdown in one shot
- Export uses live buffer content (not stale snapshots from comment time)
- Navigate between comments with `:NitNext` / `:NitPrev`
- Import unresolved PR review comments via `gh` CLI (`:NitPr`)
- Works with Snacks, Telescope, or quickfix pickers

## Getting Started

1. Install with your plugin manager (see Installation section for keymaps)
2. Call `require('nit').setup()` in your config
3. Review code and add comments with `:NitAdd` (or your keymap)
4. Export all comments with `:NitExport` (or your keymap)
5. Paste into your AI agent, let it fix everything at once

## Installation

```lua
-- lazy.nvim
{
  'tobias-walle/nit.nvim',
  config = function()
    require('nit').setup()
  end,
  keys = {
    { '<leader>na', function() require('nit').input() end, desc = '[nit] Add/edit' },
    { '<leader>na', ":'<,'>NitAdd<CR>", mode = 'v', desc = '[nit] Add/edit (range)' },
    { '<leader>nd', function() require('nit').delete() end, desc = '[nit] Delete' },
    { '<leader>nl', function() require('nit').list() end, desc = '[nit] List' },
    { '<leader>ne', function() require('nit').export() end, desc = '[nit] Export' },
    { '<leader>nx', function() require('nit').clear() end, desc = '[nit] Clear all' },
    { ']n', function() require('nit').next() end, desc = '[nit] Next' },
    { '[n', function() require('nit').prev() end, desc = '[nit] Prev' },
  },
}
```

## Importing PR Comments

`:NitPr` pulls unresolved GitHub PR review comments into your local nit list via the [`gh` CLI](https://cli.github.com). Each review thread (top-level comment + replies) collapses into one nit. PR-level comments are bundled into a single nit at the first changed file.

```vim
:NitPr                                            " auto-detect PR for branch
:NitPr https://github.com/owner/repo/pull/42      " explicit URL
```

Notes:

- Requires `gh` installed and authenticated (`gh auth login`).
- Works on forks: PR is fetched from the parent (`baseRepository`) automatically.
- Resolved threads and outdated comments (no current line) are skipped.
- Re-running clears previously imported nits and refreshes; local hand-written nits are preserved.

Recommended workflow: `gh pr checkout <num>` first so line numbers match. Then `:NitPr` → review/edit imported nits → address with your AI agent → `:NitExport`.

## Comment Input

Use `:NitAdd` (or your configured keymap) to open the input window:

| Key | Action |
|-----|--------|
| `Esc` (in insert mode) | Switch to normal mode |
| `Enter` (in normal mode) | Submit comment |
| `Ctrl+Enter` (in insert mode) | Submit comment |
| `Esc` / `q` (in normal mode) | Cancel |

The input window starts in insert mode for easy text entry.
Submit empty text on an existing comment to delete it.

## Configuration

All options are optional.

```lua
require('nit').setup({
  picker = 'auto',       -- 'snacks' | 'telescope' | 'quickfix' | 'auto'
  confirm_clear = true,  -- Ask before clearing all comments
  notify_wrap = false,   -- Notify when navigation wraps around
  export = {
    include_code = true,   -- Include code snippets in export (default true)
  },
})
```

### Picker Selection

The `picker` option controls which UI is used for listing comments:

- `'auto'` (default): Tries Snacks → Telescope → Quickfix
- `'snacks'`: Requires [snacks.nvim](https://github.com/folke/snacks.nvim)
- `'telescope'`: Requires [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- `'quickfix'`: Always available, no dependencies

## Export Format

Exported markdown is optimized for LLM consumption with context included:

```markdown
I reviewed your code and have the following comments. Please address them.

1. [nit] src/auth.lua

```lua src/auth.lua:42
if attempts > 5 then
```

_Comment_: Magic number should be a constant

2. [nit] src/auth.lua

```lua src/auth.lua:87-92
local function process_request()
  validate_input()
  check_permissions()
  execute_action()
  log_result()
end
```

_Comment_: This pattern appears in multiple places, extract to shared helper
```

With `export.include_code = false`, code fences are omitted:

```markdown
I reviewed your code and have the following comments. Please address them.

1. [nit] `src/auth.lua:42`

_Comment_: Magic number should be a constant

2. [nit] `src/auth.lua:87-92`

_Comment_: This pattern appears in multiple places, extract to shared helper
```

Each comment includes:
- Numbered list with file path
- Code block with syntax highlighting and line reference (when `include_code = true`)
- Inline file:line reference (when `include_code = false`)
- Your comment text
- Warning for deleted files (if applicable)

## Statusline Integration

```lua
-- Example statusline component
local count = require('nit').count()
if count > 0 then
  return '💬 ' .. count
end

-- Or per-file counts
local counts = require('nit').count_by_file()
-- Returns: { ["src/foo.lua"] = 3, ["src/bar.lua"] = 1 }
```

## Implementation Notes

- Comments are stored in-memory only (no persistence across sessions)
- Rendered using extmarks with `virt_lines` as virtual text
- Line tracking handled automatically by extmark API
- Only works on normal file buffers (rejects special buffer types)
- Comments beyond EOF are silently skipped on buffer restore
- Deleted files are detected on export with warnings

## Development

To work on nit.nvim locally, replace the GitHub URL with a local path in your lazy.nvim config:

```lua
{
  'tobias-walle/nit.nvim',
  dir = '~/Projects/nit.nvim',  -- Replace with checked folder
  -- ... rest of config stays the same
}
```

## License

MIT
