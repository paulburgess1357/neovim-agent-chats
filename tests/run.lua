-- Test entry point. Run it through the Makefile (`make test`), or directly:
--
--   nvim --clean --headless --cmd 'set columns=160 lines=48' -c 'luafile tests/run.lua'
--
-- SPEC=codex runs tests/spec/codex_spec.lua alone; FILTER='is working' runs
-- the tests whose name contains that text.
--
-- The screen size is set on the command line on purpose: resizing from
-- inside a headless script leaves Neovim's screen in a state where opening
-- a tab or a winbar crashes it.
--
-- Nothing here reads the real agent data in your home directory: every spec
-- builds its own in a temporary folder.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
package.path =
  table.concat({ root .. '/tests/?.lua', root .. '/tests/?/init.lua', package.path }, ';')

vim.o.swapfile = false
vim.o.shadafile = 'NONE'

-- The net under that promise. Every default location the plugin knows (its
-- state and cache under the XDG folders, the agents' homes under $HOME) is
-- moved into a temporary folder before any of it loads: what a spec forgets
-- to point at its own data lands there, never in your home. Anything that
-- does land there fails the run (see the end of this file), so the
-- forgetting is found.
local sandbox = vim.fn.tempname() .. '-agent-chats-defaults'
vim.fn.mkdir(sandbox .. '/home', 'p')
vim.env.HOME = sandbox .. '/home'
for _, name in ipairs({ 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME' }) do
  vim.env[name] = ('%s/%s'):format(sandbox, name:lower())
end
for _, name in ipairs({
  'CLAUDE_CONFIG_DIR',
  'CODEX_HOME',
  'QWEN_HOME',
  'QWEN_RUNTIME_DIR',
  'OPENCODE_CONFIG_DIR',
  'AGENT_CHATS_EVENTS_DIR',
}) do
  vim.env[name] = nil
end

-- A name used before it is declared reads as a global and is nil: a typo
-- that only fails on the path that reaches it. Every such read made from
-- the plugin's own code during the run is collected and fails the run.
local undeclared = {}
setmetatable(_G, {
  __index = function(_, name)
    local info = debug.getinfo(2, 'Sl')
    local src = info and info.source or ''
    if src:find('/lua/agent-chats/', 1, true) then
      undeclared[('%s:%d reads undeclared "%s"'):format(src:sub(2), info.currentline, name)] = true
    end
    return nil
  end,
})

-- Processes as well: an agent you have running right now is found by its
-- process, and would turn up as a chat in the middle of a test. Only what
-- this run starts itself is seen.
require('agent-chats.util.proc')._scope = vim.uv.os_getpid()

local T = require('helpers.harness')
-- Specs call these as globals, the way busted-style suites read.
for _, name in ipairs({ 'describe', 'it', 'before_each', 'after_each' }) do
  _G[name] = T[name]
end

local specs = vim.fn.globpath(root .. '/tests/spec', '*_spec.lua', false, true)
table.sort(specs)
local only = vim.env.SPEC
if only and only ~= '' then
  specs = vim.tbl_filter(function(spec)
    return vim.fs.basename(spec) == only .. '_spec.lua'
  end, specs)
end

local broken = 0
for _, spec in ipairs(specs) do
  T.new_file()
  local ok, err = pcall(dofile, spec)
  if not ok then
    broken = broken + 1
    io.stdout:write(('could not load %s:\n   %s\n'):format(spec, tostring(err)))
  end
end

local filter = vim.env.FILTER
local ok = T.run((filter and filter ~= '') and filter or nil)
for message in pairs(undeclared) do
  ok = false
  io.stdout:write('UNDECLARED ' .. message .. '\n')
end
-- Everything under it, names that start with a dot included (`~/.claude`
-- is where an installer would write), folders included: only the empty
-- `home` made above belongs there. And what Neovim makes for itself: from
-- 0.13 on it keeps its logs in a folder under its state folder, and makes
-- that as it runs. (The plugin's own state would be beside it, in
-- `agent-chats`, and that is still found.)
local app = 'xdg_state_home/' .. (vim.env.NVIM_APPNAME or 'nvim')
local neovims = { xdg_state_home = true, [app] = true, [app .. '/logs'] = true }
for name, kind in vim.fs.dir(sandbox, { depth = 20 }) do
  local own = (name == 'home' and kind == 'directory')
    or (neovims[name] and kind == 'directory')
    or name:sub(1, #app + 6) == app .. '/logs/'
  if not own then
    ok = false
    io.stdout:write(('DEFAULT LOCATION written to by a spec: %s (%s)\n'):format(name, kind))
  end
end
io.stdout:flush()
vim.cmd((ok and broken == 0) and 'qa!' or 'cquit 1')
