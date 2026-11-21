-- Hook events for tests: lines written the way the hook writes them, and
-- the real hook script run against a made-up payload.

local T = require('helpers.harness')

local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

--- The script the agents run.
M.script = root .. '/scripts/agent-chats-hook.sh'

--- The log of `agent`'s session `id` under the configured events folder.
function M.log(agent, id)
  return assert(require('agent-chats.events').path(agent, id))
end

--- Append one event to the log of `agent`'s session `id`. `fields` may hold
--- t (default: now), type, tool, agent, src, reason, pid, req, path, cwd.
function M.event(agent, id, name, fields)
  local rec = vim.tbl_extend('force', { t = os.time(), e = name }, fields or {})
  local path = M.log(agent, id)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  T.append(path, vim.json.encode(rec) .. '\n')
  return path
end

--- Run the hook script as an agent would: `payload` (a table, or raw text)
--- on its standard input. `opts`: shell (default "sh"), args (after the
--- agent name), dir (events folder; default the configured one).
---@return { code: integer, stdout: string, stderr: string }
function M.run(agent, payload, opts)
  opts = opts or {}
  local cmd = vim.split(opts.shell or 'sh', ' ', { plain = true })
  vim.list_extend(cmd, { M.script, agent })
  vim.list_extend(cmd, opts.args or {})
  local res = vim
    .system(cmd, {
      stdin = type(payload) == 'table' and vim.json.encode(payload) or (payload or ''),
      env = { AGENT_CHATS_EVENTS_DIR = opts.dir or require('agent-chats.events').dir() },
      text = true,
    })
    :wait(10000)
  return { code = res.code, stdout = res.stdout or '', stderr = res.stderr or '' }
end

--- Decoded lines of a log.
function M.lines(agent, id)
  local out = {}
  local f = io.open(M.log(agent, id), 'r')
  if not f then
    return out
  end
  for line in f:lines() do
    out[#out + 1] = vim.json.decode(line)
  end
  f:close()
  return out
end

return M
