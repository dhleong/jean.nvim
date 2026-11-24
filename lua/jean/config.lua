local M = {}

M.VALID_PROVIDERS = {
  -- Names of modules under `jean.session`:
  claude = true,
  pi = true,
}
M._provider = 'claude'

---@param session Session
---@diagnostic disable-next-line: unused-local
function M.create_provider(session)
  -- TODO: We could support a functional _provider value to select
  -- based on pwd

  -- Validate again, just in time
  local provider = M._provider
  if not M.VALID_PROVIDERS[provider] then
    error('[jean.nvim] Invalid provider: ' .. provider)
  end

  return require('jean.session.' .. provider)
end

---@type ThreadStore
M.thread_store = require('jean.threads.memory'):new()

M.request_separator = '## Request'
M.dismiss_window_after_edits = true
M.window = {
  border = 'solid',
}

return M
