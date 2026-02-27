# CLAUDE.md

## Project: nit.nvim

A minimal Neovim plugin for annotating code with review comments. Designed for AI-assisted development workflows where you review AI-generated changes, leave comments, and export structured feedback for the AI to process in one pass.

## Core Concept

- Add comments with [nit] prefix to any line or range of lines in any buffer
- Comments render as virtual text above the annotated line via extmarks (non-destructive)
- Range comments highlight the annotated lines with a subtle background (`NitRange` → `CursorLine`)
- Virtual text prefix is always `[nit]` for all comments (no line numbers in virtual text)
- Export all comments as structured markdown optimized for LLM consumption
- Navigate between comments with configured keymaps (e.g., `]n` / `[n`)

## Workflow

1. AI makes changes → open in diffview or similar
2. Navigate code, add comments via `:NitAdd` or keymap
3. `:NitExport` exports to clipboard
4. Paste into Claude/Cursor/etc → AI addresses all feedback in one pass
5. `:NitClear` and repeat

## Technical Decisions

- **In-memory only**: No persistence across sessions. Review sessions are ephemeral.
- **Extmarks for rendering**: Comments follow line movements automatically
- **Extmark position syncing**: Before operations, sync extmark positions back to state to handle line insertions/deletions
- **Picker fallback**: Snacks → Telescope → Quickfix
- **Buffer validation**: Only works on normal file buffers, not special buffers

## File Structure

```
nit.nvim/
├── lua/nit/
│   ├── init.lua    # Main implementation, ~1100 lines
│   └── health.lua  # Healthcheck implementation
├── doc/
│   └── nit.txt     # Vim help documentation
├── README.md
└── CLAUDE.md       # This file
```

## Key APIs Used

- `vim.api.nvim_buf_set_extmark()` with `virt_lines`, `virt_lines_above`, `end_row`, `hl_group`, `invalidate`
- `vim.api.nvim_buf_get_extmark_by_id()` with `{details=true}` to read current position and `end_row`
- `vim.api.nvim_set_hl()` for `NitRange` highlight group (linked to `CursorLine`)
- `vim.api.nvim_create_autocmd()` with augroup for BufWinEnter, BufLeave, BufWritePost, WinLeave, VimLeavePre
- `vim.ui.select()` for confirmation dialogs
- `vim.fn.setreg('+', ...)` for clipboard

## Commands

- `:NitAdd` - Add/edit comment at cursor (supports visual selection and command ranges)
- `:NitDelete` - Delete comment at cursor (works from any line within a range comment)
- `:NitList` - List all comments (picker)
- `:NitExport` - Copy to clipboard
- `:NitClear` - Clear all (with confirmation)
- `:NitNext` / `:NitPrev` - Navigate

Note: Keymaps are user-configured. See README.md for recommended setup.

## Best Practices

### Code Organization

- Keep everything in a single file (`lua/nit/init.lua`) for simplicity
- Use clear function names and LSP annotations (`---@class`, `---@param`, `---@return`)
- Group related functions together (utilities, core functions, pickers, public API)

### State Management

- State is module-local, not global
- Always sync extmark positions before operations that depend on line numbers
- Use `pcall()` when deleting extmarks (they might already be gone)

### Error Handling

- Validate buffer types before operations (`is_valid_buf()`)
- Show user-friendly notifications via `notify()` function
- Gracefully handle missing files, deleted buffers, etc.

### Testing Changes

- Test with all three pickers (Snacks, Telescope, quickfix)
- Verify extmark tracking with line insertions/deletions
- Test edge cases: deleted files, comments beyond EOF, special buffers

## Commit Messages

Use short, single-line conventional commits:

```
feat: add multi-line comment support
fix: extmark not updating after undo
docs: update installation instructions
refactor: simplify picker detection
chore: update dependencies
```

Format: `type: short description` (no period, lowercase)

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

## Edge Cases Handled

- Line numbers shift after edits → extmark tracking
- Range offsets adjusted when extmarks move → sync_extmark_positions
- File deleted/renamed → detected on export, shown in picker
- Accidental clear → confirmation prompt
- Empty submit while editing → deletes the comment
- Comments beyond EOF → skipped on restore
- Special buffer types → rejected
- Visual selection of single line → treated as single-line comment (no range)
- Delete/edit from any line within a range → finds the range comment

## Testing Suggestions

- Add comment, insert lines above, verify comment moves
- Add comment, delete the line, verify comment removed
- Export with deleted file, verify warning
- Test with snacks, telescope, and quickfix fallback
- Add range comment via visual selection, verify `[nit]` prefix and range highlighting
- Export range comment, verify all lines appear in code fence
- Delete range comment from middle of range, verify it gets removed
- Edit existing range comment from any line within it
- Add lines within a range, verify range offsets stay consistent
