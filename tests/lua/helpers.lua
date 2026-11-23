local M = {}

local failures = 0

---Fresh jean modules for each test; modules hold sessions and windows
local function reset()
  for name in pairs(package.loaded) do
    if name:match('^jean') then
      package.loaded[name] = nil
    end
  end
end

---@param name string
---@param fn fun()
function M.test(name, fn)
  reset()
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    io.write('ok   ', name, '\n')
  else
    failures = failures + 1
    io.write('FAIL ', name, '\n', err, '\n')
  end
end

function M.finish()
  os.exit(failures > 0 and 1 or 0)
end

function M.eq(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error(('expected %s\n     got %s'):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

---Run every callback vim.schedule()d so far
function M.flush()
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  vim.wait(10000, function()
    return drained
  end)
  assert(drained, 'scheduled callbacks never ran')
end

---Make the fake provider the configured one
---@return FakeProvider class whose `instances` lists every provider created
function M.use_fake_provider()
  local Fake = require('fake_provider')
  Fake.instances = {}
  package.loaded['jean.session.fake'] = Fake
  local config = require('jean.config')
  config.VALID_PROVIDERS.fake = true
  config._provider = 'fake'
  return Fake
end

return M
