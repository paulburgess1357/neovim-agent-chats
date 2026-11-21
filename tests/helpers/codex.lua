-- Builds a synthetic Codex home directory: rollouts shaped like the real ones
-- (envelopes, payload types, key order) in both record generations, with
-- made-up content.

local T = require('helpers.harness')

local M = {}

local counter = 0
local function uuid()
  counter = counter + 1
  return ('01a%05x-0000-7000-8000-%012x'):format(counter, counter)
end
M.uuid = uuid

local function iso(ts)
  return os.date('!%Y-%m-%dT%H:%M:%S', math.floor(ts)) .. '.000Z'
end
M.iso = iso

--- JSON for a payload with `type` as its first key, the way Codex writes it.
local function typed(typ, fields)
  local body = vim.json.encode(fields or vim.empty_dict())
  if body == '{}' or body == '[]' then
    return ('{"type":"%s"}'):format(typ)
  end
  return ('{"type":"%s",%s'):format(typ, body:sub(2))
end

---@class tests.CodexRollout
---@field id string
---@field cwd string
---@field path string
---@field ts number
---@field lines string[]
local Rollout = {}
Rollout.__index = Rollout

function Rollout:_line(typ, payload_json)
  self.ts = self.ts + 1
  self.ordinal = self.ordinal + 1
  self.lines[#self.lines + 1] = ('{"timestamp":"%s","ordinal":%d,"type":"%s","payload":%s}'):format(
    iso(self.ts),
    self.ordinal,
    typ,
    payload_json
  )
  return self
end

function Rollout:event(typ, fields)
  return self:_line('event_msg', typed(typ, fields))
end

function Rollout:response(typ, fields)
  return self:_line('response_item', typed(typ, fields))
end

--- The first line. `opts`: source, instructions (bytes of base instructions), no_git.
function Rollout:meta(opts)
  opts = opts or {}
  return self:_line(
    'session_meta',
    vim.json.encode({
      session_id = self.id,
      id = self.id,
      timestamp = iso(self.ts),
      cwd = self.cwd,
      originator = 'codex-tui',
      cli_version = '0.166.0',
      source = opts.source or 'cli',
      model_provider = 'openai',
      base_instructions = { text = string.rep('i', opts.instructions or 200) },
      git = not opts.no_git and { commit_hash = string.rep('a', 40), branch = self.branch } or nil,
    })
  )
end

-- Turn boundaries (both generations) ---------------------------------------

function Rollout:task_started()
  self:event('task_started', { turn_id = uuid(), started_at = self.ts })
  return self:_line('turn_context', vim.json.encode({ cwd = self.cwd, model = 'gpt-test-1' }))
end

function Rollout:task_complete(last)
  return self:event(
    'task_complete',
    { turn_id = uuid(), last_agent_message = last, duration_ms = 1200 }
  )
end

function Rollout:turn_aborted(reason)
  return self:event('turn_aborted', { turn_id = uuid(), reason = reason or 'interrupted' })
end

function Rollout:error(message)
  return self:event('error', { message = message })
end

-- Model input/output (both generations) -------------------------------------

function Rollout:raw_user(text)
  return self:response(
    'message',
    { role = 'user', content = { { type = 'input_text', text = text } } }
  )
end

function Rollout:raw_assistant(text)
  return self:response(
    'message',
    { role = 'assistant', content = { { type = 'output_text', text = text } } }
  )
end

--- Context Codex injects ahead of the first prompt.
function Rollout:context()
  self:raw_user('# AGENTS.md instructions for ' .. self.cwd .. '\n\nBe careful.')
  return self:raw_user(
    '<environment_context>\n  <cwd>' .. self.cwd .. '</cwd>\n</environment_context>'
  )
end

function Rollout:function_call(name, args)
  self.call_id = 'call_' .. uuid():sub(1, 8)
  return self:response(
    'function_call',
    { name = name, arguments = vim.json.encode(args or vim.empty_dict()), call_id = self.call_id }
  )
end

function Rollout:function_output(output, id)
  return self:response('function_call_output', { call_id = id or self.call_id, output = output })
end

function Rollout:custom_call(name, input)
  self.call_id = 'call_' .. uuid():sub(1, 8)
  return self:response(
    'custom_tool_call',
    { status = 'completed', call_id = self.call_id, name = name, input = input }
  )
end

function Rollout:custom_output(output, id)
  return self:response(
    'custom_tool_call_output',
    { call_id = id or self.call_id, output = { { type = 'input_text', text = output } } }
  )
end

--- Bookkeeping of the kind real rollouts are full of.
function Rollout:noise(bytes)
  self:event('token_count', { info = { total = 1 } })
  self:response('reasoning', { summary = {}, encrypted_content = string.rep('x', bytes or 100) })
  return self:_line(
    'world_state',
    vim.json.encode({ full = true, state = { model = 'gpt-test-1' } })
  )
end

-- Events generation ----------------------------------------------------------

function Rollout:user_message(text)
  self:event('user_message', { message = text, images = {}, local_images = {} })
  return self:raw_user(text)
end

function Rollout:agent_message(text, phase)
  self:event('agent_message', { message = text, phase = phase or 'final_answer' })
  return self:raw_assistant(text)
end

function Rollout:agent_reasoning(text)
  return self:event('agent_reasoning', { text = text })
end

-- Items generation -----------------------------------------------------------

function Rollout:item(typ, fields)
  local item = vim.tbl_extend('force', { id = uuid() }, fields or {})
  return self:_line('event_msg', ('{"type":"item_completed","item":%s}'):format(typed(typ, item)))
end

function Rollout:item_user(text)
  self:raw_user(text)
  return self:item(
    'UserMessage',
    { content = { { type = 'text', text = text, text_elements = {} } } }
  )
end

function Rollout:item_agent(text, phase)
  self:item(
    'AgentMessage',
    { content = { { type = 'Text', text = text } }, phase = phase or 'final_answer' }
  )
  return self:raw_assistant(text)
end

function Rollout:item_command(script, output, exit_code)
  return self:item('CommandExecution', {
    command = { '/bin/bash', '-lc', script },
    cwd = self.cwd,
    status = (exit_code or 0) == 0 and 'completed' or 'failed',
    aggregated_output = output,
    exit_code = exit_code or 0,
  })
end

function Rollout:item_file_change(changes, status)
  return self:item('FileChange', { changes = changes, status = status or 'completed' })
end

function Rollout:item_mcp(server, tool, args, output, failed)
  return self:item('McpToolCall', {
    server = server,
    tool = tool,
    arguments = args or vim.empty_dict(),
    status = failed and 'failed' or 'completed',
    result = { content = { { type = 'text', text = output } }, isError = failed or false },
  })
end

function Rollout:compacted()
  return self:_line('compacted', vim.json.encode({ message = '', window_number = 1 }))
end

--- Write the rollout. `mtime` defaults to the time of its last record.
function Rollout:write(mtime)
  T.write(self.path, self.lines)
  T.touch(self.path, mtime or self.ts)
  return self
end

---@class tests.CodexHome
---@field dir string
local Home = {}
Home.__index = Home

--- A rollout under this home. `opts`: id, cwd, branch, start (epoch seconds).
---@return tests.CodexRollout
function Home:rollout(opts)
  opts = opts or {}
  local id = opts.id or uuid()
  local start = opts.start or (os.time() - 3600)
  return setmetatable({
    id = id,
    cwd = opts.cwd or '/work/project',
    branch = opts.branch or 'main',
    ts = start,
    ordinal = 0,
    lines = {},
    path = ('%s/sessions/%s/rollout-%s-%s.jsonl'):format(
      self.dir,
      os.date('%Y/%m/%d', start),
      os.date('%Y-%m-%dT%H-%M-%S', start),
      id
    ),
  }, Rollout)
end

--- Append a title to the session index.
function Home:index(id, name)
  local path = self.dir .. '/session_index.jsonl'
  local line = vim.json.encode({ id = id, thread_name = name, updated_at = iso(os.time()) }) .. '\n'
  if vim.uv.fs_stat(path) then
    T.append(path, line)
  else
    T.write(path, line)
  end
  -- Appends within one second must still read as a change.
  self.index_time = (self.index_time or os.time()) + 1
  T.touch(path, self.index_time)
end

--- A new, empty Codex home in a temporary folder, selected in the options.
---@return tests.CodexHome
function M.home(extra)
  require('helpers.env').reset()
  local root = T.tmpdir()
  local dir = root .. '/.codex'
  vim.fn.mkdir(dir .. '/sessions', 'p')
  local opts = vim.tbl_deep_extend('force', {
    providers = {
      claude = { enabled = false },
      codex = { home = dir },
      qwen = { enabled = false },
      opencode = { enabled = false },
    },
    watch = { enabled = false },
    notify = { enabled = false },
    hooks = { dir = root .. '/events', script = root .. '/share/agent-chats-hook.sh' },
    state_file = root .. '/state.json',
    cache_file = false,
  }, extra or {})
  require('agent-chats.config').setup(opts)
  return setmetatable({ dir = dir, root = root }, Home)
end

--- Start a stand-in for a running codex: a script named `codex` that blocks
--- on its input. `opts`: args, cwd, hold (a file it keeps open), body (script
--- text replacing the default), env. Returns `{ job, pid, stop }`.
function M.fake(opts)
  opts = opts or {}
  local bin = T.tmpdir() .. '/codex'
  T.write(bin, '#!/bin/sh\n' .. (opts.body or '[ -n "$HOLD" ] && exec 3<"$HOLD"\nread _\n'))
  vim.uv.fs_chmod(bin, 493)
  local cmd = { bin }
  vim.list_extend(cmd, opts.args or {})
  local env = vim.tbl_extend('force', { HOLD = opts.hold or '' }, opts.env or {})
  local job = vim.system(cmd, { cwd = opts.cwd, stdin = true, env = env })
  local proc = require('agent-chats.util.proc')
  -- The name is the script's only once the kernel has exec'd it.
  T.wait(3000, function()
    local st = proc.stat(job.pid)
    return st ~= nil and st.comm == 'codex'
  end, 'fake codex did not start')
  return {
    job = job,
    pid = job.pid,
    bin = bin,
    stop = function()
      pcall(job.write, job, nil)
      pcall(job.kill, job, 9)
      job:wait(2000)
    end,
  }
end

return M
