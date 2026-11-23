local PROMPT_MIN_WIDTH = 20
local PROMPT_MAX_WIDTH_RATIO = 0.7
local CARET = '❯'
local CHIP_QUEUED = '…'
local CHIP_DONE = '●'
local CHIP_ERROR = '✗'
local CHIP_DETACHED = '⚠'
local NOTIFY_MAX_LINES = 5
local NOTIFY_MAX_CHARS = 200
local WATCH_DEBOUNCE_MS = 100

local T = require('jean.thread')

local ns = vim.api.nvim_create_namespace('jean.inline')
local augroup = vim.api.nvim_create_augroup('jean.inline', { clear = true })

-- NOTE: The padding stays outside of %{} because it strips leading whitespace
---@param highlight string statusline item selecting the strip highlight
---@return string
local function caret_statuscolumn(highlight)
  return string.format(
    "%s %%{v:lnum == 1 && v:virtnum == 0 ? '%s' : '%s'} %%* ",
    highlight,
    CARET,
    string.rep(' ', vim.fn.strdisplaywidth(CARET))
  )
end

local PROMPT_STATUSCOLUMN = caret_statuscolumn('%#JeanPromptCaret#')
-- NOTE: Keep in sync with caret_statuscolumn: padding, caret, padding, then the gap
local CARET_WIDTH = vim.fn.strdisplaywidth(CARET) + 3
local CARET_PADDING = string.rep(' ', vim.fn.strdisplaywidth(CARET))

vim.api.nvim_set_hl(0, 'JeanPromptCaret', { link = 'PmenuSel', default = true })
vim.api.nvim_set_hl(0, 'JeanResponseCaret', { link = 'Pmenu', default = true })
vim.api.nvim_set_hl(0, 'JeanChip', { link = 'DiagnosticVirtualTextInfo', default = true })
vim.api.nvim_set_hl(0, 'JeanChipSelected', { link = 'PmenuSel', default = true })

---@type JeanMini
local Mini

---@type fun(thread: Thread)
local reply

---@param thread Thread
---@param frame? string spinner frame to show while the latest prompt runs
---@return string
local function thread_status(thread, frame)
  if thread.detached then
    return CHIP_DETACHED
  end
  local exchange = thread.exchanges[#thread.exchanges]
  local status = exchange and exchange.status
  if status == 'done' then
    return CHIP_DONE
  elseif status == 'error' then
    return CHIP_ERROR
  elseif status == 'running' and frame then
    return frame
  end
  return CHIP_QUEUED
end

---@param thread Thread
local function save(thread)
  T.run(T.save, thread)
end

---A buffer that has threads: its watcher and the cursor state shared by its chips
---@class JeanThreadedBuffer
---@field augroup number
---@field watcher uv.uv_fs_event_t|nil
---@field debounce uv.uv_timer_t|nil
---@field saved_virtualedit {winid: number, value: string}|nil
---@field notified boolean the user was told the file changed under their unsaved edits

---@type table<number, JeanThreadedBuffer>
local buffers = {}

---@class JeanChip
---@field thread Thread
---@field selected boolean
---@field mark_id number|nil
---@field spinner Spinner|nil
---@field frame string|nil current spinner frame
---@field screen_col number|nil 0-indexed editor column the mini window is anchored at
---@field mini JeanMini|nil
local Chip = {}
Chip.__index = Chip

---@type table<string, JeanChip> chips by thread id
local chips = {}

---@param thread Thread
---@return JeanChip
function Chip:new(thread)
  local instance = setmetatable({ thread = thread, selected = false }, self)
  local exchange = thread.exchanges[#thread.exchanges]
  if exchange and exchange.status == 'running' then
    instance:start_spinner()
  end
  return instance
end

---@return number row 0-indexed; a detached thread stays at its last row
function Chip:row()
  T.sync(self.thread)
  return math.min(self.thread.last_row, vim.api.nvim_buf_line_count(self.thread.bufnr)) - 1
end

---@return string
function Chip:status()
  return thread_status(self.thread, self.frame)
end

---@return string
function Chip:_label()
  local bufnr = self.thread.bufnr
  local row = self:row()
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local winid = vim.fn.bufwinid(bufnr)
  local width = winid == -1 and vim.o.columns or vim.api.nvim_win_get_width(winid)
  if winid ~= -1 then
    width = width - vim.fn.getwininfo(winid)[1].textoff
  end

  -- space + status + space around the prompt
  local available = width - vim.fn.strdisplaywidth(line) - 3
  local exchange = self.thread.exchanges[#self.thread.exchanges]
  local prompt = (exchange and exchange.prompt or ''):gsub('%s+', ' ')
  if vim.fn.strdisplaywidth(prompt) > available then
    local chars = math.max(available - 1, 0)
    while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(prompt, 0, chars)) > available - 1 do
      chars = chars - 1
    end
    prompt = available > 1 and vim.fn.strcharpart(prompt, 0, chars) .. '…' or ''
  end
  return ' ' .. self:status() .. (prompt == '' and '' or ' ' .. prompt)
end

function Chip:render()
  local bufnr = self.thread.bufnr
  local row = self:row()
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local hl = self.selected and 'JeanChipSelected' or 'JeanChip'
  self.mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, #line, {
    id = self.mark_id,
    virt_text = not self.mini and { { self:_label(), hl } } or nil,
    virt_text_pos = 'inline',
    right_gravity = true,
  })
end

function Chip:update()
  self:render()
  if self.mini then
    self.mini:refresh()
  end
end

function Chip:start_spinner()
  self.spinner = require('jean.spinner'):new({
    on_frame = function(frame)
      self.frame = frame
      self:update()
    end,
  })
  self.frame = self.spinner.frames[1]
end

function Chip:stop_spinner()
  if self.spinner then
    self.spinner:destroy()
    self.spinner = nil
    self.frame = nil
  end
end

---@param at_input? boolean leave the cursor at the end of the latest prompt instead of the last line
function Chip:open_mini(at_input)
  if self.mini then
    return
  end
  local pos = vim.fn.screenpos(0, self:row() + 1, 1)
  local screen_row = math.max(pos.row - 1, 0)
  self.mini = Mini:new(self, screen_row, self.screen_col or math.max(pos.col - 1, 0), at_input)
  self:render()
end

function Chip:collapse()
  if self.mini then
    self.mini:close()
  end
  self:render()
end

function Chip:open_chat()
  self:collapse()
  require('jean.window').open(require('jean.session').from_buffer(self.thread.bufnr))
end

---Drop the chip's UI; the thread itself lives on in the store
function Chip:remove()
  self:stop_spinner()
  if self.mini then
    self.mini:close()
  end
  if self.mark_id then
    vim.api.nvim_buf_del_extmark(self.thread.bufnr, ns, self.mark_id)
  end
  chips[self.thread.id] = nil
end

---@param bufnr number
---@return JeanChip[]
local function unsorted_buffer_chips(bufnr)
  return vim.tbl_filter(function(chip)
    return chip.thread.bufnr == bufnr
  end, vim.tbl_values(chips))
end

---Chips of a buffer, by row
---@param bufnr number
---@return JeanChip[]
local function buffer_chips(bufnr)
  local result = unsorted_buffer_chips(bufnr)
  table.sort(result, function(a, b)
    local ra, rb = a:row(), b:row()
    if ra ~= rb then
      return ra < rb
    end
    return a.thread.created_at < b.thread.created_at
      or (a.thread.created_at == b.thread.created_at and a.thread.id < b.thread.id)
  end)
  return result
end

---The chip on a buffer row, preferring an attached thread over a detached one
---@param bufnr number
---@param row number 0-indexed
---@return JeanChip|nil
local function chip_at(bufnr, row)
  local found
  for _, chip in ipairs(buffer_chips(bufnr)) do
    if chip:row() == row and (not found or found.thread.detached) then
      found = chip
    end
  end
  return found
end

---@param bufnr number
---@return JeanChip|nil
local function chip_on_cursor_line(bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return nil
  end
  return chip_at(bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
end

---@param state JeanThreadedBuffer
local function restore_virtualedit(state)
  local saved = state.saved_virtualedit
  if not saved then
    return
  end
  state.saved_virtualedit = nil
  if vim.api.nvim_win_is_valid(saved.winid) then
    vim.api.nvim_set_option_value('virtualedit', saved.value, { scope = 'local', win = saved.winid })
  end
end

---@param bufnr number
---@param selected JeanChip|nil
local function select_chip(bufnr, selected)
  for _, chip in ipairs(buffer_chips(bufnr)) do
    if chip.selected ~= (chip == selected) then
      chip.selected = chip == selected
      chip:render()
    end
  end
end

---Keep virtualedit and the selected chip in sync with the cursor
---@param bufnr number
local function sync_cursor(bufnr)
  local state = buffers[bufnr]
  local winid = vim.api.nvim_get_current_win()
  local chip = chip_on_cursor_line(bufnr)

  if chip and not state.saved_virtualedit then
    state.saved_virtualedit = {
      winid = winid,
      value = vim.api.nvim_get_option_value('virtualedit', { scope = 'local', win = winid }),
    }
    vim.api.nvim_set_option_value('virtualedit', 'onemore', { scope = 'local', win = winid })
  elseif not chip then
    restore_virtualedit(state)
  end

  local selected
  if chip and vim.fn.mode() == 'n' then
    local cursor = vim.api.nvim_win_get_cursor(0)
    if cursor[2] >= #vim.api.nvim_get_current_line() then
      selected = chip
    end
  end
  select_chip(bufnr, selected)
end

---@param bufnr number
local function checktime(bufnr)
  if buffers[bufnr] then
    vim.cmd.checktime(bufnr)
  end
end

local function checktime_all()
  for bufnr in pairs(buffers) do
    checktime(bufnr)
  end
end

---@param bufnr number
local function untrack_buffer(bufnr)
  local state = buffers[bufnr]
  buffers[bufnr] = nil
  if state.watcher then
    state.watcher:close()
    state.debounce:close()
  end
  restore_virtualedit(state)
  vim.api.nvim_del_augroup_by_id(state.augroup)
  for _, chip in ipairs(unsorted_buffer_chips(bufnr)) do
    chip:remove()
    chip.thread.bufnr = nil
    chip.thread.extmark = nil
  end
end

---Re-attach the buffer's threads after its lines were replaced from disk.
---Their extmarks still sit on the old rows, so nothing may sync them before
---reanchor: that would adopt whatever line now occupies the old row.
---@param bufnr number
local function reattach(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local list = unsorted_buffer_chips(bufnr)
  for _, chip in ipairs(list) do
    T.reanchor(chip.thread, lines)
    save(chip.thread)
  end
  for _, chip in ipairs(list) do
    chip:update()
  end
end

---Watch the file's directory: writers that replace the file by renaming over
---it would end a watch on the file itself.
---@param bufnr number
---@param state JeanThreadedBuffer
local function watch(bufnr, state)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    return
  end
  local name = vim.fs.basename(path)
  state.watcher = assert(vim.uv.new_fs_event())
  state.debounce = assert(vim.uv.new_timer())
  state.watcher:start(vim.fs.dirname(path), {}, function(err, filename)
    if err or (filename and filename ~= name) then
      return
    end
    state.debounce:start(
      WATCH_DEBOUNCE_MS,
      0,
      vim.schedule_wrap(function()
        checktime(bufnr)
      end)
    )
  end)
end

---Set a buffer up for its threads: cursor tracking, edits on anchor lines,
---and reloading it when the file changes on disk
---@param bufnr number
local function track_buffer(bufnr)
  if buffers[bufnr] then
    return
  end
  ---@type JeanThreadedBuffer
  local state = {
    augroup = vim.api.nvim_create_augroup('jean.inline.buffer.' .. bufnr, { clear = true }),
    notified = false,
  }
  buffers[bufnr] = state
  vim.bo[bufnr].autoread = true
  watch(bufnr, state)

  local function on(events, callback)
    vim.api.nvim_create_autocmd(events, { group = state.augroup, buffer = bufnr, callback = callback })
  end

  on({ 'CursorMoved', 'ModeChanged', 'BufEnter', 'WinEnter' }, function()
    sync_cursor(bufnr)
  end)
  on({ 'WinLeave', 'BufLeave' }, function()
    restore_virtualedit(state)
    select_chip(bufnr, nil)
  end)
  on({ 'TextChanged', 'TextChangedI' }, function()
    for _, chip in ipairs(buffer_chips(bufnr)) do
      local thread = chip.thread
      local anchor_text, detached = thread.anchor_text, thread.detached
      T.sync(thread)
      if thread.anchor_text ~= anchor_text or thread.detached ~= detached then
        save(thread)
      end
      chip:render()
    end
  end)
  on('CursorHold', function()
    checktime(bufnr)
  end)
  on('FileChangedShell', function()
    if vim.bo[bufnr].modified then
      vim.v.fcs_choice = ''
      if not state.notified then
        state.notified = true
        vim.notify(
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
            .. ' changed on disk; keeping your unsaved changes',
          vim.log.levels.WARN,
          { title = 'Jean' }
        )
      end
    elseif vim.v.fcs_reason ~= 'deleted' then
      vim.v.fcs_choice = 'reload'
    end
  end)
  on({ 'BufReadPost', 'FileChangedShellPost' }, function()
    state.notified = false
    reattach(bufnr)
  end)
  on('BufWritePost', function()
    state.notified = false
  end)
  on('BufUnload', function()
    untrack_buffer(bufnr)
  end)

  -- NOTE: with virtualedit=onemore `$` stops on the last character, so step
  -- once more to land on the chip
  vim.keymap.set('n', '$', function()
    if chip_on_cursor_line(bufnr) and vim.v.count1 == 1 and vim.fn.col('.') < vim.fn.col('$') then
      return '$l'
    end
    return '$'
  end, { buffer = bufnr, expr = true, desc = 'Jean: move onto the chip' })

  vim.keymap.set('n', '<cr>', function()
    local chip = chip_on_cursor_line(bufnr)
    if chip and chip.selected then
      vim.schedule(function()
        chip:open_mini()
      end)
      return ''
    end
    return '<cr>'
  end, { buffer = bufnr, expr = true, desc = 'Jean: open the thread from its chip' })
end

vim.api.nvim_create_autocmd('FocusGained', { group = augroup, callback = checktime_all })

---@param thread Thread
---@return JeanChip
local function ensure_chip(thread)
  track_buffer(thread.bufnr)
  local chip = chips[thread.id]
  if not chip then
    chip = Chip:new(thread)
    chips[thread.id] = chip
  end
  return chip
end

---@param response table[]
---@param result {success: boolean, error?: string}
local function notify_done(response, result)
  if result.success and not result.error then
    local text = vim.trim(table.concat(
      vim.tbl_map(function(block)
        return block.text
      end, response),
      '\n'
    ))
    local lines = vim.list_slice(vim.split(text, '\n'), 1, NOTIFY_MAX_LINES)
    local preview = table.concat(lines, '\n')
    if #preview > NOTIFY_MAX_CHARS or #lines < #vim.split(text, '\n') then
      preview = vim.fn.strcharpart(preview, 0, NOTIFY_MAX_CHARS) .. '…'
    end
    vim.notify(preview ~= '' and preview or 'Response available', vim.log.levels.INFO, { title = 'Jean' })
  else
    vim.notify(result.error or 'Request failed or was canceled', vim.log.levels.ERROR, { title = 'Jean' })
  end
end

---Queue a prompt in a thread; its messages go to this exchange only
---@param session Session
---@param thread Thread
---@param text string
---@param screen_col number
local function submit(session, thread, text, screen_col)
  ---@type ThreadExchange
  local exchange = { prompt = text, blocks = {}, status = 'queued' }
  thread.exchanges[#thread.exchanges + 1] = exchange
  save(thread)

  local chip = ensure_chip(thread)
  chip.screen_col = screen_col
  chip:update()
  chip:open_mini(true)

  local function chip_update()
    local current = chips[thread.id]
    if current then
      current:update()
    end
  end

  local streaming = false
  require('jean.window')._get_or_create(session)
  session:submit_prompt(T.format_prompt(thread, text, { pwd = session.pwd }), {
    context = false,
    echo = true,
    spinner = false,
    on_start = function()
      exchange.status = 'running'
      local current = chips[thread.id]
      if current then
        current:start_spinner()
      end
    end,
    on_message = function(message)
      local blocks = exchange.blocks
      if message.type == 'text_delta' then
        if not streaming then
          blocks[#blocks + 1] = { type = 'text', text = '' }
          streaming = true
        end
        blocks[#blocks].text = blocks[#blocks].text .. message.text
      elseif message.type == 'text' then
        if streaming and message.streamed then
          blocks[#blocks].text = message.text
        else
          blocks[#blocks + 1] = { type = 'text', text = message.text }
        end
        streaming = false
      else
        return
      end
      chip_update()
    end,
    on_done = function(result)
      local ok = result.success and not result.error
      exchange.status = ok and 'done' or 'error'
      if not ok then
        exchange.error = result.error or 'Request failed or was canceled'
      end
      save(thread)
      local current = chips[thread.id]
      if current then
        current:stop_spinner()
        current:update()
      end
      if not (current and current.mini and not current.mini.leaving) then
        notify_done(exchange.blocks, result)
      end
      checktime_all()
    end,
  })
end

---Pick the side of the anchor with more room, once, so a growing float never flips sides
local function choose_side(self)
  -- Either way the float covers the anchor line itself
  local below = vim.o.lines - 2 - self.screen_row
  local above = self.screen_row + 1
  self.above = below < above
  self.max_height = math.max(self.above and above or below, 1)
end

---@class JeanMini
---@field chip JeanChip
---@field bufnr number
---@field winid number
---@field screen_row number
---@field screen_col number
---@field above boolean
---@field max_height number
---@field prompt_rows table<number, 'start'|'rest'> buffer lines holding a prompt
---@field input number[] first and last line of the latest prompt
---@field closed boolean
---@field following boolean scroll to the latest content on refresh until the user moves the cursor
---@field follow_cursor? number[] cursor position last set by following
---@field leaving boolean set synchronously on WinLeave, before the collapse is scheduled
---@field augroup number
Mini = {}
Mini.__index = Mini

---@type table<number, JeanMini> by window id
local minis = {}

---The thread's history: each prompt, then its response
---@return string[]
function Mini:_lines()
  local chip = self.chip
  local thread = chip.thread
  local lines = {}
  local prompt_rows = {}
  local function add(text)
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    vim.list_extend(lines, vim.split(text, '\n'))
  end

  for _, exchange in ipairs(thread.exchanges) do
    add(exchange.prompt)
    local first = #lines - #vim.split(exchange.prompt, '\n') + 1
    for row = first, #lines do
      prompt_rows[row] = row == first and 'start' or 'rest'
    end
    self.input = { first, #lines }
    for _, block in ipairs(exchange.blocks) do
      add(block.text)
    end
    if exchange.error then
      add(exchange.error)
    end
    if exchange.status == 'queued' or exchange.status == 'running' then
      add(exchange.status == 'running' and chip.frame or CHIP_QUEUED)
    end
  end
  if thread.detached then
    add(CHIP_DETACHED .. ' detached from: ' .. thread.anchor_text)
  end
  self.prompt_rows = prompt_rows
  return lines
end

---Drop the mini and show the chip when its window or buffer was closed externally
function Mini:_lost()
  if self.closed then
    return
  end
  self:close()
  self.chip:render()
end

function Mini:refresh()
  if not vim.api.nvim_win_is_valid(self.winid) or not vim.api.nvim_buf_is_valid(self.bufnr) then
    self:_lost()
    return
  end
  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, self:_lines())
  vim.bo[self.bufnr].modifiable = false
  self:resize()
  if self.following then
    vim.api.nvim_win_call(self.winid, function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(self.bufnr), 0 })
      -- Refit the topline: the window may have grown since Neovim last scrolled it
      vim.cmd.normal({ 'zb', bang = true })
      if cursor[1] >= self.input[1] and cursor[1] <= self.input[2] and cursor[1] >= vim.fn.line('w0') then
        vim.api.nvim_win_set_cursor(0, cursor)
      end
      self.follow_cursor = vim.api.nvim_win_get_cursor(0)
    end)
  end
end

function Mini:close()
  if self.closed then
    return
  end
  self.closed = true
  self.chip.mini = nil
  minis[self.winid] = nil
  vim.api.nvim_del_augroup_by_id(self.augroup)
  if vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_close(self.winid, true)
  end
end

---@param chip JeanChip
---@param screen_row number
---@param screen_col number
---@param at_input? boolean
---@return JeanMini
function Mini:new(chip, screen_row, screen_col, at_input)
  local instance = setmetatable({
    chip = chip,
    closed = false,
    following = true,
    prompt_rows = {},
    input = { 1, 1 },
    leaving = false,
    screen_row = screen_row,
    screen_col = screen_col,
    bufnr = vim.api.nvim_create_buf(false, true),
  }, self)
  vim.b[instance.bufnr].jean_nvim_managed = true
  choose_side(instance)

  instance.winid = vim.api.nvim_open_win(instance.bufnr, true, {
    relative = 'editor',
    style = 'minimal',
    row = 0,
    col = 0,
    width = PROMPT_MIN_WIDTH,
    height = 1,
    zindex = 50,
  })
  minis[instance.winid] = instance
  vim.bo[instance.bufnr].bufhidden = 'wipe'
  vim.wo[instance.winid].wrap = true
  vim.wo[instance.winid].linebreak = true
  -- NOTE: Without smoothscroll, zb cannot start mid-line and, with the statuscolumn,
  -- leaves blank rows below the last line
  vim.wo[instance.winid].smoothscroll = true
  vim.wo[instance.winid].winhighlight = 'Normal:NormalFloat'
  vim.wo[instance.winid].statuscolumn = "%!v:lua.require'jean.inline'._mini_statuscolumn()"
  instance.augroup = vim.api.nvim_create_augroup('jean.inline.mini.' .. chip.thread.id, { clear = true })
  instance:refresh()
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = instance.augroup,
    buffer = instance.bufnr,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(instance.winid)
      if instance.follow_cursor and not vim.deep_equal(cursor, instance.follow_cursor) then
        instance.following = false
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    group = instance.augroup,
    buffer = instance.bufnr,
    callback = function()
      instance.leaving = true
      vim.schedule(function()
        if not instance.closed then
          chip:collapse()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = instance.augroup,
    pattern = tostring(instance.winid),
    callback = function()
      vim.schedule(function()
        instance:_lost()
      end)
    end,
  })

  if at_input then
    local last = instance.input[2]
    local text = vim.api.nvim_buf_get_lines(instance.bufnr, last - 1, last, false)[1]
    vim.api.nvim_win_set_cursor(instance.winid, { last, #text })
    instance.follow_cursor = nil
    vim.cmd.stopinsert()
    -- NOTE: Leaving insert mode steps the cursor back onto the last character
    vim.schedule(function()
      if not instance.closed then
        instance.follow_cursor = vim.api.nvim_win_get_cursor(instance.winid)
      end
    end)
  end

  local function collapse()
    chip:collapse()
  end
  local function reply_here()
    reply(chip.thread)
  end
  local function open_chat()
    chip:open_chat()
  end
  local opts = { buffer = instance.bufnr, nowait = true }
  vim.keymap.set('n', '<esc>', collapse, vim.tbl_extend('force', opts, { desc = 'Collapse to chip' }))
  vim.keymap.set('n', 'q', collapse, vim.tbl_extend('force', opts, { desc = 'Collapse to chip' }))
  for _, key in ipairs({ 'i', 'a', 'o', 'r' }) do
    vim.keymap.set('n', key, reply_here, vim.tbl_extend('force', opts, { desc = 'Reply in this thread' }))
  end
  vim.keymap.set('n', 'gc', open_chat, vim.tbl_extend('force', opts, { desc = 'Open chat' }))

  return instance
end

---Floating prompt input with a caret drawn in its statuscolumn
---@class JeanPromptInput
---@field bufnr number
---@field winid number
---@field screen_row number 0-indexed editor row of the anchor line
---@field screen_col number 0-indexed editor column of the cursor
---@field above boolean
---@field max_height number
---@field closed boolean
local PromptInput = {}
PromptInput.__index = PromptInput

local function resize_float(self)
  local columns = vim.o.columns
  local max_width = math.max(math.floor(columns * PROMPT_MAX_WIDTH_RATIO) - CARET_WIDTH, PROMPT_MIN_WIDTH)
  local text_width = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)) do
    text_width = math.max(text_width, vim.fn.strdisplaywidth(line))
  end
  -- Two spare columns: with one, a new character briefly pushes the cursor past the
  -- edge before this resize runs, and Neovim leaves it drawn in the wrong place
  local width = math.min(math.max(text_width + 2, PROMPT_MIN_WIDTH), max_width)
  local config = vim.api.nvim_win_get_config(self.winid)
  if config.width ~= width + CARET_WIDTH then
    vim.api.nvim_win_set_width(self.winid, width + CARET_WIDTH)
  end
  local height = vim.api.nvim_win_text_height(self.winid, {}).all
  local col = math.max(math.min(self.screen_col, columns - CARET_WIDTH - width), 0)

  local function apply(h)
    local row = self.above and self.screen_row - h + 1 or self.screen_row
    local cfg = vim.api.nvim_win_get_config(self.winid)
    if cfg.height ~= h or cfg.row ~= row or cfg.col ~= col then
      vim.api.nvim_win_set_config(self.winid, {
        relative = 'editor',
        row = row,
        col = col,
        width = width + CARET_WIDTH,
        height = h,
      })
    end
    if height <= self.max_height then
      -- Neovim scrolled before the window grew (or skipcol-scrolled within line 1);
      -- show the first line again.
      local view = vim.api.nvim_win_call(self.winid, vim.fn.winsaveview)
      if view.topline ~= 1 or view.skipcol ~= 0 then
        vim.api.nvim_win_call(self.winid, function()
          vim.fn.winrestview({ topline = 1, skipcol = 0 })
        end)
      end
    end
  end

  apply(math.min(height, self.max_height))
  -- nvim_win_text_height ignores the insert cursor's cell past the end of the line;
  -- when the last character ends at the right edge, that cell wraps onto a new row.
  if height < self.max_height and vim.fn.mode():sub(1, 1) == 'i' then
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    local line = vim.api.nvim_buf_get_lines(self.bufnr, cursor[1] - 1, cursor[1], false)[1]
    if cursor[2] == #line and #line > 0 then
      local pos = vim.fn.screenpos(self.winid, cursor[1], #line)
      if pos.row ~= 0 and pos.endcol == vim.fn.win_screenpos(self.winid)[2] + CARET_WIDTH + width - 1 then
        height = height + 1
        apply(height)
      end
    end
  end
end
PromptInput.resize = resize_float
Mini.resize = resize_float

function PromptInput:close()
  if self.closed then
    return
  end
  self.closed = true
  vim.cmd.stopinsert()
  if vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_close(self.winid, true)
  end
  vim.api.nvim_del_augroup_by_id(self.augroup)
end

---@param on_submit fun(text: string, screen_row: number, screen_col: number)
---@param on_cancel fun()
---@return JeanPromptInput
function PromptInput:new(on_submit, on_cancel)
  local pos = vim.fn.screenpos(0, vim.fn.line('.'), vim.fn.col('.'))
  local instance = setmetatable({
    closed = false,
    screen_row = pos.row - 1,
    screen_col = pos.col - 1,
    bufnr = vim.api.nvim_create_buf(false, true),
  }, self)
  vim.b[instance.bufnr].jean_nvim_managed = true
  choose_side(instance)

  local float = {
    relative = 'editor',
    style = 'minimal',
    row = 0,
    col = 0,
    width = PROMPT_MIN_WIDTH,
    height = 1,
    zindex = 50,
  }
  instance.winid = vim.api.nvim_open_win(instance.bufnr, true, float)
  vim.bo[instance.bufnr].bufhidden = 'wipe'
  vim.wo[instance.winid].wrap = true
  vim.wo[instance.winid].linebreak = true
  vim.wo[instance.winid].winhighlight = 'Normal:NormalFloat'
  vim.wo[instance.winid].statuscolumn = PROMPT_STATUSCOLUMN
  vim.wo[instance.winid].smoothscroll = false
  instance:resize()

  instance.augroup = vim.api.nvim_create_augroup('jean.inline.prompt', { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = instance.augroup,
    buffer = instance.bufnr,
    callback = function()
      instance:resize()
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = instance.augroup,
    pattern = tostring(instance.winid),
    callback = function()
      vim.schedule(function()
        instance:close()
      end)
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    group = instance.augroup,
    buffer = instance.bufnr,
    callback = function()
      vim.schedule(function()
        instance:close()
      end)
    end,
  })

  local function submit_input()
    if instance.closed then
      return
    end
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false), '\n'))
    instance:close()
    if text ~= '' then
      on_submit(text, instance.screen_row, instance.screen_col)
    else
      on_cancel()
    end
  end
  local function cancel()
    instance:close()
    on_cancel()
  end
  local opts = { buffer = instance.bufnr, nowait = true }
  vim.keymap.set('n', '<cr>', submit_input, vim.tbl_extend('force', opts, { desc = 'Submit prompt' }))
  -- NOTE: stopinsert only takes effect once the mapping returns, so leave insert
  -- mode with keys and submit on the next tick: InsertLeave must fire in the
  -- input buffer, not after it's gone
  vim.keymap.set('i', '<cr>', function()
    vim.schedule(submit_input)
    return '<C-\\><C-n>'
  end, vim.tbl_extend('force', opts, { desc = 'Submit prompt', expr = true }))
  vim.keymap.set('n', '<esc>', cancel, vim.tbl_extend('force', opts, { desc = 'Cancel prompt' }))
  vim.keymap.set('n', 'q', cancel, vim.tbl_extend('force', opts, { desc = 'Cancel prompt' }))

  vim.cmd.startinsert()
  return instance
end


local M = {}

---Statuscolumn of a mini window: the caret strip marks each prompt as user input
---@return string
function M._mini_statuscolumn()
  local kind = minis[vim.g.statusline_winid].prompt_rows[vim.v.lnum]
  local caret = kind == 'start' and vim.v.virtnum == 0 and CARET or CARET_PADDING
  return (kind and '%#JeanPromptCaret#' or '%#JeanResponseCaret#') .. ' ' .. caret .. ' %* '
end

---Open the prompt input at the cursor: a reply in `thread`, or a new thread on the cursor line
---@param thread? Thread
local function open_input(thread)
  local bufnr = vim.api.nvim_get_current_buf()
  local session = require('jean.session').from_buffer(thread and thread.bufnr or bufnr)
  -- Tracks the anchor line through edits made while the prompt is open
  local anchor = not thread and vim.api.nvim_buf_set_extmark(bufnr, ns, vim.fn.line('.') - 1, 0, {}) or nil

  PromptInput:new(function(text, _, screen_col)
    if anchor then
      local row = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, anchor, {})[1]
      vim.api.nvim_buf_del_extmark(bufnr, ns, anchor)
      thread = T.create({
        path = vim.api.nvim_buf_get_name(bufnr),
        bufnr = bufnr,
        row = row + 1,
        text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1],
      })
    end
    submit(session, assert(thread), text, screen_col)
  end, function()
    if anchor then
      vim.api.nvim_buf_del_extmark(bufnr, ns, anchor)
    end
  end)
end

reply = function(thread)
  local chip = chips[thread.id]
  chip:collapse()
  if vim.api.nvim_get_current_buf() == thread.bufnr then
    vim.api.nvim_win_set_cursor(0, { chip:row() + 1, 0 })
  end
  open_input(thread)
end

---Prompt on the cursor line: a reply if the line has a thread, else a new thread
function M.prompt()
  local chip = chip_on_cursor_line(vim.api.nvim_get_current_buf())
  open_input(chip and chip.thread)
end

---Load the threads of a file that was just read into a buffer
---@param bufnr number
function M.read_buffer(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' or buffers[bufnr] then
    return
  end
  T.run(function()
    local threads = T.load(path)
    if #threads == 0 or not vim.api.nvim_buf_is_loaded(bufnr) then
      return
    end
    for _, thread in ipairs(threads) do
      T.bind(thread, bufnr)
      ensure_chip(thread)
    end
    reattach(bufnr)
  end)
end

---Show the thread's buffer, put the cursor on its line and open its history
---@param thread Thread
function M.jump(thread)
  if not (thread.bufnr and buffers[thread.bufnr]) then
    vim.cmd.edit(vim.fn.fnameescape(thread.path))
  elseif vim.api.nvim_get_current_buf() ~= thread.bufnr then
    vim.api.nvim_set_current_buf(thread.bufnr)
  end
  -- A store that loads asynchronously may not have delivered the thread yet
  local chip = chips[thread.id]
  if chip then
    vim.api.nvim_win_set_cursor(0, { chip:row() + 1, 0 })
    chip:open_mini()
  end
end

---@param forward boolean
local function step(forward)
  local list = buffer_chips(vim.api.nvim_get_current_buf())
  if #list == 0 then
    vim.notify('No threads in this buffer', vim.log.levels.WARN, { title = 'Jean' })
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  if forward then
    target = vim.iter(list):find(function(chip)
      return chip:row() > row
    end) or list[1]
  else
    target = vim.iter(list):rev():find(function(chip)
      return chip:row() < row
    end) or list[#list]
  end
  M.jump(target.thread)
end

function M.next_thread()
  step(true)
end

function M.prev_thread()
  step(false)
end

---@param thread Thread
---@return string
local function describe(thread)
  local exchange = thread.exchanges[#thread.exchanges]
  local text = ('%s:%d %s %s'):format(
    vim.fn.fnamemodify(thread.path, ':~:.'),
    thread.last_row,
    thread_status(thread),
    vim.trim(thread.anchor_text)
  )
  if exchange then
    text = text .. ' — ' .. exchange.prompt:gsub('%s+', ' ')
  end
  return text
end

local QUICKFIX = {}

---Pick any thread in the project to jump to, or send them all to the quickfix list
function M.threads()
  for _, thread in pairs(T.by_id) do
    T.sync(thread)
  end
  local threads = T.list()
  if #threads == 0 then
    vim.notify('No threads', vim.log.levels.WARN, { title = 'Jean' })
    return
  end
  local items = vim.list_extend({}, threads)
  items[#items + 1] = QUICKFIX
  vim.ui.select(items, {
    prompt = 'Jean threads',
    format_item = function(item)
      return item == QUICKFIX and 'Send all to the quickfix list' or describe(item)
    end,
  }, function(choice)
    if choice == QUICKFIX then
      vim.fn.setqflist({}, ' ', {
        title = '[Jean] Threads',
        items = vim.tbl_map(function(thread)
          local exchange = thread.exchanges[#thread.exchanges]
          return {
            filename = thread.path,
            lnum = thread.last_row,
            text = thread_status(thread) .. ' ' .. (exchange and exchange.prompt:gsub('%s+', ' ') or ''),
          }
        end, threads),
      })
      vim.cmd.copen()
    elseif choice then
      M.jump(choice)
    end
  end)
end

---Re-attach a detached thread of this buffer to the cursor line, picking one if there are several
function M.attach_thread()
  local row = vim.fn.line('.')
  local detached = vim.tbl_filter(function(chip)
    return chip.thread.detached
  end, buffer_chips(vim.api.nvim_get_current_buf()))

  local function attach(chip)
    T.attach(chip.thread, row)
    T.sync(chip.thread)
    save(chip.thread)
    chip:update()
  end

  if #detached == 0 then
    vim.notify('No detached threads in this buffer', vim.log.levels.WARN, { title = 'Jean' })
  elseif #detached == 1 then
    attach(detached[1])
  else
    vim.ui.select(detached, {
      prompt = 'Attach thread',
      format_item = function(chip)
        return describe(chip.thread)
      end,
    }, function(chip)
      if chip then
        attach(chip)
      end
    end)
  end
end

return M
