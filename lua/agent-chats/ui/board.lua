-- The board: every chat in one list, with a pane beside it.
--
--   +--------------------------------------+---------------------------+
--   |  12 chats · 2 need you · 3 working   |                           |
--   |                                      |  the chat under the       |
--   |  ▾ Needs you  2                      |  cursor: its live         |
--   |   ● claude  Fix flaky restore   2m   |  terminal when it runs    |
--   |  ▾ Working  3                        |  in this Neovim, a        |
--   |   ◐ codex   Port renderer      41s   |  summary otherwise        |
--   +--------------------------------------+---------------------------+
--
-- The list is a plain buffer rendered from the index (store.lua). The pane
-- follows the cursor while the list has focus; opening a chat or a
-- transcript puts it in the pane and moves the cursor there.

local api = vim.api
local config = require('agent-chats.config')
local display = require('agent-chats.display')
local fs = require('agent-chats.util.fs')
local git = require('agent-chats.util.git')
local preview = require('agent-chats.ui.preview')
local providers = require('agent-chats.providers')
local state = require('agent-chats.state')
local status = require('agent-chats.status')
local store = require('agent-chats.store')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

local M = {}

local ns = api.nvim_create_namespace('agent-chats-board')
local ns_spin = api.nvim_create_namespace('agent-chats-spinner')
local GROUP_MODES = { 'status', 'folder', 'provider', 'worktree' }

---@class agent_chats.Row
---@field kind "header"|"blank"|"group"|"chat"|"hit"|"more"|"info"
---@field chat agent_chats.Chat?
---@field group string?   Group id.
---@field hit agent_chats.Hit?
---@field id string?      Identity used to keep the cursor in place.

local S = {
  buf = nil, ---@type integer?
  win = nil, ---@type integer?
  pane_win = nil, ---@type integer?
  pane_on = true,
  pane_mode = nil, ---@type string?
  preview_buf = nil, ---@type integer?
  layout = nil, ---@type string?
  tab = nil, ---@type integer?
  prev_win = nil, ---@type integer?
  prev_tab = nil, ---@type integer?
  prev_buf = nil, ---@type integer?
  rows = {}, ---@type agent_chats.Row[]
  group_by = nil, ---@type string?
  filter = '',
  expanded = {}, ---@type table<string, boolean>
  full = {}, ---@type table<string, boolean>
  show_archived = false,
  search = nil, ---@type { query: string, hits: table<string, agent_chats.Hit[]>, running: boolean }?
  spin = {}, ---@type { [1]: integer, [2]: integer }[]
  frame = 1,
  timer = nil,
  unsub = nil,
  closing = false,
  pending_pane = false,
}

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

function M.is_open()
  return valid_win(S.win) and valid_buf(S.buf)
end

-----------------------------------------------------------------------------
-- Building rows
-----------------------------------------------------------------------------

local function haystack(chat)
  return table
    .concat({
      display.title(chat),
      chat.cwd or '',
      chat.branch or '',
      providers.label(chat.provider),
      status.labels[chat.status] or '',
      table.concat(state.labels(chat.key), ' '),
      state.note(chat.key) or '',
      chat.last_prompt or '',
      chat.last_reply or '',
    }, '\n')
    :lower()
end

local function matches(chat, terms)
  if #terms == 0 then
    return true
  end
  local hay = haystack(chat)
  for _, term in ipairs(terms) do
    if not hay:find(term, 1, true) then
      return false
    end
  end
  return true
end

local function visible_chats()
  local terms = vim.split(S.filter:lower(), '%s+', { trimempty = true })
  local out = {}
  for _, chat in ipairs(store.list({ archived = S.show_archived })) do
    local keep = matches(chat, terms)
    if keep and S.search then
      keep = S.search.hits[chat.key] ~= nil
    end
    if keep then
      out[#out + 1] = chat
    end
  end
  return out
end

local function chat_order(a, b)
  local pa, pb = state.pinned(a.key), state.pinned(b.key)
  if pa ~= pb then
    return pa
  end
  if S.group_by ~= 'status' then
    local ra, rb = status.rank[a.status] or 9, status.rank[b.status] or 9
    if ra ~= rb then
      return ra < rb
    end
  end
  local ua, ub = a.updated or 0, b.updated or 0
  if ua ~= ub then
    return ua > ub
  end
  return a.key < b.key
end

local function request_git(cwd)
  if not cwd then
    return nil
  end
  local had = git.cached(cwd)
  return git.info(cwd, function(info)
    -- First answer for this folder (or a changed one): draw it.
    if not had or had.dirty ~= info.dirty or had.branch ~= info.branch or had.root ~= info.root then
      had = info
      vim.schedule(function()
        if M.is_open() then
          M.render()
        end
      end)
    end
  end)
end

---@return { id: string, label: string, hl: string, extra: string?, chats: agent_chats.Chat[], latest: number }[]
local function build_groups(chats)
  local mode = S.group_by
  local by, order = {}, {}
  local function group(id, label, hl, extra)
    local g = by[id]
    if not g then
      g = { id = mode .. ':' .. id, label = label, hl = hl, extra = extra, chats = {}, latest = 0 }
      by[id] = g
      order[#order + 1] = g
    end
    return g
  end

  for _, chat in ipairs(chats) do
    local g
    if mode == 'provider' then
      g = group(chat.provider, providers.label(chat.provider), 'AgentChatsGroup')
    elseif mode == 'folder' then
      local cwd = chat.cwd or '(unknown folder)'
      local info = request_git(chat.cwd)
      local extra = info
          and info.dirty
          and info.dirty > 0
          and (config.get().icons.dirty .. info.dirty)
        or nil
      g = group(cwd, fs.tilde(cwd), 'AgentChatsFolder', extra)
    elseif mode == 'worktree' then
      local info = request_git(chat.cwd)
      if info and info.root then
        local label = fs.basename(info.repo or info.root)
        local branch = info.branch or (info.detached and 'detached') or nil
        if branch then
          label = label .. ' › ' .. branch
        end
        local extra = {}
        if info.worktree then
          extra[#extra + 1] = fs.tilde(info.root)
        end
        if (info.dirty or 0) > 0 then
          extra[#extra + 1] = config.get().icons.dirty .. info.dirty
        end
        if (info.ahead or 0) > 0 then
          extra[#extra + 1] = '↑' .. info.ahead
        end
        if (info.behind or 0) > 0 then
          extra[#extra + 1] = '↓' .. info.behind
        end
        g = group(info.root, label, 'AgentChatsFolder', table.concat(extra, '  '))
      else
        local cwd = chat.cwd or '(unknown folder)'
        local suffix = info and info.missing and 'folder is gone'
          or (info and 'not a git repository' or nil)
        g = group(cwd, fs.tilde(cwd), 'AgentChatsFolder', suffix)
      end
    else
      g = group(chat.status, status.labels[chat.status] or chat.status, status.hl[chat.status])
    end
    g.chats[#g.chats + 1] = chat
    g.latest = math.max(g.latest, chat.updated or 0)
  end

  if mode == 'status' then
    table.sort(order, function(a, b)
      return (status.rank[a.chats[1].status] or 9) < (status.rank[b.chats[1].status] or 9)
    end)
  elseif mode == 'provider' then
    local rank = {}
    for i, p in ipairs(providers.all()) do
      rank[p.name] = i
    end
    table.sort(order, function(a, b)
      return (rank[a.chats[1].provider] or 99) < (rank[b.chats[1].provider] or 99)
    end)
  else
    -- Folders with something going on first, then by recency.
    local function urgency(g)
      local best = 9
      for _, c in ipairs(g.chats) do
        best = math.min(best, status.rank[c.status] or 9)
      end
      return math.min(best, 3)
    end
    table.sort(order, function(a, b)
      local ua, ub = urgency(a), urgency(b)
      if ua ~= ub then
        return ua < ub
      end
      return a.latest > b.latest
    end)
  end
  for _, g in ipairs(order) do
    table.sort(g.chats, chat_order)
  end
  return order
end

-----------------------------------------------------------------------------
-- Drawing
-----------------------------------------------------------------------------

local function Line()
  return { parts = {}, hls = {}, marks = {}, len = 0, width = 0 }
end

local function add(line, s, hl)
  if not s or s == '' then
    return
  end
  if hl then
    line.marks[#line.marks + 1] = { line.len, line.len + #s, hl }
  end
  line.parts[#line.parts + 1] = s
  line.hls[#line.parts] = hl or false
  line.len = line.len + #s
  line.width = line.width + text.width(s)
end

-- Append every part of `other` to `line`, highlights included.
local function extend(line, other)
  for i, part in ipairs(other.parts) do
    add(line, part, other.hls[i] or nil)
  end
end

local function glyph_for(chat, icons)
  return icons[chat.status] or '?'
end

local function chat_line(chat, depth, cols, width, now)
  local icons = config.get().icons
  local line = Line()
  local hl = status.hl[chat.status] or 'AgentChatsIdle'
  add(line, ' ' .. string.rep('  ', depth))
  if depth > 0 then
    add(line, icons.sub .. ' ', 'AgentChatsDim')
  end
  local glyph_col = line.len
  add(line, glyph_for(chat, icons), hl)
  add(line, chat.inferred and icons.inferred or ' ', hl)
  add(line, ' ')
  if cols.provider > 0 then
    -- A subagent row sits under its chat, two cells in: give those back.
    local label = chat.subagent and ''
      or (icons.providers[chat.provider] or providers.label(chat.provider))
    add(
      line,
      text.fit(label, math.max(0, cols.provider - (depth > 0 and 4 or 0))),
      'AgentChatsProvider'
    )
    add(line, '  ')
  end

  -- Right-hand columns, built first so the title knows its room.
  local right = Line()
  if cols.folder > 0 then
    add(
      right,
      text.fit(chat.subagent and '' or display.folder(chat), cols.folder),
      'AgentChatsFolder'
    )
    add(right, '  ')
  end
  if cols.branch > 0 then
    local branch = (chat.branch and chat.branch ~= 'HEAD') and chat.branch or ''
    add(right, text.fit(chat.subagent and '' or branch, cols.branch), 'AgentChatsBranch')
    add(right, '  ')
  end
  add(right, text.rfit(time.ago(chat.updated or chat.mtime, now), 4), 'AgentChatsAge')
  add(right, ' ')

  local suffix = Line()
  if not chat.subagent then
    if state.note(chat.key) then
      add(suffix, ' ' .. icons.note, 'AgentChatsNote')
    end
    local queued = #state.queue(chat.key)
    if queued > 0 then
      add(suffix, (' %s%d'):format(icons.queue, queued), 'AgentChatsQueue')
    end
    for _, label in ipairs(state.labels(chat.key)) do
      add(suffix, ' #' .. label, 'AgentChatsLabel')
    end
    if chat.live and not chat.term then
      add(suffix, ' ' .. icons.elsewhere, 'AgentChatsDim')
    end
  end

  local pinned = not chat.subagent and state.pinned(chat.key)
  if pinned then
    add(line, icons.pin .. ' ', 'AgentChatsPin')
  end
  local room = math.max(8, width - line.width - right.width - 1)
  local suffix_w = math.min(suffix.width, math.max(0, room - 12))
  local name = display.title(chat)
  if chat.subagent and chat.agent_type then
    name = chat.agent_type .. ': ' .. name
  end
  local title = text.truncate(name, room - suffix_w)
  local title_hl = (chat.status == 'done' or chat.status == 'attention') and 'AgentChatsUnread'
    or (chat.status == 'ended' and 'AgentChatsEnded' or 'AgentChatsTitle')
  add(line, title, title_hl)
  if suffix_w >= suffix.width then
    extend(line, suffix)
  end
  add(line, string.rep(' ', math.max(1, width - line.width - right.width)))
  extend(line, right)
  return line, glyph_col
end

local function column_widths(chats, width)
  local cols = { provider = 0, folder = 0, branch = 0 }
  if S.group_by ~= 'provider' and width >= 48 then
    for _, p in ipairs(providers.enabled()) do
      local label = config.get().icons.providers[p.name] or p.label
      cols.provider = math.max(cols.provider, text.width(label))
    end
  end
  local folder, branch = 0, 0
  for _, chat in ipairs(chats) do
    folder = math.max(folder, text.width(display.folder(chat)))
    if chat.branch and chat.branch ~= 'HEAD' then
      branch = math.max(branch, text.width(chat.branch))
    end
  end
  if S.group_by ~= 'folder' and S.group_by ~= 'worktree' and width >= 56 then
    cols.folder = math.min(folder, 18)
  end
  if width >= 78 then
    cols.branch = math.min(branch, 16)
  end
  return cols
end

local function header_line(chats, width)
  -- The numbers are those of the rows below: with a filter on, of what
  -- the filter left.
  local c = { attention = 0, working = 0, done = 0 }
  for _, chat in ipairs(chats) do
    if c[chat.status] then
      c[chat.status] = c[chat.status] + 1
    end
  end
  local line = Line()
  add(line, ' ')
  if S.search then
    local hits = 0
    for _, chat in ipairs(chats) do
      hits = hits + #(S.search.hits[chat.key] or {})
    end
    add(line, ('Search “%s”'):format(S.search.query), 'AgentChatsHeader')
    add(
      line,
      S.search.running and '  searching…'
        or ('  %d match%s in %d chat%s'):format(
          hits,
          hits == 1 and '' or 'es',
          #chats,
          #chats == 1 and '' or 's'
        ),
      'AgentChatsCount'
    )
  else
    add(line, ('%d chat%s'):format(#chats, #chats == 1 and '' or 's'), 'AgentChatsHeader')
    if c.attention > 0 then
      add(line, ' · ')
      add(line, ('%d need you'):format(c.attention), 'AgentChatsAttention')
    end
    if c.working > 0 then
      add(line, ' · ')
      add(line, ('%d working'):format(c.working), 'AgentChatsWorking')
    end
    if c.done > 0 then
      add(line, ' · ')
      add(line, ('%d unread'):format(c.done), 'AgentChatsDone')
    end
  end
  -- The right-hand side, most telling piece first. On a narrow list the
  -- last pieces are left out one by one rather than all at once.
  local pieces = {}
  if S.filter ~= '' then
    pieces[#pieces + 1] = { 'filter: ' .. S.filter, 'AgentChatsMatch' }
  end
  if S.filter ~= '' or S.search then
    local clears = config.hint('clear', '%s clears')
    if clears ~= '' then
      pieces[#pieces + 1] = { clears, 'AgentChatsDim' }
    end
  end
  local help = config.hint('help', '%s help')
  if help ~= '' then
    pieces[#pieces + 1] = { help, 'AgentChatsDim' }
  end
  if S.show_archived then
    pieces[#pieces + 1] = { 'archived shown', 'AgentChatsDim' }
  end
  pieces[#pieces + 1] = { 'by ' .. S.group_by, 'AgentChatsDim' }
  for keep = #pieces, 1, -1 do
    local right = Line()
    for i = 1, keep do
      add(right, pieces[i][1], pieces[i][2])
      add(right, i < keep and '   ' or ' ')
    end
    if line.width + right.width + 2 <= width then
      add(line, string.rep(' ', width - line.width - right.width))
      extend(line, right)
      break
    end
  end
  return line
end

local function row_id(row)
  if row.kind == 'chat' then
    return row.chat.key
  elseif row.kind == 'hit' then
    return row.chat.key .. '#' .. row.hit.index
  elseif row.kind == 'group' or row.kind == 'more' then
    return row.kind .. ':' .. row.group
  end
  return nil
end

local function selectable(row)
  return row ~= nil and row.kind ~= 'header' and row.kind ~= 'blank' and row.kind ~= 'info'
end

--- The window of the list that counts. The list can be shown twice (a
--- split of its window): the one the keys are typed in is the one meant.
local function list_win()
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) == S.buf then
    return win
  end
  return S.win
end

--- The row under the cursor.
---@return agent_chats.Row?
function M.row()
  if not M.is_open() then
    return nil
  end
  return S.rows[api.nvim_win_get_cursor(list_win())[1]]
end

--- The chat under the cursor, if the cursor is on one.
---@return agent_chats.Chat?, agent_chats.Row?
function M.current()
  local row = M.row()
  if row and row.chat then
    return row.chat, row
  end
  return nil, row
end

local function place_cursor(id, fallback_line)
  if not valid_win(S.win) then
    return
  end
  local target
  if id then
    for i, row in ipairs(S.rows) do
      if row.id == id then
        target = i
        break
      end
    end
  end
  if not target and not fallback_line then
    -- First time: start on a chat, not on a heading.
    for i, row in ipairs(S.rows) do
      if row.kind == 'chat' then
        target = i
        break
      end
    end
  end
  if not target then
    local from = math.min(fallback_line or 1, #S.rows)
    for i = from, #S.rows do
      if selectable(S.rows[i]) then
        target = i
        break
      end
    end
    if not target then
      for i = math.min(from, #S.rows), 1, -1 do
        if selectable(S.rows[i]) then
          target = i
          break
        end
      end
    end
  end
  if target then
    pcall(api.nvim_win_set_cursor, S.win, { target, 1 })
  end
end

local update_pane

--- Sentences joined by a space, the empty ones (a hint whose key is not
--- bound) left out.
local function sentences(...)
  local out = {}
  for i = 1, select('#', ...) do
    local piece = select(i, ...)
    if piece and piece ~= '' then
      out[#out + 1] = piece
    end
  end
  return table.concat(out, ' ')
end

--- What to say when there is no chat to list: what is going on, and the
--- next thing to do. One entry per paragraph ('' for a blank line).
---@return string[]
local function empty_state()
  if not store.initialized then
    return { 'Looking for chats…' }
  end
  local hint = config.hint
  if S.search then
    if S.search.running then
      return { 'Searching…' }
    end
    if S.filter ~= '' and next(S.search.hits) ~= nil then
      -- The search found something; the filter typed since hides it.
      return {
        ('No chat with “%s” in it matches the filter “%s”.'):format(
          S.search.query,
          S.filter
        ),
        '',
        hint('clear', '%s clears the filter.'),
      }
    end
    return {
      ('No conversation contains “%s”.'):format(S.search.query),
      '',
      hint('clear', '%s goes back to all chats.'),
    }
  end
  if S.filter ~= '' then
    return {
      ('Nothing on the board matches “%s”.'):format(S.filter),
      '',
      sentences(
        'The filter looks at names, folders, labels and the latest messages.',
        hint('search', '%s looks through every conversation for it.'),
        hint('clear', '%s clears the filter.')
      ),
    }
  end
  local days = config.get().board.max_age_days or 0
  if store.older > 0 then
    return {
      ('No chats in the last %d days.'):format(days),
      '',
      sentences(
        hint(
          'show_all',
          ('%%s shows the %d older one%s.'):format(store.older, store.older == 1 and '' or 's')
        ),
        hint('new', '%s starts a new chat.')
      ),
    }
  end
  if not S.show_archived and #store.list({ archived = true }) > 0 then
    return {
      'Every chat is archived.',
      '',
      sentences(hint('show_all', '%s shows them.'), hint('new', '%s starts a new chat.')),
    }
  end
  local known, runnable = {}, {}
  for _, p in ipairs(providers.enabled()) do
    known[#known + 1] = p.label
    if providers.executable(p.name) then
      runnable[#runnable + 1] = p.label
    end
  end
  if #known == 0 then
    return { 'Every agent is switched off in the options (providers).' }
  end
  if #runnable == 0 then
    return {
      'No agent found.',
      '',
      ('This board lists the chats of %s. Install one and start a chat: it shows up here by itself.'):format(
        text.list(known)
      ),
      '',
      ':checkhealth agent-chats shows where it looked.',
    }
  end
  local with = #runnable == 1 and runnable[1]
    or (table.concat(runnable, ', ', 1, #runnable - 1) .. ' or ' .. runnable[#runnable])
  return {
    'No chats yet.',
    '',
    sentences(
      hint('new', '%s starts one with ' .. with:gsub('%%', '%%%%') .. '.'),
      'Chats you start in any terminal show up here too.'
    ),
  }
end

--- Agents in use whose "needs you" is a guess because their hooks are not
--- installed. Agents that report through a registry are left out: nothing
--- is missing for them.
---@return string[]
function M._guessed()
  local hooks = require('agent-chats.hooks')
  local out = {}
  if config.get().hooks.enabled == false then
    -- Installing them would change nothing: they are not listened to.
    return out
  end
  local lacking = {}
  for _, label in ipairs(hooks.lacking()) do
    lacking[label] = true
  end
  for _, p in ipairs(providers.enabled()) do
    if lacking[p.label] and not providers.exact(p) then
      out[#out + 1] = p.label
    end
  end
  return out
end

--- Redraw the list from the index.
function M.render()
  if not M.is_open() then
    return
  end
  local cfg = config.get()
  local icons = cfg.icons
  local width = api.nvim_win_get_width(S.win)
  local now = os.time()
  local chats = visible_chats()
  local cols = column_widths(chats, width)
  -- The list window's own cursor is the one kept in place, whichever
  -- window the keys are typed in.
  local prev = S.rows[api.nvim_win_get_cursor(S.win)[1]]
  local prev_id = prev and prev.id
  -- Until the cursor has been put on a chat once, there is no place to keep.
  local prev_line = S.placed and api.nvim_win_get_cursor(S.win)[1] or nil

  local lines, rows, marks, spin = {}, {}, {}, {}
  local function push(line, row)
    lines[#lines + 1] = table.concat(line.parts)
    row.id = row_id(row)
    rows[#rows + 1] = row
    for _, m in ipairs(line.marks) do
      marks[#marks + 1] = { #lines - 1, m[1], m[2], m[3] }
    end
    return #lines - 1
  end
  local function blank()
    push(Line(), { kind = 'blank' })
  end

  push(header_line(chats, width), { kind = 'header' })
  -- Under the header, where it cannot scroll out of sight: the one thing
  -- left to set up, until it is.
  local guessed = not S.search and cfg.hooks.remind and M._guessed() or {}
  if #guessed > 0 then
    local whose = #guessed == 1 and 'its hooks' or 'their hooks'
    local note = ('%s can only guess "needs you". %s sets up %s, once.'):format(
      text.list(guessed),
      config.key('hooks') or ':Chats hooks',
      whose
    )
    for _, piece in ipairs(text.wrap(note, width - 2)) do
      local l = Line()
      add(l, ' ' .. piece, 'AgentChatsDim')
      push(l, { kind = 'info' })
    end
  end
  blank()

  local function push_chat(chat, depth)
    local line, glyph_col = chat_line(chat, depth, cols, width, now)
    local lnum = push(line, { kind = 'chat', chat = chat })
    if chat.status == 'working' then
      spin[#spin + 1] = { lnum, glyph_col }
    end
    if S.search and S.search.hits[chat.key] and depth == 0 then
      local match = text.matcher(S.search.query)
      for _, hit in ipairs(S.search.hits[chat.key]) do
        local l = Line()
        local who = hit.role == 'user' and 'You'
          or (hit.role == 'assistant' and providers.label(chat.provider) or hit.role)
        add(l, '       ' .. who .. ': ', 'AgentChatsDim')
        local excerpt = text.oneline(hit.excerpt, math.max(20, width - l.width - 2))
        local s, e = match(excerpt)
        if s then
          add(l, excerpt:sub(1, s - 1), 'AgentChatsDim')
          add(l, excerpt:sub(s, e), 'AgentChatsMatch')
          add(l, excerpt:sub(e + 1), 'AgentChatsDim')
        else
          add(l, excerpt, 'AgentChatsDim')
        end
        push(l, { kind = 'hit', chat = chat, hit = hit })
      end
    end
    if depth == 0 and S.expanded[chat.key] then
      for _, sub in ipairs(store.load_children(chat)) do
        push_chat(sub, 1)
      end
    end
  end

  if #chats == 0 then
    for _, para in ipairs(empty_state()) do
      if para == '' then
        blank()
      end
      for _, piece in ipairs(text.wrap(para, width - 4)) do
        local l = Line()
        add(l, '  ' .. piece, 'AgentChatsDim')
        push(l, { kind = 'info' })
      end
    end
  end

  for _, g in ipairs(build_groups(chats)) do
    -- What a search found is shown, whatever was folded before it.
    local collapsed = not S.search and state.collapsed(g.id)
    local l = Line()
    add(l, (collapsed and icons.collapsed or icons.expanded) .. ' ', 'AgentChatsDim')
    add(l, g.label, g.hl)
    add(l, ('  %d'):format(#g.chats), 'AgentChatsCount')
    if g.extra and g.extra ~= '' then
      add(l, '   ' .. g.extra, 'AgentChatsDim')
    end
    push(l, { kind = 'group', group = g.id })
    if not collapsed then
      local limit = (S.full[g.id] or S.search) and #g.chats or cfg.board.max_per_group
      for i = 1, math.min(limit, #g.chats) do
        push_chat(g.chats[i], 0)
      end
      if #g.chats > limit then
        local m = Line()
        add(
          m,
          ('     … %d more%s'):format(#g.chats - limit, config.hint('toggle', ' (%s shows them)')),
          'AgentChatsDim'
        )
        push(m, { kind = 'more', group = g.id })
      end
    end
    blank()
  end

  if store.older > 0 and not S.search then
    local l = Line()
    add(
      l,
      ('  %d older chat%s not shown%s'):format(
        store.older,
        store.older == 1 and '' or 's',
        config.hint('show_all', ' (%s shows everything)')
      ),
      'AgentChatsDim'
    )
    push(l, { kind = 'info' })
  end

  S.rows, S.spin = rows, spin
  vim.bo[S.buf].modifiable = true
  api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(S.buf, ns_spin, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(S.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  place_cursor(prev_id, prev_line)
  S.placed = S.placed or #chats > 0
  M.spin()
  update_pane()
end

--- Advance the working-chat spinner one frame.
function M.spin()
  if not M.is_open() or not config.get().board.spinner then
    return
  end
  local frames = config.get().icons.spinner
  if #frames == 0 then
    return
  end
  S.frame = S.frame % #frames + 1
  for i, pos in ipairs(S.spin) do
    pcall(api.nvim_buf_set_extmark, S.buf, ns_spin, pos[1], pos[2], {
      id = i,
      virt_text = { { frames[S.frame], 'AgentChatsWorking' } },
      virt_text_pos = 'overlay',
    })
  end
end

-----------------------------------------------------------------------------
-- The pane
-----------------------------------------------------------------------------

local function set_pane_options(mode)
  local win = S.pane_win
  if not valid_win(win) then
    return
  end
  S.pane_mode = mode
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, 'no', '0'
  wo.list, wo.spell, wo.cursorline, wo.winfixbuf = false, false, false, false
  wo.fillchars = 'eob: '
  if mode == 'term' then
    wo.wrap, wo.conceallevel, wo.foldenable = false, 0, false
  else
    wo.wrap, wo.linebreak, wo.breakindent = true, true, true
    wo.conceallevel, wo.concealcursor = 2, 'nc'
    wo.foldenable = mode == 'transcript'
  end
end

local function pane_title(label, hl)
  if valid_win(S.pane_win) then
    vim.wo[S.pane_win].winbar = ('%%#%s# %s %%*'):format(
      hl or 'AgentChatsDim',
      (label:gsub('%%', '%%%%'))
    )
  end
end

-- In a chat's terminal, the key that goes back to the list.
local function map_back(buf)
  local back = config.get().open.back_key
  if back and valid_buf(buf) and not vim.b[buf].agent_chats_back then
    vim.b[buf].agent_chats_back = true
    vim.keymap.set('t', back, function()
      M.focus()
    end, { buffer = buf, silent = true, desc = 'Agent chats: back to the list' })
  end
  return back
end

--- The summary buffer, made anew when the one there is gone or no longer
--- what it was (`:bdelete` leaves a buffer valid but plain: writable, and
--- written to a file by `:wall`).
local function summary_buf()
  local old = S.preview_buf
  if valid_buf(old) and api.nvim_buf_is_loaded(old) and vim.bo[old].buftype == 'nofile' then
    return old
  end
  S.preview_buf = preview.create()
  if valid_buf(old) then
    -- Out of every window first: deleting a buffer closes the windows
    -- that show it, and the pane is one of them.
    for _, win in ipairs(vim.fn.win_findbuf(old)) do
      pcall(api.nvim_win_set_buf, win, S.preview_buf)
    end
    pcall(api.nvim_buf_delete, old, { force = true })
  end
  return S.preview_buf
end

--- The title of a terminal the cursor is in: which chat, and the way back.
local function term_title(label)
  local back = config.get().open.back_key
  return ('LIVE  %s%s'):format(
    (label and label ~= '') and (label .. '   ') or '',
    back and (back .. ' back to the list') or ':Chats goes back to the list'
  )
end

--- What the summary's title offers, from the keys that are bound.
local function summary_hint(chat)
  if not chat then
    return ''
  end
  local parts = {}
  if not chat.subagent then
    parts[#parts + 1] = config.hint('open', '%s open')
  end
  parts[#parts + 1] = config.hint('transcript', '%s transcript')
  if not chat.subagent then
    parts[#parts + 1] = config.hint('reply', '%s reply')
  end
  return table.concat(
    vim.tbl_filter(function(part)
      return part ~= ''
    end, parts),
    ' · '
  )
end

local function open_pane()
  if valid_win(S.pane_win) or not M.is_open() then
    return
  end
  local cfg = config.get().board
  summary_buf()
  if S.layout == 'float' then
    local c = api.nvim_win_get_config(S.win)
    local d = M._float_dims()
    local list_w, pane_w = M._float_split(d.width)
    if not pane_w then
      -- No room for two windows side by side.
      S.pane_on = false
      return
    end
    api.nvim_win_set_config(S.win, { width = list_w })
    S.pane_win = api.nvim_open_win(S.preview_buf, false, {
      relative = 'editor',
      row = d.row,
      col = d.col + list_w + 2,
      width = pane_w,
      height = d.height,
      border = c.border,
      zindex = c.zindex,
    })
  else
    local total = api.nvim_win_get_width(S.win)
    S.pane_win = api.nvim_open_win(S.preview_buf, false, {
      split = 'right',
      win = S.win,
      width = math.max(1, math.min(total - 1, math.max(20, math.floor(total * cfg.pane_size)))),
    })
  end
  vim.w[S.pane_win].agent_chats_pane = true
  set_pane_options('preview')
end

local function close_pane()
  if valid_win(S.pane_win) then
    local win = S.pane_win
    S.pane_win = nil
    pcall(api.nvim_win_close, win, true)
    if S.layout == 'float' and valid_win(S.win) then
      local dims = M._float_dims()
      api.nvim_win_set_config(S.win, { width = dims.width })
    end
  end
  S.pane_win = nil
end

update_pane = function()
  if not S.pane_on or not valid_win(S.pane_win) or not M.is_open() then
    return
  end
  -- The pane follows the cursor only while the list has focus; otherwise
  -- the user is in it (typing to an agent, reading a transcript).
  if api.nvim_win_get_buf(api.nvim_get_current_win()) ~= S.buf then
    return
  end
  local chat, row = M.current()
  local term = chat and require('agent-chats.term').find(chat) or nil
  -- What the pane is about. While that stays the same a refresh must not
  -- move the pane's view: the user may have scrolled it.
  local shown = (term and 'term:' or 'summary:') .. tostring(row and row.id)
  local moved = S.pane_shown ~= shown
  S.pane_shown = shown
  if term then
    if api.nvim_win_get_buf(S.pane_win) ~= term then
      api.nvim_win_set_buf(S.pane_win, term)
      moved = true
    end
    set_pane_options('term')
    map_back(term)
    if moved then
      pcall(api.nvim_win_set_cursor, S.pane_win, { api.nvim_buf_line_count(term), 0 })
    end
    pane_title(
      ('LIVE  %s · %s%s'):format(
        providers.label(chat.provider),
        display.title(chat, 60),
        config.hint('open', '   (%s to type)')
      ),
      'AgentChatsLive'
    )
  else
    local buf = summary_buf()
    preview.render(buf, chat, row, S.rows)
    if api.nvim_win_get_buf(S.pane_win) ~= buf then
      api.nvim_win_set_buf(S.pane_win, buf)
      moved = true
    end
    set_pane_options('preview')
    if moved then
      pcall(api.nvim_win_set_cursor, S.pane_win, { 1, 0 })
    end
    pane_title('Summary   ' .. summary_hint(chat))
  end
end

local function schedule_pane()
  if S.pending_pane then
    return
  end
  S.pending_pane = true
  vim.schedule(function()
    S.pending_pane = false
    update_pane()
  end)
end

--- The pane's window, opening the board and the pane as needed. Used to put
--- a terminal or a transcript there.
---@return integer? win
function M.pane_window()
  if not M.is_open() then
    M.open()
  end
  if not M.is_open() then
    return nil
  end
  if S.tab and api.nvim_tabpage_is_valid(S.tab) and api.nvim_get_current_tabpage() ~= S.tab then
    api.nvim_set_current_tabpage(S.tab)
  end
  S.pane_on = true
  open_pane()
  return S.pane_win
end

--- Say that the pane cannot be shown (a floating board on a narrow screen).
function M.no_room()
  vim.notify(
    'There is no room for the pane beside the list. Make Neovim wider, or use the board in a tab (board.layout = "tab").',
    vim.log.levels.INFO,
    { title = 'Agent chats' }
  )
end

--- Show `buf` in the pane and move the cursor there. `label` names what a
--- terminal runs, for a terminal that is not registered yet.
---@param mode "term"|"transcript"|"diff"
---@param title string?
---@param label string?
function M.pane_show(buf, mode, title, label)
  local win = M.pane_window()
  if not win then
    -- A terminal goes to a split instead (see term.lua); anything else
    -- has nowhere to go, and saying nothing would look like a dead key.
    if mode ~= 'term' and M.is_open() then
      M.no_room()
    end
    return nil
  end
  api.nvim_win_set_buf(win, buf)
  set_pane_options(mode)
  S.pane_shown = nil
  if mode == 'term' then
    map_back(buf)
    local known = require('agent-chats.term').terms[buf]
    title = title or term_title(label or (known and known.title))
  end
  if title then
    pane_title(title, mode == 'term' and 'AgentChatsLive' or 'AgentChatsHeader')
  end
  api.nvim_set_current_win(win)
  return win
end

--- The agent in a terminal shown in the pane has stopped and its screen is
--- kept (it failed, or `open.close_on_exit` is off): say so, instead of
--- "LIVE".
function M.pane_ended(buf, code)
  if valid_win(S.pane_win) and api.nvim_win_get_buf(S.pane_win) == buf then
    local back = config.get().open.back_key
    pane_title(
      ('ENDED  the agent has exited (code %s)%s'):format(
        tostring(code),
        back and ('   ' .. back .. ' back to the list') or ''
      ),
      'AgentChatsAttention'
    )
  end
end

--- A buffer shown in the pane is about to be deleted: put the summary back
--- first, so the window survives.
function M.release(buf)
  if valid_win(S.pane_win) and api.nvim_win_get_buf(S.pane_win) == buf then
    api.nvim_win_set_buf(S.pane_win, summary_buf())
    set_pane_options('preview')
    pane_title('Summary')
    S.pane_shown = nil
    return true
  end
  return false
end

--- Whether the cursor is in the board (its list or its pane).
function M.has_focus()
  local win = api.nvim_get_current_win()
  return M.is_open() and (win == S.win or win == S.pane_win)
end

--- Put the cursor back in the list.
function M.focus()
  if M.is_open() then
    if S.tab and api.nvim_tabpage_is_valid(S.tab) then
      api.nvim_set_current_tabpage(S.tab)
    end
    api.nvim_set_current_win(S.win)
    vim.cmd.stopinsert()
    update_pane()
  end
end

function M.toggle_pane()
  S.pane_on = not S.pane_on
  if S.pane_on then
    open_pane()
    if not valid_win(S.pane_win) then
      M.no_room()
    end
    update_pane()
  else
    close_pane()
  end
  M.render()
end

-----------------------------------------------------------------------------
-- Movement and view state
-----------------------------------------------------------------------------

--- Move the cursor to a chat, unfolding and unfiltering as needed.
---@return boolean found
function M.goto_chat(key)
  if not M.is_open() then
    return false
  end
  for _ = 1, 2 do
    for i, row in ipairs(S.rows) do
      if row.kind == 'chat' and row.chat.key == key then
        api.nvim_win_set_cursor(list_win(), { i, 1 })
        update_pane()
        return true
      end
    end
    -- Not on screen: it may be filtered out, in a folded group, or past the cap.
    local chat = store.get(key)
    if not chat then
      return false
    end
    S.filter, S.search = '', nil
    for _, g in ipairs(build_groups({ chat })) do
      state.set_collapsed(g.id, false)
      S.full[g.id] = true
    end
    M.render()
  end
  return false
end

--- Move to the next (dir 1) or previous (dir -1) chat that wants you, in
--- the order the board lists them. One in a folded group, or past the end
--- of a long one, is counted in the header: so the key reaches it, and
--- unfolds what hides it.
function M.jump_attention(dir)
  if not M.is_open() then
    return
  end
  -- Where every chat stands in the list: its group, and its place in it.
  local place, wanted = {}, {}
  for gi, g in ipairs(build_groups(visible_chats())) do
    place[g.id] = { gi, 0 }
    for ci, chat in ipairs(g.chats) do
      place[chat.key] = { gi, ci }
      if status.wants_you[chat.status] then
        wanted[#wanted + 1] = chat
      end
    end
  end
  if #wanted == 0 then
    vim.notify('No chat needs you right now.', vim.log.levels.INFO, { title = 'Agent chats' })
    return
  end
  local function before(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end
  -- Where the cursor stands: on a chat or a heading, or below one.
  local win = list_win()
  local here = { 0, 0 }
  for i = api.nvim_win_get_cursor(win)[1], 1, -1 do
    local row = S.rows[i]
    local at = row and ((row.chat and place[row.chat.key]) or (row.group and place[row.group]))
    if at then
      here = at
      break
    end
  end
  local target
  if dir > 0 then
    for _, chat in ipairs(wanted) do
      if before(here, place[chat.key]) then
        target = chat
        break
      end
    end
    target = target or wanted[1]
  else
    for i = #wanted, 1, -1 do
      if before(place[wanted[i].key], here) then
        target = wanted[i]
        break
      end
    end
    target = target or wanted[#wanted]
  end
  local function on_screen()
    for i, row in ipairs(S.rows) do
      if row.kind == 'chat' and row.chat.key == target.key then
        return i
      end
    end
  end
  local line = on_screen()
  if not line then
    -- Unfolding is enough; what narrows the board stays as it is.
    for _, g in ipairs(build_groups({ target })) do
      if not S.search then
        state.set_collapsed(g.id, false)
      end
      S.full[g.id] = true
    end
    M.render()
    line = on_screen()
  end
  if line then
    api.nvim_win_set_cursor(win, { line, 1 })
    update_pane()
  end
end

function M.set_filter(value)
  S.filter = value or ''
  M.render()
end

function M.get_filter()
  return S.filter
end

--- Ask for a filter, narrowing the list as you type.
function M.filter_prompt()
  local before = S.filter
  local group = api.nvim_create_augroup('AgentChatsFilter', { clear = true })
  api.nvim_create_autocmd('CmdlineChanged', {
    group = group,
    callback = function()
      if vim.fn.getcmdtype() == '@' then
        S.filter = vim.fn.getcmdline()
        M.render()
        vim.cmd.redraw()
      end
    end,
  })
  local ok, res =
    pcall(vim.fn.input, { prompt = 'Filter the board: ', default = before, cancelreturn = '\0' })
  api.nvim_del_augroup_by_id(group)
  if not ok or res == '\0' then
    S.filter = before
  else
    S.filter = res
  end
  M.render()
end

function M.set_group(mode)
  S.group_by = mode
  M.render()
end

function M.cycle_group()
  for i, mode in ipairs(GROUP_MODES) do
    if mode == S.group_by then
      M.set_group(GROUP_MODES[i % #GROUP_MODES + 1])
      return
    end
  end
  M.set_group('status')
end

--- Show search results (nil clears them).
---@param search { query: string, hits: table<string, agent_chats.Hit[]>, running: boolean }?
function M.set_search(search)
  -- A new search looks through every conversation: a filter left over
  -- from before would hide what it finds. (One typed afterwards narrows
  -- the results, and stays.)
  if search and (not S.search or S.search.query ~= search.query) then
    S.filter = ''
  end
  S.search = search
  M.render()
end

--- Fold or unfold whatever is under the cursor.
function M.toggle_row()
  local row = M.row()
  if not row then
    return
  end
  if row.kind == 'group' then
    if S.search then
      -- Shown open whatever the fold says (see `render`): changing the
      -- fold now would only be found out later, as a group gone missing.
      vim.notify(
        'Groups stay open while search results are shown.',
        vim.log.levels.INFO,
        { title = 'Agent chats' }
      )
      return
    end
    state.set_collapsed(row.group, not state.collapsed(row.group))
  elseif row.kind == 'more' then
    S.full[row.group] = true
  elseif row.kind == 'chat' and not row.chat.subagent then
    local key = row.chat.key
    if S.expanded[key] then
      S.expanded[key] = nil
    elseif #store.load_children(row.chat) > 0 then
      S.expanded[key] = true
    else
      vim.notify('This chat has no subagents.', vim.log.levels.INFO, { title = 'Agent chats' })
    end
  end
  M.render()
end

--- Undo the last narrowing: the filter, then the search. (A filter that
--- is on during a search was typed after it; see `set_search`.)
function M.clear()
  if S.filter ~= '' then
    S.filter = ''
  elseif S.search then
    require('agent-chats.search').cancel()
    S.search = nil
  else
    return
  end
  M.render()
end

function M.toggle_show_all()
  local on = not (store.show_all and S.show_archived)
  S.show_archived = on
  store.set_show_all(on)
  M.render()
end

local function scroll_pane(dir)
  if valid_win(S.pane_win) then
    api.nvim_win_call(S.pane_win, function()
      local key = api.nvim_replace_termcodes(dir > 0 and '<C-d>' or '<C-u>', true, false, true)
      pcall(vim.cmd, 'normal! ' .. key)
    end)
  end
end

-----------------------------------------------------------------------------
-- Keys
-----------------------------------------------------------------------------

local DESCRIPTIONS = {
  { 'open', 'Open the chat (its terminal; resumes it if it ended)' },
  { 'transcript', 'Read the whole conversation' },
  { 'reply', 'Reply to the chat' },
  { 'queue', 'Queue a reply for when it finishes; send or drop queued ones' },
  { 'new', 'Start a new chat' },
  { 'fork', 'Fork the chat into a new one' },
  { 'handoff', 'Hand the chat to another agent' },
  { 'diff', 'Show uncommitted changes in its folder' },
  { 'filter', 'Filter by name, folder, branch, agent, label, last message' },
  { 'search', 'Search inside all conversations' },
  { 'clear', 'Clear the filter, then the search' },
  { 'group', 'Group by status / folder / agent / worktree' },
  { 'toggle', "Fold a group, or show a chat's subagents" },
  { 'pane', 'Show or hide the right-hand pane' },
  { 'unread', 'Mark read / unread' },
  { 'read_all', 'Mark everything read' },
  { 'pin', 'Pin to the top of its group' },
  { 'archive', 'Archive (hidden until it moves again)' },
  { 'show_all', 'Show archived and older chats' },
  { 'label', 'Edit labels' },
  { 'note', 'Edit the note' },
  { 'rename', 'Rename' },
  { 'yank', 'Copy the command that resumes it' },
  { 'yank_id', 'Copy its id' },
  { 'next_attention', 'Next chat that needs you' },
  { 'prev_attention', 'Previous chat that needs you' },
  { 'scroll_down', 'Scroll the pane down' },
  { 'scroll_up', 'Scroll the pane up' },
  { 'refresh', 'Refresh now' },
  { 'hooks', "Set up the agents' status hooks" },
  { 'help', 'This help' },
  { 'close', 'Close the board' },
}
M.descriptions = DESCRIPTIONS

local function handlers()
  local actions = require('agent-chats.actions')
  local function on_chat(fn)
    return function()
      local chat, row = M.current()
      if chat then
        fn(chat, row)
      end
    end
  end
  return {
    open = function()
      local row = M.row()
      if not row then
        return
      end
      if row.kind == 'group' or row.kind == 'more' then
        M.toggle_row()
      elseif row.kind == 'hit' then
        actions.transcript(row.chat, { index = row.hit.index, query = S.search and S.search.query })
      elseif row.chat then
        actions.open(row.chat)
      end
    end,
    transcript = function()
      local chat, row = M.current()
      if chat then
        local hit = row and row.kind == 'hit' and row.hit or nil
        actions.transcript(
          chat,
          { index = hit and hit.index, query = hit and S.search and S.search.query }
        )
      end
    end,
    reply = on_chat(actions.reply),
    queue = on_chat(actions.queue),
    new = function()
      actions.new({ chat = M.current() })
    end,
    fork = on_chat(actions.fork),
    handoff = on_chat(actions.handoff),
    diff = on_chat(actions.diff),
    filter = M.filter_prompt,
    search = function()
      -- What the filter did not find on the board is the likeliest thing
      -- to look for inside the conversations.
      actions.search(nil, { default = S.filter })
    end,
    clear = M.clear,
    group = M.cycle_group,
    toggle = M.toggle_row,
    pane = M.toggle_pane,
    unread = on_chat(actions.toggle_unread),
    read_all = actions.read_all,
    pin = on_chat(actions.pin),
    archive = on_chat(actions.archive),
    show_all = M.toggle_show_all,
    label = on_chat(actions.labels),
    note = on_chat(actions.note),
    rename = on_chat(actions.rename),
    yank = on_chat(actions.yank),
    yank_id = on_chat(actions.yank_id),
    next_attention = function()
      M.jump_attention(1)
    end,
    prev_attention = function()
      M.jump_attention(-1)
    end,
    scroll_down = function()
      scroll_pane(1)
    end,
    scroll_up = function()
      scroll_pane(-1)
    end,
    refresh = function()
      store.refresh({ full = true })
    end,
    hooks = function()
      require('agent-chats.ui.hooks').open()
    end,
    help = function()
      require('agent-chats.ui.help').open()
    end,
    close = M.close,
  }
end

local function set_keys(buf)
  local h = handlers()
  for action in pairs(config.get().keys) do
    if h[action] then
      for _, key in ipairs(config.keys_of(action)) do
        vim.keymap.set(
          'n',
          key,
          h[action],
          { buffer = buf, nowait = true, silent = true, desc = 'Agent chats: ' .. action }
        )
      end
    end
  end
end

-----------------------------------------------------------------------------
-- Opening and closing
-----------------------------------------------------------------------------

local function border()
  local b = config.get().board.border
  if b then
    return b
  end
  local wb = vim.o.winborder
  if wb == nil or wb == '' then
    return 'rounded'
  end
  if wb:find(',', 1, true) then
    return vim.split(wb, ',', { plain = true })
  end
  return wb
end

local function span(total, size)
  if size > 1 then
    return math.min(math.floor(size), total)
  end
  return math.max(1, math.min(total, math.max(20, math.floor(total * size))))
end

--- Widths of the list and the pane inside a float `total` cells wide, or
--- just the list's when there is no room for both.
---@return integer list, integer? pane
function M._float_split(total)
  local pane = math.floor(total * config.get().board.pane_size)
  local list = total - pane - 2
  if pane < 16 or list < 24 then
    return total, nil
  end
  return list, pane
end

function M._float_dims()
  local cfg = config.get().board
  local has_border = border() ~= 'none'
  local pad = has_border and 2 or 0
  local width = span(vim.o.columns - pad, cfg.width)
  local height = span(vim.o.lines - 2 - pad, cfg.height)
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - 2 - height - pad) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - pad) / 2)),
  }
end

local SAVED = {
  'number',
  'relativenumber',
  'signcolumn',
  'foldcolumn',
  'wrap',
  'list',
  'spell',
  'cursorline',
  'foldenable',
  'conceallevel',
  'fillchars',
}

local function save_options(win)
  local saved = {}
  for _, name in ipairs(SAVED) do
    saved[name] = vim.wo[win][name]
  end
  return saved
end

local function list_options(win)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, 'no', '0'
  wo.wrap, wo.list, wo.spell, wo.cursorline = false, false, false, true
  wo.foldenable, wo.conceallevel = false, 0
  wo.fillchars = 'eob: '
  wo.winfixbuf = true
end

local function cleanup()
  if S.timer then
    S.timer:stop()
    if not S.timer:is_closing() then
      S.timer:close()
    end
    S.timer = nil
  end
  if S.unsub then
    S.unsub()
    S.unsub = nil
  end
  pcall(api.nvim_del_augroup_by_name, 'AgentChatsBoard')
  store.set_fast(false)
  if not config.get().watch.enabled then
    -- Nothing else wants the index kept current.
    store.stop()
  end
  if valid_buf(S.preview_buf) then
    pcall(api.nvim_buf_delete, S.preview_buf, { force = true })
  end
  S.buf, S.win, S.pane_win, S.preview_buf, S.tab = nil, nil, nil, nil, nil
  S.rows, S.spin, S.search = {}, {}, nil
  S.expanded, S.full = {}, {}
  S.placed, S.pane_shown, S.saved_wo = false, nil, nil
end

--- Close the board. Terminals shown in it keep running.
function M.close()
  if S.closing then
    return
  end
  S.closing = true
  local layout, win, pane, tab, buf = S.layout, S.win, S.pane_win, S.tab, S.buf
  local prev_win, prev_tab, prev_buf = S.prev_win, S.prev_tab, S.prev_buf
  local saved_wo = S.saved_wo
  cleanup()
  if layout == 'tab' and tab and api.nvim_tabpage_is_valid(tab) then
    if #api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(tab))
    else
      -- The only tab (the others were closed from here): leave one plain
      -- window behind, looking the way the user's windows do.
      if valid_win(pane) then
        pcall(api.nvim_win_close, pane, true)
      end
      if valid_win(win) then
        vim.wo[win].winfixbuf = false
        for name, value in pairs(saved_wo or {}) do
          vim.wo[win][name] = value
        end
        api.nvim_win_call(win, function()
          vim.cmd('enew')
        end)
      end
    end
    if prev_tab and api.nvim_tabpage_is_valid(prev_tab) then
      pcall(api.nvim_set_current_tabpage, prev_tab)
    end
  elseif layout == 'current' then
    if valid_win(pane) then
      pcall(api.nvim_win_close, pane, true)
    end
    if valid_win(win) then
      vim.wo[win].winfixbuf = false
      for name, value in pairs(saved_wo or {}) do
        vim.wo[win][name] = value
      end
      if valid_buf(prev_buf) then
        api.nvim_win_set_buf(win, prev_buf)
      else
        api.nvim_win_call(win, function()
          vim.cmd('enew')
        end)
      end
    end
  else
    -- Back to where the board was opened from, but only for someone who
    -- is still in it. A chat opened from it into a split or a tab has the
    -- cursor already, and keeps it.
    local cur = api.nvim_get_current_win()
    local inside = cur == win or cur == pane
    for _, w in ipairs({ pane, win }) do
      if valid_win(w) then
        pcall(api.nvim_win_close, w, true)
      end
    end
    if inside and valid_win(prev_win) then
      pcall(api.nvim_set_current_win, prev_win)
    end
  end
  if valid_buf(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  S.closing = false
end

local function open_board(opts)
  opts = opts or {}
  if M.is_open() then
    M.focus()
    if opts.filter then
      M.set_filter(opts.filter)
    end
    return
  end
  local cfg = config.get()
  require('agent-chats.ui.highlights').setup()
  require('agent-chats.term').setup()
  S.layout = opts.layout or cfg.board.layout
  S.group_by = opts.group_by or S.group_by or cfg.board.group_by
  S.filter = opts.filter or ''
  S.show_archived = store.show_all
  S.pane_on = cfg.board.pane
  S.prev_win, S.prev_tab = api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  S.prev_buf = api.nvim_get_current_buf()

  S.buf = api.nvim_create_buf(false, true)
  vim.bo[S.buf].buftype = 'nofile'
  vim.bo[S.buf].bufhidden = 'wipe'
  vim.bo[S.buf].swapfile = false
  vim.bo[S.buf].filetype = 'agent-chats'
  vim.bo[S.buf].modifiable = false
  pcall(api.nvim_buf_set_name, S.buf, 'Agent chats')

  if S.layout == 'float' then
    local d = M._float_dims()
    S.win = api.nvim_open_win(S.buf, true, {
      relative = 'editor',
      row = d.row,
      col = d.col,
      width = d.width,
      height = d.height,
      border = border(),
      title = ' Agent chats ',
      zindex = 40,
    })
  elseif S.layout == 'current' then
    S.win = api.nvim_get_current_win()
    -- This window goes back to the user afterwards, as it was.
    S.saved_wo = save_options(S.win)
    vim.wo[S.win].winfixbuf = false
    api.nvim_win_set_buf(S.win, S.buf)
  else
    vim.cmd('tabnew')
    local scratch = api.nvim_get_current_buf()
    S.win = api.nvim_get_current_win()
    S.tab = api.nvim_get_current_tabpage()
    -- A new tab's window starts with the options of the one it came from:
    -- kept, in case this window is the one left over at the end.
    S.saved_wo = save_options(S.win)
    api.nvim_win_set_buf(S.win, S.buf)
    if scratch ~= S.buf and valid_buf(scratch) then
      pcall(api.nvim_buf_delete, scratch, { force = true })
    end
    vim.t[S.tab].agent_chats = true
  end
  list_options(S.win)
  set_keys(S.buf)
  if S.pane_on then
    open_pane()
  end

  local group = api.nvim_create_augroup('AgentChatsBoard', { clear = true })
  api.nvim_create_autocmd(
    'CursorMoved',
    { group = group, buffer = S.buf, callback = schedule_pane }
  )
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      if win == S.win or api.nvim_win_get_buf(win) == S.buf then
        schedule_pane()
      elseif S.layout == 'float' and api.nvim_win_get_config(win).relative == '' then
        -- Focus left the floating board for a normal window: get out of the way.
        vim.schedule(function()
          if M.is_open() and api.nvim_win_get_config(api.nvim_get_current_win()).relative == '' then
            M.close()
          end
        end)
      end
    end,
  })
  api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      if not M.is_open() then
        return
      end
      if S.layout == 'float' then
        -- Move and resize in place: recreating the pane would throw the
        -- user out of the terminal they are typing in.
        local d = M._float_dims()
        local list_w, pane_w = d.width, nil
        if valid_win(S.pane_win) then
          list_w, pane_w = M._float_split(d.width)
        end
        if valid_win(S.pane_win) and not pane_w then
          close_pane()
          S.pane_on = false
          list_w = d.width
        end
        pcall(
          api.nvim_win_set_config,
          S.win,
          { relative = 'editor', row = d.row, col = d.col, width = list_w, height = d.height }
        )
        if valid_win(S.pane_win) then
          pcall(api.nvim_win_set_config, S.pane_win, {
            relative = 'editor',
            row = d.row,
            col = d.col + list_w + 2,
            width = pane_w,
            height = d.height,
          })
        end
      end
      M.render()
    end,
  })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed == S.win then
        vim.schedule(M.close)
      elseif closed == S.pane_win then
        S.pane_win = nil
        S.pane_on = false
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = S.buf,
    callback = function()
      vim.schedule(function()
        if not S.closing and S.buf and not valid_buf(S.buf) then
          M.close()
        end
      end)
    end,
  })

  S.unsub = store.on(function(ev)
    if ev.type == 'update' then
      M.render()
    end
  end)
  if cfg.board.spinner then
    S.timer = vim.uv.new_timer()
    S.timer:start(120, 120, vim.schedule_wrap(M.spin))
  end

  store.set_fast(true)
  M.render()
  if not store.is_watching() then
    store.start()
  else
    store.refresh({ full = true })
  end
end

--- Open the board, or go to it when it is already open.
---@param opts { layout: string?, group_by: string?, filter: string? }?
function M.open(opts)
  local ok, err = pcall(open_board, opts)
  if not ok then
    -- Never leave half a board behind.
    pcall(M.close)
    vim.notify('agent-chats: could not open the board: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.toggle(opts)
  if M.is_open() and api.nvim_get_current_win() == S.win then
    M.close()
  else
    M.open(opts)
  end
end

--- Internal state, for tests.
M._state = S

return M
