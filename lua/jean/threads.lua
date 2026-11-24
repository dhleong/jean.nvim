---Inline conversation threads: each is anchored to a line of a file and has its
---own list of prompt/response exchanges.
---
---Leading-id convention: pi-build writes plan lines that start with an id such
---as `T3`, `C2`, `Q4` or `PQ1`. After optional markdown markers (`#`s, list
---bullets, `1.`, `>`, `**`, `[ ]`, spaces) the first token matching `^%u+%d+`
---that is followed by a non-alphanumeric character (or end of line) is the
---line's id: `### T3 · title` -> T3, `- **C2.** Should…` -> C2, `Q4: …` -> Q4,
---`PQ1 …` -> PQ1. The id survives rewording, so a thread can re-attach to its
---line after the file is rewritten on disk.
---
---Threads are persisted through a ThreadStore (`thread_store` in setup()). Its
---methods run inside a coroutine (see `run` and `await`), so an implementation
---may yield on async I/O. A Notion or file-backed store can inflate threads
---(and their exchanges) for a path when a document opens, via `load`.

---@alias ThreadStatus 'queued'|'running'|'done'|'error'

---@class ThreadExchange
---@field prompt string
---@field blocks table[] response blocks
---@field status ThreadStatus
---@field error string?

---@class Thread
---@field id string
---@field path string absolute file path
---@field bufnr integer?
---@field extmark integer?
---@field anchor_text string
---@field anchor_key string?
---@field last_row integer 1-based
---@field detached boolean
---@field exchanges ThreadExchange[]
---@field created_at integer
---@field updated_at integer

---@class ThreadStore
---@field load fun(self: ThreadStore, path: string): Thread[]
---@field save fun(self: ThreadStore, thread: Thread)
---@field remove fun(self: ThreadStore, thread: Thread)

local M = {}

local ns = vim.api.nvim_create_namespace('jean.threads')
local ANCHOR_MAX = 120

---@type table<string, Thread>
M.by_id = {}
local next_id = 0

---@return ThreadStore
function M.store()
  local store = require('jean.config').thread_store
  if not store then
    store = require('jean.threads.memory'):new()
    require('jean.config').thread_store = store
  end
  return store
end

---Run `fn` in a coroutine so store calls may yield
---@param fn fun(...)
function M.run(fn, ...)
  coroutine.wrap(fn)(...)
end

---Yield the running coroutine until `start`'s callback fires; the coroutine
---is resumed on the main loop, so it is safe to call from fast events.
---@param start fun(callback: fun(...))
---@return any ...
function M.await(start)
  local co = assert(coroutine.running(), 'thread.await must be called inside thread.run')
  start(function(...)
    local args = vim.F.pack_len(...)
    vim.schedule(function()
      assert(coroutine.resume(co, vim.F.unpack_len(args)))
    end)
  end)
  return coroutine.yield()
end

---@param line string
---@return string?
function M.leading_id(line)
  local rest = line
  while true do
    local stripped = rest
      :gsub('^%s+', '')
      :gsub('^#+', '')
      :gsub('^[-*+]%s', '')
      :gsub('^%d+[.)]%s', '')
      :gsub('^>', '')
      :gsub('^%*%*', '')
      :gsub('^%[.%]', '')
    if stripped == rest then
      break
    end
    rest = stripped
  end
  local id, after = rest:match('^(%u+%d+)(.?)')
  if id and not after:match('^%w') then
    return id
  end
end

---@param opts { path: string, bufnr?: integer, row: integer, text: string }
---@return Thread
function M.create(opts)
  next_id = next_id + 1
  local now = os.time()
  ---@type Thread
  local thread = {
    id = 't' .. next_id,
    path = opts.path,
    bufnr = opts.bufnr,
    anchor_text = opts.text,
    anchor_key = M.leading_id(opts.text),
    last_row = opts.row,
    detached = false,
    exchanges = {},
    created_at = now,
    updated_at = now,
  }
  if opts.bufnr then
    M.bind(thread, opts.bufnr)
  end
  M.by_id[thread.id] = thread
  return thread
end

---Track the thread in a loaded buffer with a new extmark at `last_row`
---(clamped to the buffer). Deleting its line invalidates the extmark.
---@param thread Thread
---@param bufnr integer
function M.bind(thread, bufnr)
  local row = math.min(thread.last_row, vim.api.nvim_buf_line_count(bufnr))
  thread.bufnr = bufnr
  thread.extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, { invalidate = true })
end

---@param thread Thread
function M.delete(thread)
  if thread.bufnr and thread.extmark and vim.api.nvim_buf_is_valid(thread.bufnr) then
    vim.api.nvim_buf_del_extmark(thread.bufnr, ns, thread.extmark)
  end
  M.by_id[thread.id] = nil
end

---Follow the extmark: update `last_row`, and `anchor_text` if the user edited
---that line. Deleting the line detaches the thread, keeping its anchor.
---@param thread Thread
function M.sync(thread)
  if not (thread.bufnr and thread.extmark) or thread.detached then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(thread.bufnr, ns, thread.extmark, { details = true })
  if #pos == 0 then
    return
  end
  if pos[3].invalid then
    thread.detached = true
    return
  end
  thread.last_row = pos[1] + 1
  local line = vim.api.nvim_buf_get_lines(thread.bufnr, pos[1], pos[1] + 1, false)[1]
  if line and line ~= thread.anchor_text then
    thread.anchor_text = line
    thread.anchor_key = M.leading_id(line) or thread.anchor_key
  end
end

---@param thread Thread
---@param row integer
function M.attach(thread, row)
  thread.last_row = row
  thread.detached = false
  if thread.bufnr and thread.extmark then
    vim.api.nvim_buf_set_extmark(thread.bufnr, ns, row - 1, 0, { id = thread.extmark, invalidate = true })
  end
end

---Re-attach after the file's lines changed behind our back: same text (closest
---to `last_row`), else same leading id, else detached (history is kept).
---@param thread Thread
---@param lines string[]
---@return boolean attached
function M.reanchor(thread, lines)
  local function find(matches)
    local best
    for row, line in ipairs(lines) do
      if matches(line) and (not best or math.abs(row - thread.last_row) < math.abs(best - thread.last_row)) then
        best = row
      end
    end
    return best
  end

  local row = find(function(line)
    return line == thread.anchor_text
  end)
  if not row and thread.anchor_key then
    row = find(function(line)
      return M.leading_id(line) == thread.anchor_key
    end)
    if row then
      thread.anchor_text = lines[row]
    end
  end

  if row then
    M.attach(thread, row)
    return true
  end
  thread.detached = true
  return false
end

---@param thread Thread
---@param text string
---@param opts { pwd: string, row?: integer }
---@return string
function M.format_prompt(thread, text, opts)
  local path = thread.path
  local prefix = opts.pwd:gsub('/$', '') .. '/'
  if vim.startswith(path, prefix) then
    path = path:sub(#prefix + 1)
  end
  local anchor = vim.trim(thread.anchor_text)
  if vim.fn.strchars(anchor) > ANCHOR_MAX then
    anchor = vim.fn.strcharpart(anchor, 0, ANCHOR_MAX - 1) .. '…'
  end
  return ('[jean thread %s · %s · near line %d · "%s"]\n%s'):format(
    thread.id,
    path,
    opts.row or thread.last_row,
    anchor,
    text
  )
end

---@param text string
---@return { id: string, path: string, row: integer, anchor: string, text: string }?
function M.parse_header(text)
  local header, body = text:match('^(%[jean thread [^\n]*%])\n(.*)$')
  if not header then
    header = text:match('^(%[jean thread [^\n]*%])$')
    body = ''
  end
  if not header then
    return
  end
  local id, path, row, anchor = header:match('^%[jean thread (%S+) · (.-) · near line (%d+) · "(.*)"%]$')
  if id then
    return { id = id, path = path, row = tonumber(row), anchor = anchor, text = body }
  end
end

---@param path string
---@return Thread[]
function M.load(path)
  local threads = M.store():load(path)
  for _, thread in ipairs(threads) do
    M.by_id[thread.id] = thread
  end
  return threads
end

---@param thread Thread
function M.save(thread)
  thread.updated_at = os.time()
  M.store():save(thread)
end

---@param thread Thread
function M.remove(thread)
  M.store():remove(thread)
  M.delete(thread)
end

---Threads across the project, sorted by path then row
---@param opts { path?: string }?
---@return Thread[]
function M.list(opts)
  local result = {}
  for _, thread in pairs(M.by_id) do
    if not (opts and opts.path) or thread.path == opts.path then
      result[#result + 1] = thread
    end
  end
  table.sort(result, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.last_row ~= b.last_row then
      return a.last_row < b.last_row
    end
    return a.id < b.id
  end)
  return result
end

return M
