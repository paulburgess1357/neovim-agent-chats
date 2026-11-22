-- Reading the conversations for a text.
--
-- A search on the board narrows the rows at once from what the index holds
-- (names, folders, the first and the latest exchange). This is its other
-- half: it reads the conversations themselves, every prompt and reply of
-- every chat, and the line each tool call has there ("Bash · make test"):
-- what a conversation shows when it is read is what a search finds. What
-- a call was given and what it gave back is read as well when
-- `search.tools` is on. `rg`, when installed, narrows the files worth
-- reading first; without it the search still works, just slower.

local async = require('agent-chats.util.async')
local config = require('agent-chats.config')
local providers = require('agent-chats.providers')
local store = require('agent-chats.store')
local text = require('agent-chats.util.text')

local M = {}

local generation = 0

-- Around the match: enough to recognise the passage.
local BEFORE, AFTER = 50, 160

local function excerpt(body, s, e)
  local from = math.max(1, s - BEFORE)
  local to = math.min(#body, e + AFTER)
  local out = text.clip_tail(text.clip(body, to), to - from + 1)
  out = text.oneline(out)
  return (from > 1 and '…' or '') .. out .. (to < #body and '…' or '')
end

--- Matches of `query` in one conversation.
---@param messages agent_chats.Message[]
---@param query string
---@param opts { max_hits: integer, tools: boolean }
---@return agent_chats.Hit[]
function M.scan(messages, query, opts)
  local match = text.matcher(query)
  local hits = {}
  for i, m in ipairs(messages) do
    local searchable = m.role == 'user'
      or m.role == 'assistant'
      or m.role == 'tool'
      or (opts.tools and m.role == 'tool_result')
    if searchable then
      local body = m.text
      if m.role == 'tool' then
        -- Its line as the conversation shows it; with `search.tools`, what
        -- it was given too.
        body = (m.name or 'tool') .. ' · ' .. (m.summary or '')
        if opts.tools then
          body = body .. '\n' .. (m.input or '')
        end
      end
      local s, e = match(body)
      if s then
        hits[#hits + 1] = { index = i, role = m.role, excerpt = excerpt(body, s, e) }
        if #hits >= opts.max_hits then
          break
        end
      end
    end
  end
  return hits
end

-- Whether the query appears in a JSON file exactly as typed (no character
-- that JSON would escape), so a raw text search finds every file with it.
local function greppable(query)
  return not query:find('[%c"\\\128-\255]')
end

--- Paths among `paths` that contain `query`, or nil when rg cannot say.
---@return table<string, boolean>?
local function rg_filter(query, paths)
  if #paths == 0 or vim.fn.executable('rg') ~= 1 or not greppable(query) then
    return nil
  end
  local found = {}
  for start = 1, #paths, 200 do
    local cmd = {
      'rg',
      '--files-with-matches',
      '--fixed-strings',
      '--smart-case',
      '--no-messages',
      '--no-config',
      '-e',
      query,
      '--',
    }
    for i = start, math.min(start + 199, #paths) do
      cmd[#cmd + 1] = paths[i]
    end
    local res = async.system(cmd, { timeout = 20000 })
    -- 0: matches, 1: none. Anything else: do not trust it.
    if res.code ~= 0 and res.code ~= 1 then
      return nil
    end
    for line in (res.stdout or ''):gmatch('[^\n]+') do
      found[line] = true
    end
  end
  return found
end

--- Search every chat in the index. `on_update(hits, running)` is called as
--- results come in and once more when the search ends.
---@param query string
---@param on_update fun(hits: table<string, agent_chats.Hit[]>, running: boolean)
function M.run(query, on_update)
  generation = generation + 1
  local mine = generation
  local opts = config.get().search
  local hits = {}

  async.run(function()
    local chats = store.list({ archived = true })
    table.sort(chats, function(a, b)
      return (a.updated or 0) > (b.updated or 0)
    end)

    -- Narrow the field per agent.
    local paths, grep = {}, {}
    for _, chat in ipairs(chats) do
      if chat.path then
        paths[#paths + 1] = chat.path
      end
    end
    local with_match = rg_filter(query, paths)
    for _, p in ipairs(providers.enabled()) do
      if p.grep then
        local ok, ids = pcall(p.grep, query)
        if ok and type(ids) == 'table' then
          grep[p.name] = ids
        end
      end
    end

    local since = vim.uv.hrtime()
    for _, chat in ipairs(chats) do
      if mine ~= generation then
        return
      end
      local wanted = true
      if chat.path then
        wanted = with_match == nil or with_match[chat.path] == true
      elseif grep[chat.provider] then
        wanted = grep[chat.provider][chat.id] == true
      end
      local p = wanted and not chat.stub and providers.get(chat.provider)
      if p then
        local ok, messages = pcall(p.messages, chat, {})
        if ok and type(messages) == 'table' then
          local found = M.scan(messages, query, opts)
          if #found > 0 then
            hits[chat.key] = found
            if vim.uv.hrtime() - since > 2e8 then
              since = vim.uv.hrtime()
              on_update(hits, true)
            end
          end
        end
        async.tick()
      end
    end
  end, function(ok, err)
    if mine ~= generation then
      return
    end
    if not ok then
      vim.notify('agent-chats: search failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
    on_update(hits, false)
  end)
end

--- Stop a search in flight.
function M.cancel()
  generation = generation + 1
end

return M
