-- The board: every chat in one list, with a pane beside it.
--
--   +---------------------------------------------+---------------------------+
--   | Enter open  C conversation          ? more  | Summary                   |
--   | 12 chats · 2 need you   + new  M notify: on |                           |
--   |                                             |  the chat under the       |
--   | ▾ Needs you  2                              |  cursor: its live         |
--   |  ● Claude  Fix flaky restore            2m  |  terminal when it runs    |
--   | ▾ Working  3                                |  in this Neovim, a        |
--   |  ◐ Codex   Port renderer               41s  |  summary otherwise        |
--   +---------------------------------------------+---------------------------+
--
-- The list is a plain buffer rendered from the index (store.lua). The bar
-- above it names what can be done with the row under the cursor, and the
-- keys for it. The pane follows the cursor while the list has focus;
-- opening a chat or a conversation puts it in the pane and moves the cursor
-- there.

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
local GROUP_MODES = { 'status', 'folder', 'agent', 'worktree' }
-- How long typing has to pause before the conversations are read too (ms).
M._search_delay = 250
-- The introduction is shown once; raising this shows it once more.
local INTRO = 1

---@class agent_chats.Row
---@field kind "header"|"blank"|"group"|"chat"|"hit"|"more"|"older"|"info"
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
  expanded = {}, ---@type table<string, boolean>
  full = {}, ---@type table<string, boolean>
  show_archived = false,
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
  -- A search looks at every chat there is, the archived ones too.
  for _, chat in ipairs(store.list({ archived = S.show_archived or search ~= nil })) do
    if not search or matches(chat, terms) or search.hits[chat.key] ~= nil then
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

--- The order inside a group of your own, which holds chats in every
--- state: what needs you first.
local function own_order(a, b)
  local pa, pb = state.pinned(a.key), state.pinned(b.key)
  if pa ~= pb then
    return pa
  end
  local ra, rb = status.rank[a.status] or 9, status.rank[b.status] or 9
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

  for _, chat in ipairs(chats) do
    local g
    if mode == 'agent' then
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
        g = group(chat.status, status.labels[chat.status] or chat.status, status.hl[chat.status])
        -- A heading that says what it means: no table to look it up in.
        g.about = status.about[chat.status]
        g.about_short = status.about_short[chat.status]
      end
    end
    g.chats[#g.chats + 1] = chat
    g.latest = math.max(g.latest, chat.updated or 0)
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
      return (status.rank[a.chats[1].status] or 9) < (status.rank[b.chats[1].status] or 9)
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
    table.sort(g.chats, g.own and own_order or chat_order)
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

--- `key label` as a piece of a line, the key set apart; nil when the
--- action has no key (a hint never names a key that does nothing).
local function hint_piece(action, label)
  local key = keys.key(action)
  if not key then
    return nil
  end
  local piece = Line()
  add(piece, key, 'AgentChatsKey')
  add(piece, ' ' .. label, 'AgentChatsDim')
  return piece
end

--- `key label` for a key that is not an action's (those of the prompt a
--- search is typed at).
local function key_piece(key, label)
  local piece = Line()
  add(piece, key, 'AgentChatsKey')
  add(piece, ' ' .. label, 'AgentChatsDim')
  return piece
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
  if not chat.subagent then
    if state.note(chat.key) then
      mark(' ' .. icons.note, 'AgentChatsNote', 3)
    end
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
    -- Out of sight on the plain board; a search finds it all the same.
    if state.is_archived(chat.key, chat.updated) then
      mark(' archived', 'AgentChatsDim', 4)
    end
  end

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
  local title = text.truncate(name, room - used)
  local title_hl = (chat.status == 'done' or chat.status == 'attention') and 'AgentChatsUnread'
    or (chat.status == 'ended' and 'AgentChatsEnded' or 'AgentChatsTitle')
  add(line, title, title_hl)
  for _, m in ipairs(marks) do
    if not m.gone then
      add(line, m.text, m.hl)
    end
  end
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

--- The first line of the list: how many chats and what they are doing on
--- the left, what can be done with the board as a whole on the right. On a
--- narrow list it says the same in fewer cells, step by step, rather than
--- lose the keys: counts shrink to glyphs before a hint is dropped.
local function header_line(chats, width)
  -- The numbers are those of the rows below: with a search on, of what
  -- the search left.
  local c = { attention = 0, working = 0, done = 0 }
  for _, chat in ipairs(chats) do
    if c[chat.status] then
      c[chat.status] = c[chat.status] + 1
    end
  end
  local icons = config.get().icons
  -- The ways to say each side, richest first, and the pairs of them
  -- (`{ left, right }`) in order of preference.
  local lefts, rights, order = {}, {}, {}
  --- A right-hand side from pieces (nil ones, hints without a key, left out).
  local function side(...)
    local line, any = Line(), false
    for i = 1, select('#', ...) do
      local piece = select(i, ...)
      if piece then
        if any then
          add(line, '   ')
        end
        extend(line, piece)
        any = true
      end
    end
    if any then
      add(line, ' ')
    end
    return line
  end
  local function note(words)
    local piece = Line()
    add(piece, words, 'AgentChatsDim')
    return piece
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
    lefts = {
      left('Search ', query, found, ' · reading conversations…'),
      left('Search ', query, found, ' · reading…'),
      left('', query, found, ' · reading…'),
      left('', query, only_chats, ' …'),
      left('', text.truncate(query, 10), only_chats, ' …'),
    }
    local ends = hint_piece('back', 'ends the search') or hint_piece('clear', 'ends the search')
    local ends_short = hint_piece('back', 'ends it') or hint_piece('clear', 'ends it')
    rights = {
      side(ends, hint_piece('search', 'changes it')),
      side(ends_short, hint_piece('search', 'changes it')),
      side(ends),
      side(ends_short),
      Line(),
    }
    -- Words go before a key does: the long form of what is being read,
    -- then that of the hints, the word "Search", the number of passages
    -- (they are listed below) and the end of a long text. Only then does
    -- the key that changes the search go, and last the one that ends it.
    order = {
      { 1, 1 },
      { 2, 1 },
      { 2, 2 },
      { 3, 2 },
      { 4, 2 },
      { 5, 2 },
      { 2, 3 },
      { 3, 3 },
      { 3, 4 },
      { 4, 4 },
      { 5, 4 },
      { 5, 5 },
    }
  else
    local words = Line()
    add(words, ' ')
    add(words, plural(#chats, 'chat'), 'AgentChatsHeader')
    local glyphs = Line()
    add(glyphs, ' ')
    add(glyphs, plural(#chats, 'chat'), 'AgentChatsHeader')
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
    local grouped = S.group_by ~= 'status' and note('by ' .. S.group_by) or nil
    local older = S.show_archived and note('older and archived shown') or nil
    -- Notifications are switched in the menu. That they are off is said
    -- here, where it cannot be overlooked: nothing else would tell.
    local muted
    if not require('agent-chats.notify').enabled() then
      muted = Line()
      add(muted, 'notifications off', 'AgentChatsDim')
    end
    local new_chat, new, search =
      hint_piece('new', 'new chat'), hint_piece('new', 'new'), hint_piece('search', 'search')
    rights = {
      side(new_chat, search, muted, grouped, older),
      side(new_chat, search, muted, grouped),
      side(new_chat, search, muted),
      side(new, search, muted),
      side(new_chat, search),
      side(new, search),
      side(new),
      Line(),
    }
    -- A note goes before a key does, and the counts go from words to marks
    -- before "notifications off" goes: the headings below say the same in
    -- words. The keys go last.
    order = {
      { 1, 1 },
      { 1, 2 },
      { 1, 3 },
      { 1, 4 },
      { 2, 3 },
      { 2, 4 },
      { 2, 5 },
      { 2, 6 },
      { 2, 7 },
      { 2, 8 },
      { 1, 8 },
    }
  end

  if S.typing then
    -- The text is being typed at the prompt: the keys that count are the
    -- prompt's own, and they are not the board's to choose.
    rights = {
      side(key_piece('Enter', 'keeps it'), key_piece('Esc', 'calls it off')),
      side(key_piece('Enter', 'keeps'), key_piece('Esc', 'calls off')),
      Line(),
    }
    order = {}
    for r = 1, #rights do
      for l = 1, #lefts do
        order[#order + 1] = { l, r }
      end
    end
  end

  -- The richest pair that fits, from a list in order of preference: a note
  -- goes before a hint does, and the counts shrink before the last hint goes.
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
local set_keys
local summary_keys

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
  if not S.show_archived and #store.list({ archived = true }) > 0 then
    return {
      'Every chat is archived.',
      '',
      sentences(
        ('%s shows them: “Show older and archived chats”.'):format(
          config.key('menu') or config.command('menu')
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
    local collapsed = not S.search and state.collapsed(g.id)
    local l = heading(g, collapsed)
    if explain and g[explain] then
      add(l, '   ' .. g[explain], 'AgentChatsDim')
    end
    local heading = push(l, { kind = 'group', group = g.id })
    if S.group_by ~= 'status' or g.own then
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
  -- With the cursor in a chat's terminal, its title follows the chat: an
  -- agent names a new chat after its first answer.
  if
    S.pane_mode == 'term'
    and valid_win(S.pane_win)
    and api.nvim_get_current_win() == S.pane_win
  then
    M.pane_entered(api.nvim_win_get_buf(S.pane_win))
  end
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

--- What Enter does with `chat`, in a word and in a sentence.
---@return string word, string sentence
function M.open_words(chat)
  if chat.subagent then
    return 'read', 'Read what this subagent did'
  end
  local term = require('agent-chats.term').find(chat)
  if term then
    if chat.status == 'attention' then
      return 'answer it', 'Go to its terminal and answer'
    end
    return 'open', 'Open: go to its terminal'
  end
  if chat.live then
    if require('agent-chats.term').in_background(chat) then
      return 'read', 'Read it (it is answering in the background)'
    end
    return 'read', 'Read it (it runs outside this Neovim)'
  end
  if chat.cwd and not fs.is_dir(chat.cwd) then
    return 'read', 'Read it (its folder is gone, so it cannot be resumed)'
  end
  -- (The folder in full is in the summary; here it must not stretch a menu.)
  return 'resume', ('Resume it in %s'):format(chat.cwd and fs.short(chat.cwd, 44) or 'a terminal')
end

--- Whether the agent of `chat` can be started in the chat's folder: false
--- for a chat that is not running and whose folder is no longer there.
local function startable(chat)
  return chat.live or not chat.cwd or fs.is_dir(chat.cwd)
end

--- Whether `chat` can be gone into and typed to from here (a reply queued
--- for it would reach it): `false` and why not.
---@return boolean, string?
local function reachable(chat)
  if chat.subagent then
    return false, 'a subagent'
  end
  local term = require('agent-chats.term').find(chat)
  if chat.live and not term then
    return false, require('agent-chats.term').in_background(chat) and 'background' or 'elsewhere'
  end
  if chat.status == 'attention' and term then
    return false, 'asking'
  end
  if not startable(chat) then
    -- Going into it would mean resuming it.
    return false, 'folder gone'
  end
  return true
end

--- The hints for the row under the cursor of `win`: `{ key, label }` each,
--- and a few words on why some are not there, when that needs saying (in
--- full and in short).
---@return { [1]: string, [2]: string }[] hints, string[]? note
local function row_hints(win)
  local row = S.rows[api.nvim_win_get_cursor(win)[1]]
  local out, note = {}, nil
  local function hint(action, label)
    local key = keys.key(action)
    if key then
      out[#out + 1] = { key, label }
    end
  end
  if row and row.kind == 'group' then
    -- (Not while a search is on: what it found is shown, folded or not.)
    if not S.search then
      hint('open', state.collapsed(row.group) and 'unfold' or 'fold')
    end
  elseif row and (row.kind == 'more' or row.kind == 'older') then
    hint('open', 'show them')
  elseif row and row.kind == 'hit' then
    hint('open', 'read this passage')
  elseif row and row.chat then
    local chat = row.chat
    local word = M.open_words(chat)
    hint('open', word)
    if not chat.subagent then
      -- Why Enter only reads it, where it does.
      local _, why = reachable(chat)
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
        hint('queue', ('queued replies (%d)'):format(queued))
      elseif
        why ~= 'elsewhere'
        and why ~= 'background'
        and (chat.status == 'working' or chat.status == 'attention')
      then
        hint('queue', 'queue a reply')
      end
      if not chat.stub then
        if word ~= 'read' then
          hint('read', 'conversation')
        end
        hint('pass', 'pass to agent')
      end
    end
  else
    hint('new', 'new chat')
    hint('search', 'search')
  end
  return out, note
end

--- A statusline string: the hints that fit in `width`, and the way to
--- everything else at the right edge, which is never left out. `note` goes
--- after the hints when there is room for it.
local function bar_text(hints, width, note)
  local function esc(s)
    return (s:gsub('%%', '%%%%'))
  end
  local menu = keys.key('menu')
  local right = menu and { menu, 'menu' } or { config.command('menu'), '' }
  local function cells(h)
    return text.width(h[1]) + (h[2] ~= '' and 1 + text.width(h[2]) or 0)
  end
  local right_w = cells(right) + 1
  --- The hints that fit when `reserved` cells are kept free behind them.
  local function fit(reserved)
    local parts, used = {}, 1
    for i, h in ipairs(hints) do
      local need = cells(h) + (i > 1 and 2 or 0)
      if used + need + 2 + right_w + reserved > width then
        break
      end
      used = used + need
      parts[#parts + 1] = ('%s%%#AgentChatsKey#%s%%* %s'):format(
        i > 1 and '  ' or '',
        esc(h[1]),
        esc(h[2])
      )
    end
    return parts, used
  end
  -- Why a chat cannot be gone into ("runs elsewhere") is said before the
  -- less used keys are named: room is kept for its short form. Only the
  -- first key, what Enter does instead, comes before it.
  local short = note and note[#note] or nil
  local parts, used = fit(short and (text.width(short) + 5) or 0)
  if short and #parts == 0 and #hints > 0 then
    parts, used = fit(0)
    note = nil
  end
  -- In full where that fits, else in short.
  for _, words in ipairs(note or {}) do
    if used + text.width(words) + 5 + 2 + right_w <= width then
      parts[#parts + 1] = ('%s%%#AgentChatsDim#(%s)%%*'):format(
        #parts > 0 and '   ' or '',
        esc(words)
      )
      break
    end
  end
  return (' %s%%=%%#AgentChatsKey#%s%%*%s '):format(
    table.concat(parts),
    esc(right[1]),
    right[2] ~= '' and (' ' .. esc(right[2])) or ''
  )
end

update_bar = function()
  if not M.is_open() then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(S.buf)) do
    local hints, note = row_hints(win)
    local bar = bar_text(hints, api.nvim_win_get_width(win), note)
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

--- Title the pane: `label` on the left, `right` (the way back, where there
--- is one) at the right edge.
local function pane_title(label, hl, right)
  if valid_win(S.pane_win) then
    local function esc(str)
      return (str:gsub('%%', '%%%%'))
    end
    vim.wo[S.pane_win].winbar = ('%%#%s# %s%s %%*'):format(
      hl or 'AgentChatsDim',
      esc(label),
      right and ('%=' .. esc(right)) or ''
    )
  end
end

--- Cells the pane's title has for its words, beside `right`.
local function title_room(right)
  local width = valid_win(S.pane_win) and api.nvim_win_get_width(S.pane_win) or 60
  return width - 2 - (right and (text.width(right) + 2) or 0)
end

--- The title of a view in the pane: what it is, then its keys, as many as
--- fit. `hints` are `{ text, rank }` in the order they are shown; the ones
--- of the highest rank go first when there is no room, and the name of the
--- view goes before the last key does.
---@param lead string
---@param hints { [1]: string, [2]: integer }[]
---@return string
local function view_title(lead, hints)
  local room = title_room()
  local kept = vim.deepcopy(hints)
  local function words(with_lead)
    local parts = {}
    for _, h in ipairs(kept) do
      parts[#parts + 1] = h[1]
    end
    local keys_ = table.concat(parts, ' · ')
    if not with_lead then
      return keys_
    end
    return keys_ == '' and lead or (lead .. '   ' .. keys_)
  end
  while #kept > 1 and text.width(words(true)) > room do
    local worst = 1
    for i, h in ipairs(kept) do
      if h[2] >= kept[worst][2] then
        worst = i
      end
    end
    table.remove(kept, worst)
  end
  if text.width(words(true)) > room and #kept > 0 then
    return words(false)
  end
  return words(true)
end

--- Title the pane for the view in it (a conversation, a diff) from what
--- that view says of itself now: the keys it names are the ones it still
--- has.
local function retitle_view()
  local fn = S.pane_title_fn
  if fn and valid_win(S.pane_win) then
    local ok, title = pcall(fn)
    if ok and type(title) == 'table' then
      pane_title(view_title(title[1], title[2]), 'AgentChatsHeader')
    end
  end
end

--- Whether the cursor is typing in a terminal (terminal mode) right now.
function M._typing()
  return api.nvim_get_mode().mode == 't'
end

--- A terminal that holds a chat is about to be shown or entered: give it
--- the ways back to the list, once, and then let the user's own setup at it.
---@return string? typing, string? normal  The keys that go back from it: while typing, and in its normal mode.
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

local function prepare_terminal(buf)
  window_keys(buf)
  return require('agent-chats.term').prepare(buf)
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
      pcall(api.nvim_win_set_buf, win, S.preview_buf)
    end
    pcall(api.nvim_buf_delete, old, { force = true })
  end
  return S.preview_buf
end

--- `agent · name · folder` in at most `room` cells. The folder gives way
--- first (from its start: the end of a path says the most), then the
--- agent; the name of the chat is the last to go.
local function fit_label(agent, name, dir, room)
  room = room or 200
  local beside = room - text.width(agent) - 3
  if beside < 8 then
    -- Not even room for the agent beside it.
    return text.truncate(name, math.max(1, room))
  end
  local rest = beside - 3
  if dir and rest >= 16 then
    -- Half each at the least, and what one does not need goes to the other.
    local name_w =
      math.min(text.width(name), math.max(math.floor(rest / 2), rest - text.width(dir)))
    local dir_w = rest - name_w
    if dir_w >= 8 then
      return table.concat(
        { agent, text.truncate(name, name_w), text.truncate_left(dir, dir_w) },
        ' · '
      )
    end
  end
  -- No room for the folder: it is on the row and in the summary.
  return agent .. ' · ' .. text.truncate(name, beside)
end

--- What a terminal is: the agent, the chat, and the folder it runs in.
local function term_label(chat, room)
  if not chat then
    return ''
  end
  return fit_label(
    providers.label(chat.provider),
    display.title(chat),
    chat.cwd and fs.tilde(chat.cwd) or nil,
    room
  )
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

--- Title the pane for a terminal the cursor is in: which chat it is, and
--- the way back to the list that works in the mode the terminal is in:
--- one key while typing, another in its normal mode.
---@param label string|table|nil  A chat, `{ agent, name, dir }`, or plain words.
local function term_title(buf, label, lead, hl)
  local typing, normal = prepare_terminal(buf)
  -- Closing the window goes back whatever is mapped: with no key, that is
  -- what the title says.
  local from_normal = normal and keys.name(normal) or ':q'
  local right
  if M._typing() then
    -- With no key of its own, typing has to be left first.
    right = typing and (typing .. ' back') or ([[<C-\><C-n> then %s back]]):format(from_normal)
  else
    right = from_normal .. ' back'
  end
  lead = lead or 'LIVE  '
  -- A gap before the key, however full the title is.
  local room = title_room(right) - text.width(lead) - 1
  local words
  if type(label) == 'table' and label.key then
    words = term_label(label, room)
  elseif type(label) == 'table' then
    words = fit_label(label.agent or '', label.name or '', label.dir and fs.tilde(label.dir), room)
  else
    words = text.truncate(label or '', math.max(8, room))
  end
  pane_title(lead .. words, hl or 'AgentChatsLive', right)
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
      -- As the list has it, said in so many words where it has none (or
      -- the pane would take 'winborder', and be two cells wider than
      -- there is room for).
      border = c.border or 'none',
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
    pcall(api.nvim_win_close, win, true)
    if S.layout == 'float' and valid_win(S.win) then
      local dims = M._float_dims()
      api.nvim_win_set_config(S.win, { width = dims.width })
    end
  end
  S.pane_win = nil
end

--- Put `buf` in the pane while the cursor is somewhere else. Neovim says
--- "BufEnter" for a buffer that is put into a window the cursor is not in,
--- and a common autocommand answers that for a terminal by starting to
--- type: the list would be typed into. Nothing was entered, so nothing
--- is said.
local function pane_set_buf(buf)
  if api.nvim_get_current_win() == S.pane_win then
    return api.nvim_win_set_buf(S.pane_win, buf)
  end
  local had = vim.o.eventignore
  local quiet = 'BufEnter,BufLeave,WinEnter,WinLeave'
  vim.o.eventignore = had == '' and quiet or (had .. ',' .. quiet)
  local ok, err = pcall(api.nvim_win_set_buf, S.pane_win, buf)
  vim.o.eventignore = had
  if not ok then
    error(err, 0)
  end
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
      pane_title('Welcome')
      S.pane_shown = 'intro'
      return
    end
    S.intro = false
  end
  local term = chat and require('agent-chats.term').find(chat) or nil
  S.pane_title_fn = nil
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
    pane_title('LIVE  ' .. term_label(chat, title_room() - 6), 'AgentChatsLive')
  else
    local buf = summary_buf()
    preview.render(buf, chat, row, S.rows, api.nvim_win_get_width(S.pane_win))
    if api.nvim_win_get_buf(S.pane_win) ~= buf then
      pane_set_buf(buf)
      moved = true
    end
    set_pane_options('preview')
    if moved then
      pcall(api.nvim_win_set_cursor, S.pane_win, { 1, 0 })
    end
    pane_title('Summary')
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

--- Show `buf` in the pane and move the cursor there. `label` names what a
--- terminal runs, for a terminal that is not registered yet.
---@param mode "term"|"conversation"|"diff"
---@param title (string|table|fun(): table)?  Words; `{ name, hints }` to fit to the pane (see `view_title`); or a function that returns that, asked again whenever the keys it names may have changed.
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
  window_keys(buf)
  S.pane_shown = nil
  -- Whatever is put in the pane is what the user asked for: the
  -- introduction has had its turn.
  S.intro = false
  S.pane_title_fn = type(title) == 'function' and title or nil
  if mode == 'term' then
    if not label then
      local known = require('agent-chats.term').terms[buf]
      label = known and (known.label or known.title) or nil
    end
    term_title(buf, label)
  elseif S.pane_title_fn then
    retitle_view()
  elseif type(title) == 'table' then
    pane_title(view_title(title[1], title[2]), 'AgentChatsHeader')
  elseif title then
    pane_title(title, 'AgentChatsHeader')
  end
  api.nvim_set_current_win(win)
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
--- mapped may have changed), and its title names the way back.
function M.summary_entered()
  if not (valid_win(S.pane_win) and S.pane_mode == 'preview') then
    return
  end
  summary_keys()
  if S.intro then
    return
  end
  local buf = api.nvim_win_get_buf(S.pane_win)
  local back
  for _, lhs in ipairs(keys.wanted('back')) do
    if keys.is_ours(buf, 'n', lhs) then
      back = back or keys.name(lhs)
    end
  end
  pane_title('Summary', nil, back and (back .. ' back') or (config.command() .. ' goes back'))
end

--- The terminal `buf` in the pane holds a chat the cursor has gone into (or
--- that has only now started in it, or whose mode has changed): its title
--- says which, and how to get back to the list from where it is now.
---@param what agent_chats.Chat|table|string|nil  The chat, `{ agent, name, dir }`, or what to call the terminal; nil: whatever is known of it.
function M.pane_entered(buf, what)
  if valid_win(S.pane_win) and api.nvim_win_get_buf(S.pane_win) == buf then
    S.intro = false
    if not what then
      local known = require('agent-chats.term').terms[buf]
      what = chat_in(buf) or (known and (known.label or known.title)) or nil
    end
    if vim.b[buf].agent_chats_exited then
      return M.pane_ended(buf, vim.b[buf].agent_chats_exited)
    end
    term_title(buf, what)
  end
end

--- The agent in a terminal shown in the pane has stopped and its screen is
--- kept (it failed, or `open.close_on_exit` is off): say so, instead of
--- "LIVE".
function M.pane_ended(buf, code)
  pcall(function()
    -- Remembered, so that a title set again later (a mode change) still says so.
    vim.b[buf].agent_chats_exited = tostring(code)
  end)
  if valid_win(S.pane_win) and api.nvim_win_get_buf(S.pane_win) == buf then
    term_title(
      buf,
      ('the agent has exited (code %s)'):format(tostring(code)),
      'ENDED  ',
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
    S.pane_shown, S.pane_title_fn = nil, nil
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
    set_keys(S.buf)
    update_bar()
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
        update_bar()
        update_pane()
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
      state.set_collapsed(g.id, false)
      S.full[g.id] = true
    end
    M.render()
  end
  return false
end

--- Move to the next (dir 1) or previous (dir -1) chat that wants you, in
--- the order the board lists them. One in a folded group, or past the end
--- of a long one, is counted in the header: so this reaches it, and
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
    info('No chat needs you right now.')
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
    update_bar()
    update_pane()
  end
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
  if S.search and S.search.query == vim.trim(res) then
    -- The same text as was shown while typing: only the header changes.
    M.render()
  end
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
      info('This chat has no subagents.')
    end
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
  pass = 'pass the chat to another agent',
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
  yank = 'copy the command that resumes the chat',
  group = 'group by status, folder, agent or worktree',
  pane = 'show or hide the pane',
  show_all = 'show older and archived chats',
  read_all = 'mark every chat read',
  next_attention = 'next chat that needs you',
  prev_attention = 'previous chat that needs you',
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
    pass = on_chat(actions.pass, 'pass on'),
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
    unread = on_chat(actions.toggle_unread, 'mark'),
    read_all = actions.read_all,
    pin = on_chat(actions.pin, 'pin'),
    move = on_chat(function(chat)
      actions.move(chat, function(name)
        -- Seen at once where the list is grouped by status. Where it is
        -- not, nothing on the screen would say that it worked.
        if name and S.group_by ~= 'status' then
          info(
            ('It is in “%s”. Your own groups are shown when the list is grouped by status.'):format(
              name
            )
          )
        end
      end)
    end, 'move'),
    archive = on_chat(actions.archive, 'archive'),
    show_all = M.toggle_show_all,
    label = on_chat(actions.labels, 'label'),
    note = on_chat(actions.note, 'put a note on'),
    rename = on_chat(actions.rename, 'rename'),
    yank = on_chat(actions.yank, 'copy the command of'),
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
      item('open', state.collapsed(row.group) and 'Unfold this group' or 'Fold this group')
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
    if queued > 0 then
      item('queue', ('Queued replies (%d): send, add or drop'):format(queued))
    elseif busy and not elsewhere then
      item('queue', 'Queue a reply for when it finishes its turn')
    end
    -- Passing a chat on is there only where it has been given a key.
    if not chat.stub and #keys.wanted('pass') > 0 then
      item('pass', 'Pass to another agent, with notes')
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
        state.is_archived(chat.key, chat.updated) and 'Unarchive'
          or 'Archive (hide it until it is active again)'
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
      -- What moves in the conversation itself: its title names these keys
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
  item(
    'show_all',
    S.show_archived and 'Hide older and archived chats' or 'Show older and archived chats'
  )
  if store.counts().done > 0 then
    item('read_all', 'Mark every chat read')
  end
  if store.counts().attention + store.counts().done > 0 then
    item('next_attention', 'Go to the next chat that needs you')
    item('prev_attention', 'Go to the previous chat that needs you')
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
      retitle_view()
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
  S.keys, S.at, S.follow = nil, nil, nil
  S.settled, S.auto_line = nil, nil
  S.summary_for, S.summary_book, S.pane_title_fn = nil, nil, nil
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
  S.show_archived = store.show_all
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
      -- <buffer> R ...` typed on the list): what the screen says of the
      -- keys follows at once, not at the next move of the cursor.
      vim.schedule(function()
        if M.is_open() and api.nvim_get_current_buf() == S.buf and set_keys(S.buf) then
          M.render()
        end
      end)
    end,
  })
  api.nvim_create_autocmd('ModeChanged', {
    group = group,
    callback = function()
      -- Into or out of typing in a chat's terminal: its title names the
      -- key that goes back in the mode it is in now.
      local win = api.nvim_get_current_win()
      if win == S.pane_win and S.pane_mode == 'term' then
        M.pane_entered(api.nvim_win_get_buf(win))
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
      elseif win == S.pane_win and S.pane_mode == 'term' then
        -- Gone into the chat with a window command rather than through the
        -- list: its title says how to get back all the same.
        M.pane_entered(api.nvim_win_get_buf(win))
      elseif win == S.pane_win and S.pane_mode == 'preview' then
        -- In the summary: the same.
        M.summary_entered()
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
        S.pane_win = nil
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
