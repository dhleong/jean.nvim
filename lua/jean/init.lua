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

---Open a floating prompt at the cursor: a new thread on this line, or a reply
---in the thread already there
function M.prompt_inline()
  require('jean.inline').prompt()
end

---Jump to the next thread in this buffer, wrapping around
function M.next_thread()
  require('jean.inline').next_thread()
end

---Jump to the previous thread in this buffer, wrapping around
function M.prev_thread()
  require('jean.inline').prev_thread()
end

---Pick a thread in the project to jump to, or fill the quickfix list with them
function M.threads()
  require('jean.inline').threads()
end

---Re-attach a detached thread of this buffer to the cursor line
function M.attach_thread()
  require('jean.inline').attach_thread()
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
