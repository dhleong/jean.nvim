-- Run every tests/*_spec.lua in a fresh nvim: nvim --headless -u NONE -l tests/run.lua [name...]
-- With names, only specs whose file name contains one of them run (e.g. `inline`).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ':p'))))
local specs = vim.fn.glob(vim.fs.joinpath(root, 'tests', '*_spec.lua'), false, true)
table.sort(specs)
if #arg > 0 then
  specs = vim.tbl_filter(function(spec)
    local name = vim.fs.basename(spec)
    for _, pattern in ipairs(arg) do
      if name:find(pattern, 1, true) then
        return true
      end
    end
    return false
  end, specs)
end

local failed = 0
for _, spec in ipairs(specs) do
  io.write('# ', vim.fs.basename(spec), '\n')
  local result = vim
    .system({
      vim.v.progpath,
      '--headless',
      '-u',
      'NONE',
      '--cmd',
      'set rtp^=' .. root .. ',' .. vim.fs.joinpath(root, 'tests'),
      '-l',
      spec,
    }, { cwd = root, text = true })
    :wait()
  io.write(result.stdout, result.stderr)
  if result.code ~= 0 then
    failed = failed + 1
  end
end

io.write(('%d spec file(s), %d failed\n'):format(#specs, failed))
os.exit((failed > 0 or #specs == 0) and 1 or 0)
