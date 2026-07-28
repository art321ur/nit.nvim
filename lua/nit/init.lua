-- lua/nit/init.lua

---@class NitRange
---@field start integer 1-indexed start line
---@field end_ integer 1-indexed end line (inclusive)

---@class NitComment
---@field text string
---@field extmarks table<integer, integer>
---@field range? NitRange
---@field source? string Source tag ('pr' for imported PR comments)
---@field thread_id? string GitHub review thread node id (for PR imports)

---@class NitState
---@field comments table<string, table<integer, NitComment>>
---@field initialized boolean

---@class NitExportOpts
---@field include_code? boolean Whether to include code snippets in export (default true)

---@class NitOpts
---@field picker? 'snacks'|'telescope'|'quickfix'|'auto'
---@field confirm_clear? boolean
---@field notify_wrap? boolean
---@field export? NitExportOpts

local M = {}

local ns = vim.api.nvim_create_namespace('nit')
local augroup = nil

---@type NitState
local state = {
  comments = {},
  initialized = false,
}

local codediff_session = {
  tabpage = nil,
  orig_buf = nil,
  mod_buf = nil,
  orig_path = nil,
  mod_path = nil,
}

---@type NitOpts
local config = {
  picker = 'auto',
  confirm_clear = true,
  notify_wrap = false,
  export = {
    include_code = true,
  },
}

local HL = 'DiagnosticHint'

-- Utilities

local function update_codediff_session()
  local ok, lifecycle = pcall(require, 'codediff.ui.lifecycle')
  if not ok then return end
  local tabpage = vim.api.nvim_get_current_tabpage()
  local sess = lifecycle.get_session(tabpage)
  if not sess then
    codediff_session.tabpage = nil
    codediff_session.orig_buf = nil
    codediff_session.mod_buf = nil
    codediff_session.orig_path = nil
    codediff_session.mod_path = nil
    return
  end
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  local orig_path, mod_path = lifecycle.get_paths(tabpage)
  codediff_session.tabpage = tabpage
  codediff_session.orig_buf = orig_buf
  codediff_session.mod_buf = mod_buf
  codediff_session.orig_path = orig_path
  codediff_session.mod_path = mod_path
end

---@param bufnr integer
---@return boolean
local function is_valid_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname:match("^codediff://") then return true end
  if vim.b[bufnr].snacks_meta then return true end
  local bt = vim.bo[bufnr].buftype
  return bt == '' or bt == 'acwrite'
end

---@param file string
---@return string
local function normalize_path(file)
  if file == '' then return '' end
  local absolute = vim.fn.fnamemodify(file, ':p')

  -- Try to resolve symlinks
  local realpath = vim.uv.fs_realpath(absolute)
  if realpath then
    return realpath
  end

  -- Fallback to absolute path if realpath fails (file doesn't exist yet)
  return absolute
end

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'nit.nvim' })
end

---@return 'snacks'|'telescope'|'quickfix'
local function detect_picker()
  if config.picker ~= 'auto' then
    return config.picker
  end

  local has_snacks, snacks = pcall(require, 'snacks')
  if has_snacks and snacks.picker then return 'snacks' end

  local has_telescope = pcall(require, 'telescope')
  if has_telescope then return 'telescope' end

  return 'quickfix'
end

---@param file string
---@return boolean
local function file_exists(file)
  return vim.fn.filereadable(file) == 1
end

---Read current line content from buffer or disk.
---Returns lines for the given range, reading from the loaded buffer
---if available, otherwise falling back to reading from disk.
---Preserves original indentation for readable code snippets in export.
---@param file string absolute file path
---@param bufnr? integer loaded buffer number (or nil)
---@param start_lnum integer 1-indexed start line
---@param end_lnum integer 1-indexed end line (inclusive)
---@return string[]? lines line contents, or nil if unreadable
local function read_current_lines(file, bufnr, start_lnum, end_lnum)
  if bufnr then
    -- Read from loaded buffer (live content)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, end_lnum, false)
    if lines and #lines > 0 then
      return lines
    end
  end

  -- Fallback: read from disk
  if not file_exists(file) then return nil end
  local disk_lines = vim.fn.readfile(file)
  if not disk_lines or #disk_lines == 0 then return nil end

  local result = {}
  for i = start_lnum, math.min(end_lnum, #disk_lines) do
    table.insert(result, disk_lines[i])
  end
  if #result == 0 then return nil end
  return result
end

---@param filepath string
---@return string
local function get_language(filepath)
  local ext = vim.fn.fnamemodify(filepath, ':e')
  local lang_map = {
    lua = 'lua',
    py = 'python',
    js = 'javascript',
    ts = 'typescript',
    jsx = 'javascript',
    tsx = 'typescript',
    md = 'markdown',
    sh = 'bash',
    bash = 'bash',
    vim = 'vim',
    c = 'c',
    cpp = 'cpp',
    h = 'c',
    hpp = 'cpp',
    rs = 'rust',
    go = 'go',
    rb = 'ruby',
    java = 'java',
    kt = 'kotlin',
    swift = 'swift',
    cs = 'csharp',
    php = 'php',
    html = 'html',
    css = 'css',
    scss = 'scss',
    json = 'json',
    yaml = 'yaml',
    yml = 'yaml',
    toml = 'toml',
    xml = 'xml',
    sql = 'sql',
  }
  return lang_map[ext] or ''
end

---@param bufnr integer
---@param extmark_id integer
---@return integer? lnum 1-indexed line number or nil if not found
local function get_extmark_lnum(bufnr, extmark_id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, extmark_id, {})
  if mark and #mark >= 1 then
    return mark[1] + 1
  end
  return nil
end

---Get the start and optional end line of an extmark (1-indexed).
---For range extmarks, returns both start_lnum and end_lnum.
---@param bufnr integer
---@param extmark_id integer
---@return integer? start_lnum 1-indexed start line
---@return integer? end_lnum 1-indexed end line (nil for single-line)
local function get_extmark_range(bufnr, extmark_id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, extmark_id, { details = true })
  if not mark or #mark < 3 then return nil, nil end

  local start_lnum = mark[1] + 1
  local details = mark[3]

  if details and details.end_row then
    return start_lnum, details.end_row + 1
  end

  return start_lnum, nil
end

---@param file string
---@return integer? bufnr
local function get_bufnr_for_file(file)
  local bufnr = vim.fn.bufnr(file)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return bufnr
  end
  return nil
end

---Find a comment at the given cursor line, checking both exact match and range membership.
---State key is now the start line. For range comments, the end comes from the extmark's end_row.
---@param file string normalized file path
---@param bufnr integer
---@param cursor_lnum integer 1-indexed cursor line in bufnr
---@return integer? stored_lnum the key in state.comments[file], or nil
---@return NitComment? comment
local function find_comment_at(file, bufnr, cursor_lnum)
  local comments = state.comments[file]
  if not comments then return nil, nil end

  for lnum, comment in pairs(comments) do
    if comment.extmarks and comment.extmarks[bufnr] then
      local start_lnum, end_lnum = get_extmark_range(bufnr, comment.extmarks[bufnr])
      if start_lnum then
        -- Exact match on start line (works for both single-line and range)
        if start_lnum == cursor_lnum then
          return lnum, comment
        end

        -- Range match: cursor is within the range
        if end_lnum and cursor_lnum > start_lnum and cursor_lnum <= end_lnum then
          return lnum, comment
        end
      end
    else
      -- If no extmark for this buffer, we need to compare using real lines
      local _, real_cursor = get_cursor_context(bufnr, cursor_lnum)
      if real_cursor then
        if lnum == real_cursor then
          return lnum, comment
        end
        if comment.range and real_cursor >= comment.range.start and real_cursor <= comment.range.end_ then
          return lnum, comment
        end
      end
    end
  end

  return nil, nil
end

-- Core functions

---@param bufnr integer
---@param file string
---@param real_lnum integer
---@return integer? render_lnum
local function get_render_lnum(bufnr, file, real_lnum)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname:match("^codediff://") then
    return real_lnum
  end
  if vim.b[bufnr].snacks_meta then
    for l, m in pairs(vim.b[bufnr].snacks_meta) do
      if type(m) == 'table' and m.diff and normalize_path(m.diff.file) == file and m.diff.line == real_lnum then
        return l
      end
    end
    return nil
  end
  return real_lnum
end

---Render a comment as an extmark. For range comments, the extmark is placed at the
---start line with end_row pointing to the end line. Virtual text renders above the
---start line. Range highlighting uses NitRange hl_group.
---@param bufnr integer
---@param file string
---@param lnum integer 1-indexed start line (state key)
---@param comment NitComment
---@return integer? extmark_id
local function render(bufnr, file, lnum, comment)
  comment.extmarks = comment.extmarks or {}
  -- Clean up old extmark
  if comment.extmarks[bufnr] then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, comment.extmarks[bufnr])
  end

  local render_start = get_render_lnum(bufnr, file, lnum)
  if not render_start then return nil end

  local is_range = comment.range and comment.range.start ~= comment.range.end_
  local render_end = nil
  if is_range then
    render_end = get_render_lnum(bufnr, file, comment.range.end_)
  end

  local extmark_opts = {
    virt_lines = {
      {
        { '┃ ', HL },
        { string.format('[nit] %s', comment.text), 'Comment' },
      },
    },
    virt_lines_above = true,
    invalidate = true,
  }

  if is_range then
    -- Range comment: single extmark at start with end_row at end
    render_end = render_end or render_start
    extmark_opts.end_row = render_end - 1  -- 0-indexed
    extmark_opts.end_col = 0
    extmark_opts.hl_group = 'NitRange'
    extmark_opts.hl_eol = true
    extmark_opts.right_gravity = false
    extmark_opts.end_right_gravity = true
  else
    -- Single-line comment: default gravity (right_gravity=true)
    extmark_opts.right_gravity = true
  end

  local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, render_start - 1, 0, extmark_opts)
  if extmark_id then
    comment.extmarks[bufnr] = extmark_id
  end

  return extmark_id
end

---@param bufnr integer
local function restore_comments(bufnr)
  if not is_valid_buf(bufnr) then return end

  local real_files = {}
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  
  if bufname:match("^codediff://") then
    local path
    if codediff_session.orig_buf and bufnr == codediff_session.orig_buf then
      path = codediff_session.orig_path
    elseif codediff_session.mod_buf and bufnr == codediff_session.mod_buf then
      path = codediff_session.mod_path
    end
    if path then
      real_files[normalize_path(path)] = true
    end
  elseif vim.b[bufnr].snacks_meta then
    for _, m in pairs(vim.b[bufnr].snacks_meta) do
      if type(m) == 'table' and m.diff and m.diff.file then
        real_files[normalize_path(m.diff.file)] = true
      end
    end
  else
    local file = normalize_path(bufname)
    if file ~= '' then
      real_files[file] = true
    end
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for file in pairs(real_files) do
    local comments = state.comments[file]
    if comments then
      local to_remove = {}

      for lnum, comment in pairs(comments) do
        local render_lnum = get_render_lnum(bufnr, file, lnum)
        if render_lnum and render_lnum > 0 and render_lnum <= line_count then
          render(bufnr, file, lnum, comment)
        elseif not vim.b[bufnr].snacks_meta and not bufname:match("^codediff://") then
          table.insert(to_remove, lnum)
        end
      end

      for _, lnum in ipairs(to_remove) do
        comments[lnum] = nil
      end
    end
  end
end

---@param bufnr integer
---@param cursor_lnum? integer
---@return string? file, integer? lnum
function get_cursor_context(bufnr, cursor_lnum)
  cursor_lnum = cursor_lnum or vim.api.nvim_win_get_cursor(0)[1]
  local file = vim.api.nvim_buf_get_name(bufnr)
  
  if file:match("^codediff://") then
    if not codediff_session.orig_path and not codediff_session.mod_path then
      update_codediff_session()
    end
    local path
    if codediff_session.orig_buf and bufnr == codediff_session.orig_buf then
      path = codediff_session.orig_path
    elseif codediff_session.mod_buf and bufnr == codediff_session.mod_buf then
      path = codediff_session.mod_path
    else
      path = codediff_session.mod_path or codediff_session.orig_path
    end
    if path then
      return normalize_path(path), cursor_lnum
    end
    return nil, nil
  end

  if vim.b[bufnr].snacks_meta then
    local meta = vim.b[bufnr].snacks_meta
    -- Try to find the exact line
    if type(meta[cursor_lnum]) == 'table' and meta[cursor_lnum].diff and meta[cursor_lnum].diff.file then
      return normalize_path(meta[cursor_lnum].diff.file), meta[cursor_lnum].diff.line
    end
    -- Fallback: scan upwards
    for l = cursor_lnum - 1, 1, -1 do
      if type(meta[l]) == 'table' and meta[l].diff and meta[l].diff.file then
        return normalize_path(meta[l].diff.file), meta[l].diff.line
      end
    end
    -- Fallback: scan downwards
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for l = cursor_lnum + 1, line_count do
      if type(meta[l]) == 'table' and meta[l].diff and meta[l].diff.file then
        return normalize_path(meta[l].diff.file), meta[l].diff.line
      end
    end
    return nil, nil
  end

  return normalize_path(file), cursor_lnum
end

---@param file string
---@param bufnr? integer
---@return {lnum: integer, comment: NitComment}[]
local function get_sorted_comments(file, bufnr)
  local comments = state.comments[file]
  if not comments then return {} end

  local result = {}

  for stored_lnum, comment in pairs(comments) do
    local lnum = stored_lnum

    if bufnr and comment.extmarks and comment.extmarks[bufnr] then
      local extmark_lnum = get_extmark_lnum(bufnr, comment.extmarks[bufnr])
      if extmark_lnum then
        lnum = extmark_lnum
      else
        lnum = get_render_lnum(bufnr, file, stored_lnum) or stored_lnum
      end
    elseif bufnr then
      lnum = get_render_lnum(bufnr, file, stored_lnum) or stored_lnum
    end

    table.insert(result, { lnum = lnum, comment = comment })
  end

  table.sort(result, function(a, b) return a.lnum < b.lnum end)
  return result
end

---@return {file: string, lnum: integer, range_end: integer?, comment: NitComment, exists: boolean}[]
local function collect_comments()
  local items = {}

  for file, comments in pairs(state.comments) do
    local exists = file_exists(file)
    local bufnr = get_bufnr_for_file(file)

    for stored_lnum, comment in pairs(comments) do
      local lnum = stored_lnum
      local range_end = nil

      if bufnr and comment.extmarks and comment.extmarks[bufnr] then
        local start_lnum, end_lnum = get_extmark_range(bufnr, comment.extmarks[bufnr])
        if start_lnum then
          lnum = start_lnum
          range_end = end_lnum
        end
      end

      -- Fallback to stored range if extmark didn't provide end
      if not range_end and comment.range then
        range_end = comment.range.end_
      end

      -- Don't report range_end if same as lnum (single-line)
      if range_end and range_end == lnum then
        range_end = nil
      end

      table.insert(items, {
        file = file,
        lnum = lnum,
        range_end = range_end,
        comment = comment,
        exists = exists,
      })
    end
  end

  table.sort(items, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.lnum < b.lnum
  end)

  return items
end

---@param file string
local function sync_extmark_positions(file)
  local comments = state.comments[file]
  if not comments then return end

  local bufnr = get_bufnr_for_file(file)
  if not bufnr then return end

  local updated = {}
  local collisions = {}

  for stored_lnum, comment in pairs(comments) do
    local lnum = stored_lnum

    if comment.extmarks and comment.extmarks[bufnr] then
      local start_lnum, end_lnum = get_extmark_range(bufnr, comment.extmarks[bufnr])
      if start_lnum then
        lnum = start_lnum
        -- Update range from extmark-tracked positions
        if comment.range and end_lnum then
          comment.range.start = start_lnum
          comment.range.end_ = end_lnum
        end
      end
    end

    if updated[lnum] then
      -- Collision detected
      collisions[lnum] = collisions[lnum] or { updated[lnum] }
      table.insert(collisions[lnum], comment)
    else
      updated[lnum] = comment
    end
  end

  -- Resolve collisions by offsetting to next available line
  for lnum, coll_comments in pairs(collisions) do
    for i, comment in ipairs(coll_comments) do
      local offset_lnum = lnum + i - 1
      while updated[offset_lnum] do
        offset_lnum = offset_lnum + 1
      end
      updated[offset_lnum] = comment
    end
  end

  state.comments[file] = updated
end

---Sync extmark positions for a single buffer (used by autocmds)
---@param bufnr integer
local function sync_buf_extmarks(bufnr)
  if not is_valid_buf(bufnr) then return end
  local real_files = {}
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname:match("^codediff://") then
    local path = bufname:match("^codediff://[^/]+/(.+)%?") or bufname:match("^codediff://[^/]+/(.+)$")
    if path then real_files[normalize_path(path)] = true end
  elseif vim.b[bufnr].snacks_meta then
    for _, m in pairs(vim.b[bufnr].snacks_meta) do
      if type(m) == 'table' and m.diff and m.diff.file then
        real_files[normalize_path(m.diff.file)] = true
      end
    end
  else
    local file = normalize_path(bufname)
    if file ~= '' then real_files[file] = true end
  end

  for file in pairs(real_files) do
    sync_extmark_positions(file)
  end
end

-- Picker implementations

---Format the nit label for display in pickers
---@param comment NitComment
---@return string
local function format_nit_label(comment)
  return string.format('[nit] %s', comment.text)
end

---Format the line indicator for pickers (e.g., "42" or "10-15")
---@param item table collected comment item
---@return string
local function format_line_indicator(item)
  if item.range_end then
    return string.format('%d-%d', item.lnum, item.range_end)
  end
  return tostring(item.lnum)
end

---@param items table[]
local function list_snacks(items)
  local snacks = require('snacks')

  local picker_items = vim.tbl_map(function(item)
    local prefix = item.exists and '' or '[DELETED] '
    local label = format_nit_label(item.comment)
    return {
      text = string.format('%s%s', prefix, label),
      file = item.file,
      pos = { item.lnum, 0 },
      line_indicator = format_line_indicator(item),
      exists = item.exists,
    }
  end, items)

  snacks.picker({
    items = picker_items,
    format = function(item)
      if not item then return {} end
      local short = vim.fn.fnamemodify(item.file, ':~:.')
      local formatted = string.format('%s:%s %s', short, item.line_indicator, item.text)
      return { { formatted } }
    end,
    actions = {
      confirm = function(picker)
        local item = picker:current()
        if not item then return end
        picker:close()
        if item.exists then
          vim.cmd('edit ' .. vim.fn.fnameescape(item.file))
          vim.api.nvim_win_set_cursor(0, item.pos)
        else
          notify('File no longer exists: ' .. item.file, vim.log.levels.WARN)
        end
      end,
    },
  })
end

---@param items table[]
local function list_telescope(items)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'Nits',
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        local short = vim.fn.fnamemodify(item.file, ':~:.')
        local prefix = item.exists and '' or '[DELETED] '
        local label = format_nit_label(item.comment)
        local line_ind = format_line_indicator(item)
        local display = string.format('%s%s:%s %s', prefix, short, line_ind, label)
        return {
          value = item,
          display = display,
          ordinal = display,
          filename = item.file,
          lnum = item.lnum,
          exists = item.exists,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = conf.grep_previewer({}),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          if selection.exists then
            vim.cmd('edit ' .. vim.fn.fnameescape(selection.filename))
            vim.api.nvim_win_set_cursor(0, { selection.lnum, 0 })
          else
            notify('File no longer exists: ' .. selection.filename, vim.log.levels.WARN)
          end
        end
      end)
      return true
    end,
  }):find()
end

---@param items table[]
local function list_quickfix(items)
  local qf_items = vim.tbl_map(function(item)
    local prefix = item.exists and '' or '[DELETED] '
    local label = format_nit_label(item.comment)
    return {
      filename = item.file,
      lnum = item.lnum,
      col = 1,
      text = string.format('%s%s', prefix, label),
      type = 'N',
      valid = item.exists,
    }
  end, items)

  vim.fn.setqflist({}, ' ', {
    title = 'Nits',
    items = qf_items,
  })

  vim.cmd('copen')
end

-- PR import (gh CLI)

local GRAPHQL_PR_QUERY = [[
query($owner:String!,$repo:String!,$number:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$number){
      reviewThreads(first:100){
        nodes{
          id
          isResolved
          isOutdated
          comments(first:50){
            nodes{ author{login} body path line startLine originalLine }
          }
        }
      }
      comments(first:100){
        nodes{ author{login} body }
      }
    }
  }
}
]]

---@param cmd string[]
---@return boolean ok, string stdout, string stderr
local function run_cmd(cmd)
  local result = vim.system(cmd, { text = true }):wait()
  return result.code == 0, result.stdout or '', result.stderr or ''
end

---@param json string
---@return any?
local function json_decode(json)
  local ok, decoded = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
  if not ok then return nil end
  return decoded
end

---@return string? root absolute path to git toplevel
local function git_root()
  local ok, stdout = run_cmd({ 'git', 'rev-parse', '--show-toplevel' })
  if not ok then return nil end
  local trimmed = vim.trim(stdout)
  if trimmed == '' then return nil end
  return trimmed
end

---@param url string
---@return {owner:string, repo:string, number:integer}?
local function parse_pr_url(url)
  local owner, repo, num = url:match('github%.com/([^/]+)/([^/]+)/pull/(%d+)')
  if owner and repo and num then
    return { owner = owner, repo = repo, number = tonumber(num) }
  end
  return nil
end

---Detect PR for current branch via `gh pr view`, or parse URL if given.
---`gh pr view` resolves to the upstream PR even from a fork checkout,
---and the returned `url` field contains owner/repo/number directly.
---@param url? string
---@return {owner:string, repo:string, number:integer}?
local function detect_pr(url)
  if url then
    local parsed = parse_pr_url(url)
    if parsed then return parsed end
    notify('Invalid PR URL: ' .. url, vim.log.levels.ERROR)
    return nil
  end

  local ok, stdout, stderr = run_cmd({ 'gh', 'pr', 'view', '--json', 'url' })
  if not ok then
    local hint = vim.trim(stderr) ~= '' and ('\n' .. vim.trim(stderr)) or ''
    notify('No PR detected for current branch. Pass URL: :NitPr <url>' .. hint, vim.log.levels.ERROR)
    return nil
  end

  local decoded = json_decode(stdout)
  if not decoded or not decoded.url then
    notify('Failed to parse gh pr view output', vim.log.levels.ERROR)
    return nil
  end

  local parsed = parse_pr_url(decoded.url)
  if not parsed then
    notify('Could not parse PR URL from gh: ' .. decoded.url, vim.log.levels.ERROR)
    return nil
  end
  return parsed
end

---@param owner string
---@param repo string
---@param number integer
---@return {threads:table[], general:table[]}?
local function fetch_pr(owner, repo, number)
  local ok, stdout, stderr = run_cmd({
    'gh', 'api', 'graphql',
    '-F', 'owner=' .. owner,
    '-F', 'repo=' .. repo,
    '-F', 'number=' .. number,
    '-f', 'query=' .. GRAPHQL_PR_QUERY,
  })
  if not ok then
    notify('gh api graphql failed:\n' .. vim.trim(stderr), vim.log.levels.ERROR)
    return nil
  end

  local decoded = json_decode(stdout)
  if not decoded or not decoded.data or not decoded.data.repository
     or not decoded.data.repository.pullRequest then
    notify('Failed to parse PR data from gh', vim.log.levels.ERROR)
    return nil
  end

  local pr = decoded.data.repository.pullRequest
  local threads = (pr.reviewThreads and pr.reviewThreads.nodes) or {}
  local general = (pr.comments and pr.comments.nodes) or {}
  return { threads = threads, general = general }
end

---Pick the last comment in a thread that has a non-nil line anchor.
---@param comments table[]
---@return table?
local function pick_anchor_comment(comments)
  if not comments or #comments == 0 then return nil end
  for i = #comments, 1, -1 do
    if comments[i].line then return comments[i] end
  end
  return comments[#comments]
end

---@param comments table[]
---@return string
local function format_thread_body(comments)
  local parts = {}
  for _, c in ipairs(comments) do
    local author = (c.author and c.author.login) or 'unknown'
    table.insert(parts, string.format('@%s: %s', author, c.body or ''))
  end
  return table.concat(parts, '\n\n')
end

---@param comments table[]
---@return string
local function format_general_body(comments)
  local lines = { '[PR general comments]', '' }
  for i, c in ipairs(comments) do
    local author = (c.author and c.author.login) or 'unknown'
    table.insert(lines, string.format('@%s: %s', author, c.body or ''))
    if i < #comments then
      table.insert(lines, '')
    end
  end
  return table.concat(lines, '\n')
end

---Find the first changed file path that exists locally. Tries thread paths
---first, falls back to `gh pr diff --name-only`.
---@param threads table[]
---@param owner string
---@param repo string
---@param number integer
---@param root string
---@return string?
local function first_changed_file(threads, owner, repo, number, root)
  for _, thread in ipairs(threads) do
    local nodes = (thread.comments and thread.comments.nodes) or {}
    if nodes[1] and nodes[1].path then
      local abs = normalize_path(root .. '/' .. nodes[1].path)
      if file_exists(abs) then return abs end
    end
  end
  local ok, stdout = run_cmd({
    'gh', 'pr', 'diff', '--name-only',
    '--repo', owner .. '/' .. repo,
    tostring(number),
  })
  if ok and stdout then
    for line in stdout:gmatch('[^\n]+') do
      local abs = normalize_path(root .. '/' .. line)
      if file_exists(abs) then return abs end
    end
  end
  return nil
end

---Remove all PR-imported nits (source == 'pr') from state and clear extmarks.
---@return integer count number cleared
local function clear_imported()
  local count = 0
  for _, comments in pairs(state.comments) do
    local to_remove = {}
    for lnum, comment in pairs(comments) do
      if comment.source == 'pr' then
        if comment.extmarks then
          for b, e in pairs(comment.extmarks) do
            pcall(vim.api.nvim_buf_del_extmark, b, ns, e)
          end
        end
        table.insert(to_remove, lnum)
        count = count + 1
      end
    end
    for _, lnum in ipairs(to_remove) do
      comments[lnum] = nil
    end
  end
  return count
end

---Write a comment to state without rendering. Caller invokes
---refresh_loaded_buffers() once after batch.
---@param file string normalized absolute path
---@param lnum integer 1-indexed
---@param text string
---@param range? NitRange
---@param opts? { source?: string, thread_id?: string }
local function add_for_file(file, lnum, text, range, opts)
  opts = opts or {}
  state.comments[file] = state.comments[file] or {}

  local old = state.comments[file][lnum]
  if old and old.extmarks then
    for b, e in pairs(old.extmarks) do
      pcall(vim.api.nvim_buf_del_extmark, b, ns, e)
    end
  end

  state.comments[file][lnum] = {
    text = text,
    extmarks = {},
    range = range,
    source = opts.source,
    thread_id = opts.thread_id,
  }
end

---Re-render all comments in every loaded valid buffer.
local function refresh_loaded_buffers()
  for _, bufinfo in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
    if is_valid_buf(bufinfo.bufnr) then
      restore_comments(bufinfo.bufnr)
    end
  end
end

-- Public API

---@param bufnr? integer
---@param lnum? integer 1-indexed start line in buffer
---@param text string
---@param range? NitRange
function M.add(bufnr, lnum, text, range)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not is_valid_buf(bufnr) then
    notify('Cannot add comment to this buffer type', vim.log.levels.WARN)
    return
  end

  local file, real_lnum = get_cursor_context(bufnr, lnum)
  if not file or file == '' then
    notify('Cannot add comment to unnamed buffer', vim.log.levels.WARN)
    return
  end
  if not real_lnum then
    notify('Could not resolve line number in buffer', vim.log.levels.WARN)
    return
  end

  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]

  sync_extmark_positions(file)

  state.comments[file] = state.comments[file] or {}

  ---@type NitComment
  local comment = {
    text = text,
    extmarks = {},
    range = range,
  }

  local old = state.comments[file][real_lnum]
  if old and old.extmarks then
    for b, e in pairs(old.extmarks) do
      pcall(vim.api.nvim_buf_del_extmark, b, ns, e)
    end
  end

  state.comments[file][real_lnum] = comment
  render(bufnr, file, real_lnum, comment)

  for _, bufinfo in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
    local b = bufinfo.bufnr
    if b ~= bufnr then
      restore_comments(b)
    end
  end
end

function M.delete()
  local bufnr = vim.api.nvim_get_current_buf()
  local file, cursor_lnum = get_cursor_context(bufnr)

  if not file or file == '' then return end

  sync_extmark_positions(file)

  local found_lnum, comment = find_comment_at(file, bufnr, cursor_lnum)

  if not found_lnum or not comment then
    notify('No comment at cursor', vim.log.levels.WARN)
    return
  end

  if comment.extmarks then
    for b, e in pairs(comment.extmarks) do
      pcall(vim.api.nvim_buf_del_extmark, b, ns, e)
    end
  end

  state.comments[file][found_lnum] = nil
  notify('Deleted comment')
end

function M.next()
  local bufnr = vim.api.nvim_get_current_buf()
  local file, cursor = get_cursor_context(bufnr)
  if not file or file == '' then return end
  local sorted = get_sorted_comments(file, bufnr)

  if #sorted == 0 then
    notify('No comments in buffer')
    return
  end

  for _, item in ipairs(sorted) do
    if item.lnum > cursor then
      vim.api.nvim_win_set_cursor(0, { item.lnum, 0 })
      vim.cmd('normal! zz')
      return
    end
  end

  vim.api.nvim_win_set_cursor(0, { sorted[1].lnum, 0 })
  vim.cmd('normal! zz')
  if config.notify_wrap then
    notify('Wrapped to first comment')
  end
end

function M.prev()
  local bufnr = vim.api.nvim_get_current_buf()
  local file, cursor = get_cursor_context(bufnr)
  if not file or file == '' then return end
  local sorted = get_sorted_comments(file, bufnr)

  if #sorted == 0 then
    notify('No comments in buffer')
    return
  end

  for i = #sorted, 1, -1 do
    if sorted[i].lnum < cursor then
      vim.api.nvim_win_set_cursor(0, { sorted[i].lnum, 0 })
      vim.cmd('normal! zz')
      return
    end
  end

  vim.api.nvim_win_set_cursor(0, { sorted[#sorted].lnum, 0 })
  vim.cmd('normal! zz')
  if config.notify_wrap then
    notify('Wrapped to last comment')
  end
end

---@return string[] sorted list of files with at least one comment
local function get_files_with_comments()
  local files = {}
  for f, comments in pairs(state.comments) do
    if next(comments) then
      table.insert(files, f)
    end
  end
  table.sort(files)
  return files
end

---@param dir 'next'|'prev'
local function nav_global(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local file, cursor = get_cursor_context(bufnr)

  -- Try in-buffer first (no wrap)
  if file and file ~= '' then
    local sorted = get_sorted_comments(file, bufnr)
    if dir == 'next' then
      for _, item in ipairs(sorted) do
        if item.lnum > cursor then
          vim.api.nvim_win_set_cursor(0, { item.lnum, 0 })
          vim.cmd('normal! zz')
          return
        end
      end
    else
      for i = #sorted, 1, -1 do
        if sorted[i].lnum < cursor then
          vim.api.nvim_win_set_cursor(0, { sorted[i].lnum, 0 })
          vim.cmd('normal! zz')
          return
        end
      end
    end
  end

  -- Jump to next/prev file
  local files = get_files_with_comments()
  if #files == 0 then
    notify('No comments')
    return
  end

  local cur_idx
  for i, f in ipairs(files) do
    if f == file then cur_idx = i; break end
  end

  local next_idx
  if cur_idx then
    if #files == 1 then
      -- Only one file with comments; wrap within current file
      local sorted = get_sorted_comments(file, bufnr)
      if #sorted == 0 then return end
      local target = dir == 'next' and sorted[1] or sorted[#sorted]
      vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
      vim.cmd('normal! zz')
      if config.notify_wrap then
        notify(dir == 'next' and 'Wrapped to first comment' or 'Wrapped to last comment')
      end
      return
    end
    if dir == 'next' then
      next_idx = (cur_idx % #files) + 1
    else
      next_idx = ((cur_idx - 2) % #files) + 1
    end
  else
    next_idx = dir == 'next' and 1 or #files
  end

  local target_file = files[next_idx]
  if not file_exists(target_file) then
    notify('File no longer exists: ' .. target_file, vim.log.levels.WARN)
    return
  end

  vim.cmd('edit ' .. vim.fn.fnameescape(target_file))
  vim.schedule(function()
    local new_bufnr = vim.api.nvim_get_current_buf()
    local sorted = get_sorted_comments(target_file, new_bufnr)
    if #sorted == 0 then return end
    local target = dir == 'next' and sorted[1] or sorted[#sorted]
    vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
    vim.cmd('normal! zz')
  end)
end

function M.next_global()
  nav_global('next')
end

function M.prev_global()
  nav_global('prev')
end

---@param opts? {line1?: integer, line2?: integer}
function M.input(opts)
  opts = opts or {}
  local target_buf = vim.api.nvim_get_current_buf()
  if not is_valid_buf(target_buf) then
    notify('Cannot add comment to this buffer type', vim.log.levels.WARN)
    return
  end

  local file = normalize_path(vim.api.nvim_buf_get_name(target_buf))
  if file == '' then
    notify('Cannot add comment to unnamed buffer', vim.log.levels.WARN)
    return
  end

  local line1 = opts.line1
  local line2 = opts.line2

  -- Default to cursor line if no range provided
  if not line1 then
    line1 = vim.api.nvim_win_get_cursor(0)[1]
    line2 = line1
  end

  -- Clamp to buffer bounds
  local line_count = vim.api.nvim_buf_line_count(target_buf)
  line1 = math.max(1, math.min(line1, line_count))
  line2 = math.max(1, math.min(line2, line_count))

  -- Ensure line1 <= line2
  if line1 > line2 then
    line1, line2 = line2, line1
  end

  local file1, real_line1 = get_cursor_context(target_buf, line1)
  local file2, real_line2 = get_cursor_context(target_buf, line2)

  if not file1 or file1 == '' then
    notify('Cannot add comment to unnamed buffer', vim.log.levels.WARN)
    return
  end
  if not real_line1 then
    notify('Could not resolve real file context for start line', vim.log.levels.WARN)
    return
  end
  if not real_line2 then
    notify('Could not resolve real file context for end line', vim.log.levels.WARN)
    return
  end
  if file1 ~= file2 then
    notify('Selection spans multiple files', vim.log.levels.WARN)
    return
  end

  local file = file1
  -- Ensure real_line1 <= real_line2
  if real_line1 > real_line2 then
    real_line1, real_line2 = real_line2, real_line1
  end

  local is_range = real_line1 ~= real_line2
  ---@type NitRange?
  local range = is_range and { start = real_line1, end_ = real_line2 } or nil

  sync_extmark_positions(file)

  -- Look for existing comment
  local existing_lnum, existing = find_comment_at(file, target_buf, line1)

  local prefill = ''

  if existing then
    prefill = existing.text
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'nit_input'

  local width = math.min(70, vim.o.columns - 4)
  local height = 5

  local title
  if is_range then
    title = string.format(' [nit L%d-%d] ', real_line1, real_line2)
  else
    title = ' [nit] '
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
    footer = ' Enter: submit | Esc/q: cancel ',
    footer_pos = 'center',
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  if prefill ~= '' then
    local prefill_lines = vim.split(prefill, '\n')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, prefill_lines)
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        local last_line = #prefill_lines
        local last_col = #prefill_lines[last_line]
        vim.api.nvim_win_set_cursor(win, { last_line, last_col })
      end
    end)
  end

  local closed = false

  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd('stopinsert')
  end

  local function submit()
    if closed or not vim.api.nvim_buf_is_valid(buf) then return end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, '\n'))
    close()

    if text == '' then
      if existing and existing_lnum then
        if existing.extmarks then
          for b, e in pairs(existing.extmarks) do
            pcall(vim.api.nvim_buf_del_extmark, b, ns, e)
          end
        end
        state.comments[file][existing_lnum] = nil
        notify('Deleted comment')
      end
      return
    end

    if existing and existing_lnum then
      if existing.extmarks then
        for b, e in pairs(existing.extmarks) do
          pcall(vim.api.nvim_buf_del_extmark, b, ns, e)
        end
      end
      state.comments[file][existing_lnum] = nil
    end

    M.add(target_buf, line1, text, range)
    notify(existing and 'Updated comment' or 'Added comment')
  end

  local kopts = { buffer = buf, nowait = true }

  -- Submit
  vim.keymap.set('n', '<CR>', submit, kopts)
  vim.keymap.set('i', '<C-CR>', submit, kopts)

  -- Cancel
  vim.keymap.set('n', '<Esc>', close, kopts)
  vim.keymap.set('n', 'q', close, kopts)

  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = close,
  })

  vim.cmd('startinsert!')
end

function M.list()
  local items = collect_comments()

  if #items == 0 then
    notify('No comments')
    return
  end

  local picker = detect_picker()

  if picker == 'snacks' then
    list_snacks(items)
  elseif picker == 'telescope' then
    list_telescope(items)
  else
    list_quickfix(items)
  end
end

function M.export()
  local items = collect_comments()

  if #items == 0 then
    notify('No comments to export', vim.log.levels.WARN)
    return
  end

  local deleted_files = {}
  for _, item in ipairs(items) do
    if not item.exists and not deleted_files[item.file] then
      deleted_files[item.file] = true
    end
  end

  if next(deleted_files) then
    local count = vim.tbl_count(deleted_files)
    notify(string.format('Warning: %d file(s) no longer exist', count), vim.log.levels.WARN)
  end

  local include_code = config.export.include_code
  local lines = {
    'I reviewed your code and have the following comments. Please address them.',
    '',
  }

  for i, item in ipairs(items) do
    local filepath = vim.fn.fnamemodify(item.file, ':~:.')
    local lang = get_language(item.file)
    local has_range = item.range_end ~= nil

    if include_code then
      -- Header (file path only, line info goes in code fence)
      table.insert(lines, string.format('%d. [nit] %s', i, filepath))
      table.insert(lines, '')

      -- Code block with live content from buffer or disk
      if item.exists then
        local bufnr = get_bufnr_for_file(item.file)
        local start_lnum = item.lnum
        local end_lnum = item.range_end or item.lnum
        local current_lines = read_current_lines(item.file, bufnr, start_lnum, end_lnum)

        if current_lines and #current_lines > 0 then
          if has_range then
            table.insert(lines, string.format('```%s %s:%d-%d', lang, filepath, start_lnum, end_lnum))
          else
            table.insert(lines, string.format('```%s %s:%d', lang, filepath, start_lnum))
          end
          for _, line in ipairs(current_lines) do
            table.insert(lines, line)
          end
          table.insert(lines, '```')
          table.insert(lines, '')
        end
      end
    else
      -- No code snippets: header includes file path and line indicator
      if has_range then
        table.insert(lines, string.format('%d. [nit] `%s:%d-%d`', i, filepath, item.lnum, item.range_end))
      else
        table.insert(lines, string.format('%d. [nit] `%s:%d`', i, filepath, item.lnum))
      end
      table.insert(lines, '')
    end

    -- Comment
    table.insert(lines, string.format('_Comment_: %s', item.comment.text))

    -- Deleted file warning
    if not item.exists then
      table.insert(lines, '')
      table.insert(lines, '⚠️  _Warning: File has been deleted_')
    end

    table.insert(lines, '')
  end

  local export_text = table.concat(lines, '\n')

  -- Try clipboard registers in order of preference
  local success = false
  local registers = { '+', '*', '"' }  -- system clipboard, selection, unnamed

  for _, reg in ipairs(registers) do
    local ok = pcall(vim.fn.setreg, reg, export_text)
    if ok then
      success = true
      if reg == '+' or reg == '*' then
        notify(string.format('Exported %d comments to system clipboard', #items))
      else
        notify(string.format('Exported %d comments to register "%s" (clipboard unavailable)', #items, reg))
      end
      break
    end
  end

  if not success then
    notify('Failed to export: clipboard unavailable. Install +clipboard support or xclip/xsel',
      vim.log.levels.ERROR)
  end
end

---Import unresolved PR comments as nits via `gh` CLI.
---Each unresolved review thread becomes one nit (all replies collapsed).
---PR-level (issue) comments are combined into a single nit anchored at
---line 1 of the first changed file. Outdated comments (no current line)
---are skipped. Re-running clears previously imported nits first.
---@param url? string PR URL; if omitted, auto-detects from current branch
function M.pr(url)
  if vim.fn.executable('gh') == 0 then
    notify('gh CLI not installed. See https://cli.github.com', vim.log.levels.ERROR)
    return
  end

  notify('Fetching PR comments...')

  local pr = detect_pr(url)
  if not pr then return end

  local data = fetch_pr(pr.owner, pr.repo, pr.number)
  if not data then return end

  local root = git_root()
  if not root then
    notify('Not in a git repository', vim.log.levels.ERROR)
    return
  end

  local cleared = clear_imported()

  local imported = 0
  local outdated = 0
  local missing = 0

  for _, thread in ipairs(data.threads) do
    if not thread.isResolved then
      local nodes = (thread.comments and thread.comments.nodes) or {}
      local anchor = pick_anchor_comment(nodes)
      if anchor then
        if not anchor.line then
          outdated = outdated + 1
        else
          local file_abs = normalize_path(root .. '/' .. anchor.path)
          if not file_exists(file_abs) then
            missing = missing + 1
          else
            local body = format_thread_body(nodes)
            local range = nil
            if anchor.startLine and anchor.startLine ~= anchor.line then
              local start_l = math.min(anchor.startLine, anchor.line)
              local end_l = math.max(anchor.startLine, anchor.line)
              range = { start = start_l, end_ = end_l }
            end
            add_for_file(file_abs, anchor.line, body, range, {
              source = 'pr',
              thread_id = thread.id,
            })
            imported = imported + 1
          end
        end
      end
    end
  end

  local general_count = 0
  if #data.general > 0 then
    local anchor_file = first_changed_file(data.threads, pr.owner, pr.repo, pr.number, root)
    if anchor_file then
      local body = format_general_body(data.general)
      add_for_file(anchor_file, 1, body, nil, {
        source = 'pr',
        thread_id = 'pr-general',
      })
      general_count = #data.general
    else
      notify('No anchor file found for PR general comments; skipped', vim.log.levels.WARN)
    end
  end

  refresh_loaded_buffers()

  notify(string.format(
    'PR #%d: imported %d threads, %d general (%d outdated, %d missing skipped). Cleared %d previous.',
    pr.number, imported, general_count, outdated, missing, cleared
  ))
end

function M.clear()
  local total = M.count()

  if total == 0 then
    notify('No comments to clear')
    return
  end

  local function do_clear()
    for file in pairs(state.comments) do
      for _, bufinfo in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
        if normalize_path(bufinfo.name) == file then
          vim.api.nvim_buf_clear_namespace(bufinfo.bufnr, ns, 0, -1)
        end
      end
    end
    state.comments = {}
    notify(string.format('Cleared %d comments', total))
  end

  if config.confirm_clear then
    vim.ui.select({ 'Yes', 'No' }, {
      prompt = string.format('Clear all %d comments?', total),
    }, function(choice)
      if choice == 'Yes' then
        do_clear()
      end
    end)
  else
    do_clear()
  end
end

---Get all comments for a file or all files
---@param file? string Optional file path (normalized). If nil, returns all comments.
---@return table<string, table<integer, NitComment>>
function M.get_comments(file)
  if file then
    local normalized = normalize_path(file)
    return vim.deepcopy(state.comments[normalized] or {})
  else
    return vim.deepcopy(state.comments)
  end
end

---@return integer
function M.count()
  local count = 0
  for _, comments in pairs(state.comments) do
    count = count + vim.tbl_count(comments)
  end
  return count
end

---@return table<string, integer>
function M.count_by_file()
  local counts = {}
  for file, comments in pairs(state.comments) do
    local short = vim.fn.fnamemodify(file, ':~:.')
    counts[short] = vim.tbl_count(comments)
  end
  return counts
end

---@param opts? NitOpts
function M.setup(opts)
  if state.initialized then
    return
  end

  opts = opts or {}
  vim.validate({
    opts = { opts, 'table' },
    picker = { opts.picker, 'string', true },
    confirm_clear = { opts.confirm_clear, 'boolean', true },
    notify_wrap = { opts.notify_wrap, 'boolean', true },
    export = { opts.export, 'table', true },
  })

  if opts.export then
    vim.validate({
      include_code = { opts.export.include_code, 'boolean', true },
    })
  end

  config = vim.tbl_deep_extend('force', config, opts)

  -- Define highlight group for range comments (subtle background)
  vim.api.nvim_set_hl(0, 'NitRange', { default = true, link = 'CursorLine' })

  -- Create augroup
  augroup = vim.api.nvim_create_augroup('nit', { clear = true })

  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = augroup,
    callback = function(ev)
      if is_valid_buf(ev.buf) then
        restore_comments(ev.buf)
      end
      -- Fallback for dynamic buffers (snacks diff, codediff)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) and is_valid_buf(ev.buf) then
          restore_comments(ev.buf)
        end
      end, 100)
    end,
  })

  -- Explicit hooks for codediff
  vim.api.nvim_create_autocmd('User', {
    pattern = { 'CodeDiffOpen', 'CodeDiffFileSelect' },
    group = augroup,
    callback = function()
      vim.defer_fn(function()
        update_codediff_session()
        for _, b in ipairs({ codediff_session.orig_buf, codediff_session.mod_buf }) do
          if b and vim.api.nvim_buf_is_valid(b) then
            restore_comments(b)
          end
        end
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd('TabEnter', {
    group = augroup,
    callback = function()
      vim.defer_fn(update_codediff_session, 100)
    end,
  })

  -- Sync extmark positions back to state when leaving buffers/windows
  -- This ensures line numbers stay correct after edits, including autoformat
  vim.api.nvim_create_autocmd({ 'BufLeave', 'BufWritePost', 'WinLeave' }, {
    group = augroup,
    callback = function(ev)
      sync_buf_extmarks(ev.buf)
    end,
  })

  -- Sync all files before Neovim exits
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function()
      for file, _ in pairs(state.comments) do
        local bufnr = get_bufnr_for_file(file)
        if bufnr then
          sync_buf_extmarks(bufnr)
        end
      end
    end,
  })

  local commands = {
    NitDelete = { fn = M.delete, desc = 'Delete comment at cursor' },
    NitList = { fn = M.list, desc = 'List all comments' },
    NitExport = { fn = M.export, desc = 'Export comments to clipboard' },
    NitClear = { fn = M.clear, desc = 'Clear all comments' },
    NitNext = { fn = M.next, desc = 'Go to next comment' },
    NitPrev = { fn = M.prev, desc = 'Go to previous comment' },
    NitNextGlobal = { fn = M.next_global, desc = 'Go to next comment (cross-file)' },
    NitPrevGlobal = { fn = M.prev_global, desc = 'Go to previous comment (cross-file)' },
  }

  for name, cmd in pairs(commands) do
    vim.api.nvim_create_user_command(name, cmd.fn, { desc = cmd.desc })
  end

  -- NitPr accepts an optional URL argument
  vim.api.nvim_create_user_command('NitPr', function(cmd_opts)
    local arg = cmd_opts.args ~= '' and cmd_opts.args or nil
    M.pr(arg)
  end, { nargs = '?', desc = 'Import unresolved PR comments as nits' })

  -- NitAdd supports range for visual selection and command ranges
  vim.api.nvim_create_user_command('NitAdd', function(cmd_opts)
    local input_opts = {}
    -- Only pass range if explicitly given (visual selection or :10,15NitAdd)
    if cmd_opts.range > 0 then
      input_opts.line1 = cmd_opts.line1
      input_opts.line2 = cmd_opts.line2
    end
    M.input(input_opts)
  end, { desc = 'Add or edit comment', range = true })

  state.initialized = true
end

return M
