---In-memory ThreadStore: threads keyed by file path. Lives as long as nvim.
---@class MemoryThreadStore: ThreadStore
local M = {}
M.__index = M

function M:new()
  return setmetatable({ by_path = {} }, M)
end

---@param path string
---@return Thread[]
function M:load(path)
  return vim.list_slice(self.by_path[path] or {})
end

---@param thread Thread
function M:save(thread)
  local list = self.by_path[thread.path] or {}
  self.by_path[thread.path] = list
  if not vim.tbl_contains(list, thread) then
    list[#list + 1] = thread
  end
end

---@param thread Thread
function M:remove(thread)
  local list = self.by_path[thread.path] or {}
  for i, t in ipairs(list) do
    if t == thread then
      table.remove(list, i)
      return
    end
  end
end

return M
