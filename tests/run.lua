-- Run every tests/*_spec.lua in a fresh nvim: nvim --headless -u NONE -l tests/run.lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ':p'))))
local specs = vim.fn.glob(vim.fs.joinpath(root, 'tests', '*_spec.lua'), false, true)
table.sort(specs)

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
os.exit(failed > 0 and 1 or 0)
