local M = {}

function M.prompt()
  local session = require('jean.session').from_buffer()
  require('jean.window').open(session)
end

---@param prompt string
function M.submit(prompt)
  local session = require('jean.session').from_buffer()
  local win = require('jean.window').open(session, { startinsert = false })
  win:append_lines_and_follow(prompt)
  session:submit_prompt(prompt)
end

function M.setup(opts)
  -- TODO
end

return M
