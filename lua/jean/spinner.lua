---@class Spinner
---@field tooltip Tooltip|nil
---@field timer uv.uv_timer_t|nil
---@field frames string[]
---@field current_frame number
local Spinner = {}

---@return Spinner
function Spinner:new()
  local tooltip = require('jean.tooltip'):new()

  local instance = {
    tooltip = tooltip,
    frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
    current_frame = 1,
  }
  setmetatable(instance, self)
  self.__index = self

  instance:start()
  return instance
end

function Spinner:start()
  if self.timer then
    return
  end

  if not self.tooltip then
    error('Spinner is already destroyed')
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(
    0, -- initial timeout
    100, -- interval (ms)
    vim.schedule_wrap(function()
      if not self.tooltip then
        self:stop()
        return
      end

      local frame = self.frames[self.current_frame]
      self.tooltip.buffer:set_lines({ frame })

      self.current_frame = self.current_frame + 1
      if self.current_frame > #self.frames then
        self.current_frame = 1
      end
    end)
  )
end

function Spinner:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

function Spinner:destroy()
  self:stop()

  if self.tooltip then
    self.tooltip:destroy()
    self.tooltip = nil
  end
end

return Spinner
