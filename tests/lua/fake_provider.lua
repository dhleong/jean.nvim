---A provider tests drive by hand: it records prompts and emits what it's told.
---@class FakeProvider : JeanProvider
---@field opts JeanProviderOpts
---@field prompts string[] texts sent, in order
---@field stops number
local Fake = {
  id = 'fake',
  ---@type FakeProvider[]
  instances = {},
}

---@param opts JeanProviderOpts
function Fake:new(opts)
  local instance = setmetatable({ opts = opts, prompts = {}, stops = 0 }, { __index = self })
  Fake.instances[#Fake.instances + 1] = instance
  return instance
end

function Fake:prompt(text)
  self.prompts[#self.prompts + 1] = text
end

function Fake:stop()
  self.stops = self.stops + 1
end

function Fake:destroy() end

---@param message JeanMessage
function Fake:emit(message)
  self.opts.on_message(message)
end

return Fake
