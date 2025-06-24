---@param path string
---@return string|nil
local function filter_path(path)
  if path == '/' or path == vim.env.HOME then
    return nil
  end
  return path
end

-- ======= Strategies ========================================

local function lsp(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if not clients or #clients == 0 then
    return nil
  end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  for _, client in ipairs(clients) do
    local workspace_folders = client.workspace_folders
    if workspace_folders then
      for _, schema in ipairs(workspace_folders) do
        -- TODO: Do we need `vim.loop.fs_realpath`?
        local root_dir = schema.name
        if root_dir and vim.startswith(fname, root_dir) then
          return root_dir
        end
      end
    end

    if client.root_dir and vim.startswith(fname, client.root_dir) then
      return client.root_dir
    end
  end
end

local function pwd()
  return vim.fn.getcwd()
end

local function vim_test(bufnr)
  local test_root = vim.g['test#project_root']

  -- Ensure bufnr *actually* "under" this dir
  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  if vim.startswith(buf_path, test_root) then
    return test_root
  end
end

-- ======= API =============================================

local strategies = {
  lsp,
  vim_test,
  pwd,
}

local M = {}

function M.root_for_buffer(bufnr)
  for _, strategy in ipairs(strategies) do
    local found = strategy(bufnr)
    if found and filter_path(found) then
      return found
    end
  end
end

return M
