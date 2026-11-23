-- The menu: everything that can be done with what the cursor is on, in
-- words, each with its key beside it where it has one.
--
--   ╭ Fix flaky session restore ───────────────╮
--   │  ── This chat ─────────────────────────  │
--   │  Enter  Resume it in ~/work/nvim         │
--   │  C      Read the conversation            │
--   │  ── Keep track of it ──────────────────  │
--   │         Rename                           │
--   │         Add a note                       │
--   │  ── The list ──────────────────────────  │
--   │  +      New chat                         │
--   │  S      Search chats                     │
--   │  ── The board ─────────────────────────  │
--   │         Turn notifications off           │
--   │         Close the board (q)              │
--   ╰────────────────── Enter choose · q close ╯
--
-- It is one list, all of it in view, in the order of what it is about: the
-- chat, your own marks on it, the list, the board. Nothing has to be
-- remembered to use it: move to a line and press Enter, or click it. A key
-- in the column on the left does the same thing straight from where the
-- menu was opened, and picks the line here as well, so the keys are learnt
-- by using them. A key the menu needs for itself (q, Esc) is named after
-- the words instead, and keeps its meaning here. Only what applies is
-- listed (the board decides: `board.menu_items`), which is also why this is
-- the key reference: there is no second list to keep in step with it.

local api = vim.api
local config = require('agent-chats.config')
local keys = require('agent-chats.keys')

local M = {}

local ns = api.nvim_create_namespace('agent-chats-menu')

---@class agent_chats.MenuItem
---@field text string?
---@field action string?     Its name in the `keys` option, for the key beside it.
---@field run fun()?
---@field heading string?    Not a choice: the words over the lines that follow.

---@type { win: integer, buf: integer, origin: integer, title: string, footer: string?, items: agent_chats.MenuItem[], rows: table<integer, agent_chats.MenuItem>, mapped: string[], own: table<string, boolean> }?
local active

-- Keys that move in the menu or leave it. An action whose own key is one
-- of these is still shown with it, but here the key keeps this meaning.
local OWN = { 'q', '<Esc>', '<CR>', 'j', 'k', '<Down>', '<Up>', '<BS>', 'gg', 'G' }

local function norm(lhs)
  return api.nvim_replace_termcodes(lhs, true, true, true)
end

local function is_mouse(lhs)
  return lhs:lower():find('mouse', 1, true) ~= nil
end

--- The keys of an item, as the place the menu was opened from has them:
--- the keys themselves, and whether they are yours there (left alone, so
--- that the action can only be picked from here).
---@return string[] lhs, boolean yours
local function keys_of(item, cur)
  if not item.action then
    return {}, false
  end
  return cur.keys(item.action)
end

--- Whether one of `lhs` is a key the menu needs for itself.
local function own_key(lhs, cur)
  for _, key in ipairs(lhs) do
    if not is_mouse(key) and cur.own[norm(key)] and norm(key) ~= norm('<CR>') then
      return true
    end
  end
  return false
end

--- The lines of a list of items, as drawn: text, where the keys are, and
--- which item each line stands for.
---@param items agent_chats.MenuItem[]
---@param cur table  The menu they are drawn for (its own keys, and whose keys are whose).
---@return string[] lines, table[] marks, table<integer, agent_chats.MenuItem> rows, boolean starred
function M.layout(items, cur)
  local key_w, text_w, starred = 0, 0, false
  local shown = {}
  for i, item in ipairs(items) do
    if not item.heading then
      local lhs, yours = keys_of(item, cur)
      local key = keys.shown(lhs)
      local label, words = '', item.text or ''
      if key and own_key(lhs, cur) then
        -- Named, but not in the column of keys that act here.
        if not yours then
          words = ('%s (%s)'):format(words, key)
        end
      elseif key then
        label = key .. (yours and '*' or '')
        starred = starred or yours
      end
      shown[i] = { label = label, yours = yours, words = words }
      key_w = math.max(key_w, vim.api.nvim_strwidth(label))
      text_w = math.max(text_w, vim.api.nvim_strwidth(words))
    end
  end
  -- With no key to show on any line, there is no column for them.
  local gap = key_w > 0 and 2 or 0
  local lines, marks, rows = {}, {}, {}
  local inner = key_w + gap + text_w
  for i, item in ipairs(items) do
    if item.heading then
      -- A rule with the words in it: where one part ends and what the next
      -- is about, in one line.
      local lead = '── '
      local rest = math.max(2, inner - vim.api.nvim_strwidth(lead .. item.heading .. ' '))
      lines[#lines + 1] = '  ' .. lead .. item.heading .. ' ' .. string.rep('─', rest)
      local line = #lines - 1
      marks[#marks + 1] = { line, 0, 2 + #lead, 'AgentChatsDim' }
      marks[#marks + 1] = { line, 2 + #lead, 2 + #lead + #item.heading, 'AgentChatsHeader' }
      marks[#marks + 1] = { line, 2 + #lead + #item.heading, #lines[#lines], 'AgentChatsDim' }
    else
      local s = shown[i]
      local pad = string.rep(' ', key_w - vim.api.nvim_strwidth(s.label) + gap)
      lines[#lines + 1] = ('  %s%s%s'):format(s.label, pad, s.words)
      if s.label ~= '' then
        marks[#marks + 1] =
          { #lines - 1, 2, 2 + #s.label, s.yours and 'AgentChatsDim' or 'AgentChatsKey' }
      end
      rows[#lines] = item
    end
  end
  return lines, marks, rows, starred
end

--- What is said under the items when a key shown here is not taken on the
--- list: why, and what to do about it.
local function note(width)
  local out = {}
  local text = require('agent-chats.util.text')
  for _, piece in
    ipairs(
      text.wrap(
        '* a key of yours, which the board leaves alone. Here it picks the action; `keys` in setup() gives the action a key of its own.',
        math.max(24, width - 3)
      )
    )
  do
    out[#out + 1] = '  ' .. piece
  end
  return out
end

function M.is_open()
  return active ~= nil and api.nvim_win_is_valid(active.win)
end

--- Take the menu off the screen without choosing anything.
function M.close()
  local cur = active
  active = nil
  if cur and api.nvim_win_is_valid(cur.win) then
    pcall(api.nvim_win_close, cur.win, true)
  end
end

--- The line in the border under the menu: its keys, and, when the menu is
--- taller than the screen has room for, that there is more of it and which
--- way. (It goes round at its ends and scrolls by itself, but a list that
--- ends at the edge of its window looks like one that ends there.)
---@param more string?  '↓', '↑' or '↑↓'.
---@param room integer  Cells there are for it.
---@return string
function M.footer(more, room)
  local keys_ = 'Enter Choose · q Close'
  if not more then
    return ' ' .. keys_ .. ' '
  end
  local full = (' %s More · %s '):format(more, keys_)
  if vim.api.nvim_strwidth(full) <= room then
    return full
  end
  -- That there is more is what would not be found out otherwise.
  return (' %s More '):format(more)
end

--- Say in the footer which way the menu goes on, as it is scrolled.
local function foot()
  local cur = active
  if not cur or not api.nvim_win_is_valid(cur.win) then
    return
  end
  local last = api.nvim_buf_line_count(cur.buf)
  -- (Asked of the view, which is brought up to date for the asking: the
  -- first and last line on screen are those of the last redraw.)
  local top = api.nvim_win_call(cur.win, function()
    return vim.fn.winsaveview().topline
  end)
  local bottom = top + api.nvim_win_get_height(cur.win) - 1
  local more = (top > 1 and '↑' or '') .. (bottom < last and '↓' or '')
  local footer = M.footer(more ~= '' and more or nil, api.nvim_win_get_width(cur.win) - 2)
  if footer ~= cur.footer then
    cur.footer = footer
    pcall(api.nvim_win_set_config, cur.win, { footer = footer, footer_pos = 'right' })
  end
end

--- Choose `item`: the menu goes, and it is done.
local function choose(item)
  local cur = active
  if not cur or not item or item.heading then
    return
  end
  local origin = cur.origin
  M.close()
  -- Back where the menu was called from, before anything acts: an action
  -- looks at the window it is run in.
  if api.nvim_win_is_valid(origin) then
    pcall(api.nvim_set_current_win, origin)
  end
  if item.run then
    item.run()
  end
end

--- Draw the menu that is open: its lines, its size, and the keys that pick.
local function draw()
  local cur = active
  if not cur then
    return
  end
  local lines, marks, rows, starred = M.layout(cur.items, cur)
  local width = 24
  for _, l in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(l) + 2)
  end
  if #lines > vim.o.lines - 6 then
    -- Taller than there is room for: wide enough, at least, for its footer
    -- to say so beside its keys.
    width = math.max(width, vim.api.nvim_strwidth(M.footer('↑↓', 999)) + 2)
  end
  -- A menu, not a banner: a line that is longer loses its end.
  local limit = math.max(24, math.min(vim.o.columns - 4, 72))
  if width > limit then
    width = limit
    local text = require('agent-chats.util.text')
    for i, l in ipairs(lines) do
      lines[i] = text.truncate(l, width - 2)
    end
    for _, m in ipairs(marks) do
      -- (Both ends: a mark that began past the cut would end before it began.)
      m[2] = math.min(m[2], #lines[m[1] + 1])
      m[3] = math.min(m[3], #lines[m[1] + 1])
    end
  end
  if starred then
    lines[#lines + 1] = ''
    for _, l in ipairs(note(width)) do
      lines[#lines + 1] = l
      marks[#marks + 1] = { #lines - 1, 0, #l, 'AgentChatsDim' }
    end
  end
  cur.rows = rows
  vim.bo[cur.buf].modifiable = true
  api.nvim_buf_set_lines(cur.buf, 0, -1, false, lines)
  vim.bo[cur.buf].modifiable = false
  api.nvim_buf_clear_namespace(cur.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(cur.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  -- A title wider than the menu is cut by Neovim at its start, which is
  -- the part that says whose menu this is: cut here instead, at its end.
  local title = require('agent-chats.util.text').truncate(cur.title, math.max(8, width - 4))
  cur.footer = M.footer(nil, width - 2)
  api.nvim_win_set_config(cur.win, {
    width = width,
    height = height,
    title = ' ' .. title .. ' ',
    footer = cur.footer,
    footer_pos = 'right',
  })
  -- The keys shown beside the items pick them here too.
  for _, lhs in ipairs(cur.mapped) do
    pcall(vim.keymap.del, 'n', lhs, { buffer = cur.buf })
  end
  cur.mapped = {}
  local taken = {}
  local function map(lhs, item)
    local raw = norm(lhs)
    if cur.own[raw] or taken[raw] then
      return
    end
    taken[raw] = true
    -- (A key Neovim will not take is no key here either.)
    local ok = pcall(vim.keymap.set, 'n', lhs, function()
      choose(item)
    end, { buffer = cur.buf, nowait = true, silent = true })
    if ok then
      cur.mapped[#cur.mapped + 1] = lhs
    end
  end
  local lettered = {}
  for _, item in ipairs(cur.items) do
    local lhs = keys_of(item, cur)
    if not own_key(lhs, cur) then
      for _, key in ipairs(lhs) do
        if not is_mouse(key) then
          map(key, item)
          lettered[#lettered + 1] = { key, item }
        end
      end
    end
  end
  -- Either case will do for a letter, where the other case is nobody's:
  -- not a key of another action, and not a mapping of yours.
  for _, pair in ipairs(lettered) do
    local key = pair[1]
    if key:match('^%a$') then
      local other = key == key:upper() and key:lower() or key:upper()
      if not keys.is_given(other) and not keys.yours(other, 'n') then
        map(other, pair[2])
      end
    end
  end
  -- The key of an action that is not listed for this row at all acts as
  -- well: it does what it does where the menu was opened from, which may be
  -- to say why it cannot be done. (Left to Vim, `C` in a window that cannot
  -- be changed is an error message.)
  for _, action in ipairs(cur.actions) do
    local lhs, yours = cur.keys(action)
    if not yours then
      for _, key in ipairs(lhs) do
        if not is_mouse(key) then
          map(key, {
            run = function()
              cur.run(action)
            end,
          })
        end
      end
    end
  end
  -- On the line Enter stands beside, where there is one: Enter then does
  -- here what it says.
  local line
  local enter = norm('<CR>')
  for l = 1, #lines do
    if rows[l] then
      local lhs, yours = keys_of(rows[l], cur)
      for _, key in ipairs(yours and {} or lhs) do
        if not is_mouse(key) and norm(key) == enter then
          line = line or l
        end
      end
    end
  end
  if not line or not rows[line] then
    for l = 1, #lines do
      if rows[l] then
        line = l
        break
      end
    end
  end
  pcall(api.nvim_win_set_cursor, cur.win, { line or 1, 2 })
  foot()
end

--- Move to the next line that stands for an item.
local function step(dir)
  local cur = active
  if not cur then
    return
  end
  local last = api.nvim_buf_line_count(cur.buf)
  local line = api.nvim_win_get_cursor(cur.win)[1]
  for _ = 1, last do
    line = line + dir
    if line < 1 then
      line = last
    elseif line > last then
      line = 1
    end
    if cur.rows[line] then
      pcall(api.nvim_win_set_cursor, cur.win, { line, 2 })
      foot()
      return
    end
  end
end

--- Open the menu on `items`.
---@param items agent_chats.MenuItem[]
---@param opts { title: string?, keys: (fun(action: string): string[], boolean)?, actions: string[]?, run: fun(action: string)? }?  `keys`: the keys of an action where the menu is opened from, and whether they are yours there (without it, those of the list). `actions` and `run`: every action that has a key there, and how to run one, for a key of an action the menu does not list.
---@return integer? win
function M.open(items, opts)
  opts = opts or {}
  M.close()
  if #items == 0 then
    return nil
  end
  require('agent-chats.ui.highlights').setup()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.bo[buf].filetype = 'agent-chats-menu'
  local origin = api.nvim_get_current_win()
  local win = api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 2,
    width = 24,
    height = 1,
    border = config.box_border(),
    title = ' ' .. (opts.title or 'Agent chats') .. ' ',
    zindex = 70,
  })
  vim.wo[win].cursorline, vim.wo[win].wrap = true, false
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn = false, false, 'no'
  local own = {}
  for _, lhs in ipairs(OWN) do
    own[norm(lhs)] = true
  end
  active = {
    win = win,
    buf = buf,
    origin = origin,
    title = opts.title or 'Agent chats',
    items = items,
    rows = {},
    mapped = {},
    own = own,
    actions = opts.run and opts.actions or {},
    run = opts.run,
    keys = opts.keys or function(action)
      local bound = keys.of(action)
      if keys.shown(bound) then
        return bound, false
      end
      -- No key on the list: one of yours is on it. It still picks here.
      local wanted = keys.wanted(action)
      return wanted, keys.shown(wanted) ~= nil
    end,
  }
  local mine = active

  local function map(lhs, fn)
    pcall(vim.keymap.set, 'n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  local function here()
    return mine.rows[api.nvim_win_get_cursor(win)[1]]
  end
  map('<CR>', function()
    choose(here())
  end)
  -- A click chooses, as in any menu. (The press has moved the cursor.)
  map('<LeftRelease>', function()
    local pos = vim.fn.getmousepos()
    if pos.winid == win and mine.rows[pos.line] then
      choose(mine.rows[pos.line])
    end
  end)
  for _, lhs in ipairs({ 'q', '<Esc>', '<BS>' }) do
    map(lhs, M.close)
  end
  for _, lhs in ipairs({ 'j', '<Down>' }) do
    map(lhs, function()
      step(1)
    end)
  end
  for _, lhs in ipairs({ 'k', '<Up>' }) do
    map(lhs, function()
      step(-1)
    end)
  end
  -- The first choice and the last, not the heading over the first.
  map('gg', function()
    pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(buf), 2 })
    step(1)
  end)
  map('G', function()
    pcall(api.nvim_win_set_cursor, win, { 1, 2 })
    step(-1)
  end)
  -- However else the cursor got onto a line that is no choice (a click, a
  -- page key, the wheel): on to the choice next to it, the way it was going.
  local was ---@type integer?
  api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      if active ~= mine or not api.nvim_win_is_valid(win) then
        return
      end
      -- (After the window has scrolled to where the cursor went.)
      vim.schedule(foot)
      local line = api.nvim_win_get_cursor(win)[1]
      if mine.rows[line] then
        was = line
        return
      end
      local last = api.nvim_buf_line_count(buf)
      local dir = (was and line < was) and -1 or 1
      for _, d in ipairs({ dir, -dir }) do
        local l = line + d
        while l >= 1 and l <= last do
          if mine.rows[l] then
            was = l
            pcall(api.nvim_win_set_cursor, win, { l, 2 })
            return
          end
          l = l + d
        end
      end
    end,
  })
  -- Scrolled without the cursor moving (the wheel): the footer follows.
  api.nvim_create_autocmd('WinScrolled', {
    pattern = tostring(win),
    callback = function()
      if active == mine then
        foot()
      end
    end,
  })
  -- The key that opened it closes it again.
  for _, lhs in ipairs(keys.wanted('menu')) do
    if not own[norm(lhs)] and not is_mouse(lhs) then
      own[norm(lhs)] = true
      map(lhs, M.close)
    end
  end
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      -- Left for another window: do not stay on top of it.
      vim.schedule(function()
        if active == mine then
          M.close()
        end
      end)
    end,
  })
  draw()
  return win
end

--- Choose the item of the menu that is open by its text or its action
--- (tests, and anything that drives the menu from outside).
---@param what string
---@return boolean found
function M.pick(what)
  local cur = active
  if not cur then
    return false
  end
  for _, item in ipairs(cur.items) do
    if not item.heading and (item.action == what or item.text == what) then
      choose(item)
      return true
    end
  end
  return false
end

--- The text of the menu that is open, a line per entry.
---@return string[]
function M.lines()
  if not M.is_open() then
    return {}
  end
  return api.nvim_buf_get_lines(active.buf, 0, -1, false)
end

return M
