local PROMPT_MIN_WIDTH = 20
local PROMPT_MAX_WIDTH_RATIO = 0.7
local CARET = '❯'
local CHIP_DONE = '●'
local CHIP_ERROR = '✗'
local NOTIFY_MAX_LINES = 5
local NOTIFY_MAX_CHARS = 200

local ns = vim.api.nvim_create_namespace('jean.inline')

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

---Highlight the strip as user input only on the first `prompt_lines` buffer lines
---@param prompt_lines number
---@return string
local function mini_statuscolumn(prompt_lines)
  return caret_statuscolumn(
    string.format("%%{%%v:lnum <= %d ? '%%#JeanPromptCaret#' : '%%#JeanResponseCaret#'%%}", prompt_lines)
  )
end

vim.api.nvim_set_hl(0, 'JeanPromptCaret', { link = 'PmenuSel', default = true })
vim.api.nvim_set_hl(0, 'JeanResponseCaret', { link = 'Pmenu', default = true })
vim.api.nvim_set_hl(0, 'JeanChip', { link = 'DiagnosticVirtualTextInfo', default = true })
vim.api.nvim_set_hl(0, 'JeanChipSelected', { link = 'PmenuSel', default = true })

---@type JeanMini
local Mini

---@class JeanChip
---@field session Session
---@field bufnr number
---@field prompt string
---@field status string
---@field selected boolean
---@field mark_id number
---@field spinner Spinner|nil
---@field augroup number
---@field saved_virtualedit {winid: number, value: string}|nil
---@field response string[] text blocks, the last one being built from text_delta chunks while streaming
---@field streaming boolean|nil true while the last response block is receiving text_delta chunks
---@field error string|nil
---@field screen_col number 0-indexed editor column the mini window is anchored at
---@field mini JeanMini|nil
---@field removed boolean
local Chip = {}
Chip.__index = Chip

---@type table<string, JeanChip> chips by session id
local chips = {}

---@return number|nil row 0-indexed
function Chip:row()
  local pos = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, ns, self.mark_id, {})
  return pos[1]
end

---@return string
function Chip:_label()
  local row = self:row()
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
  local winid = vim.fn.bufwinid(self.bufnr)
  local width = winid == -1 and vim.o.columns or vim.api.nvim_win_get_width(winid)
  if winid ~= -1 then
    width = width - vim.fn.getwininfo(winid)[1].textoff
  end

  -- space + status + space around the prompt
  local available = width - vim.fn.strdisplaywidth(line) - 3
  local prompt = self.prompt:gsub('%s+', ' ')
  if vim.fn.strdisplaywidth(prompt) > available then
    local chars = math.max(available - 1, 0)
    while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(prompt, 0, chars)) > available - 1 do
      chars = chars - 1
    end
    prompt = available > 1 and vim.fn.strcharpart(prompt, 0, chars) .. '…' or ''
  end
  return ' ' .. self.status .. (prompt == '' and '' or ' ' .. prompt)
end

function Chip:render()
  local row = self:row()
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1]
  local hl = self.selected and 'JeanChipSelected' or 'JeanChip'
  vim.api.nvim_buf_set_extmark(self.bufnr, ns, row, #line, {
    id = self.mark_id,
    virt_text = not self.mini and { { self:_label(), hl } } or nil,
    virt_text_pos = 'inline',
    right_gravity = true,
  })
end

---@param status string
function Chip:set_status(status)
  self.status = status
  self:render()
  if self.mini then
    self.mini:refresh()
  end
end

function Chip:_restore_virtualedit()
  local saved = self.saved_virtualedit
  if not saved then
    return
  end
  self.saved_virtualedit = nil
  if vim.api.nvim_win_is_valid(saved.winid) then
    vim.api.nvim_set_option_value('virtualedit', saved.value, { scope = 'local', win = saved.winid })
  end
end

---@return boolean true if the current window's cursor is on the chip line
function Chip:_cursor_on_line()
  return vim.api.nvim_get_current_buf() == self.bufnr and vim.api.nvim_win_get_cursor(0)[1] - 1 == self:row()
end

---Keep virtualedit and the selected state in sync with the cursor
function Chip:_sync_cursor()
  local winid = vim.api.nvim_get_current_win()
  local on_line = self:_cursor_on_line()

  if on_line and not self.saved_virtualedit then
    self.saved_virtualedit = {
      winid = winid,
      value = vim.api.nvim_get_option_value('virtualedit', { scope = 'local', win = winid }),
    }
    vim.api.nvim_set_option_value('virtualedit', 'onemore', { scope = 'local', win = winid })
  elseif not on_line then
    self:_restore_virtualedit()
  end

  local selected = false
  if on_line and vim.fn.mode() == 'n' then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    selected = cursor[2] >= #line
  end
  if selected ~= self.selected then
    self.selected = selected
    self:render()
  end
end

---@param screen_row number 0-indexed editor row of the anchor line
---@param at_input? boolean leave the cursor at the end of the prompt instead of the last line
function Chip:open_mini(screen_row, at_input)
  if self.mini then
    return
  end
  self.mini = Mini:new(self, screen_row, self.screen_col, at_input)
  self:_sync_cursor()
  self:render()
end

function Chip:collapse()
  if self.mini then
    self.mini:close()
  end
  self:render()
end

function Chip:open_chat()
  local session = self.session
  self:remove()
  require('jean.window').open(session)
end

function Chip:_setup_cursor_tracking()
  local bufnr = self.bufnr
  self.augroup = vim.api.nvim_create_augroup('jean.inline.chip.' .. self.mark_id, { clear = true })

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'ModeChanged', 'BufEnter', 'WinEnter' }, {
    group = self.augroup,
    buffer = bufnr,
    callback = function()
      self:_sync_cursor()
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    group = self.augroup,
    buffer = bufnr,
    callback = function()
      self:_restore_virtualedit()
      if self.selected then
        self.selected = false
        self:render()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = self.augroup,
    callback = function()
      self:render()
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = self.augroup,
    buffer = bufnr,
    callback = function()
      -- the anchor line may have been deleted along with the chip's extmark
      if self:row() < vim.api.nvim_buf_line_count(bufnr) then
        self:render()
      end
    end,
  })

  -- NOTE: with virtualedit=onemore `$` stops on the last character, so step
  -- once more to land on the chip
  vim.keymap.set('n', '$', function()
    if self:_cursor_on_line() and vim.v.count1 == 1 and vim.fn.col('.') < vim.fn.col('$') then
      return '$l'
    end
    return '$'
  end, { buffer = bufnr, expr = true, desc = 'Jean: move onto the chip' })

  vim.keymap.set('n', '<cr>', function()
    if self.selected then
      vim.schedule(function()
        self:open_mini(vim.fn.screenpos(0, self:row() + 1, 1).row - 1)
      end)
      return ''
    end
    return '<cr>'
  end, { buffer = bufnr, expr = true, desc = 'Jean: open response from the chip' })
end

function Chip:remove()
  if self.removed then
    return
  end
  self.removed = true

  if self.spinner then
    self.spinner:destroy()
  end
  if self.mini then
    self.mini:close()
  end
  self:_restore_virtualedit()
  vim.api.nvim_del_augroup_by_id(self.augroup)
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_del_extmark(self.bufnr, ns, self.mark_id)
    pcall(vim.keymap.del, 'n', '$', { buffer = self.bufnr })
    pcall(vim.keymap.del, 'n', '<cr>', { buffer = self.bufnr })
  end
  if chips[self.session.id] == self then
    chips[self.session.id] = nil
  end
end

---@param response string[]
---@param result {success: boolean, error?: string}
local function notify_done(response, result)
  if result.success and not result.error then
    local text = vim.trim(table.concat(response, '\n'))
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

---@param session Session
---@param bufnr number
---@param row number 0-indexed
---@param prompt string
---@param screen_row number
---@param screen_col number
local function submit(session, bufnr, row, prompt, screen_row, screen_col)
  local previous = chips[session.id]
  if previous then
    previous:remove()
    session:cancel_active_prompt()
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  ---@type JeanChip
  local chip = setmetatable({
    session = session,
    bufnr = bufnr,
    prompt = prompt,
    status = ' ',
    selected = false,
    response = {},
    screen_col = screen_col,
    removed = false,
    mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, #line, { right_gravity = true }),
  }, Chip)
  chips[session.id] = chip
  chip:_setup_cursor_tracking()
  chip:open_mini(screen_row, true)
  chip.spinner = require('jean.spinner'):new({
    on_frame = function(frame)
      chip:set_status(frame)
    end,
  })

  local win = require('jean.window')._get_or_create(session)
  win:append_lines_and_follow(prompt)
  session:submit_prompt(prompt, {
    spinner = false,
    on_message = function(message)
      if message.type == 'text_delta' then
        if not chip.streaming then
          table.insert(chip.response, '')
          chip.streaming = true
        end
        chip.response[#chip.response] = chip.response[#chip.response] .. message.text
      elseif message.type == 'text' then
        if chip.streaming and message.streamed then
          chip.response[#chip.response] = message.text
        else
          table.insert(chip.response, message.text)
        end
        chip.streaming = false
      else
        return
      end
      if chip.mini then
        chip.mini:refresh()
      end
    end,
    on_done = function(result)
      if chip.removed then
        return
      end
      chip.spinner:destroy()
      chip.spinner = nil
      local ok = result.success and not result.error
      if not ok then
        chip.error = result.error or 'Request failed or was canceled'
      end
      chip:set_status(ok and CHIP_DONE or CHIP_ERROR)
      if not chip.mini or chip.mini.leaving then
        notify_done(chip.response, result)
      end
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
---@field prompt_lines number
---@field closed boolean
---@field following boolean scroll to the latest content on refresh until the user moves the cursor
---@field follow_cursor? number[] cursor position last set by following
---@field leaving boolean set synchronously on WinLeave, before the collapse is scheduled
---@field augroup number
Mini = {}
Mini.__index = Mini

---@return string[]
function Mini:_lines()
  local chip = self.chip
  local blocks = { chip.prompt }
  vim.list_extend(blocks, chip.response)
  if chip.error then
    table.insert(blocks, chip.error)
  end
  if chip.spinner then
    table.insert(blocks, chip.status)
  end
  return vim.split(table.concat(blocks, '\n\n'), '\n')
end

---Drop the mini and show the chip when its window or buffer was closed externally
function Mini:_lost()
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
      if cursor[1] <= self.prompt_lines and cursor[1] >= vim.fn.line('w0') then
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
    prompt_lines = #vim.split(chip.prompt, '\n'),
    leaving = false,
    screen_row = screen_row,
    screen_col = screen_col,
    bufnr = vim.api.nvim_create_buf(false, true),
  }, self)
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
  vim.bo[instance.bufnr].bufhidden = 'wipe'
  vim.wo[instance.winid].wrap = true
  vim.wo[instance.winid].linebreak = true
  -- NOTE: Without smoothscroll, zb cannot start mid-line and, with the statuscolumn,
  -- leaves blank rows below the last line
  vim.wo[instance.winid].smoothscroll = true
  vim.wo[instance.winid].winhighlight = 'Normal:NormalFloat'
  vim.wo[instance.winid].statuscolumn = mini_statuscolumn(instance.prompt_lines)
  instance:refresh()
  instance.augroup = vim.api.nvim_create_augroup('jean.inline.mini.' .. chip.mark_id, { clear = true })
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
    local last = instance.prompt_lines
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
  local function open_chat()
    chip:open_chat()
  end
  local opts = { buffer = instance.bufnr, nowait = true }
  vim.keymap.set('n', '<esc>', collapse, vim.tbl_extend('force', opts, { desc = 'Collapse to chip' }))
  vim.keymap.set('n', 'q', collapse, vim.tbl_extend('force', opts, { desc = 'Collapse to chip' }))
  for _, key in ipairs({ 'i', 'I', 'a', 'A', 'o', 'O', 'c', 'C', 's', 'S', 'R' }) do
    vim.keymap.set('n', key, open_chat, vim.tbl_extend('force', opts, { desc = 'Open chat' }))
  end

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

function M.prompt()
  local session = require('jean.session').from_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  -- Tracks the anchor line through edits made while the prompt is open
  local anchor = vim.api.nvim_buf_set_extmark(bufnr, ns, vim.fn.line('.') - 1, 0, {})

  PromptInput:new(function(text, screen_row, screen_col)
    local row = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, anchor, {})[1]
    vim.api.nvim_buf_del_extmark(bufnr, ns, anchor)
    submit(session, bufnr, row, text, screen_row, screen_col)
  end, function()
    vim.api.nvim_buf_del_extmark(bufnr, ns, anchor)
  end)
end

return M
