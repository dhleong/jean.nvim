local M = {}

function M.prompt()
  local session = require('jean.session').from_buffer()
  session:capture_context_source()
  local window = require('jean.window').open(session)

  -- Always move the cursor to the end to be ready for input
  window:move_cursor_to_end()
end

---@param prompt string
function M.submit(prompt)
  local session = require('jean.session').from_buffer()
  session:capture_context_source()
  require('jean.window').open(session, { startinsert = false })
  session:submit_prompt(prompt, { echo = true })
end

---Open a floating prompt at the cursor; the response shows as a chip on this line
function M.prompt_inline()
  require('jean.inline').prompt()
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

  if opts and opts.thread_store then
    Config.thread_store = opts.thread_store
  end

  -- TODO
end

return M
