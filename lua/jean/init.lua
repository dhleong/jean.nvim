local M = {}

function M.prompt()
  local session = require('jean.session').from_buffer()
  require('jean.window').open(session)
  -- TODO: Replace unused context in the buffer
end

function M.setup(opts)
  -- TODO
end

return M
