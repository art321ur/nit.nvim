local M = {}

function M.check()
  vim.health.start('nit.nvim')

  -- Check Neovim version
  local nvim_version = vim.version()
  if nvim_version.major == 0 and nvim_version.minor < 10 then
    vim.health.error('Neovim 0.10+ required', {
      'Current version: ' .. vim.inspect(nvim_version),
      'Upgrade Neovim to use nit.nvim'
    })
  else
    vim.health.ok('Neovim version ' .. vim.inspect(nvim_version))
  end

  -- Check clipboard support
  if vim.fn.has('clipboard') == 1 then
    vim.health.ok('Clipboard support available')
  else
    vim.health.warn('Clipboard support not available', {
      'Export will fall back to unnamed register',
      'Install xclip or xsel on Linux for system clipboard'
    })
  end

  -- Check picker availability
  local has_snacks, snacks = pcall(require, 'snacks')
  local has_telescope = pcall(require, 'telescope')

  if has_snacks and snacks.picker then
    vim.health.ok('snacks.nvim with picker available')
  elseif has_snacks then
    vim.health.warn('snacks.nvim installed but picker not available')
  else
    vim.health.info('snacks.nvim not installed (optional)')
  end

  if has_telescope then
    vim.health.ok('telescope.nvim available')
  else
    vim.health.info('telescope.nvim not installed (optional)')
  end

  vim.health.info('Quickfix picker always available (built-in)')

  -- Check gh CLI (required for :NitPr)
  if vim.fn.executable('gh') == 1 then
    local out = vim.fn.system({ 'gh', 'auth', 'status' })
    if vim.v.shell_error == 0 then
      vim.health.ok('gh CLI: installed and authenticated')
    else
      vim.health.warn('gh CLI installed but not authenticated', {
        'Run: gh auth login',
        'Required for :NitPr',
        tostring(out),
      })
    end
  else
    vim.health.info('gh CLI not installed (only required for :NitPr)')
  end

  -- Check if initialized
  local ok, nit = pcall(require, 'nit')
  if ok then
    vim.health.ok('nit.nvim loaded successfully')
  else
    vim.health.error('Failed to load nit.nvim', { tostring(nit) })
  end
end

return M
