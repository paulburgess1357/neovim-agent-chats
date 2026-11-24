-- The board: every chat in one list, with a pane beside it.
--
--   +---------------------------------------------+---------------------------+
--   | Enter Open     C Conversation  + New  ? Menu|                           |
--   | 12 chats · 2 need you                       |  the chat under the       |
--   |                                             |  cursor: its live         |
--   | ▾ Needs you  2                              |  terminal when it runs    |
--   | ▌● Claude  Fix flaky restore            2m  |  in this Neovim, a        |
--   | ▾ Working  3                                |  summary otherwise        |
--   |  ◐ Codex   Port renderer               41s  |                           |
--   +---------------------------------------------+---------------------------+
--
-- The list is a plain buffer rendered from the index (store.lua). The bar
-- above it is the one place that names keys: at its left what Enter does
-- with the row under the cursor, at its right every other key (those of the
-- row, then those of the list), and last the way to the menu. The pane follows the cursor while
-- the list has focus; opening a chat or a conversation puts it in the pane
-- and moves the cursor there, and for as long as it is there the bar names
-- the keys of that view (the way back, first of all). The pane has no
-- title of its own. The row of the chat that is in the pane is marked (the
-- bar at its left), wherever the cursor is.

local api = vim.api
local config = require('agent-chats.config')
local display = require('agent-chats.display')
local fs = require('agent-chats.util.fs')
local git = require('agent-chats.util.git')
local keys = require('agent-chats.keys')
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
local ns_shown = api.nvim_create_namespace('agent-chats-shown')
local GROUP_MODES = { 'status', 'folder', 'agent', 'worktree' }
-- The group of the chats whose folders the options filter out
-- (`filter_out`): the same one however the list is grouped.
local FILTERED = 'filtered'
-- The group of the chats whose folder is no longer there (by status).
local GONE = 'status:gone'
-- The group of the chats that were archived.
local ARCHIVED = 'archived'
-- How long typing has to pause before the conversations are read too (ms).
M._search_delay = 250
-- The introduction is shown once; raising this shows it once more.
local INTRO = 1

---@class agent_chats.Row
---@field kind "header"|"blank"|"group"|"chat"|"hit"|"more"|"older"|"info"
---@field chat agent_chats.Chat?
---@field group string?   Group id.
---@field own string?     On the heading of a group of your own: its name.
---@field filtered boolean?  On the heading of the chats that are filtered out.
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
  expanded = {}, ---@type table<string, boolean>
  full = {}, ---@type table<string, boolean>
  show_older = false,
  -- The search that is on: its text, the passages found inside
  -- conversations so far (by chat), and whether those are still being read.
  search = nil, ---@type { query: string, hits: table<string, agent_chats.Hit[]>, running: boolean, read: boolean?, fresh: boolean? }?
  spin = {}, ---@type { [1]: integer, [2]: integer }[]
  frame = 1,
  timer = nil,
  unsub = nil,
  closing = false,
  pending_pane = false,
  intro = false, ---@type boolean
  intro_row = nil, ---@type (string|boolean)?
  -- The row whose summary was asked for in place of its live terminal
  -- (`M.toggle_info`): for as long as the cursor stays on it.
  info = nil, ---@type string?
  -- The chat under the list's cursor, and the status it was listed under
  -- when the cursor came to it (see `listed_as`). `free`: it goes where
  -- its status puts it all the same (its read mark was set by hand).
  hold = nil, ---@type { key: string, status: string?, free: boolean? }?
}

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and api.nvim_buf_is_valid(buf)
end

local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = 'Agent chats' })
end

function M.is_open()
  return valid_win(S.win) and valid_buf(S.buf)
end

-- How long a chat has to be in the pane before it counts as looked at.
local LOOKED_AT_SECS = 2

--- Whether terminal `buf` is in front of the user on the board: live in
--- the pane, with the cursor in the list beside it, and for more than a
--- moment. (Going down the list passes over rows: a chat that was in the
--- pane for the blink that takes has not been looked at, and its "unread"
--- is not taken away.)
---@return boolean
function M.is_showing(buf)
  return M.is_open()
    and S.pane_mode == 'term'
    and valid_win(S.pane_win)
    and api.nvim_win_get_buf(S.pane_win) == buf
    and api.nvim_get_current_win() == S.win
    and S.shown_term == buf
    and (vim.uv.hrtime() - (S.shown_since or 0)) / 1e9 >= (M._looked_at_secs or LOOKED_AT_SECS)
end

--- The buffer of the list, while the board is open.
---@return integer?
function M.buf()
  return M.is_open() and S.buf or nil
end

--- Whether the group `id` is folded. The chats that are archived, those
--- that are filtered out, and those that cannot be resumed because their
--- folder is gone, are out of the way until they are asked for: folded
--- until unfolded, where every other group is open until it is folded.
---@return boolean
local function folded(id)
  if id == ARCHIVED or id == FILTERED or id == GONE then
    return not state.collapsed(id .. ':open')
  end
  return state.collapsed(id)
end

local function set_folded(id, value)
  if id == ARCHIVED or id == FILTERED or id == GONE then
    return state.set_collapsed(id .. ':open', not value)
  end
  state.set_collapsed(id, value)
end

-----------------------------------------------------------------------------
-- Building rows
-----------------------------------------------------------------------------

--- What a row shows and holds, for narrowing the list as a search is typed.
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
      state.group(chat.key) or '',
      chat.first_prompt or '',
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
  local search = S.search
  local terms = search and vim.split(search.query:lower(), '%s+', { trimempty = true }) or {}
  local out = {}
  -- The archived ones too: they are under a heading of their own.
  for _, chat in ipairs(store.list({ archived = true })) do
    if not search or matches(chat, terms) or search.hits[chat.key] ~= nil then
      out[#out + 1] = chat
    end
  end
  return out
end

--- The status `chat` is listed under: its own, with one exception.
---
--- A chat is not moved from under the cursor for having been read. Looked
--- at, an unread chat becomes "Idle" or "Ended", which is another group:
--- the row would jump away with the cursor on it, and the list would close
--- up where it was. So the chat the cursor is on stays where it was when
--- the cursor came to it, for as long as all that has happened to it is
--- that it was read. Its mark says that it has been; it goes to its new
--- place when the cursor leaves the row. What the agent does (a new turn,
--- a question, its exit) moves it at once, as it always did.
---@return string
local function listed_as(chat)
  local hold = S.hold
  if
    hold
    and hold.key == chat.key
    and not hold.free
    and hold.status == 'done'
    and (chat.status == 'idle' or chat.status == 'ended')
  then
    return 'done'
  end
  return chat.status
end

--- Note which chat the list's cursor is on now, and how it is listed.
local function hold_row()
  local row = valid_win(S.win) and S.rows[api.nvim_win_get_cursor(S.win)[1]] or nil
  local chat = row and row.chat and store.get(row.chat.key) or nil
  if not chat then
    S.hold = nil
    return
  end
  local hold = S.hold
  if not hold or hold.key ~= chat.key then
    S.hold = { key = chat.key, status = chat.status }
  elseif listed_as(chat) == chat.status then
    -- Nothing is being kept in place: it is listed as what it is.
    hold.status = chat.status
  end
end

--- Whether the cursor has left a row that was being kept in its place.
local function hold_left()
  local hold = S.hold
  local chat = hold and store.get(hold.key) or nil
  if not chat or listed_as(chat) == chat.status then
    return false
  end
  local row = valid_win(S.win) and S.rows[api.nvim_win_get_cursor(S.win)[1]] or nil
  return not (row and row.chat and row.chat.key == hold.key)
end

local function chat_order(a, b)
  local pa, pb = state.pinned(a.key), state.pinned(b.key)
  if pa ~= pb then
    return pa
  end
  if S.group_by ~= 'status' then
    local ra, rb = status.rank[listed_as(a)] or 9, status.rank[listed_as(b)] or 9
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

--- The order inside a group of your own, which holds chats in every
--- state: what needs you first.
local function own_order(a, b)
  local pa, pb = state.pinned(a.key), state.pinned(b.key)
  if pa ~= pb then
    return pa
  end
  local ra, rb = status.rank[listed_as(a)] or 9, status.rank[listed_as(b)] or 9
  if ra ~= rb then
    return ra < rb
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
  return git.info(cwd, function(info_)
    -- First answer for this folder (or a changed one): draw it.
    if
      not had
      or had.dirty ~= info_.dirty
      or had.branch ~= info_.branch
      or had.root ~= info_.root
    then
      had = info_
      -- One redraw for however many chats were waiting for this answer
      -- (every chat of the folder asks, and each is answered).
      if not S.git_redraw then
        S.git_redraw = true
        vim.schedule(function()
          S.git_redraw = nil
          if M.is_open() then
            M.render()
          end
        end)
      end
    end
  end)
end

---@return { id: string, label: string, hl: string, extra: string?, about: string?, chats: agent_chats.Chat[], latest: number }[]
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
  -- Whether a folder is still there, asked once for each.
  local there = {}
  local function has_folder(chat)
    local cwd = chat.cwd
    if not cwd then
      return true
    end
    if there[cwd] == nil then
      there[cwd] = fs.is_dir(cwd)
    end
    return there[cwd]
  end

  for _, chat in ipairs(chats) do
    local g
    if state.is_archived(chat.key, chat.updated) then
      -- Put away by hand: it is with the others of that kind, at the very
      -- end, however the list is grouped and whatever else holds for it.
      g = group(ARCHIVED, 'Archived', 'AgentChatsGroup')
      g.id, g.archived = ARCHIVED, true
      local key = keys.key('archive')
      g.about = key and ('%s takes a chat out again'):format(key) or 'put away by you'
      g.about_short = 'put away'
    elseif config.filtered(chat.cwd) then
      -- Its folder is filtered out in the options: it is with the others
      -- of that kind, however the list is grouped and whatever group of
      -- yours it was put in.
      g = group(FILTERED, 'Filtered out', 'AgentChatsGroup')
      g.id, g.filtered = FILTERED, true
      g.about, g.about_short = 'folders named in filter_out', 'by folder'
    elseif mode == 'agent' then
      g = group(chat.provider, providers.label(chat.provider), 'AgentChatsGroup')
    elseif mode == 'folder' then
      local cwd = chat.cwd or '(unknown folder)'
      local info_ = request_git(chat.cwd)
      local extra = info_
          and info_.dirty
          and info_.dirty > 0
          and (config.get().icons.dirty .. info_.dirty)
        or nil
      g = group(cwd, fs.tilde(cwd), 'AgentChatsFolder', extra)
    elseif mode == 'worktree' then
      local info_ = request_git(chat.cwd)
      if info_ and info_.root then
        local label = fs.basename(info_.repo or info_.root)
        local branch = info_.branch or (info_.detached and 'detached') or nil
        if branch then
          label = label .. ' › ' .. branch
        end
        local extra = {}
        if info_.worktree then
          extra[#extra + 1] = fs.tilde(info_.root)
        end
        if (info_.dirty or 0) > 0 then
          extra[#extra + 1] = config.get().icons.dirty .. info_.dirty
        end
        if (info_.ahead or 0) > 0 then
          extra[#extra + 1] = '↑' .. info_.ahead
        end
        if (info_.behind or 0) > 0 then
          extra[#extra + 1] = '↓' .. info_.behind
        end
        g = group(info_.root, label, 'AgentChatsFolder', table.concat(extra, '  '))
      else
        local cwd = chat.cwd or '(unknown folder)'
        local suffix = info_ and info_.missing and 'folder is gone'
          or (info_ and 'not a git repository' or nil)
        g = group(cwd, fs.tilde(cwd), 'AgentChatsFolder', suffix)
      end
    else
      local own = state.group(chat.key)
      if own then
        -- A group of yours: the chat is there, whatever it is doing, until
        -- you take it out. (Its mark on the row still says what it is doing.)
        g = group('own:' .. own, own, 'AgentChatsGroup')
        g.own = own
      else
        local st = listed_as(chat)
        if st == 'ended' and not has_folder(chat) then
          -- "Ended" says its chats can be resumed, and this one cannot:
          -- an agent takes a chat up only in the folder it was in. It is
          -- with the others of that kind, after everything else.
          g = group('gone', 'Folder gone', status.hl.ended)
          g.status, g.gone = 'gone', true
          g.about, g.about_short = 'can be read, not resumed', 'read only'
        else
          g = group(st, status.labels[st] or st, status.hl[st])
          g.status = st
          -- A heading that says what it means: no table to look it up in.
          g.about = status.about[st]
          g.about_short = status.about_short[st]
        end
      end
    end
    g.chats[#g.chats + 1] = chat
    g.latest = math.max(g.latest, chat.updated or 0)
  end

  -- What is filtered out comes after everything else, however that is
  -- ordered, and what is archived last of all.
  local aside = {}
  for _, id in ipairs({ FILTERED, ARCHIVED }) do
    for i, g in ipairs(order) do
      if g == by[id] then
        aside[#aside + 1] = table.remove(order, i)
        break
      end
    end
  end

  if mode == 'status' then
    -- Your own groups first, by name; then what is left, by its status.
    table.sort(order, function(a, b)
      if (a.own ~= nil) ~= (b.own ~= nil) then
        return a.own ~= nil
      elseif a.own then
        local la, lb = a.own:lower(), b.own:lower()
        if la ~= lb then
          return la < lb
        end
        return a.own < b.own
      end
      return (status.rank[a.status] or 9) < (status.rank[b.status] or 9)
    end)
    -- A group of yours holds chats in every state, and folded it shows
    -- none of them: its heading says what in it wants a look.
    local icons = config.get().icons
    for _, g in ipairs(order) do
      if g.own then
        local attention, done = 0, 0
        for _, c in ipairs(g.chats) do
          attention = attention + (c.status == 'attention' and 1 or 0)
          done = done + (c.status == 'done' and 1 or 0)
        end
        local parts = {}
        if attention > 0 then
          parts[#parts + 1] = ('%s%d'):format(icons.attention, attention)
        end
        if done > 0 then
          parts[#parts + 1] = ('%s%d'):format(icons.done, done)
        end
        g.extra = #parts > 0 and table.concat(parts, '  ') or nil
      end
    end
  elseif mode == 'agent' then
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
        best = math.min(best, status.rank[listed_as(c)] or 9)
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
  vim.list_extend(order, aside)
  for _, g in ipairs(order) do
    -- (A group of chats in every state: what needs you first.)
    table.sort(g.chats, (g.own or g.filtered or g.archived) and own_order or chat_order)
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

  -- What is marked on the row, in the order it is shown, each with how
  -- much it would be missed: the lower, the longer it stays.
  local marks = {} ---@type { text: string, hl: string, rank: integer, width: integer, gone: boolean? }[]
  local function mark(str, hl, rank)
    marks[#marks + 1] = { text = str, hl = hl, rank = rank, width = text.width(str) }
  end
  local note = not chat.subagent and state.note(chat.key) or nil
  if not chat.subagent then
    local queued = #state.queue(chat.key)
    if queued > 0 then
      mark((' %s%d'):format(icons.queue, queued), 'AgentChatsQueue', 1)
    end
    for i, label in ipairs(state.labels(chat.key)) do
      mark(' #' .. label, 'AgentChatsLabel', 5 + i)
    end
    if chat.live and not chat.term then
      mark(' ' .. icons.elsewhere, 'AgentChatsDim', 2)
    end
    -- Last: what the note says goes on behind its mark.
    if note then
      mark(' ' .. icons.note, 'AgentChatsNote', 3)
    end
  end
  local note_mark = note and marks[#marks] or nil

  local pinned = not chat.subagent and state.pinned(chat.key)
  if pinned then
    add(line, icons.pin .. ' ', 'AgentChatsPin')
  end
  local room = math.max(8, width - line.width - right.width - 1)
  -- The title keeps a dozen cells. What does not fit beside that goes one
  -- mark at a time, the least telling first (the labels, from the last),
  -- so that a long label does not take the queued replies with it.
  local budget, used = math.max(0, room - 12), 0
  for _, m in ipairs(marks) do
    used = used + m.width
  end
  while used > budget do
    local worst
    for _, m in ipairs(marks) do
      if not m.gone and (not worst or m.rank > worst.rank) then
        worst = m
      end
    end
    if not worst then
      break
    end
    worst.gone = true
    used = used - worst.width
  end
  local name = display.title(chat)
  if chat.subagent and chat.agent_type then
    name = chat.agent_type .. ': ' .. name
  end
  -- A note is shown in its own words, behind its mark. The title is what
  -- the row is known by: it gives up a third of its room at most. Where
  -- that is too little to say much of the note (it takes a dozen cells, or
  -- room for all of it), the mark stands alone, as it does on a narrow list.
  local avail, said = room - used, ''
  if note_mark and not note_mark.gone then
    local words = text.oneline(note)
    local want = text.width(words) + 1
    local share = math.max(avail - text.width(name), math.min(want, math.floor(avail / 3)))
    if share >= want or share >= 12 then
      said = ' ' .. text.truncate(words, share - 1)
    end
  end
  local title = text.truncate(name, avail - text.width(said))
  local title_hl = (chat.status == 'done' or chat.status == 'attention') and 'AgentChatsUnread'
    or (chat.status == 'ended' and 'AgentChatsEnded' or 'AgentChatsTitle')
  add(line, title, title_hl)
  for _, m in ipairs(marks) do
    if not m.gone then
      add(line, m.text, m.hl)
    end
  end
  add(line, said, 'AgentChatsNote')
  add(line, string.rep(' ', math.max(1, width - line.width - right.width)))
  extend(line, right)
  return line, glyph_col
end

local function column_widths(chats, width)
  local cols = { provider = 0, folder = 0, branch = 0 }
  if S.group_by ~= 'agent' and width >= 48 then
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

local function plural(n, one, many)
  return ('%d %s'):format(n, n == 1 and one or (many or (one .. 's')))
end

--- The first line of the list: how many chats and what they are doing, or
--- what a search found; at the right, how the list is arranged where that
--- is not the usual way. No keys: those are on the bar above. On a narrow
--- list it says the same in fewer cells, step by step.
local function header_line(chats, width)
  -- The numbers are those of the rows below: with a search on, of what
  -- the search left.
  -- Not those that are archived or filtered out: they are under a heading
  -- of their own, with their number. (What a search found is counted whole.)
  local c, total = { attention = 0, working = 0, done = 0 }, 0
  for _, chat in ipairs(chats) do
    local aside = config.filtered(chat.cwd) or state.is_archived(chat.key, chat.updated)
    if S.search or not aside then
      total = total + 1
      if c[chat.status] then
        c[chat.status] = c[chat.status] + 1
      end
    end
  end
  local icons = config.get().icons
  -- The ways to say each side, richest first, and the pairs of them
  -- (`{ left, right }`) in order of preference.
  local lefts, rights, order = {}, {}, {}
  --- A right-hand side of notes (nil ones left out).
  local function side(...)
    local line, any = Line(), false
    for i = 1, select('#', ...) do
      local words = select(i, ...)
      if words then
        add(line, any and '   ' or '')
        add(line, words, 'AgentChatsDim')
        any = true
      end
    end
    if any then
      add(line, ' ')
    end
    return line
  end

  if S.search then
    local passages = 0
    for _, chat in ipairs(chats) do
      passages = passages + #(S.search.hits[chat.key] or {})
    end
    local found = plural(#chats, 'chat')
    if passages > 0 then
      found = found .. ' · ' .. plural(passages, 'passage')
    end
    local function left(lead, query, counts, reading)
      local line = Line()
      add(line, ' ')
      add(line, ('%s“%s”'):format(lead, query), 'AgentChatsHeader')
      add(line, '  ' .. counts, 'AgentChatsCount')
      if S.search.running then
        add(line, reading, 'AgentChatsCount')
      end
      return line
    end
    local query = S.search.query
    local only_chats = plural(#chats, 'chat')
    -- Words go one by one: the long form of what is being read, the word
    -- "Search", the number of passages (they are listed below), and last
    -- the end of a long text.
    lefts = {
      left('Search ', query, found, ' · reading conversations…'),
      left('Search ', query, found, ' · reading…'),
      left('', query, found, ' · reading…'),
      left('', query, only_chats, ' …'),
      left('', text.truncate(query, 10), only_chats, ' …'),
    }
    rights = { Line() }
    for l = 1, #lefts do
      order[l] = { l, 1 }
    end
  else
    local words = Line()
    add(words, ' ')
    add(words, plural(total, 'chat'), 'AgentChatsHeader')
    local glyphs = Line()
    add(glyphs, ' ')
    add(glyphs, plural(total, 'chat'), 'AgentChatsHeader')
    local function count(n, label, glyph, hl)
      if n > 0 then
        add(words, ' · ')
        add(words, label, hl)
        add(glyphs, ('  %s%d'):format(glyph, n), hl)
      end
    end
    count(
      c.attention,
      ('%d need%s you'):format(c.attention, c.attention == 1 and 's' or ''),
      icons.attention,
      'AgentChatsAttention'
    )
    count(c.working, ('%d working'):format(c.working), icons.working, 'AgentChatsWorking')
    count(c.done, ('%d unread'):format(c.done), icons.done, 'AgentChatsDone')
    lefts = { words, glyphs }
    local grouped = S.group_by ~= 'status' and ('by ' .. S.group_by) or nil
    local older = S.show_older and 'older chats shown' or nil
    rights = { side(grouped, older), side(grouped), Line() }
    -- A note goes before the counts go from words to marks: the headings
    -- below say how the list is arranged as well.
    order = { { 1, 1 }, { 1, 2 }, { 1, 3 }, { 2, 3 } }
  end

  -- The richest pair that fits.
  local best
  for _, pair in ipairs(order) do
    local left, right = lefts[pair[1]], rights[pair[2]]
    if left.width + right.width + (right.width > 0 and 2 or 0) <= width then
      best = { left, right }
      break
    end
  end
  best = best or { lefts[#lefts], Line() }
  local line = Line()
  extend(line, best[1])
  if best[2].width > 0 then
    add(line, string.rep(' ', math.max(1, width - line.width - best[2].width)))
    extend(line, best[2])
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
  elseif row.kind == 'older' then
    return 'older'
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

--- Put the cursor on the row with `id`. When that row is gone: on the
--- nearest chat from `fallback_line` on, a chat rather than a heading, so
--- that Enter does to the list what the eye expects. `top`: on the first
--- chat of the list, whatever was under the cursor (a new search).
local function place_cursor(id, fallback_line, top, chat_id, term_buf)
  if not valid_win(S.win) then
    return
  end
  local target
  if not top then
    -- The row itself; failing that, the chat it belonged to (a passage
    -- that a search found is gone with the search, its chat is not).
    for _, wanted in ipairs({ id or false, chat_id or false }) do
      for i, row in ipairs(S.rows) do
        if wanted and row.id == wanted then
          target = i
          break
        end
      end
      if target then
        break
      end
    end
    -- Failing that too, the chat that is in the same terminal now: a chat
    -- started here is listed under a stand-in until its agent has named
    -- its session, and then under that.
    if not target and term_buf then
      for i, row in ipairs(S.rows) do
        if row.kind == 'chat' and row.chat.term == term_buf then
          target = i
          break
        end
      end
    end
  end
  if not target and (top or not fallback_line) then
    -- First time, or first result: start on a chat, not on a heading.
    for i, row in ipairs(S.rows) do
      if row.kind == 'chat' then
        target = i
        break
      end
    end
  end
  if not target then
    local from = math.min(fallback_line or 1, #S.rows)
    local function nearest(wanted)
      for i = from, #S.rows do
        if wanted(S.rows[i]) then
          return i
        end
      end
      for i = math.min(from, #S.rows), 1, -1 do
        if wanted(S.rows[i]) then
          return i
        end
      end
    end
    target = nearest(function(row)
      return row.kind == 'chat'
    end) or nearest(selectable)
  end
  if target then
    pcall(api.nvim_win_set_cursor, S.win, { target, 1 })
  end
end

--- The cursor has moved in the list. A line that stands for nothing (the
--- counts, the gap between two groups) is passed over: the cursor comes to
--- rest on the next row in the direction it was going, so that a key always
--- has something to act on.
local function settle_cursor()
  if not M.is_open() then
    return
  end
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= S.buf then
    return
  end
  S.at = S.at or {}
  local line = api.nvim_win_get_cursor(win)[1]
  local was = S.at[win] or line
  if not selectable(S.rows[line]) then
    local function find(step)
      local i = line
      while i >= 1 and i <= #S.rows do
        if selectable(S.rows[i]) then
          return i
        end
        i = i + step
      end
    end
    local dir = line >= was and 1 or -1
    local target = find(dir) or find(-dir)
    if target then
      pcall(api.nvim_win_set_cursor, win, { target, 1 })
      line = target
    end
  end
  S.at[win] = line
end

local update_pane
local update_bar
local prepare_terminal
local set_keys
local summary_keys
local mark_shown

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
      return { 'Nothing in what the rows show. Reading the conversations…' }
    end
    if not S.search.read then
      -- Still being typed, and only the rows have been looked at.
      return {
        ('No row shows “%s”. The conversations are read for it next.'):format(S.search.query),
      }
    end
    local out = { ('No chat has “%s” in it.'):format(S.search.query), '' }
    local ways = sentences(
      hint('back', '%s ends the search.'),
      keys.key('back') and '' or hint('clear', '%s ends the search.'),
      hint('search', '%s changes it.')
    )
    if ways ~= '' then
      out[#out + 1] = ways
    end
    if store.older > 0 then
      out[#out + 1] = ('%s older than %d days %s not looked at.'):format(
        plural(store.older, 'chat'),
        config.get().board.max_age_days or 0,
        store.older == 1 and 'was' or 'were'
      )
    end
    return out
  end
  local days = config.get().board.max_age_days or 0
  if store.older > 0 then
    return {
      ('No chats in the last %d days.'):format(days),
      '',
      sentences(
        ('%s on the line below shows the %d older one%s.'):format(
          config.key('open') or config.command('menu'),
          store.older,
          store.older == 1 and '' or 's'
        ),
        hint('new', '%s starts a new chat.')
      ),
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
  -- What is drawn names keys: they are settled first, each time (cheap),
  -- so that no line names one that has been taken or given back since.
  set_keys(S.buf)
  -- Where the cursor is as this is drawn: that chat keeps its place.
  hold_row()
  local cfg = config.get()
  local icons = cfg.icons
  local width = api.nvim_win_get_width(S.win)
  local now = os.time()
  local chats = visible_chats()
  local cols = column_widths(chats, width)
  -- The list window's own cursor is the one kept in place, whichever
  -- window the keys are typed in.
  local at_line = api.nvim_win_get_cursor(S.win)[1]
  -- While the index is still being read for the first time the rows come
  -- and go and change places: a cursor that kept to the chat it was first
  -- put on would be carried half way down the list with it, and the board
  -- would open scrolled past its own first lines. Until the list is whole,
  -- the cursor is kept on the first chat instead. It is the user's as soon
  -- as it has been moved (it is then not on the line it was last put on).
  if S.auto_line and at_line ~= S.auto_line then
    S.settled = true
  end
  local keep = S.settled
  local prev = keep and S.rows[at_line] or nil
  local prev_id = prev and prev.id
  local prev_chat = prev and prev.chat and prev.chat.key or nil
  local prev_term = prev and prev.kind == 'chat' and prev.term or nil
  -- Until the cursor has been put on a chat once, there is no place to keep.
  local prev_line = keep and S.placed and at_line or nil

  local lines, rows, marks, spin = {}, {}, {}, {}
  local function push(line, row)
    -- (A folder name can hold a line break, and a buffer line cannot: one
    -- such chat would keep the whole board from being drawn. One byte for
    -- one byte, so what is marked stays where it is.)
    lines[#lines + 1] = (table.concat(line.parts):gsub('[%z\n\r]', ' '))
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
      config.key('hooks') or config.command('hooks'),
      whose
    )
    for _, piece in ipairs(text.wrap(note, width - 2)) do
      local l = Line()
      add(l, ' ' .. piece, 'AgentChatsDim')
      push(l, { kind = 'info' })
    end
  end
  blank()

  -- What a search was asked for, as the rows are compared with it.
  local terms = S.search and vim.split(S.search.query:lower(), '%s+', { trimempty = true }) or {}
  local found = {}
  --- Mark where line `lnum` (the last one pushed) shows the text itself:
  --- in a title, or in a folder, on the row or in the heading of its group
  --- (a chat found by where it is would otherwise show no reason).
  local function mark_terms(lnum)
    local shown = lines[#lines]:lower()
    for _, term in ipairs(terms) do
      local from = 1
      while true do
        local a, b = shown:find(term, from, true)
        if not a then
          break
        end
        found[#found + 1] = { lnum, a - 1, b }
        from = b + 1
      end
    end
  end
  local function push_chat(chat, depth)
    local line, glyph_col = chat_line(chat, depth, cols, width, now)
    -- (Its terminal as it is now: the row is found again by it when the chat
    -- itself is replaced by another, as a stand-in is by the real session.)
    local lnum = push(line, { kind = 'chat', chat = chat, term = chat.term })
    mark_terms(lnum)
    if chat.status == 'working' then
      spin[#spin + 1] = { lnum, glyph_col }
    end
    if S.search and S.search.hits[chat.key] and depth == 0 then
      local match = text.matcher(S.search.query)
      for _, hit in ipairs(S.search.hits[chat.key]) do
        local l = Line()
        -- (A tool call is something the agent did: it goes by its name too.)
        local who = hit.role == 'user' and 'You'
          or (
            (hit.role == 'assistant' or hit.role == 'tool') and providers.label(chat.provider)
            or hit.role
          )
        add(l, '       ' .. who .. ': ', 'AgentChatsDim')
        local room = math.max(20, width - l.width - 2)
        local excerpt = text.oneline(hit.excerpt)
        local s, e = match(excerpt)
        if s and text.width(excerpt:sub(1, e)) > room then
          -- The words it was found by are what the line is for: on a
          -- narrow list, what comes before them gives way until they show.
          local lead = math.max(1, math.floor((room - text.width(excerpt:sub(s, e))) / 3))
          excerpt = text.truncate_left(excerpt:sub(1, s - 1), lead) .. excerpt:sub(s)
        end
        excerpt = text.truncate(excerpt, room)
        s, e = match(excerpt)
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

  local groups = build_groups(chats)
  --- The heading of a group, without the words on what it means.
  local function heading(g, collapsed)
    local l = Line()
    local fold = (collapsed and icons.collapsed or icons.expanded) .. ' '
    local count = ('  %d'):format(#g.chats)
    local extra = (g.extra and g.extra ~= '') and ('   ' .. g.extra) or ''
    add(l, fold, 'AgentChatsDim')
    -- Cut to the list like any row (a folder can be long), its count and
    -- what follows it kept: at its start, where a path says least.
    local room = width - text.width(fold) - text.width(count) - text.width(extra) - 1
    local label = g.label
    if text.width(label) > room then
      label = text.truncate_left(label, math.max(8, room))
    end
    add(l, label, g.hl)
    add(l, count, 'AgentChatsCount')
    if extra ~= '' then
      add(l, extra, 'AgentChatsDim')
    end
    return l
  end
  -- What each status means is said beside every heading or beside none: a
  -- list that explains "Idle" and not "Unread", because one fits and the
  -- other does not, reads as if the other needed no explaining. In full
  -- where all of them fit, else in short, else not at all.
  local explain ---@type string?
  for _, form in ipairs({ 'about', 'about_short' }) do
    local fits = #groups > 0
    local any = false
    for _, g in ipairs(groups) do
      -- (A group of yours has nothing to explain: it is not asked.)
      if not g.own then
        local words = g[form]
        any = true
        fits = fits
          and words ~= nil
          and heading(g, false).width + 3 + text.width(words) + 1 <= width
      end
    end
    fits = fits and any
    if fits then
      explain = form
      break
    end
  end

  for _, g in ipairs(groups) do
    -- What a search found is shown, whatever was folded before it.
    local collapsed = not S.search and folded(g.id)
    local l = heading(g, collapsed)
    if explain and g[explain] then
      add(l, '   ' .. g[explain], 'AgentChatsDim')
    end
    local heading = push(l, {
      kind = 'group',
      group = g.id,
      own = g.own,
      filtered = g.filtered,
      gone = g.gone,
      archived = g.archived,
    })
    if (S.group_by ~= 'status' or g.own) and not g.filtered and not g.archived then
      -- A folder or an agent, which may be what was searched for.
      mark_terms(heading)
    end
    if not collapsed then
      local limit = (S.full[g.id] or S.search) and #g.chats or cfg.board.max_per_group
      for i = 1, math.min(limit, #g.chats) do
        push_chat(g.chats[i], 0)
      end
      if #g.chats > limit then
        local m = Line()
        local how = config.key('open') or config.key('toggle')
        add(
          m,
          ('     … %d more%s'):format(
            #g.chats - limit,
            how and (' (%s shows them)'):format(how) or ''
          ),
          'AgentChatsDim'
        )
        push(m, { kind = 'more', group = g.id })
      end
    end
    blank()
  end

  if store.older > 0 and not S.search then
    local l = Line()
    local how = config.key('open') or config.key('show_all')
    add(
      l,
      ('  %s older than %d days not shown%s'):format(
        plural(store.older, 'chat'),
        cfg.board.max_age_days or 0,
        how and (' (%s shows them)'):format(how) or ''
      ),
      'AgentChatsDim'
    )
    push(l, { kind = 'older' })
  end

  -- A second window on the list (a split of it) is a view like the first:
  -- its cursor stays with the row it is on, as the first one's does. The
  -- keys act on the window they are typed in.
  local others = {}
  for _, win in ipairs(vim.fn.win_findbuf(S.buf)) do
    if win ~= S.win then
      local at = S.rows[api.nvim_win_get_cursor(win)[1]]
      others[win] = at and at.id or false
    end
  end
  S.rows, S.spin = rows, spin
  vim.bo[S.buf].modifiable = true
  api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  for win, id in pairs(others) do
    if id then
      for i, row in ipairs(rows) do
        if row.id == id then
          pcall(api.nvim_win_set_cursor, win, { i, 1 })
          break
        end
      end
    end
  end
  api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  api.nvim_buf_clear_namespace(S.buf, ns_spin, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(S.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  for _, m in ipairs(found) do
    -- Over the colours of the row.
    pcall(
      api.nvim_buf_set_extmark,
      S.buf,
      ns,
      m[1],
      m[2],
      { end_col = m[3], hl_group = 'AgentChatsMatch', priority = 200 }
    )
  end
  -- A search just asked for starts on its first result.
  local top = S.search ~= nil and S.search.fresh
  if S.search then
    S.search.fresh = nil
  end
  place_cursor(prev_id, prev_line, top, prev_chat, prev_term)
  S.placed = S.placed or #chats > 0
  if not keep then
    -- From its first line, too.
    pcall(api.nvim_win_call, S.win, function()
      vim.fn.winrestview({ topline = 1 })
    end)
  end
  -- A chat that was started from here a moment ago has its row now: the
  -- cursor goes to it, so that "back" lands on the new chat. Not when the
  -- cursor has been moved to another row since: then it is where the user
  -- put it.
  local follow = S.follow
  if follow then
    if
      (prev_id or false) ~= follow.from
      or not valid_buf(follow.buf)
      or vim.uv.now() > follow.till
    then
      S.follow = nil
    else
      local find = require('agent-chats.term').find
      for i, row in ipairs(rows) do
        if row.kind == 'chat' and (row.chat.term == follow.buf or find(row.chat) == follow.buf) then
          pcall(api.nvim_win_set_cursor, S.win, { i, 1 })
          S.follow, S.settled = nil, true
          break
        end
      end
    end
  end
  -- Where the cursor was put: on any other line next time, it was moved.
  S.auto_line = api.nvim_win_get_cursor(S.win)[1]
  M.spin()
  update_bar()
  update_pane()
  -- (The rows are new: the mark is put on the one it belongs to now.)
  mark_shown()
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
-- The bar above the list: what can be done with the row under the cursor
-----------------------------------------------------------------------------

--- What Enter does with `chat`: as the bar above the list names it, and in
--- a sentence.
---@return string word, string sentence
function M.open_words(chat)
  if chat.subagent then
    return 'Read', 'Read what this subagent did'
  end
  local term = require('agent-chats.term').find(chat)
  if term then
    if chat.status == 'attention' then
      return 'Answer', 'Go to its terminal and answer'
    end
    return 'Open', 'Open: go to its terminal'
  end
  if chat.live then
    if require('agent-chats.term').in_background(chat) then
      return 'Read', 'Read it (it is answering in the background)'
    end
    return 'Read', 'Read it (it runs outside this Neovim)'
  end
  if chat.cwd and not fs.is_dir(chat.cwd) then
    return 'Read', 'Read it (its folder is gone, so it cannot be resumed)'
  end
  -- (The folder in full is in the summary; here it must not stretch a menu.)
  return 'Resume', ('Resume it in %s'):format(chat.cwd and fs.short(chat.cwd, 44) or 'a terminal')
end

--- Whether the agent of `chat` can be started in the chat's folder: false
--- for a chat that is not running and whose folder is no longer there.
local function startable(chat)
  return chat.live or not chat.cwd or fs.is_dir(chat.cwd)
end

--- Why `chat` cannot be gone into and typed to from here; nil when it can.
---@return ("background"|"elsewhere"|"folder gone")?
local function out_of_reach(chat)
  local terms = require('agent-chats.term')
  if chat.live and not terms.find(chat) then
    return terms.in_background(chat) and 'background' or 'elsewhere'
  end
  if not startable(chat) then
    -- Going into it would mean resuming it.
    return 'folder gone'
  end
  return nil
end

--- The terminal of `chat` when the pane is the place for it: it runs in
--- this Neovim, and no window of the user's shows it. nil for a chat the
--- pane has the summary of whatever is asked.
---@return integer?
local function pane_term(chat)
  if not (chat and S.pane_on and valid_win(S.pane_win)) then
    return nil
  end
  local terms = require('agent-chats.term')
  local term = terms.find(chat)
  return term and not terms.window_of(term) and term or nil
end

--- The hints for the row under the cursor of `win`, `{ key, label }` each:
--- what Enter does there, the other keys of the row, and a few words on
--- why Enter does no more than it does, when that needs saying (in full
--- and in short).
---@return table? enter, table[] others, string[]? note
local function row_hints(win)
  local row = S.rows[api.nvim_win_get_cursor(win)[1]]
  local enter, out, note = nil, {}, nil
  local function hint(action, label, more)
    local key = keys.key(action)
    if key then
      out[#out + 1] = vim.tbl_extend('force', { key, label }, more or {})
    end
  end
  local function opens(label)
    local key = keys.key('open')
    enter = key and { key, label } or nil
  end
  if row and row.kind == 'group' then
    -- (Not while a search is on: what it found is shown, folded or not.)
    if not S.search then
      opens(folded(row.group) and 'Unfold' or 'Fold')
    end
  elseif row and (row.kind == 'more' or row.kind == 'older') then
    opens('Show Them')
  elseif row and row.kind == 'hit' then
    opens('Read This Passage')
  elseif row and row.chat then
    local chat = row.chat
    opens((M.open_words(chat)))
    if not chat.subagent then
      -- Why Enter only reads it, where it does.
      local why = out_of_reach(chat)
      if why == 'background' then
        note = { 'answering in the background', 'in the background' }
      elseif why == 'elsewhere' then
        note = { 'it runs outside this Neovim', 'runs elsewhere' }
      elseif why == 'folder gone' then
        note = { 'its folder is gone', 'folder gone' }
      end
      local queued = #state.queue(chat.key)
      if queued > 0 then
        -- (What the key leads to, as "conversation" is: said as a state,
        -- it read as one.)
        hint('queue', ('Queued Replies (%d)'):format(queued))
      elseif
        why ~= 'elsewhere'
        and why ~= 'background'
        and (chat.status == 'working' or chat.status == 'attention')
      then
        hint('queue', 'Queue a Reply')
      end
      -- Named on every chat there is something to read of, also where
      -- Enter does no more than read it: the key is always in its place.
      if not chat.stub then
        hint('read', 'Conversation')
      end
      if not chat.unstarted then
        hint('archive', state.is_archived(chat.key, chat.updated) and 'Unarchive' or 'Archive')
      end
      -- Its terminal is in the pane: the summary can be had in its place,
      -- and the terminal again. Only some rows have this key, so it is
      -- the first to give way: the others stay where they are. (One name
      -- for both ways: a longer one for the way back would not always
      -- fit where this one did, and the key would go as it is pressed.
      -- The summary says how to have the terminal back.)
      if pane_term(chat) then
        hint('info', 'Info', { drop = 1 })
      end
    end
  end
  return enter, out, note
end

--- The hints that are the same on every row, for the right of the bar:
--- what can be done with the list as a whole. With a search on, the ways
--- out of it and to another.
---@return table[]
local function list_hints()
  local out = {}
  local function hint(action, label, more)
    local key = keys.key(action)
    if key then
      out[#out + 1] = vim.tbl_extend('force', { key, label }, more or {})
    end
    return key
  end
  if S.search then
    -- The key that changes the search gives way before the one that ends it.
    if not hint('back', 'End Search', { short = 'End', drop = 8 }) then
      hint('clear', 'End Search', { short = 'End', drop = 8 })
    end
    hint('search', 'New Search')
  else
    hint('new', 'New Chat', { short = 'New', drop = 8 })
    hint('search', 'Search')
    -- The list keeps itself up to date: the key for doing it now is the
    -- first to give way.
    hint('refresh', 'Refresh', { drop = 2 })
  end
  return out
end

--- The hints for the view the cursor is in, in the pane; nil when the
--- keys there are those of the list (the summary: they act on the chat it
--- shows).
---@return table[]? hints, string[]? note, table|false|nil menu
local function pane_hints()
  local win = S.pane_win
  if not (valid_win(win) and api.nvim_get_current_win() == win) then
    return nil
  end
  local buf = api.nvim_win_get_buf(win)
  if S.pane_mode == 'term' then
    -- The way back to the list that works in the mode the terminal is in:
    -- one key while typing, another in its normal mode. Closing the
    -- window goes back whatever is mapped: with no key, that is named.
    local typing, normal = prepare_terminal(buf)
    local from_normal = normal and keys.name(normal) or ':q'
    local hints
    if M._typing() then
      -- With no key of its own, typing has to be left first.
      hints = typing and { { typing, 'Back' } }
        or { { [[<C-\><C-n>]], ('then %s Back'):format(from_normal) } }
    else
      hints = { { from_normal, 'Back' } }
    end
    -- The agent has stopped and its screen is kept (it failed, or
    -- `open.close_on_exit` is off).
    local code = vim.b[buf].agent_chats_exited
    local note = code and { ('the agent has exited, code %s'):format(code), 'exited' } or nil
    return hints, note, false
  end
  local fn = S.pane_hints_fn
  if fn then
    -- A conversation, a diff: asked what keys it has now.
    local ok, hints = pcall(fn)
    if ok and type(hints) == 'table' then
      return hints, nil, hints.menu and { hints.menu, 'Menu' } or false
    end
  end
  return nil
end

--- A statusline string for the bar. `left` is at its left: what Enter
--- does with what the cursor is on, with `note` behind it (why it does no
--- more than that). `right` is every other key, and `menu`, the way to
--- everything else, comes last, at the right edge.
---
--- A hint is `{ key, label }`, with `short` for a label that can be said
--- in fewer cells and `drop` for when it gives way (the lowest number
--- first, and of two the later one).
---
--- The right side is settled first, with `least` cells kept for the left
--- and `reserve` for the other keys of a row, whatever the row under the
--- cursor has of them: so the keys of the list stay where they are as the
--- cursor goes from row to row. A key that only some rows have is there
--- while nothing has to make room for it (1). The key that is needed least
--- goes first (2), then long labels are shortened (3). Then the other keys
--- of the row go, the last one first (5), then the keys of the list (6),
--- and last what starts a chat or ends a search (8). The way to the menu
--- stays.
---
--- The left side has what room that leaves: the note is said in short
--- (1), then not at all (4); what Enter does is the last to go (9).
local function bar_text(width, left, note, right, menu, least, reserve)
  local function esc(s)
    return (s:gsub('%%', '%%%%'))
  end
  local function label(part)
    return part.short and part.hint.short or part.hint[2]
  end
  local function cells(part)
    if part.note then
      return text.width(part.note[part.at]) + 2
    end
    local words = label(part)
    return text.width(part.hint[1]) + (words ~= '' and 1 + text.width(words) or 0)
  end
  --- The cells `parts` take side by side.
  local function span(parts)
    local w = 0
    for _, part in ipairs(parts) do
      if not part.gone then
        -- (A note belongs to the key before it.)
        w = w + cells(part) + (w > 0 and (part.note and 1 or 2) or 0)
      end
    end
    return w
  end
  --- Say `parts` in fewer cells, step by step, until `fits`; no step past
  --- `upto` is taken.
  local function reduce(parts, fits, upto)
    while not fits() do
      local worst, how, rank
      for _, part in ipairs(parts) do
        if not part.gone and not part.keep then
          local can
          if part.note then
            can = part.at < #part.note
          else
            can = part.hint.short ~= nil and not part.short
          end
          local r = can and part.shrink or part.drop
          if not rank or r <= rank then
            worst, how, rank = part, can and 'shrink' or 'drop', r
          end
        end
      end
      if not worst or (upto and rank > upto) then
        return
      end
      if how == 'drop' then
        worst.gone = true
      elseif worst.note then
        worst.at = worst.at + 1
      else
        worst.short = true
      end
    end
  end

  -- (`others`: the keys that are there on every row.)
  local rights, others = {}, {}
  for _, h in ipairs(right) do
    rights[#rights + 1] = { hint = h, shrink = 3, drop = h.drop or 6 }
    if not h.row then
      others[#others + 1] = rights[#rights]
    end
  end
  if menu then
    rights[#rights + 1] = { hint = menu, keep = true }
    others[#others + 1] = rights[#rights]
  end
  local lefts = {}
  for i, h in ipairs(left) do
    lefts[#lefts + 1] = { hint = h, shrink = 3, drop = h.drop or (i == 1 and 9 or 5) }
    if i == 1 and note then
      lefts[#lefts + 1] = { note = note, at = 1, shrink = 1, drop = 4 }
    end
  end
  least = math.max(least or 0, lefts[1] and cells(lefts[1]) or 0)
  -- A cell at each edge, and two between the sides where there are two.
  local function beside(w)
    return 2 + least + ((w > 0 and least > 0) and 2 or 0) + w <= width
  end
  if (reserve or 0) > 0 then
    -- (Of the keys that are there on every row: what a row adds to them
    -- has no say in where they stand.)
    reduce(others, function()
      return beside(span(others) + reserve + 2)
    end, 3)
  end
  reduce(rights, function()
    return beside(span(rights))
  end)
  local right_w = span(rights)
  reduce(lefts, function()
    local w = span(lefts)
    return w == 0 or 2 + w + (right_w > 0 and 2 or 0) + right_w <= width
  end)

  local out = { ' ' }
  local function say(parts)
    local any = false
    for _, part in ipairs(parts) do
      if not part.gone and part.note then
        out[#out + 1] = ('%s%%#AgentChatsDim#(%s)%%*'):format(
          any and ' ' or '',
          esc(part.note[part.at])
        )
        any = true
      elseif not part.gone then
        local words = label(part)
        out[#out + 1] = ('%s%%#AgentChatsKey#%s%%*%s'):format(
          any and '  ' or '',
          esc(part.hint[1]),
          words ~= '' and (' ' .. esc(words)) or ''
        )
        any = true
      end
    end
  end
  say(lefts)
  out[#out + 1] = '%='
  say(rights)
  out[#out + 1] = ' '
  return table.concat(out)
end

--- Bring the bar above the list up to date. It is the one place that
--- names keys, and it names those of where the cursor is: of the row it is
--- on in the list; of the chat, the conversation or the diff it is in, in
--- the pane.
update_bar = function()
  if not M.is_open() then
    return
  end
  local menu_key = keys.key('menu')
  local list_menu = menu_key and { menu_key, 'Menu' } or { config.command('menu'), '' }
  local in_pane, pane_note, pane_menu = pane_hints()
  -- What Enter takes on a chat that can be resumed, kept free at the left
  -- on every row: the keys at the right do not move as the cursor does.
  local open_key, read_key, archive_key = keys.key('open'), keys.key('read'), keys.key('archive')
  local least = open_key and (text.width(open_key) + 7) or 0
  -- And what the two keys every chat has take, at the right.
  local reserve = (read_key and (text.width(read_key) + 13) or 0)
    + (archive_key and (text.width(archive_key) + 8) or 0)
    + ((read_key and archive_key) and 2 or 0)
  for _, win in ipairs(vim.fn.win_findbuf(S.buf)) do
    local width = api.nvim_win_get_width(win)
    local bar
    if S.typing then
      -- A search is being typed at the prompt: the keys that count are
      -- the prompt's own, and they are not the board's to choose.
      bar = bar_text(
        width,
        { { 'Enter', 'Keep Search', short = 'Keep' }, { 'Esc', 'Cancel', drop = 8 } },
        nil,
        {},
        nil
      )
    elseif in_pane then
      bar = bar_text(width, in_pane, pane_note, {}, pane_menu or nil)
    else
      local enter, others, note = row_hints(win)
      if S.pane_mode == 'preview' and api.nvim_get_current_win() == S.pane_win and not S.intro then
        -- In the summary the keys are the list's, but for the one that
        -- goes back: there it leads to the list. (With no key of its own
        -- there, the command is the way: the one that opens the board,
        -- since the bare command closes a board that is in front of you.)
        local buf = api.nvim_win_get_buf(S.pane_win)
        local back = config.command('open')
        for _, lhs in ipairs(keys.wanted('back')) do
          if keys.is_ours(buf, 'n', lhs) then
            back = keys.name(lhs)
            break
          end
        end
        others[#others + 1] = { back, 'Back' }
      end
      -- The other keys of the row are at the right, before those of the
      -- list: they give way before those do.
      local right = {}
      for _, h in ipairs(others) do
        right[#right + 1] = vim.tbl_extend('keep', { drop = h.drop or 5, row = true }, h)
      end
      vim.list_extend(right, list_hints())
      bar = bar_text(width, { enter }, note, right, list_menu, least, reserve)
    end
    if vim.wo[win].winbar ~= bar then
      vim.wo[win].winbar = bar
    end
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
    -- (A list item that wraps goes on under its own words.)
    pcall(function()
      wo.breakindentopt = 'list:-1'
    end)
    wo.conceallevel, wo.concealcursor = 2, 'nc'
    wo.foldenable = mode == 'conversation'
  end
end

--- Whether the cursor is typing in a terminal (terminal mode) right now.
function M._typing()
  return api.nvim_get_mode().mode == 't'
end

-- Window commands, and where each leads inside the floating board.
local FLOAT_MOVES = {
  h = 'list',
  l = 'pane',
  w = 'other',
  p = 'other',
  j = 'stay',
  k = 'stay',
  ['<Left>'] = 'list',
  ['<Right>'] = 'pane',
  ['<Down>'] = 'stay',
  ['<Up>'] = 'stay',
}

--- In the floating board the list and the pane are two floats, and
--- Neovim's window commands know nothing of two floats side by side: from
--- either of them `<C-w>l` goes to the window behind, and the board, left
--- for a plain window, closes. On the buffers it shows, these commands
--- mean what they would between two windows that are side by side.
--- (A key of yours for moving between windows calls `:wincmd` itself, and
--- is not seen here: in this layout it closes the board.)
local function window_keys(buf)
  if S.layout ~= 'float' or not valid_buf(buf) or vim.b[buf].agent_chats_window_keys then
    return
  end
  vim.b[buf].agent_chats_window_keys = true
  for key, to in pairs(FLOAT_MOVES) do
    local ctrl = #key == 1 and ('<C-%s>'):format(key) or nil
    for _, lhs in ipairs({ '<C-w>' .. key, ctrl and ('<C-w>' .. ctrl) or nil }) do
      keys.map_key(buf, 'n', lhs, function()
        local win = api.nvim_get_current_win()
        local here = M.is_open() and S.layout == 'float' and (win == S.win or win == S.pane_win)
        if not here then
          -- Shown somewhere else by now: the command is Neovim's again.
          local raw = api.nvim_replace_termcodes(lhs, true, true, true)
          return api.nvim_feedkeys(raw, 'n', false)
        end
        local target = to
        if target == 'other' then
          target = win == S.win and 'pane' or 'list'
        end
        if target == 'list' and win ~= S.win then
          M.focus()
        elseif target == 'pane' and win ~= S.pane_win and valid_win(S.pane_win) then
          api.nvim_set_current_win(S.pane_win)
        end
      end, 'move inside the floating board', false)
    end
  end
end

--- A terminal that holds a chat is about to be shown or entered: give it
--- the ways back to the list, once, and then let the user's own setup at it.
---@return string? typing, string? normal  The keys that go back from it: while typing, and in its normal mode.
prepare_terminal = function(buf)
  window_keys(buf)
  return require('agent-chats.term').prepare(buf)
end

-- What Neovim says when a buffer comes to be shown in a window and when it
-- goes from the last one, and what it says when the cursor changes buffer
-- or window.
local SHOWN = 'BufWinEnter,BufWinLeave,BufHidden'
local ENTERED = 'BufEnter,BufLeave,WinEnter,WinLeave'

--- Call `fn` with the autocommands for `events` held back.
local function quietly(events, fn, ...)
  local had = vim.o.eventignore
  vim.o.eventignore = had == '' and events or (had .. ',' .. events)
  local ok, err = pcall(fn, ...)
  vim.o.eventignore = had
  if not ok then
    error(err, 0)
  end
  return err
end

--- Put `buf` in the pane.
---
--- The pane is the board's own window. A buffer shown there has not been
--- opened in a window of the user's, and one taken out of it has not been
--- hidden by them: "BufWinEnter", "BufWinLeave" and "BufHidden" are not
--- said. (A config that keeps a terminal's window for that terminal marks
--- the window on the first of these, and from then on puts the terminal
--- back whenever another buffer lands there: the pane would be stuck on
--- one chat, with a warning for every move of the cursor.)
---
--- With the cursor somewhere else, nothing is entered either. Neovim says
--- "BufEnter" all the same for a buffer put into a window the cursor is
--- not in, and a common autocommand answers that for a terminal by
--- starting to type: the list would be typed into.
local function pane_set_buf(buf)
  local events = SHOWN
  if api.nvim_get_current_win() ~= S.pane_win then
    events = events .. ',' .. ENTERED
  end
  quietly(events, api.nvim_win_set_buf, S.pane_win, buf)
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
  -- The cursor can end up in the summary (a window command, a click,
  -- `:windo`): the board's keys work there as well.
  summary_keys()
  if valid_buf(old) then
    -- Out of every window first: deleting a buffer closes the windows
    -- that show it, and the pane is one of them.
    for _, win in ipairs(vim.fn.win_findbuf(old)) do
      if win == S.pane_win then
        pcall(pane_set_buf, S.preview_buf)
      else
        pcall(api.nvim_win_set_buf, win, S.preview_buf)
      end
    end
    pcall(api.nvim_buf_delete, old, { force = true })
  end
  return S.preview_buf
end

--- The chat that terminal `buf` holds, as far as the index knows.
local function chat_in(buf)
  for _, chat in pairs(store.chats) do
    if chat.term == buf then
      return chat
    end
  end
  return nil
end

--- The chat the pane is showing, by its key (and, for a subagent, the key
--- of the chat it belongs to); nil when the pane shows none.
---@return string?, string?
local function pane_chat()
  if not (M.is_open() and valid_win(S.pane_win)) then
    return nil
  end
  local buf = api.nvim_win_get_buf(S.pane_win)
  if S.pane_mode == 'term' then
    local chat = chat_in(buf)
    local known = require('agent-chats.term').terms[buf]
    return chat and chat.key or (known and known.key) or nil
  elseif S.pane_mode == 'conversation' or S.pane_mode == 'diff' then
    return vim.b[buf].agent_chats_key, vim.b[buf].agent_chats_parent
  elseif S.pane_shown == 'intro' then
    return nil
  end
  -- A summary is of the row the list's cursor is on.
  local row = S.rows[api.nvim_win_get_cursor(S.win)[1]]
  return row and row.chat and row.chat.key or nil
end

--- Mark the row of the chat that is in the pane: a bar at its left edge,
--- and the whole line set off. Whatever the pane shows of it (its live
--- terminal, its summary, its conversation), and wherever the cursor is:
--- from inside a chat, a glance at the list says which one it is. The
--- cursor line alone does not: many colorschemes draw it faintly or not at
--- all, and many configs take it away in a window the cursor is not in.
mark_shown = function()
  if not M.is_open() then
    return
  end
  api.nvim_buf_clear_namespace(S.buf, ns_shown, 0, -1)
  local key, parent = pane_chat()
  if not key then
    return
  end
  local at = api.nvim_win_get_cursor(S.win)[1]
  local line
  if S.rows[at] and S.rows[at].chat and S.rows[at].chat.key == key then
    -- The row the cursor is on is of that chat (it may be a passage a
    -- search found in it).
    line = at
  else
    -- Its own row; for a subagent that is not listed, the row of the chat
    -- it belongs to.
    for _, wanted in ipairs({ key, parent or false }) do
      for i, row in ipairs(S.rows) do
        if wanted and row.kind == 'chat' and row.chat.key == wanted then
          line = i
          break
        end
      end
      if line then
        break
      end
    end
  end
  if not line then
    return
  end
  local bar = config.get().icons.shown
  pcall(api.nvim_buf_set_extmark, S.buf, ns_shown, line - 1, 0, {
    virt_text = (type(bar) == 'string' and bar ~= '') and { { bar, 'AgentChatsShownMark' } } or nil,
    virt_text_pos = 'overlay',
    line_hl_group = 'AgentChatsShown',
  })
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
    S.pane_win = quietly(SHOWN, api.nvim_open_win, S.preview_buf, false, {
      relative = 'editor',
      row = d.row,
      col = d.col + list_w + 2,
      width = pane_w,
      height = d.height,
      -- As the list has it, said in so many words where it has none (or
      -- the pane would take 'winborder', and be two cells wider than
      -- there is room for).
      border = c.border or 'none',
      zindex = c.zindex,
    })
  else
    local total = api.nvim_win_get_width(S.win)
    S.pane_win = quietly(SHOWN, api.nvim_open_win, S.preview_buf, false, {
      split = 'right',
      win = S.win,
      width = math.max(1, math.min(total - 1, math.max(20, math.floor(total * cfg.pane_size)))),
    })
  end
  vim.w[S.pane_win].agent_chats_pane = true
  set_pane_options('preview')
  if api.nvim_get_current_win() == S.win then
    -- The list is fixed to its buffer, and `:windo`, `:bufdo` and `:tabdo`
    -- (netrw runs the first as Neovim starts) answer a fixed window that
    -- has no other to go to by splitting it. The pane is made the window
    -- "before" this one, so there is one to go to. No autocommands:
    -- nothing has happened.
    pcall(vim.cmd, ('noautocmd call win_gotoid(%d)'):format(S.pane_win))
    pcall(vim.cmd, ('noautocmd call win_gotoid(%d)'):format(S.win))
  end
end

local function close_pane()
  if valid_win(S.pane_win) then
    local win = S.pane_win
    S.pane_win = nil
    -- (What it showed goes out of sight as it came: without a word.)
    quietly(SHOWN, pcall, api.nvim_win_close, win, true)
    if S.layout == 'float' and valid_win(S.win) then
      local dims = M._float_dims()
      api.nvim_win_set_config(S.win, { width = dims.width })
    end
  end
  S.pane_win = nil
end

--- Show in the pane what the row under the list's cursor stands for: the
--- live terminal of its chat when the pane is the place for that, else a
--- summary.
local function show_row()
  local chat, row = M.current()
  if S.intro then
    -- Shown until the cursor is moved to another row, and only this once.
    local at = row and row.id or false
    if S.intro_row == nil and store.initialized then
      S.intro_row = at
      state.set_intro(INTRO)
    end
    if S.intro_row == nil or S.intro_row == at then
      local buf = summary_buf()
      preview.show(buf, preview.intro(api.nvim_win_get_width(S.pane_win)))
      if api.nvim_win_get_buf(S.pane_win) ~= buf then
        pane_set_buf(buf)
      end
      set_pane_options('preview')
      S.pane_shown = 'intro'
      mark_shown()
      return
    end
    S.intro = false
  end
  local terms = require('agent-chats.term')
  local term = chat and terms.find(chat) or nil
  if term and terms.window_of(term) then
    -- On screen already, in a window of the user's: it stays there, and
    -- the summary says where (see `window_of` on why not twice). The way
    -- back to the list is given to it all the same: Enter leads there.
    prepare_terminal(term)
    term = nil
  end
  -- The summary was asked for in place of the terminal (`M.toggle_info`):
  -- for that row, and until the cursor leaves it.
  if S.info and S.info ~= (row and row.id) then
    S.info = nil
  end
  if S.info then
    term = nil
  end
  S.pane_hints_fn = nil
  -- What the pane is about. While that stays the same a refresh must not
  -- move the pane's view: the user may have scrolled it.
  local shown = (term and 'term:' or 'summary:') .. tostring(row and row.id)
  local moved = S.pane_shown ~= shown
  S.pane_shown = shown
  if term then
    if api.nvim_win_get_buf(S.pane_win) ~= term then
      pane_set_buf(term)
      moved = true
    end
    if S.shown_term ~= term then
      S.shown_term, S.shown_since = term, vim.uv.hrtime()
    end
    set_pane_options('term')
    prepare_terminal(term)
    if moved then
      pcall(api.nvim_win_set_cursor, S.pane_win, { api.nvim_buf_line_count(term), 0 })
    end
  else
    -- No terminal in front of you now: one that comes back starts its
    -- couple of seconds again (see `M.is_showing`).
    S.shown_term = nil
    local buf = summary_buf()
    preview.render(
      buf,
      chat,
      row,
      S.rows,
      api.nvim_win_get_width(S.pane_win),
      api.nvim_win_get_tabpage(S.pane_win)
    )
    if api.nvim_win_get_buf(S.pane_win) ~= buf then
      pane_set_buf(buf)
      moved = true
    end
    set_pane_options('preview')
    if moved then
      pcall(api.nvim_win_set_cursor, S.pane_win, { 1, 0 })
    end
  end
  mark_shown()
end

update_pane = function()
  if not S.pane_on or not valid_win(S.pane_win) or not M.is_open() then
    return
  end
  -- The pane follows the cursor only while the list has focus; otherwise
  -- the user is in it (typing to an agent, reading a conversation).
  if api.nvim_win_get_buf(api.nvim_get_current_win()) ~= S.buf then
    return
  end
  show_row()
end

--- A terminal the pane shows has come to be shown in another window as
--- well (the user brought their own terminal up again, in their own
--- place): the pane lets go of it, for the summary. Not with the cursor
--- in the pane: whoever is typing there is not thrown out.
local function let_go()
  if
    M.is_open()
    and S.pane_mode == 'term'
    and valid_win(S.pane_win)
    and api.nvim_get_current_win() ~= S.pane_win
    and require('agent-chats.term').window_of(api.nvim_win_get_buf(S.pane_win))
  then
    S.pane_shown = nil
    show_row()
  end
end

local function schedule_pane()
  if S.pending_pane then
    return
  end
  S.pending_pane = true
  vim.schedule(function()
    S.pending_pane = false
    -- What is mapped can change under the cursor (a mapping made on this
    -- very buffer): looked at again as the cursor moves, which is cheap.
    if M.is_open() and api.nvim_get_current_buf() == S.buf and set_keys(S.buf) then
      -- The first line names keys as well.
      return M.render()
    end
    if M.is_open() and hold_left() then
      -- The chat that was read while the cursor was on it goes where it
      -- belongs now.
      return M.render()
    end
    hold_row()
    update_bar()
    update_pane()
  end)
end

--- The pane's window, opening the board and the pane as needed. Used to put
--- a terminal or a conversation there.
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
  info(
    'There is no room for the pane beside the list. Make Neovim wider, or use the board in a tab (board.layout = "tab").'
  )
end

--- Show `buf` in the pane and move the cursor there. The pane has no title
--- of its own: what it shows says what it is, the list marks the row of
--- the chat it belongs to, and the keys of the view are on the bar above
--- the list for as long as the cursor is in it.
---@param mode "term"|"conversation"|"diff"
---@param hints (fun(): table)?  The keys of the view, `{ key, label }` each and `menu` for the key of its menu; asked again whenever they may have changed.
function M.pane_show(buf, mode, hints)
  local win = M.pane_window()
  if not win then
    -- A terminal goes to a split instead (see term.lua); anything else
    -- has nowhere to go, and saying nothing would look like a dead key.
    if mode ~= 'term' and M.is_open() then
      M.no_room()
    end
    return nil
  end
  pane_set_buf(buf)
  set_pane_options(mode)
  window_keys(buf)
  S.pane_shown = nil
  -- Whatever is put in the pane is what the user asked for: the
  -- introduction has had its turn, and so has a summary that was asked
  -- for in place of a terminal.
  S.intro = false
  S.info = nil
  S.pane_hints_fn = type(hints) == 'function' and hints or nil
  if mode == 'term' then
    prepare_terminal(buf)
  end
  mark_shown()
  api.nvim_set_current_win(win)
  update_bar()
  return win
end

--- Move the list's cursor to the chat in terminal `buf` as soon as it has
--- a row (a chat that was started a moment ago gets one at the next look),
--- without taking the cursor out of wherever it is.
function M.follow(buf)
  if buf and M.is_open() and valid_win(S.win) then
    local row = S.rows[api.nvim_win_get_cursor(S.win)[1]]
    S.follow = { buf = buf, from = row and row.id or false, till = vim.uv.now() + 30000 }
  end
end

--- The cursor is in the summary: its keys are worked out again (what is
--- mapped may have changed), and the bar names the way back.
function M.summary_entered()
  if not (valid_win(S.pane_win) and S.pane_mode == 'preview') then
    return
  end
  summary_keys()
  update_bar()
end

--- The terminal `buf` in the pane holds a chat the cursor has gone into (or
--- that has only now started in it, or whose mode has changed): the bar
--- says how to get back to the list from where it is now.
function M.pane_entered(buf)
  if valid_win(S.pane_win) and api.nvim_win_get_buf(S.pane_win) == buf then
    S.intro = false
    update_bar()
  end
end

--- The agent in a terminal shown in the pane has stopped and its screen is
--- kept (it failed, or `open.close_on_exit` is off): the bar says so while
--- the cursor is in it.
function M.pane_ended(buf, code)
  pcall(function()
    -- Remembered, so that it is still said after a change of mode.
    vim.b[buf].agent_chats_exited = tostring(code)
  end)
  if valid_win(S.pane_win) and api.nvim_win_get_buf(S.pane_win) == buf then
    update_bar()
  end
end

--- A buffer shown in the pane is about to be deleted: put the summary back
--- first, so the window survives.
function M.release(buf)
  if valid_win(S.pane_win) and api.nvim_win_get_buf(S.pane_win) == buf then
    pane_set_buf(summary_buf())
    set_pane_options('preview')
    S.pane_shown, S.pane_hints_fn = nil, nil
    mark_shown()
    update_bar()
    return true
  end
  return false
end

--- Whether the cursor is on the list, or in the summary beside it: where
--- what a key did to a chat is seen at once, on its row.
function M.on_list()
  if not M.is_open() then
    return false
  end
  local win = api.nvim_get_current_win()
  return win == S.win or (win == S.pane_win and S.pane_mode == 'preview')
end

--- Whether the cursor is in the board (its list or its pane).
function M.has_focus()
  local win = api.nvim_get_current_win()
  return M.is_open() and (win == S.win or win == S.pane_win)
end

--- Whether the board is what you are looking at: the cursor is in its list
--- or its pane, or anywhere in the tab that is the board's own. A floating
--- board is, whenever it is open: it goes when the cursor leaves it for a
--- window behind it. (Asked for where this holds, the board closes; asked
--- for from anywhere else, it comes to the front: see `M.toggle`.)
---@return boolean
function M.in_front()
  if not M.is_open() then
    return false
  end
  if S.layout == 'float' or M.has_focus() then
    return true
  end
  return S.layout == 'tab'
    and S.tab ~= nil
    and api.nvim_tabpage_is_valid(S.tab)
    and api.nvim_get_current_tabpage() == S.tab
end

--- Put the cursor back in the list.
function M.focus()
  if M.is_open() then
    if S.tab and api.nvim_tabpage_is_valid(S.tab) then
      api.nvim_set_current_tabpage(S.tab)
    end
    api.nvim_set_current_win(S.win)
    vim.cmd.stopinsert()
    set_keys(S.buf)
    update_bar()
    update_pane()
  end
end

--- Show the summary of the chat under the cursor in place of its live
--- terminal, or the terminal again. For that row, and for as long as the
--- cursor stays on it: every other row shows what it always shows, and so
--- does this one when the cursor comes back to it.
---@param chat agent_chats.Chat?  The chat under the cursor when nil.
---@param row agent_chats.Row?
function M.toggle_info(chat, row)
  if not (chat and row) then
    chat, row = M.current()
  end
  if not (chat and row) then
    return
  end
  if not (S.pane_on and valid_win(S.pane_win)) then
    return info(
      ('The summary is shown in the pane, which is hidden. %s shows it.'):format(keys.reach('pane'))
    )
  end
  if not pane_term(chat) then
    -- Nothing to take the place of: no terminal here, or it is on screen
    -- in a window of its own.
    return info('The pane shows the summary of this chat already.')
  end
  S.intro = false
  S.info = S.info ~= row.id and row.id or nil
  if api.nvim_get_current_win() == S.pane_win then
    -- Pressed in the summary: the terminal comes back with the cursor on
    -- the list, as it is shown for any other row. (Going into it is what
    -- the key that opens a chat is for.)
    return M.focus()
  end
  show_row()
  update_bar()
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

--- End the search that is on. Returns whether there was one.
---@return boolean
function M.clear()
  if not S.search then
    return false
  end
  S.search_token = (S.search_token or 0) + 1
  require('agent-chats.search').cancel()
  S.search = nil
  M.render()
  return true
end

--- Move the cursor to a chat, unfolding and ending a search as needed.
---@return boolean found
function M.goto_chat(key)
  if not M.is_open() then
    return false
  end
  for _ = 1, 2 do
    for i, row in ipairs(S.rows) do
      if row.kind == 'chat' and row.chat.key == key then
        api.nvim_win_set_cursor(list_win(), { i, 1 })
        if hold_left() then
          -- The row the cursor came from was kept in its place: drawn
          -- again, it goes where it belongs (and the cursor stays here).
          M.render()
        else
          hold_row()
          update_bar()
          update_pane()
        end
        return true
      end
    end
    -- Not on screen: a search may hide it, or a folded group, or the cap.
    local chat = store.get(key)
    if not chat then
      return false
    end
    if S.search then
      S.search_token = (S.search_token or 0) + 1
      require('agent-chats.search').cancel()
      S.search = nil
    end
    for _, g in ipairs(build_groups({ chat })) do
      set_folded(g.id, false)
      S.full[g.id] = true
    end
    M.render()
  end
  return false
end

--- The text of the search that is on ('' when none is).
---@return string
function M.query()
  return S.search and S.search.query or ''
end

--- Read every conversation for the text of the search that is on, and
--- show the passages under their chats as they are found.
local function read_conversations()
  local mine = S.search
  if not mine or mine.read then
    return
  end
  mine.read, mine.running = true, true
  M.render()
  -- Asked for as the first thing after Neovim came up, the index may still
  -- be loading: a search over the part that is there would look complete.
  store.when_ready(function()
    if S.search ~= mine or not M.is_open() then
      return
    end
    require('agent-chats.search').run(vim.trim(mine.query), function(hits, running)
      if S.search ~= mine or not M.is_open() then
        return
      end
      mine.hits, mine.running = hits, running
      M.render()
      if vim.fn.getcmdtype() ~= '' then
        -- Still being typed: the screen is not drawn again by itself.
        vim.cmd.redraw()
      end
    end)
  end)
end

--- Search for `query`: the rows are narrowed at once to those that show or
--- hold it, and the conversations are read for it as well. An empty text
--- ends the search.
---@param query string?
---@param opts { conversations: boolean?, delay: integer? }?  conversations = false narrows only; delay (ms) waits for the typing to pause first.
function M.search(query, opts)
  opts = opts or {}
  -- Without the blanks around it: a text is typed with one behind it on
  -- the way to its next word, and is the same text for that.
  query = vim.trim(query or '')
  if not M.is_open() then
    return
  end
  if query == '' then
    M.clear()
    return
  end
  if not S.search or S.search.query ~= query then
    -- Another text: what was found for the last one is of no use.
    S.search_token = (S.search_token or 0) + 1
    require('agent-chats.search').cancel()
    S.search = { query = query, hits = {}, running = false, fresh = true }
  end
  M.render()
  if opts.conversations == false or S.search.read then
    return
  end
  if (opts.delay or 0) > 0 then
    local token = S.search_token
    vim.defer_fn(function()
      if S.search_token == token and S.search and S.search.query == query then
        read_conversations()
      end
    end, opts.delay)
  else
    read_conversations()
  end
end

--- Show search results as they are (tests, and whoever searched already).
---@param search { query: string, hits: table<string, agent_chats.Hit[]>, running: boolean }?
function M.set_search(search)
  S.search_token = (S.search_token or 0) + 1
  if search then
    search.read = true
  end
  S.search = search
  M.render()
end

--- Ask for the text to search for, narrowing the list as it is typed.
function M.search_prompt()
  if not M.is_open() then
    return
  end
  local before = S.search
  local live = config.get().search.live
  local group = api.nvim_create_augroup('AgentChatsSearch', { clear = true })
  api.nvim_create_autocmd('CmdlineChanged', {
    group = group,
    callback = function()
      if vim.fn.getcmdtype() == '@' then
        M.search(vim.fn.getcmdline(), { conversations = live, delay = M._search_delay })
        vim.cmd.redraw()
      end
    end,
  })
  S.typing = true
  M.render()
  -- Empty, also when a search is on: what is typed is the text to look
  -- for, not a continuation of the last one. (Up brings that one back, as
  -- in any prompt.)
  local ok, res = pcall(vim.fn.input, {
    prompt = 'Search chats: ',
    cancelreturn = '\0',
  })
  S.typing = nil
  pcall(api.nvim_del_augroup_by_id, group)
  if not ok or res == '\0' then
    -- Called off: back to what was there before.
    S.search_token = (S.search_token or 0) + 1
    local changed = S.search ~= before
    if not before or changed then
      require('agent-chats.search').cancel()
    end
    S.search = before
    if before and changed and before.running then
      -- Its reading was stopped when the first letter was typed: it is
      -- taken up again, or the header would say "reading" for ever.
      before.read, before.running = nil, false
      M.render()
      read_conversations()
      return
    end
    M.render()
    return
  end
  -- (The same text as was shown while typing: only the header changes.)
  M.search(res)
end

function M.set_group(mode)
  -- The name this grouping went by before.
  if mode == 'provider' then
    mode = 'agent'
  end
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
      info('Groups stay open while search results are shown.')
      return
    end
    set_folded(row.group, not folded(row.group))
  elseif row.kind == 'more' then
    S.full[row.group] = true
  elseif row.kind == 'chat' and not row.chat.subagent then
    local key = row.chat.key
    if S.expanded[key] then
      S.expanded[key] = nil
    elseif #store.load_children(row.chat) > 0 then
      S.expanded[key] = true
    elseif config.get().hide_subagents then
      -- It may have some: none is looked for, so that is not said.
      info('Subagents are not shown: hide_subagents is on in the options.')
    else
      info('This chat has no subagents.')
    end
  end
  M.render()
end

function M.toggle_show_all()
  local on = not (store.show_all and S.show_older)
  S.show_older = on
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

--- One step back: out of a search, else out of the board.
function M.back()
  if not M.clear() then
    M.close()
  end
end

-----------------------------------------------------------------------------
-- What can be done, and the keys for it
-----------------------------------------------------------------------------

-- Every action that can have a key, and what its mapping is described as
-- (for which-key and `:map`).
local DESCRIPTIONS = {
  open = 'open the chat (resume it if it ended)',
  queue = 'queue a reply for when the chat finishes its turn',
  read = 'read the whole conversation',
  new = 'new chat',
  search = 'search chats',
  menu = 'everything that can be done here',
  back = 'back (end the search, close the board)',
  clear = 'end the search',
  toggle = "fold a group, or show a chat's subagents",
  notify = 'notifications on or off',
  move = 'put the chat in a group of your own, or take it out',
  diff = "show what changed in the chat's folder",
  rename = 'rename the chat',
  pin = 'pin the chat to the top of its group',
  label = 'edit the labels of the chat',
  note = 'edit the note of the chat',
  unread = 'mark the chat read or unread',
  archive = 'archive the chat',
  info = "show the chat's summary in place of its terminal, or the terminal again",
  yank = 'copy the command that resumes the chat',
  group = 'group by status, folder, agent or worktree',
  pane = 'show or hide the pane',
  show_all = 'show older chats',
  read_all = 'mark every chat read',
  scroll_down = 'scroll the pane down',
  scroll_up = 'scroll the pane up',
  refresh = 'look for changes now',
  hooks = "set up the agents' status hooks",
}
M.descriptions = DESCRIPTIONS

--- What the cursor is on, for whatever acts on it.
---@return { chat: agent_chats.Chat?, row: agent_chats.Row? }
local function context()
  local chat, row = M.current()
  return { chat = chat, row = row }
end

--- Every action, as a function of what it acts on (`ctx.chat`, `ctx.row`).
---@return table<string, fun(ctx: table)>
local function handlers()
  local actions = require('agent-chats.actions')
  --- For an action that needs a chat. Pressed anywhere else, the key
  --- says so instead of doing nothing.
  local function on_chat(fn, verb)
    return function(ctx)
      if ctx.chat then
        return fn(ctx.chat, ctx.row)
      end
      info(('Move to a chat first: there is none under the cursor to %s.'):format(verb))
    end
  end
  --- Needs `ctx.chat`. On a passage a search found, the conversation opens
  --- there; on the row of a chat a search found passages in, at the first
  --- of them (what it was searched for, not its end).
  local function read(ctx)
    local row = ctx.row
    local hit = row and row.kind == 'hit' and row.hit or nil
    if not hit and row and row.kind == 'chat' and S.search and ctx.chat then
      hit = (S.search.hits[ctx.chat.key] or {})[1]
    end
    actions.read(
      ctx.chat,
      { index = hit and hit.index, query = hit and S.search and S.search.query or nil }
    )
  end
  return {
    open = function(ctx)
      local row = ctx.row
      if row and (row.kind == 'group' or row.kind == 'more') then
        M.toggle_row()
      elseif row and row.kind == 'older' then
        M.toggle_show_all()
      elseif row and row.kind == 'hit' then
        read(ctx)
      elseif ctx.chat then
        actions.open(ctx.chat)
      end
    end,
    read = function(ctx)
      if ctx.chat then
        return read(ctx)
      end
      info('Move to a chat first: there is none under the cursor to read.')
    end,
    queue = on_chat(actions.queue, 'queue a reply for'),
    new = function(ctx)
      actions.new({ chat = ctx.chat })
    end,
    diff = on_chat(actions.diff, 'show the changes of'),
    search = function()
      require('agent-chats.actions').search()
    end,
    clear = function()
      M.clear()
    end,
    back = function(ctx)
      if ctx.back then
        ctx.back()
      else
        M.back()
      end
    end,
    menu = function(ctx)
      M.menu(ctx)
    end,
    group = M.cycle_group,
    toggle = M.toggle_row,
    pane = M.toggle_pane,
    -- A read mark set by hand is seen to take effect: the chat goes where
    -- it belongs at once, also from under the cursor.
    unread = on_chat(function(chat)
      S.hold = { key = chat.key, free = true }
      actions.toggle_unread(chat)
    end, 'mark'),
    read_all = function(ctx)
      if ctx.chat then
        S.hold = { key = ctx.chat.key, free = true }
      end
      actions.read_all()
    end,
    pin = on_chat(actions.pin, 'pin'),
    move = on_chat(function(chat)
      actions.move(chat, function(name)
        -- Seen at once where the list is grouped by status. Where it is
        -- not, nothing on the screen would say that it worked.
        if name and config.filtered(chat.cwd) then
          info(
            ('It is in “%s”. It stays under “Filtered out” for as long as the options filter its folder out.'):format(
              name
            )
          )
        elseif name and S.group_by ~= 'status' then
          info(
            ('It is in “%s”. Your own groups are shown when the list is grouped by status.'):format(
              name
            )
          )
        end
      end)
    end, 'move'),
    archive = on_chat(actions.archive, 'archive'),
    info = on_chat(M.toggle_info, 'show the summary of'),
    show_all = M.toggle_show_all,
    label = on_chat(actions.labels, 'label'),
    note = on_chat(actions.note, 'put a note on'),
    rename = on_chat(actions.rename, 'rename'),
    yank = on_chat(actions.yank, 'copy the command of'),
    scroll_down = function()
      scroll_pane(1)
    end,
    scroll_up = function()
      scroll_pane(-1)
    end,
    refresh = function()
      -- Said when it is done: on a list that was up to date already, the
      -- key would look dead otherwise.
      store.refresh({ full = true }, function()
        info('The list is up to date. It also looks for changes by itself.')
      end)
    end,
    hooks = function()
      require('agent-chats.ui.hooks').open()
    end,
    notify = function()
      require('agent-chats.notify').set()
    end,
  }
end

--- The actions that apply to what `ctx` is about, in words: what the menu
--- lists. One list, in parts, each under a heading that says what it is
--- about: the chat, your own marks on it, the list, the board.
---@param ctx { chat: agent_chats.Chat?, row: agent_chats.Row?, view: string?, back: fun()? }
---@return table[] items  `{ text, action?, run }`, or `{ heading = words }` over the lines that follow.
function M.menu_items(ctx)
  local chat, row = ctx.chat, ctx.row
  local items = {}
  local part ---@type string?  The heading of the part being listed, put down with its first line.
  local function put(entry)
    if part then
      items[#items + 1] = { heading = part }
      part = nil
    end
    items[#items + 1] = entry
  end
  local function item(action, label)
    put({
      text = label,
      action = action,
      run = function()
        -- (Through `run`: a view does some of these itself.)
        M.run(action, ctx)
      end,
    })
  end
  local function custom(label, run)
    put({ text = label, run = run })
  end

  -- What the cursor is on.
  if row and row.kind == 'group' then
    part = 'This group'
    if not S.search then
      item('open', folded(row.group) and 'Unfold this group' or 'Fold this group')
    end
    if row.own then
      -- A group of yours, as a whole.
      local name = row.own
      custom('Rename this group', function()
        require('agent-chats.actions').rename_group(name, function(new)
          -- Folded or not as it was, and the cursor on its heading still.
          local id = S.group_by .. ':own:' .. new
          set_folded(id, folded(row.group))
          set_folded(row.group, false)
          M.render()
          for i, r in ipairs(S.rows) do
            if r.kind == 'group' and r.group == id and valid_win(S.win) then
              pcall(api.nvim_win_set_cursor, S.win, { i, 1 })
              break
            end
          end
          update_bar()
          update_pane()
        end)
      end)
      custom('Take every chat out of it (the group is gone then)', function()
        require('agent-chats.actions').empty_group(name)
      end)
    end
  elseif row and (row.kind == 'more' or row.kind == 'older') then
    part = 'These chats'
    item('open', 'Show them')
  end
  if chat and chat.subagent then
    part = 'This subagent'
    if ctx.view then
      item('back', 'Back to the list')
    else
      item('open', 'Read what this subagent did')
    end
  elseif chat then
    part = 'This chat'
    if ctx.view then
      item('back', 'Back to the list')
    end
    local term = require('agent-chats.term').find(chat)
    local elsewhere = chat.live and not term
    local busy = chat.status == 'working' or chat.status == 'attention'
    local queued = #state.queue(chat.key)
    local _, sentence = M.open_words(chat)
    if row and row.kind == 'hit' then
      item('open', 'Read the conversation at this passage')
    elseif not (elsewhere and ctx.view) then
      item('open', sentence)
    end
    if not chat.stub and not ctx.view and not elsewhere and startable(chat) then
      item('read', 'Read the conversation')
    end
    if not ctx.view and pane_term(chat) then
      item(
        'info',
        S.info == (row and row.id) and 'Show its terminal in the pane again'
          or 'Show its summary in the pane, in place of its terminal'
      )
    end
    if queued > 0 then
      item('queue', ('Queued replies (%d): send, add or drop'):format(queued))
    elseif busy and not elsewhere then
      item('queue', 'Queue a reply for when it finishes its turn')
    end
    if chat.cwd and fs.is_dir(chat.cwd) then
      item('diff', 'Show what changed in its folder')
    end
    -- Looked for now: those of a chat that has not moved for a day are
    -- not read until they are asked for, and this is the asking.
    if not ctx.view and #store.load_children(chat) > 0 then
      item('toggle', S.expanded[chat.key] and 'Hide its subagents' or 'Show its subagents')
    end
    if not chat.unstarted then
      part = 'Keep track of it'
      item('rename', 'Rename')
      item('pin', state.pinned(chat.key) and 'Unpin' or 'Pin to the top of its group')
      local own = state.group(chat.key)
      item(
        'move',
        own and ('Move it out of “%s”, or to another group'):format(text.truncate(own, 24))
          or 'Put it in a group of your own'
      )
      item('label', 'Edit its labels')
      item('note', state.note(chat.key) and 'Edit its note' or 'Add a note')
      if chat.status == 'done' then
        item('unread', 'Mark read')
      elseif chat.turn == 'done' then
        item('unread', 'Mark unread')
      end
      item(
        'archive',
        state.is_archived(chat.key, chat.updated) and 'Unarchive it'
          or 'Archive it: out of the way, at the end of the list'
      )
      item('yank', 'Copy the command that resumes it')
    end
  end

  if ctx.view then
    if not chat then
      part = 'This page'
      item('back', 'Back to the list')
    end
    if ctx.view == 'conversation' then
      -- What moves in the conversation itself: the bar names these keys
      -- only where there is room for them.
      part = 'This conversation'
      item('next_prompt', 'Go to the next prompt')
      item('prev_prompt', 'Go to the prompt before')
      item('toggle', 'Open or close the tool call under the cursor')
    end
    -- From a view in the pane: what is about the list as a whole is on the
    -- list's own menu.
    part = 'Chats'
    item('new', 'New chat')
    item('search', 'Search chats')
    return items
  end

  part = 'The list'
  item('new', 'New chat')
  if S.search then
    item('search', 'Search for something else')
    item('clear', 'End the search')
  else
    item('search', 'Search chats')
  end
  -- In the order the key for it goes through them, from the grouping
  -- there is now: the key stands beside the one it would pick.
  local at = 1
  for i, mode in ipairs(GROUP_MODES) do
    if mode == S.group_by then
      at = i
    end
  end
  for step = 1, #GROUP_MODES - 1 do
    local mode = GROUP_MODES[(at + step - 1) % #GROUP_MODES + 1]
    if step == 1 then
      item('group', 'Group by ' .. mode)
    else
      custom('Group by ' .. mode, function()
        M.set_group(mode)
      end)
    end
  end
  item('show_all', S.show_older and 'Hide older chats' or 'Show older chats')
  if store.counts().done > 0 then
    item('read_all', 'Mark every chat read')
  end

  part = 'The board'
  item('pane', valid_win(S.pane_win) and 'Hide the pane' or 'Show the pane')
  item('refresh', 'Refresh the list now')
  item('hooks', 'Status hooks of the agents: see or set up')
  -- Last but one: two steps up from where the menu opens (it goes round).
  item(
    'notify',
    require('agent-chats.notify').enabled() and 'Turn notifications off' or 'Turn notifications on'
  )
  if S.search then
    -- "Back" ends the search first; closing is one step further.
    custom('Close the board', M.close)
  else
    item('back', 'Close the board')
  end
  return items
end

--- Open the menu for what `ctx` is about (the row under the cursor when
--- nothing is given).
function M.menu(ctx)
  if not M.is_open() then
    M.open()
  end
  if not M.is_open() then
    return
  end
  ctx = ctx or context()
  -- (What the cursor is on other than a chat is named by the heading of
  -- the first part.)
  local title = ctx.chat and display.title(ctx.chat, 56) or 'Agent chats'
  local actions = ctx.actions or vim.tbl_keys(DESCRIPTIONS)
  table.sort(actions)
  return require('agent-chats.ui.menu').open(M.menu_items(ctx), {
    title = title,
    keys = ctx.keys,
    actions = actions,
    run = function(action)
      M.run(action, ctx)
    end,
  })
end

--- Run `action` on what `ctx` is about. The way a view in the pane (a
--- conversation) reaches the actions of its chat.
function M.run(action, ctx)
  -- What a view does itself with one of its own keys (the next prompt of a
  -- conversation) comes first.
  if ctx and ctx.run and ctx.run[action] then
    return ctx.run[action]()
  end
  local fn = handlers()[action]
  if fn then
    return fn(ctx or context())
  end
end

--- Put the cursor on the row that was clicked.
local function to_mouse()
  local pos = vim.fn.getmousepos()
  if
    pos.winid ~= 0
    and api.nvim_win_is_valid(pos.winid)
    and api.nvim_win_get_buf(pos.winid) == S.buf
  then
    if pos.line > 0 then
      api.nvim_set_current_win(pos.winid)
      pcall(api.nvim_win_set_cursor, pos.winid, { pos.line, 1 })
      return true
    end
  end
  return false
end

--- Give `buf` the keys of `plan` (action -> the keys to bind), and take
--- away what it was given before and should no longer have. `book` is the
--- record of what it was given; `run(action, lhs)` is what a key does.
---@return boolean changed
local function give_keys(buf, book, plan, run)
  local wanted = {} ---@type table<string, { lhs: string, action: string }>
  for action in pairs(DESCRIPTIONS) do
    for _, lhs in ipairs(plan[action] and plan[action].bound or {}) do
      wanted[keys.canon(lhs)] = { lhs = lhs, action = action }
    end
  end
  local changed = false
  for key, had in pairs(book) do
    local want = wanted[key]
    local stale = not want
      or want.action ~= had.action
      -- It took itself off when it was pressed (it gave way to a mapping
      -- of yours, which may be gone again by now) ...
      or not keys.is_ours(buf, 'n', had.lhs)
      -- ... or it gives way and should not any more (the key has been
      -- named in the options since), or the other way round.
      or had.yields ~= not config.explicit(had.action)
    if stale then
      keys.unset(buf, 'n', had.lhs)
      book[key] = nil
      changed = true
    end
  end
  for key, want in pairs(wanted) do
    if not book[key] then
      local action, lhs = want.action, want.lhs
      want.yields = not config.explicit(action)
      local mapped = keys.set(buf, 'n', lhs, function()
        run(action, lhs)
      end, DESCRIPTIONS[action], want.yields)
      if mapped then
        book[key] = want
        changed = true
      else
        -- Neovim would not take it: not a key the screen may name.
        plan[action].bound = vim.tbl_filter(function(each)
          return each ~= lhs
        end, plan[action].bound)
      end
    end
  end
  return changed
end

local function is_mouse(lhs)
  return lhs:lower():find('mouse', 1, true) ~= nil
end

--- Give the list the keys it should have now, and take away the ones it
--- should not. Worked out with the buffer there, so that a mapping you put
--- on this buffer yourself (a FileType autocommand) counts as yours too;
--- and again whenever the list gets the cursor or the cursor moves in it,
--- so that a mapping made since (a plugin loaded late, a `:nnoremap
--- <buffer>` typed on the list) has its key and the hints stop naming it.
---@return boolean changed
set_keys = function(buf)
  S.keys = S.keys or {}
  return give_keys(buf, S.keys, keys.plan(buf), function(action, lhs)
    if is_mouse(lhs) and not to_mouse() then
      return
    end
    M.run(action)
  end)
end

--- The summary has the keys of the list. With the cursor in it they act on
--- the chat it shows, as the bar beside it says they do; "back" goes to
--- the list. (Not the mouse: a click in a text selects.)
summary_keys = function()
  local buf = S.preview_buf
  if not valid_buf(buf) then
    return
  end
  window_keys(buf)
  if S.summary_for ~= buf then
    S.summary_for, S.summary_book = buf, {}
  end
  local plan = {}
  for action in pairs(DESCRIPTIONS) do
    plan[action] = keys.resolve(action, 'n', buf)
    plan[action].bound = vim.tbl_filter(function(lhs)
      return not is_mouse(lhs)
    end, plan[action].bound)
  end
  give_keys(buf, S.summary_book, plan, function(action)
    if action == 'back' then
      M.focus()
    else
      M.run(action)
    end
  end)
end

--- Work the keys out again (the options changed, or what is mapped did),
--- and bring everything that names a key up to date.
function M.rekey()
  if not M.is_open() then
    return
  end
  summary_keys()
  -- The list's keys are settled as it is drawn; its first line names them.
  M.render()
  if valid_win(S.pane_win) and api.nvim_get_current_win() == S.pane_win then
    if S.pane_mode == 'term' then
      M.pane_entered(api.nvim_win_get_buf(S.pane_win))
    elseif S.pane_mode == 'preview' then
      M.summary_entered()
    else
      update_bar()
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
  'winbar',
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
  if S.search then
    require('agent-chats.search').cancel()
  end
  local menu = package.loaded['agent-chats.ui.menu']
  if menu then
    menu.close()
  end
  if valid_buf(S.preview_buf) then
    pcall(api.nvim_buf_delete, S.preview_buf, { force = true })
  end
  S.buf, S.win, S.pane_win, S.preview_buf, S.tab = nil, nil, nil, nil, nil
  S.rows, S.spin, S.search = {}, {}, nil
  S.search_token = (S.search_token or 0) + 1
  S.expanded, S.full = {}, {}
  S.placed, S.pane_shown, S.saved_wo = false, nil, nil
  S.intro, S.intro_row = false, nil
  S.keys, S.at, S.follow, S.hold = nil, nil, nil, nil
  S.shown_term, S.shown_since = nil, nil
  S.settled, S.auto_line = nil, nil
  S.summary_for, S.summary_book, S.pane_hints_fn = nil, nil, nil
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
  -- Back to where the board was asked for, but only for someone who is in
  -- it: closed from another tab (`:Chats close`), it goes and the cursor
  -- stays where it is.
  local in_its_tab = tab ~= nil and api.nvim_get_current_tabpage() == tab
  local cur = api.nvim_get_current_win()
  local inside = cur == win or cur == pane
  -- The pane goes first, while what it shows is still what the board put
  -- there, and as quietly as that came: a chat's terminal goes out of
  -- sight without being said to have left a window of the user's. (Left
  -- for last, it would also be given some other buffer for a moment, when
  -- the summary it shows is deleted under it.)
  if valid_win(pane) then
    if cur == pane and valid_win(win) then
      -- To the list from the pane, so that closing the pane does not send
      -- the cursor anywhere else on the way out.
      pcall(quietly, ENTERED, api.nvim_set_current_win, win)
    end
    S.pane_win = nil
    pcall(quietly, SHOWN, api.nvim_win_close, pane, true)
  end
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
    if in_its_tab and prev_tab and api.nvim_tabpage_is_valid(prev_tab) then
      pcall(api.nvim_set_current_tabpage, prev_tab)
      if valid_win(prev_win) and api.nvim_win_get_tabpage(prev_win) == prev_tab then
        pcall(api.nvim_set_current_win, prev_win)
      end
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

--- The board is asked for from somewhere else while it is open: closing
--- it leads back there, not to where it was first opened from. (Not from
--- a chat's terminal: that is part of the board's own business.)
local function note_origin()
  local win, tab = api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  local buf = api.nvim_win_get_buf(win)
  if win == S.win or win == S.pane_win or vim.bo[buf].buftype == 'terminal' then
    return
  end
  if S.layout == 'tab' then
    if S.tab and tab ~= S.tab then
      S.prev_tab, S.prev_win = tab, win
    end
  elseif S.layout == 'float' and api.nvim_win_get_config(win).relative == '' then
    S.prev_win = win
  end
end

local function open_board(opts)
  opts = opts or {}
  if M.is_open() then
    note_origin()
    M.focus()
    if opts.search then
      M.search(opts.search)
    end
    return
  end
  -- What is left of a board whose window was closed a moment ago (its
  -- own closing is still on its way): cleared away now, or its timer and
  -- its place among those who hear of changes would be lost with it.
  if S.buf or S.unsub or S.timer then
    M.close()
  end
  S.gen = (S.gen or 0) + 1
  local cfg = config.get()
  require('agent-chats.ui.highlights').setup()
  require('agent-chats.term').setup()
  S.layout = opts.layout or cfg.board.layout
  S.group_by = opts.group_by or S.group_by or cfg.board.group_by
  if S.group_by == 'provider' then
    S.group_by = 'agent'
  end
  S.search = nil
  S.show_older = store.show_all
  S.pane_on = cfg.board.pane
  S.intro = cfg.board.intro ~= false and state.intro() < INTRO
  S.intro_row = nil
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
    window_keys(S.buf)
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
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = S.buf,
    callback = function()
      settle_cursor()
      schedule_pane()
    end,
  })
  api.nvim_create_autocmd('CmdlineLeave', {
    group = group,
    callback = function()
      -- A command may have made a mapping or taken one away (`:nnoremap
      -- <buffer> C ...` typed on the list): what the screen says of the
      -- keys follows at once, not at the next move of the cursor.
      vim.schedule(function()
        if M.is_open() and api.nvim_get_current_buf() == S.buf and set_keys(S.buf) then
          M.render()
        end
      end)
    end,
  })
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      if
        S.pane_mode == 'term'
        and valid_win(S.pane_win)
        and api.nvim_win_get_buf(S.pane_win) == ev.buf
      then
        -- (When whatever brought it up has finished with its windows.)
        vim.schedule(let_go)
      end
    end,
  })
  api.nvim_create_autocmd('ModeChanged', {
    group = group,
    callback = function()
      -- Into or out of typing in a chat's terminal: the bar names the key
      -- that goes back in the mode it is in now.
      local win = api.nvim_get_current_win()
      if win == S.pane_win and S.pane_mode == 'term' then
        update_bar()
      end
    end,
  })
  api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = function()
      local win = api.nvim_get_current_win()
      if win == S.win or api.nvim_win_get_buf(win) == S.buf then
        -- What is mapped may have changed while the cursor was away.
        set_keys(S.buf)
        schedule_pane()
      elseif win == S.pane_win and S.pane_mode == 'preview' then
        -- In the summary: its keys are looked at again, and the bar names
        -- the way back.
        M.summary_entered()
      elseif win == S.pane_win then
        -- Gone into the chat (or the conversation) with a window command
        -- rather than through the list: the bar says how to get back all
        -- the same.
        S.intro = false
        update_bar()
      elseif S.layout == 'float' and api.nvim_win_get_config(win).relative == '' then
        -- Focus left the floating board for a normal window: get out of the way.
        vim.schedule(function()
          if M.is_open() and api.nvim_win_get_config(api.nvim_get_current_win()).relative == '' then
            M.close()
          end
        end)
      else
        -- Out of the board: the bar is about the list again.
        update_bar()
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
  if vim.v.vim_did_enter == 0 then
    -- Opened as Neovim starts (`nvim -c Chats`). What runs at VimEnter can
    -- still split the list: netrw runs `:windo` then, and `:windo` splits a
    -- window that is fixed to its buffer when it has no other to go to (no
    -- pane). Nobody has typed a `:split` yet, so a second window on the
    -- list at that moment is that, and goes. (Later, a split of the list
    -- is the user's own, and a view like the first.)
    api.nvim_create_autocmd('VimEnter', {
      group = group,
      once = true,
      callback = function()
        vim.schedule(function()
          if not M.is_open() or S.closing then
            return
          end
          local tab = api.nvim_win_get_tabpage(S.win)
          for _, win in ipairs(vim.fn.win_findbuf(S.buf)) do
            if win ~= S.win and api.nvim_win_get_tabpage(win) == tab then
              local was_in = api.nvim_get_current_win() == win
              pcall(api.nvim_win_close, win, true)
              if was_in and valid_win(S.win) then
                api.nvim_set_current_win(S.win)
              end
            end
          end
        end)
      end,
    })
  end
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed == S.win then
        -- (For this board: another may have been opened by then.)
        local gen = S.gen
        vim.schedule(function()
          if S.gen == gen then
            M.close()
          end
        end)
      elseif closed == S.pane_win then
        -- Closing the window is "back", whatever key or command did it:
        -- out of a conversation, a diff or a chat's terminal the list
        -- gets the cursor and the pane shows its summary again. Closing
        -- the summary itself is asking for the pane to go.
        local was_in = api.nvim_get_current_win() == closed
        local view = S.pane_mode == 'term' or S.pane_mode == 'conversation' or S.pane_mode == 'diff'
        -- What it showed, and whether that outlives a window that shows
        -- it: afterwards, this tells a pane that was closed from one whose
        -- buffer was deleted under it.
        local shown, lasting
        pcall(function()
          shown = api.nvim_win_get_buf(closed)
          -- (With 'nohidden' a buffer goes with its last window, a running
          -- terminal too: nothing can be told there.)
          local hidden = vim.bo[shown].bufhidden
          lasting = hidden == 'hide' or (hidden == '' and vim.o.hidden)
        end)
        S.pane_win = nil
        -- Nothing is shown beside the list now: no row is marked.
        mark_shown()
        if was_in and view and not S.closing then
          vim.schedule(function()
            if M.is_open() and not valid_win(S.pane_win) then
              S.pane_on = true
              open_pane()
              M.focus()
            end
          end)
        else
          S.pane_on = false
          -- The floating list has the whole board to itself again.
          if S.layout == 'float' and valid_win(S.win) and not S.closing then
            vim.schedule(function()
              if M.is_open() and S.layout == 'float' and not valid_win(S.pane_win) then
                pcall(api.nvim_win_set_config, S.win, { width = M._float_dims().width })
                M.render()
              end
            end)
          end
          -- Unless the pane went because what it showed was deleted: that
          -- is no wish to have the list alone. A chat's terminal goes like
          -- that under a config that deletes the buffer of a shell that has
          -- exited, and the board would be left as one window, with none
          -- beside it to go to and nothing to say why. The pane comes back,
          -- with what the row under the cursor has to show. (Which of the
          -- two it was is known once the buffer has had the time to go.)
          if lasting and not S.closing then
            local gen = S.gen
            vim.schedule(function()
              local gone = not (valid_buf(shown) and api.nvim_buf_is_loaded(shown))
              if gone and S.gen == gen and M.is_open() and not S.closing and not S.pane_on then
                S.pane_on = true
                open_pane()
                S.pane_shown = nil
                M.render()
              end
            end)
          end
        end
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = S.buf,
    callback = function()
      local gen = S.gen
      vim.schedule(function()
        if S.gen == gen and not S.closing and S.buf and not valid_buf(S.buf) then
          M.close()
        end
      end)
    end,
  })

  S.unsub = store.on(function(ev)
    if ev.type == 'update' then
      M.render()
      -- Drawn from an index that has been read through: from now on the
      -- cursor stays with its chat.
      if store.initialized then
        S.settled = true
      end
    end
  end)
  if cfg.board.spinner then
    S.timer = vim.uv.new_timer()
    S.timer:start(120, 120, vim.schedule_wrap(M.spin))
  end

  store.set_fast(true)
  -- The list is whole when the index has been read once (see `M.render`
  -- on why the cursor waits for that).
  S.settled, S.auto_line = store.initialized, nil
  M.render()
  if not store.is_watching() then
    store.start()
  else
    store.refresh({ full = true })
  end
  if opts.search then
    M.search(opts.search)
  end
end

--- Open the board, or go to it when it is already open.
---@param opts { layout: string?, group_by: string?, search: string? }?
function M.open(opts)
  local ok, err = pcall(open_board, opts)
  if not ok then
    -- Never leave half a board behind.
    pcall(M.close)
    vim.notify('agent-chats: could not open the board: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

--- What the bare command does: open the board; go to it when it is open
--- somewhere else (in another tab, in another window); close it when it is
--- what you are looking at.
---@param opts { layout: string?, group_by: string?, search: string? }?
function M.toggle(opts)
  if M.in_front() then
    M.close()
  else
    M.open(opts)
  end
end

--- Internal state, for tests.
M._state = S

return M
