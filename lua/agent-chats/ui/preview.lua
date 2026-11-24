-- The summary shown in the board's pane for a chat whose live terminal is
-- not there: it has none in this Neovim, or the one it has is on screen in
-- a window of the user's own. From the top it answers: what state is it in
-- and what does it want from you; where is it; what did you first ask;
-- what did you last ask; how far did it get.
--
--   # Fix flaky session restore
--
--   ● Needs you: permission to run: rm -rf .cache/sessions
--
--   Folder  ~/work/nvim-config · main
--   Agent   Claude · opus
--   Started 14:02
--
--   ## First prompt
--   ...
--   ## Last prompt
--   ...
--   ## Last reply
--   ...
--
-- Built from what the index already holds, so moving the cursor never reads
-- a file.

local config = require('agent-chats.config')
local display = require('agent-chats.display')
local fs = require('agent-chats.util.fs')
local git = require('agent-chats.util.git')
local keys = require('agent-chats.keys')
local providers = require('agent-chats.providers')
local state = require('agent-chats.state')
local status = require('agent-chats.status')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

local M = {}

local ns = vim.api.nvim_create_namespace('agent-chats-summary')

-- Lines of a prompt shown before the rest is left to the conversation.
local FIRST_LINES, LAST_LINES, REPLY_LINES = 6, 8, 60

local function section(out, heading, body, max, more)
  if not body or vim.trim(body) == '' then
    return
  end
  out[#out + 1] = ''
  out[#out + 1] = '## ' .. heading
  out[#out + 1] = ''
  local lines, omitted = text.head_lines(body, max)
  vim.list_extend(out, lines)
  if omitted > 0 then
    out[#out + 1] = ('… %d more line%s%s'):format(omitted, omitted == 1 and '' or 's', more or '')
  end
end

--- The few lines that teach the board: what each of the things you do all
--- day is on. Only keys that are bound are named. Fitted to `width`: what
--- does not fit on a row goes on under its own words, not under its key.
---@param width integer?
---@return string[]
local function guide(width)
  width = width or 76
  -- Each under the name the bar above the list gives it.
  local rows = {
    { 'open', 'Open: go into a chat and type (one that ended is resumed, in its folder)' },
    { 'queue', 'Queue a Reply: for when the chat finishes its turn' },
    { 'read', 'Conversation: read the whole of it' },
    { 'new', 'New Chat: pick the agent, and it opens' },
    { 'search', 'Search: every chat, inside the conversations too' },
    { 'refresh', 'Refresh: look for changes now (the list also does so by itself)' },
    { 'archive', 'Archive: put a chat away, at the end of the list (again takes it out)' },
    { 'pin', 'Pin: keep a chat at the top of its group (again lets it go)' },
    { 'notify', 'Notifications: on or off' },
    { 'back', 'Back: out of a conversation, a search, the board' },
    { 'menu', 'Menu: everything else, for this chat and for the board' },
  }
  local shown, widest = {}, 0
  local function row(key, words)
    shown[#shown + 1] = { key, words }
    widest = math.max(widest, text.width(key))
  end
  for _, r in ipairs(rows) do
    local key = keys.key(r[1])
    if key then
      row(key, r[2])
    end
  end
  local out = {}
  local room = math.max(16, width - 4 - widest - 2)
  for _, r in ipairs(shown) do
    for i, piece in ipairs(text.wrap(r[2], room)) do
      local key = i == 1 and r[1] or ''
      out[#out + 1] = ('    %s%s  %s'):format(key, string.rep(' ', widest - text.width(key)), piece)
    end
  end
  return out
end

--- Whether every letter the board acts on is a capital, as it is by
--- default. ("Back" aside: its `q` is named where this is said.)
local function capitals()
  for action in pairs(config.get().keys) do
    if action ~= 'back' then
      for _, lhs in ipairs(keys.of(action)) do
        if lhs:match('^%l$') then
          return false
        end
      end
    end
  end
  return keys.key('read') ~= nil
end

--- What the pane says the first time the board is opened, fitted to a
--- pane `width` cells wide.
---@param width integer?
---@return string[]
function M.intro(width)
  width = math.max(30, (width or 76) - 1)
  local icons = config.get().icons
  local out = { '# Agent chats', '' }
  local function say(words)
    vim.list_extend(out, text.wrap(words, width))
  end
  -- (Said here, at the top: on a small screen the end of this page is
  -- below the edge of the window.)
  say(
    'Every chat of your coding agents is in the list on the left. This side shows the chat under the cursor: its live terminal when it runs in this Neovim, a summary otherwise. This page is shown once: move the cursor to see a chat.'
  )
  out[#out + 1] = ''
  vim.list_extend(out, guide(width))
  out[#out + 1] = ''
  say('The bar above the list names the keys for the row you are on.')
  if capitals() then
    local back = keys.key('back')
    if back and back:match('^%l$') then
      say(('Capital letters act; apart from %s, lowercase keys stay what they are.'):format(back))
    else
      say('Capital letters act; lowercase keys stay what they are.')
    end
  end
  -- The one key that is not pressed on the board, and that no bar can
  -- name before it is needed: while typing to an agent, every plain key
  -- is the agent's.
  local out_of_chat = config.get().open.back_key
  if type(out_of_chat) == 'string' and not keys.yours(out_of_chat, 't') then
    say(
      ('While you type in a chat every key goes to its agent: %s comes back to the list.'):format(
        out_of_chat
      )
    )
  end
  out[#out + 1] = ''
  say(
    ('Marks on a row: %s2 two replies wait to be sent to it · %s it runs outside this Neovim · %s a note of yours.'):format(
      icons.queue,
      icons.elsewhere,
      icons.note
    )
  )
  return out
end

--- Where the terminal `buf` is on screen, seen from tab `tab`, in words;
--- nil when no window of the user's shows it.
---@return string?
local function on_screen(buf, tab)
  local win = require('agent-chats.term').window_of(buf)
  if not win then
    return nil
  end
  local its = vim.api.nvim_win_get_tabpage(win)
  if its == (tab or vim.api.nvim_get_current_tabpage()) then
    return 'in another window of this tab'
  end
  return ('in tab %d'):format(vim.api.nvim_tabpage_get_number(its))
end

--- The sentence that says what state `chat` is in and what follows from
--- it, and the lines that go with it. `hl` is the highlight of the first.
---@param tab integer?  The tab the summary is shown in.
---@return string[] lines, string hl
local function state_lines(chat, now, tab)
  local icons = config.get().icons
  local st = chat.status or 'ended'
  local glyph = icons[st] or ''
  local hl = status.hl[st] or 'AgentChatsIdle'
  local label = status.labels[st] or st
  local since = time.since(chat.updated, now)
  local term = require('agent-chats.term').find(chat)
  local hosted = term ~= nil
  -- A summary for a chat that runs in a terminal here: the terminal is on
  -- screen in a window of the user's, and stays there.
  local where = term and on_screen(term, tab) or nil
  local out = {}
  if st == 'attention' then
    local store = package.loaded['agent-chats.store']
    local waiting = display.waiting(chat, store and store.get or nil)
    if chat.inferred then
      out[1] = ('%s%s May need you: quiet on a tool call, so it may be waiting for approval.'):format(
        glyph,
        icons.inferred
      )
    elseif chat.through then
      out[1] = ('%s %s: a chat it started is waiting.'):format(glyph, label)
    else
      out[1] = ('%s %s%s'):format(glyph, label, waiting[1] and (': ' .. waiting[1]) or '.')
      table.remove(waiting, 1)
    end
    for i = 1, math.min(#waiting, 5) do
      out[#out + 1] = '  ' .. text.oneline(waiting[i], 200)
    end
    if hosted and not where then
      local go = config.hint('open', '%s goes to it to answer.')
      if go ~= '' then
        out[#out + 1] = '  ' .. go
      end
    end
  elseif st == 'working' then
    out[1] = ('%s %s%s'):format(
      glyph,
      label,
      chat.activity and (': ' .. text.oneline(chat.activity, 200)) or '.'
    )
  elseif st == 'done' then
    out[1] = ('%s %s: it finished %s.'):format(glyph, label, since ~= '' and since or 'a turn')
  elseif st == 'idle' then
    out[1] = ('%s %s: open, nothing new%s.'):format(
      glyph,
      label,
      since ~= '' and (' since ' .. since) or ''
    )
  else
    out[1] = ('%s %s%s.'):format(glyph, label, since ~= '' and (' ' .. since) or '')
  end
  -- Not open anywhere: what Enter will do with it, and in which folder.
  if not chat.live and not chat.subagent and not chat.stub and chat.cwd then
    if fs.is_dir(chat.cwd) then
      local go =
        -- (In full on the line below; a long path here would bury the sentence.)
        config.hint('open', '%s resumes it in ' .. fs.short(chat.cwd, 56):gsub('%%', '%%%%') .. '.')
      if go ~= '' then
        out[#out + 1] = '  ' .. go
      end
    else
      out[#out + 1] = '  Its folder is gone, so it cannot be resumed.'
        .. config.hint('open', ' %s reads it.')
    end
  end
  if not chat.subagent and state.is_archived(chat.key, chat.updated) then
    out[#out + 1] = '  Archived' .. config.hint('archive', ': %s takes it out again') .. '.'
  end
  if where then
    out[#out + 1] = ('  Its terminal is open %s.%s'):format(
      where,
      config.hint('open', st == 'attention' and ' %s goes there to answer.' or ' %s goes there.')
    )
  elseif hosted and not chat.subagent then
    -- The summary was asked for in place of the terminal (the board's
    -- `info`): said, or the chat would look like one that is not open.
    out[#out + 1] = '  Its terminal is behind this summary.'
      .. config.hint('info', ' %s shows it again.')
  end
  if chat.live and not hosted and not chat.subagent then
    if require('agent-chats.term').in_background(chat) then
      -- Started from here, with no terminal at all: nothing to type into.
      out[#out + 1] =
        '  A reply sent from here is being answered in the background: read it here until that is done.'
    else
      out[#out + 1] = ('  It runs outside this Neovim (pid %s): read it here, type in its own terminal.'):format(
        tostring(chat.pid or '?')
      )
    end
  end
  return out, hl
end

--- `Label   value` lines: where the chat is and what runs it.
local function facts(chat, now)
  local out = {}
  local function fact(label, value)
    if value and value ~= '' then
      out[#out + 1] = ('%-8s%s'):format(label, value)
    end
  end
  if chat.cwd then
    local parts = { fs.tilde(chat.cwd) }
    if chat.branch and chat.branch ~= '' and chat.branch ~= 'HEAD' then
      parts[#parts + 1] = chat.branch
    end
    -- Only what is known already: nothing is asked of git for a summary.
    local info = git.cached(chat.cwd)
    if info and info.worktree and info.repo then
      parts[#parts + 1] = 'a worktree of ' .. fs.tilde(info.repo)
    end
    if not fs.is_dir(chat.cwd) then
      parts[#parts + 1] = 'gone'
    end
    -- Why it is where it is in the list.
    if not chat.subagent and config.filtered(chat.cwd) then
      parts[#parts + 1] = 'filtered out in the options'
    end
    fact('Folder', table.concat(parts, ' · '))
  else
    fact('Folder', 'not on record')
  end
  local agent = { providers.label(chat.provider) }
  if chat.model then
    agent[#agent + 1] = chat.model
  end
  fact('Agent', table.concat(agent, ' · '))
  if chat.created then
    fact('Started', time.stamp(chat.created, now))
  end
  -- Who says so, for a chat that is running: worth knowing when deciding
  -- how far to trust "needs you".
  local source = display.source(chat)
  if source then
    fact('Status', 'known from ' .. source)
  end
  return out
end

--- What you attached to the chat yourself, set apart from what the agent says.
local function own(chat)
  local out = {}
  local group = state.group(chat.key)
  if group then
    out[#out + 1] = ('%-8s%s'):format('Group', group)
  end
  local labels = state.labels(chat.key)
  if #labels > 0 then
    out[#out + 1] = ('%-8s%s'):format('Labels', table.concat(labels, ', '))
  end
  local note = state.note(chat.key)
  if note then
    out[#out + 1] = ('%-8s%s'):format('Note', note)
  end
  local queued = state.queue(chat.key)
  if #queued > 0 then
    -- Text that will be sent later has to say when, and how to stop it.
    local hosted = require('agent-chats.term').find(chat) ~= nil
    local it = #queued == 1 and 'it' or 'them'
    -- Nothing can be sent to it from here at all: it runs somewhere else,
    -- or it cannot be resumed.
    local unreachable = not hosted and (chat.live or (chat.cwd ~= nil and not fs.is_dir(chat.cwd)))
    local when, how
    if unreachable then
      when = ('not sent: nothing can send %s to this chat from here'):format(it)
      how = ('%s drops %s.'):format(keys.reach('queue'), it)
    elseif hosted and not state.parked(chat.key) then
      local busy = chat.status == 'working' or chat.status == 'attention'
      if not busy and state.claim(chat.key) ~= nil then
        -- A reply was handed to the chat a moment ago and has not shown
        -- as taken up yet: "its turn" would be a turn nobody can see.
        when = 'sent when the chat has finished with the reply before '
          .. (#queued == 1 and 'it' or 'them')
      else
        when = 'sent when the chat finishes its turn'
      end
      how = ('%s sends now, adds or drops.'):format(keys.reach('queue'))
    else
      -- Not open in a terminal here, or kept back since it ended.
      when = ('not sent until you send %s'):format(it)
      how = ('%s sends, adds or drops.'):format(keys.reach('queue'))
    end
    out[#out + 1] = ('%-8s%d repl%s, %s'):format(
      'Queued',
      #queued,
      #queued == 1 and 'y' or 'ies',
      when
    )
    for i, item in ipairs(queued) do
      out[#out + 1] = ('%-8s%d. %s'):format('', i, text.oneline(item.text, 90))
    end
    if how ~= '' then
      out[#out + 1] = ('%-8s%s'):format('', how)
    end
  end
  return out
end

--- Lines describing `chat` (markdown), and which of them to colour.
---@param chat agent_chats.Chat?
---@param row table?  The board row, for search hits.
---@param width integer?  The cells there are for a line: what says where the chat stands is fitted to them, each line going on under its own words. (What was said in the chat is left to the window to wrap.)
---@param tab integer?  The tab the summary is shown in ("in tab 2" is said from there); the current one when nil.
---@return string[] lines, { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] marks  0-based line, start and end column, highlight.
function M.lines(chat, row, rows, width, tab)
  if not chat then
    if row and row.kind == 'group' then
      local fold = keys.key('open') or keys.key('toggle')
      local out = { '', fold and ('  %s folds and unfolds this group.'):format(fold) or '' }
      local function say(words)
        out[#out + 1] = ''
        for _, piece in ipairs(text.wrap(words, math.max(30, (width or 76) - 5))) do
          out[#out + 1] = '  ' .. piece
        end
      end
      if row.filtered then
        -- A group that nobody made on the board: where it comes from,
        -- what it does, and how a chat gets out of it.
        say(
          ('These chats are in folders that the options filter out (filter_out): %s.'):format(
            table.concat(config.get().filter_out, ', ')
          )
        )
        say(
          ('They are left out of the counts and the notifications, and %s does not go to them. A search still finds them.'):format(
            config.command('next')
          )
        )
        say('Take a folder out of filter_out, and its chats are back among the others.')
      elseif row.archived then
        local key = keys.key('archive')
        say(
          'Chats you archived. They are left out of the counts above the list, and a search still finds them.'
        )
        say(
          (
            key and ('%s on one of them takes it out again'):format(key)
            or 'The menu of one of them takes it out again'
          ) .. ', and one that moves again (a new turn) comes back by itself.'
        )
      elseif row.gone then
        -- The other one: why these are apart from "Ended".
        say(
          'The folders these chats were in are no longer there. An agent takes a chat up again only in the folder it was in, so these can be read and not resumed.'
        )
        say('When a folder is there again, its chats are back among the others.')
      end
      return out, {}
    end
    if row and (row.kind == 'more' or row.kind == 'older') then
      local show = keys.key('open')
      return { '', show and ('  %s shows them.'):format(show) or '' }, {}
    end
    local any = false
    for _, r in ipairs(rows or {}) do
      any = any or r.chat ~= nil
    end
    local out
    if any then
      out = { '', '  Move to a chat to see it here.', '' }
    else
      -- Nothing to move to: say what this place is for.
      out = {
        '',
        '  Every chat of your coding agents in one list: which need you,',
        '  which are working, which have finished.',
        '',
        '  A chat that runs in a terminal of this Neovim shows here live.',
        '  Any other chat shows what you asked and how far it got.',
        '',
      }
    end
    vim.list_extend(out, guide())
    return out, {}
  end

  local now = os.time()
  local out, marks = { '# ' .. display.title(chat), '' }, {}
  --- `line` as the lines it takes in the pane. `keep`: the bytes it
  --- starts with that stay as they are (the column of a label); `indent`:
  --- the cells its further lines begin with. Left to the window, a line
  --- would go on at the left edge, and break wherever Vim breaks lines
  --- (in the middle of a path).
  local function fitted(line, keep, indent)
    if not width or text.width(line) <= width - 1 then
      return { line }
    end
    local pieces = text.wrap(line:sub(keep + 1), math.max(12, width - 1 - indent))
    local lines = {}
    for i, piece in ipairs(pieces) do
      lines[i] = (i == 1 and line:sub(1, keep) or string.rep(' ', indent)) .. piece
    end
    return lines
  end
  local sentence, hl = state_lines(chat, now, tab)
  for i, line in ipairs(sentence) do
    for n, piece in ipairs(fitted(line, i == 1 and 0 or 2, 2)) do
      if i == 1 and n == 1 then
        marks[#marks + 1] = { #out, 0, #piece, hl }
      end
      out[#out + 1] = piece
    end
  end
  out[#out + 1] = ''
  --- `Label   value` lines, the label dimmed.
  local function labelled(lines)
    for _, line in ipairs(lines) do
      marks[#marks + 1] = { #out, 0, 8, 'AgentChatsDim' }
      vim.list_extend(out, fitted(line, 8, 8))
    end
  end
  labelled(facts(chat, now))
  local mine = own(chat)
  if #mine > 0 then
    out[#out + 1] = ''
    labelled(mine)
  end

  if row and row.kind == 'hit' then
    section(out, 'Passage found', row.hit.excerpt, 12)
  end
  if chat.subagent then
    out[#out + 1] = ''
    out[#out + 1] = ('A subagent%s of the chat above it.%s'):format(
      chat.agent_type and (' (' .. chat.agent_type .. ')') or '',
      config.hint('open', ' %s reads what it did.')
    )
    return out, marks
  end
  if chat.stub then
    out[#out + 1] = ''
    out[#out + 1] = 'A new chat that has not been sent a prompt yet.'
    if chat.unstarted then
      out[#out + 1] = ('It is listed under its own name once it has one.%s'):format(
        config.hint('open', ' %s goes to its terminal.')
      )
    end
    return out, marks
  end

  local first = chat.first_prompt and vim.trim(chat.first_prompt) or ''
  local last = chat.last_prompt and vim.trim(chat.last_prompt) or ''
  local whole = config.hint('read', ' (%s reads the whole conversation)')
  if first ~= '' and last ~= '' and first ~= last then
    section(out, 'First prompt', first, FIRST_LINES, whole)
    section(out, 'Last prompt', last, LAST_LINES, whole)
  else
    -- Asked once, or the two are the same: said once.
    section(out, 'Prompt', first ~= '' and first or last, LAST_LINES, whole)
  end
  section(out, 'Last reply', chat.last_reply, REPLY_LINES, whole)
  return out, marks
end

--- Fill `buf` with `lines`, and colour what `marks` name.
function M.show(buf, lines, marks)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  lines = vim.deepcopy(lines)
  -- Buffer lines cannot hold newlines.
  for i, l in ipairs(lines) do
    if l:find('\n', 1, true) then
      lines[i] = l:gsub('\n', ' ')
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks or {}) do
    local line = lines[m[1] + 1]
    if line then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m[1], m[2], {
        end_col = math.min(m[3], #line),
        hl_group = m[4],
      })
    end
  end
end

--- Fill `buf` with the summary of `chat`, for a pane `width` cells wide
--- in tab `tab`.
function M.render(buf, chat, row, rows, width, tab)
  local lines, marks = M.lines(chat, row, rows, width, tab)
  M.show(buf, lines, marks)
end

--- A scratch buffer for the summary, highlighted as markdown.
---@return integer buf
function M.create()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'agent-chats-summary'
  pcall(vim.api.nvim_buf_set_name, buf, 'Agent chats: summary')
  pcall(vim.treesitter.start, buf, 'markdown')
  vim.bo[buf].modifiable = false
  return buf
end

return M
