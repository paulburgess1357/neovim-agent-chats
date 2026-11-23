-- A tiny test harness: describe / it / before_each / after_each and a few
-- assertions. No dependencies, so the suite runs with nothing but Neovim:
--
--   make test        (tests/run.lua has the command, and SPEC and FILTER)

local M = {}

local suites = {} -- { name, tests = { { name, fn } }, before = {}, after = {} }
-- Hooks declared outside any describe apply to every test of the file being
-- loaded (run.lua clears them between files).
local root = { before = {}, after = {} }
local current
local tmpdirs = {}

function M.describe(name, fn)
  local parent = current
  current = {
    name = (parent and (parent.name .. ' ') or '') .. name,
    tests = {},
    before = vim.list_slice((parent or root).before),
    after = vim.list_slice((parent or root).after),
  }
  suites[#suites + 1] = current
  fn()
  current = parent
end

function M.it(name, fn)
  table.insert(current.tests, { name = name, fn = fn })
end

function M.before_each(fn)
  table.insert((current or root).before, fn)
end

function M.after_each(fn)
  table.insert((current or root).after, fn)
end

--- Forget file-level hooks (between spec files).
function M.new_file()
  root = { before = {}, after = {} }
end

local function fail(msg, level)
  error(msg, (level or 1) + 1)
end

function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    fail(
      ('%sexpected: %s\n     actual: %s'):format(
        msg and (msg .. '\n   ') or '',
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function M.ok(cond, msg)
  if not cond then
    fail(msg or 'expected a truthy value', 2)
  end
end

function M.no(cond, msg)
  if cond then
    fail(msg or ('expected a falsy value, got ' .. vim.inspect(cond)), 2)
  end
end

--- `str` contains `needle` (plain text).
function M.has(str, needle, msg)
  if type(str) ~= 'string' or not str:find(needle, 1, true) then
    fail(
      ('%sexpected %s to contain %s'):format(
        msg and (msg .. ': ') or '',
        vim.inspect(str),
        vim.inspect(needle)
      ),
      2
    )
  end
end

function M.hasnt(str, needle, msg)
  if type(str) == 'string' and str:find(needle, 1, true) then
    fail(
      ('%sexpected %s not to contain %s'):format(
        msg and (msg .. ': ') or '',
        vim.inspect(str),
        vim.inspect(needle)
      ),
      2
    )
  end
end

--- A fresh temporary directory, removed when the run ends.
function M.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  tmpdirs[#tmpdirs + 1] = dir
  return dir
end

--- A folder called `name` that is really there (the same one each time it
--- is asked for), for a chat that is to be listed as one that can be
--- resumed: a chat whose folder is not there is listed under "Folder gone".
local folders
function M.folder(name)
  folders = folders or M.tmpdir()
  local dir = folders .. '/' .. name
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- Write `content` (a string, or a list of lines) to `path`, creating parents.
function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  if type(content) == 'table' then
    content = table.concat(content, '\n') .. '\n'
  end
  local f = assert(io.open(path, 'w'))
  f:write(content)
  f:close()
  return path
end

--- Append lines to a file.
function M.append(path, lines)
  local f = assert(io.open(path, 'a'))
  if type(lines) == 'table' then
    lines = table.concat(lines, '\n') .. '\n'
  end
  f:write(lines)
  f:close()
end

--- Set a file's modification time (seconds since the epoch).
function M.touch(path, mtime)
  assert(vim.uv.fs_utime(path, mtime, mtime))
end

--- Wait until `cond()` is truthy; fails the test after `ms`.
function M.wait(ms, cond, msg)
  local ok = vim.wait(ms, cond, 10)
  if not ok then
    fail(msg or ('condition not met within ' .. ms .. 'ms'), 2)
  end
end

--- Run `fn` while typing in the terminal the cursor is in (Neovim's
--- terminal mode), then leave that mode again. A script is never in
--- terminal mode by itself (`:startinsert` only takes effect when Neovim
--- next waits for a key), so the key is fed, and `fn` runs from a timer
--- while Neovim waits for more.
function M.typing(fn)
  if vim.bo.buftype ~= 'terminal' then
    fail('the cursor is not in a terminal', 2)
  end
  local ran, err = false, nil
  vim.defer_fn(function()
    local good, e = pcall(fn)
    ran, err = true, (not good) and e or nil
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, true, true),
      'n',
      false
    )
  end, 30)
  vim.api.nvim_feedkeys('i', 'x!', false)
  if err then
    error(err, 0)
  end
  if not ran then
    fail('the terminal was never typed in', 2)
  end
end

--- Lines of a buffer joined with newlines.
function M.buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

--- Run every registered test whose full name contains `filter`.
function M.run(filter)
  local passed, failed, failures = 0, 0, {}
  local started = vim.uv.hrtime()
  for _, suite in ipairs(suites) do
    for _, test in ipairs(suite.tests) do
      local full = suite.name .. ' ' .. test.name
      if not filter or full:find(filter, 1, true) then
        local ok, err = xpcall(function()
          for _, fn in ipairs(suite.before) do
            fn()
          end
          test.fn()
        end, function(e)
          return debug.traceback(tostring(e), 2)
        end)
        for _, fn in ipairs(suite.after) do
          local aok, aerr = pcall(fn)
          if not aok and ok then
            ok, err = false, 'after_each: ' .. tostring(aerr)
          end
        end
        if ok then
          passed = passed + 1
          io.stdout:write('  ok    ' .. full .. '\n')
        else
          failed = failed + 1
          failures[#failures + 1] = { name = full, err = err }
          io.stdout:write('  FAIL  ' .. full .. '\n')
        end
      end
    end
  end
  for _, dir in ipairs(tmpdirs) do
    vim.fn.delete(dir, 'rf')
  end
  io.stdout:write('\n')
  for _, f in ipairs(failures) do
    io.stdout:write(('FAIL %s\n   %s\n\n'):format(f.name, (f.err:gsub('\n', '\n   '))))
  end
  io.stdout:write(
    ('%d passed, %d failed (%.2fs)\n'):format(passed, failed, (vim.uv.hrtime() - started) / 1e9)
  )
  return failed == 0
end

return M
