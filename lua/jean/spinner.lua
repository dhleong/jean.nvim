---@class Spinner
---@field tooltip Tooltip|nil
---@field on_frame fun(frame: string)|nil
---@field destroyed boolean
---@field timer uv.uv_timer_t|nil
---@field frames string[]
---@field current_frame number
local Spinner = {}

---@param opts? { on_frame: fun(frame: string) } drive a callback instead of a tooltip
---@return Spinner
function Spinner:new(opts)
  local on_frame = opts and opts.on_frame
  local instance = {
    tooltip = not on_frame and require('jean.tooltip'):new() or nil,
    on_frame = on_frame,
    destroyed = false,
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

  if self.destroyed then
    error('Spinner is already destroyed')
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(
    0, -- initial timeout
    100, -- interval (ms)
    vim.schedule_wrap(function()
      if self.destroyed then
        self:stop()
        return
      end

      local frame = self.frames[self.current_frame]
      if self.on_frame then
        self.on_frame(frame)
      else
        self.tooltip.buffer:set_lines({ frame })
      end

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
  self.destroyed = true

  if self.tooltip then
    self.tooltip:destroy()
    self.tooltip = nil
  end
end

return Spinner
