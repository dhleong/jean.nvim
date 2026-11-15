local M = {}

function M.prompt()
  local session = require('jean.session').from_buffer()
  local window = require('jean.window').open(session)

  -- Always move the cursor to the end to be ready for input
  window:move_cursor_to_end()
end

---@param prompt string
function M.submit(prompt)
  local session = require('jean.session').from_buffer()
  local win = require('jean.window').open(session, { startinsert = false })
  win:append_lines_and_follow(prompt)
  session:submit_prompt(prompt)
end

function M.setup(opts)
  local Config = require('jean.config')
  if opts and opts.provider then
    if not Config.VALID_PROVIDERS[opts.provider] then
      print('[jean.nvim] Invalid provider:', opts.provider)
    else
      Config._provider = opts.provider
    end
  end

  -- TODO
end

return M
