-- How a chat is named and described, in one place, so the board, the
-- pickers, notifications and the statusline all say the same thing.

local fs = require('agent-chats.util.fs')
local providers = require('agent-chats.providers')
local state = require('agent-chats.state')
local status = require('agent-chats.status')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

local M = {}

--- The chat's title: the name you gave it, then the agent's own title, then
--- the first prompt.
---@param chat agent_chats.Chat
---@param max integer?
function M.title(chat, max)
  local t = state.name(chat.key)
  if not t and chat.name_explicit then
    t = chat.name
  end
  t = t or chat.title
  if not t or t == '' then
    t = text.first_line(chat.first_prompt) or text.first_line(chat.last_prompt)
  end
  if not t or t == '' then
    t = chat.name
  end
  if not t or t == '' then
    t = chat.subagent and (chat.agent_type or 'subagent') or '(no prompt yet)'
  end
  return text.oneline(t, max)
end

--- Short folder name: the last component of the chat's working directory.
function M.folder(chat)
  return chat.cwd and fs.basename(chat.cwd) or ''
end

--- `claude · ~/Repos/thing · main`
function M.where(chat)
  local parts = { providers.label(chat.provider) }
  if chat.cwd then
    parts[#parts + 1] = fs.tilde(chat.cwd)
  end
  if chat.branch and chat.branch ~= '' and chat.branch ~= 'HEAD' then
    parts[#parts + 1] = chat.branch
  end
  return table.concat(parts, ' · ')
end

-- Where a running chat's status comes from, in a few words.
local SOURCES = {
  hooks = 'its hooks',
  registry = "the agent's own list of running sessions",
  query = 'the agent itself',
  transcript = 'its transcript file',
}

--- `its hooks`, `the agent's own list of running sessions`, `its transcript
--- file`: who said what the chat is doing. nil for a chat that is not
--- running (nothing to be said).
---@return string?
function M.source(chat)
  if not chat.live or chat.subagent or chat.stub then
    return nil
  end
  local s = SOURCES[chat.source or 'transcript'] or chat.source
  if chat.answered then
    s = s .. ', and you answered its request in its terminal'
  end
  return s
end

--- What a chat that needs you is waiting for: lines, most telling first.
---@param chat agent_chats.Chat
---@param get (fun(key: string): agent_chats.Chat?)?  Looks up the chat it waits through.
---@return string[]
function M.waiting(chat, get)
  local out = {}
  local function push(s)
    if type(s) == 'string' and s ~= '' and not vim.tbl_contains(out, s) then
      out[#out + 1] = s
    end
  end
  --- What it is doing, unless what it waits for has said that already
  --- ("permission to run: make test", then "Bash: make test").
  local function doing(c)
    local what = type(c.activity) == 'string' and c.activity:match('^[%w_%-]+: (.+)$') or nil
    if what and type(c.waiting_for) == 'string' and c.waiting_for:find(what, 1, true) then
      return
    end
    push(c.activity)
  end
  local child = chat.through and get and get(chat.through) or nil
  if child then
    push('A chat it started: ' .. M.title(child, 80))
    push(child.waiting_for)
    doing(child)
    return out
  end
  push(chat.waiting_for)
  doing(chat)
  return out
end

--- When the chat last moved, as a short age.
function M.age(chat, now)
  return time.ago(chat.updated or chat.mtime, now)
end

--- One line for pickers: `● claude  Title  folder  2m`.
function M.line(chat, icons)
  local glyph = icons and icons[chat.status] or ''
  return ('%s %-8s %s  [%s]  %s'):format(
    glyph,
    providers.label(chat.provider),
    M.title(chat, 70),
    M.folder(chat),
    M.age(chat)
  )
end

return M
