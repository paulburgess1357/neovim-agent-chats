-- Builds a synthetic opencode data directory: a SQLite database with the
-- tables and columns the provider reads, filled with made-up content.

local T = require('helpers.harness')
local sqlite = require('agent-chats.util.sqlite')

local M = {}

local ROOT = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

local SCHEMA = [[
pragma journal_mode = wal;
create table session (id text primary key, project_id text not null, parent_id text, slug text,
  directory text not null, title text not null, version text, time_created integer,
  time_updated integer, time_archived integer, agent text, model text);
create table message (id text primary key, session_id text not null, time_created integer,
  time_updated integer, data text not null);
create table part (id text primary key, message_id text not null, session_id text not null,
  time_created integer, time_updated integer, data text not null);
create index message_session_time_created_id_idx on message (session_id, time_created, id);
create index part_session_idx on part (session_id);
create index part_message_id_id_idx on part (message_id, id);
]]

local counter = 0
local function id(prefix)
  counter = counter + 1
  return ('%s_%012x'):format(prefix, counter)
end

---@class tests.OpencodeHome
---@field dir string
---@field db string
local Home = {}
Home.__index = Home

--- Run one statement with bound parameters against the database.
function Home:run(sql, params)
  local db = assert(sqlite.open(self.db, { write = true }))
  local rows, err = db:query(sql, params)
  db:close()
  assert(rows, err)
  return rows
end

---@class tests.OpencodeSession
---@field id string
---@field home tests.OpencodeHome
---@field ts integer Milliseconds; advances with every row written.
---@field msg string? Id of the message parts are added to.
local Session = {}
Session.__index = Session

function Session:_tick()
  self.ts = self.ts + 1000
  return self.ts
end

function Session:_message(data)
  local ts = self:_tick()
  data.time = data.time or { created = ts }
  self.msg = id('msg')
  self.msg_data = data
  self.home:run(
    'insert into message (id, session_id, time_created, time_updated, data) values (?, ?, ?, ?, ?)',
    { self.msg, self.id, ts, ts, vim.json.encode(data) }
  )
  return self
end

--- Add a part to the current message. Returns the part id in `self.part`.
function Session:part(data)
  local ts = self:_tick()
  self.part_id = id('prt')
  self.home:run(
    'insert into part (id, message_id, session_id, time_created, time_updated, data) values (?, ?, ?, ?, ?, ?)',
    { self.part_id, self.msg, self.id, ts, ts, vim.json.encode(data) }
  )
  return self
end

function Session:user(text, extra)
  self:_message({
    role = 'user',
    agent = 'build',
    model = { providerID = 'test', modelID = 'model-1' },
  })
  return self:part(vim.tbl_extend('force', { type = 'text', text = text }, extra or {}))
end

--- Start an assistant message (not yet completed).
function Session:assistant()
  return self:_message({
    role = 'assistant',
    agent = 'build',
    modelID = 'model-1',
    providerID = 'test',
  })
end

function Session:text(text)
  return self:part({ type = 'text', text = text })
end

function Session:reasoning(text)
  return self:part({ type = 'reasoning', text = text })
end

function Session:tool(name, state)
  return self:part({ type = 'tool', tool = name, callID = id('call'), state = state })
end

--- Complete the current assistant message. `fields` may carry `error`.
function Session:finish(reason, fields)
  local ts = self:_tick()
  local data = vim.tbl_extend('force', self.msg_data, fields or {})
  data.time = { created = data.time.created, completed = ts }
  if reason then
    data.finish = reason
  end
  self.msg_data = data
  self.home:run(
    'update message set data = ?, time_updated = ? where id = ?',
    { vim.json.encode(data), ts, self.msg }
  )
  return self
end

--- A whole assistant reply in one go.
function Session:reply(text)
  return self:assistant():text(text):finish('stop')
end

--- Rewrite the latest part in place, as streaming does.
function Session:rewrite(data)
  local ts = self:_tick()
  self.home:run(
    'update part set data = ?, time_updated = ? where id = ?',
    { vim.json.encode(data), ts, self.part_id }
  )
  return self
end

function Session:archive()
  self.home:run('update session set time_archived = ? where id = ?', { self:_tick(), self.id })
  return self
end

--- A session. `opts`: directory, title, parent, start (epoch seconds), model.
---@return tests.OpencodeSession
function Home:session(opts)
  opts = opts or {}
  local s = setmetatable({
    id = id('ses'),
    home = self,
    ts = (opts.start or (os.time() - 86400)) * 1000,
  }, Session)
  self:run(
    'insert into session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, agent, model) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    {
      s.id,
      'global',
      opts.parent or vim.NIL,
      'test-slug',
      opts.directory or '/work/project',
      opts.title or 'Test chat',
      '1.17.4',
      s.ts,
      s.ts,
      'build',
      vim.json.encode({ id = opts.model or 'session-model', providerID = 'test' }),
    }
  )
  return s
end

--- A stand-in for the `opencode` command that answers `db <sql> --format json`
--- from this home's database and logs its arguments. Returns its path and log.
function Home:fake_cli()
  local dir = T.tmpdir()
  local script, log = dir .. '/fake.lua', dir .. '/argv.log'
  T.write(script, {
    ('vim.opt.rtp:prepend(%q)'):format(ROOT),
    ('local log = assert(io.open(%q, "a"))'):format(log),
    'log:write(vim.json.encode({ argv = { arg[1], arg[2], arg[3], arg[4] }, xdg = vim.env.XDG_DATA_HOME }) .. "\\n") log:close()',
    'if arg[1] ~= "db" or arg[3] ~= "--format" or arg[4] ~= "json" then os.exit(2) end',
    'local db = assert(require("agent-chats.util.sqlite").open(vim.env.XDG_DATA_HOME .. "/opencode/opencode.db"))',
    'local rows, err = db:query(arg[2])',
    'db:close()',
    'if not rows then io.stderr:write(err .. "\\n") os.exit(1) end',
    'io.stdout:write(#rows == 0 and "[]" or vim.json.encode(rows), "\\n")',
  })
  local exe = dir .. '/opencode'
  T.write(
    exe,
    { '#!/bin/sh', ('exec %q --clean --headless -l %q "$@"'):format(vim.v.progpath, script) }
  )
  vim.fn.setfperm(exe, 'rwxr-xr-x')
  return exe, log
end

--- A long-running stand-in process named `opencode`, started in `cwd` with
--- `args`. Returns the job; kill it with `M.kill`.
function M.spawn(cwd, args, wrapper)
  local dir = T.tmpdir()
  local exe = dir .. '/opencode'
  T.write(exe, {
    '#!/bin/sh',
    wrapper and ('%q "$@" &'):format(wrapper) or 'sleep 300 &',
    'child=$!',
    "trap 'kill $child 2>/dev/null; exit 0' TERM INT",
    'wait $child',
  })
  vim.fn.setfperm(exe, 'rwxr-xr-x')
  vim.fn.mkdir(cwd, 'p')
  local cmd = { exe }
  vim.list_extend(cmd, args or {})
  return vim.system(cmd, { cwd = cwd }), exe
end

function M.kill(job)
  pcall(function()
    job:kill('sigterm')
    job:wait(2000)
  end)
end

--- A new, empty opencode data directory, selected in the options.
---@return tests.OpencodeHome
function M.home(extra)
  require('helpers.env').reset()
  local root = T.tmpdir()
  local dir = root .. '/share/opencode'
  vim.fn.mkdir(dir, 'p')
  local home = setmetatable({ dir = dir, root = root, db = dir .. '/opencode.db' }, Home)
  local db = assert(sqlite.open(home.db, { write = true }))
  assert(db:exec(SCHEMA))
  db:close()
  local opts = vim.tbl_deep_extend('force', {
    providers = {
      opencode = { home = dir, config_dir = root .. '/config/opencode' },
      claude = { enabled = false },
      codex = { enabled = false },
      qwen = { enabled = false },
    },
    watch = { enabled = false },
    notify = { enabled = false },
    -- The introduction is for a first look at the board, not for a test of
    -- what the pane shows.
    board = { intro = false },
    hooks = { dir = root .. '/events', script = root .. '/share/agent-chats-hook.sh' },
    state_file = root .. '/state.json',
    cache_file = false,
  }, extra or {})
  require('agent-chats.config').setup(opts)
  local provider = require('agent-chats.providers.opencode')
  provider._query = nil
  provider._reset()
  return home
end

return M
