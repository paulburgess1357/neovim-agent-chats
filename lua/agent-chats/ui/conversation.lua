-- A whole conversation as a read-only markdown buffer: your prompts and the
-- agent's replies in full, tool calls folded to one line each. While the
-- chat is running the buffer follows it.
--
-- (What an agent writes to disk is its transcript; what is read here, made
-- from it, is the conversation.)

local api = vim.api
local async = require('agent-chats.util.async')
local config = require('agent-chats.config')
local display = require('agent-chats.display')
local keys = require('agent-chats.keys')
local providers = require('agent-chats.providers')
local store = require('agent-chats.store')
local text = require('agent-chats.util.text')
local time = require('agent-chats.util.time')

local M = {}

---@class agent_chats.ConversationState
---@field key string
---@field cursor any
---@field count integer         Messages read so far.
---@field levels table<integer, string>  Fold level per line.
---@field starts table<integer, integer> Message index -> first line.
---@field heading string?       Role of the last heading written.
---@field open_tool (string|boolean)?  The tool call whose fold ends the buffer: its id, or true without one.
---@field calls table<string, string>  Tool call id -> what it was, for a result that comes later.
---@field header integer        Lines of the header at the top (0: not written yet).
---@field tail integer          Lines at the end that are a remark; the next thing written replaces them.
---@field note string?          What that remark is.
---@field cursorless boolean?   The reader hands back the whole conversation every time.
---@field shown agent_chats.ConversationItem[]?  For such a reader: what is drawn, in order.
---@field marks table[]?        ... and where each began, with the state to draw it again from there.
---@field mtime number?
---@field timer uv.uv_timer_t?
---@field loading boolean
---@field fold_key string?      The key that opens and closes a tool call here, for the fold's own line.

---@class agent_chats.ConversationItem
---@field m agent_chats.Message
---@field index integer   Its place in the conversation (search hits name messages by it).
---@field results agent_chats.ConversationItem[]?

---@type table<integer, agent_chats.ConversationState>
local states = {}

-- How often an open conversation is looked at again (tests shorten it).
M._poll_ms = 1500

local ns = api.nvim_create_namespace('agent-chats-conversation')

local function fence_for(body)
  local longest = 2
  for run in body:gmatch('`+') do
    longest = math.max(longest, #run)
  end
  return string.rep('`', longest + 1)
end

local function put_lines(out, levels, base, lines, level)
  for _, l in ipairs(lines) do
    out[#out + 1] = l
    levels[base + #out] = level
  end
end

--- What a tool call is called on its line.
local function call_label(m)
  local summary = (m.summary and m.summary ~= '') and (' · ' .. text.oneline(m.summary, 100)) or ''
  return (m.name or 'tool') .. summary
end

--- `messages` in the order they are shown: a tool's result directly after
--- its call. An agent that runs several tools in one step writes call,
--- call, result, result; shown like that, the first result would sit under
--- the second call.
---@param messages agent_chats.Message[]
---@param offset integer  Messages that came before these.
---@return agent_chats.ConversationItem[]
local function arrange(messages, offset)
  local shown_thinking = config.get().conversation.thinking
  -- `nameless`: calls of a reader that gives no ids, still waiting for a
  -- result. Their results come in the order of the calls.
  local seq, calls, nameless = {}, {}, {}
  for i, m in ipairs(messages) do
    local item = { m = m, index = offset + i }
    local call
    if m.role == 'tool_result' then
      if m.id then
        call = calls[m.id]
      else
        call = table.remove(nameless, 1)
      end
    end
    if call then
      call.results = call.results or {}
      call.results[#call.results + 1] = item
    else
      seq[#seq + 1] = item
      if m.role == 'tool' then
        if m.id then
          calls[m.id] = item
        else
          nameless[#nameless + 1] = item
        end
      elseif m.role ~= 'tool_result' and (m.role ~= 'thinking' or shown_thinking) then
        -- Something was said in between: a result that comes after it is
        -- shown where it came, not moved back above what was said.
        calls, nameless = {}, {}
      end
    end
  end
  local out = {}
  for _, item in ipairs(seq) do
    out[#out + 1] = item
    for _, result in ipairs(item.results or {}) do
      out[#out + 1] = result
    end
    item.results = nil
  end
  return out
end

--- Whether two messages are drawn the same.
local function same(a, b)
  return a.role == b.role
    and a.id == b.id
    and a.text == b.text
    and a.name == b.name
    and a.summary == b.summary
    and a.input == b.input
    and a.lang == b.lang
    and a.error == b.error
    and a.time == b.time
end

--- Markdown lines for `items`, appended to what `st` already holds.
---@param st agent_chats.ConversationState
---@param items agent_chats.ConversationItem[]
---@param label string  The agent's display name.
---@param base integer  Lines in the buffer before these.
---@param before integer?  For a reader without a cursor: items drawn before these.
---@return string[]
function M.build(st, items, label, base, before)
  local cfg = config.get().conversation
  local out = {}
  local now = os.time()
  local function line(s, level)
    out[#out + 1] = s
    st.levels[base + #out] = level or '0'
  end
  local function body(s, level)
    put_lines(out, st.levels, base, text.lines(s), level or '0')
  end
  local function heading(role, name, ts)
    if st.heading ~= role then
      st.heading = role
      line(('## %s%s'):format(name, ts and ('  ·  ' .. time.stamp(ts, now)) or ''))
      line('')
    end
  end
  -- What can be folded carries the mark of an open group; closed, its fold
  -- line shows the other one (see `foldtext`).
  local mark = config.get().icons.expanded
  local function fenced(s, lang, level, max)
    local lines, omitted = text.head_lines(s, max or 100000)
    local fence = fence_for(s)
    line(fence .. (lang or ''), level)
    put_lines(out, st.levels, base, lines, level)
    if omitted > 0 then
      line(('… %d more lines'):format(omitted), level)
    end
    line(fence, level)
  end

  for n, item in ipairs(items) do
    local m = item.m
    st.starts[item.index] = base + #out + 1
    if st.marks then
      st.marks[(before or 0) + n] =
        { line = base + #out + 1, heading = st.heading, open_tool = st.open_tool }
    end
    local role = m.role
    if role == 'user' then
      st.open_tool = false
      st.heading = nil
      heading('user', 'You', m.time)
      body(m.text or '')
      line('')
    elseif role == 'assistant' then
      st.open_tool = false
      heading('assistant', label, m.time)
      body(m.text or '')
      line('')
    elseif role == 'thinking' then
      if cfg.thinking and m.text and m.text ~= '' then
        st.open_tool = false
        line(mark .. ' Thinking', '>1')
        body(m.text, '1')
        line('', '0')
      end
    elseif role == 'tool' then
      heading('assistant', label, m.time)
      local what = call_label(m)
      line(mark .. ' ' .. what, '>1')
      if m.input and m.input ~= '' then
        fenced(m.input, m.lang, '1', 200)
      end
      if m.id then
        st.calls[m.id] = what
      end
      st.open_tool = m.id or true
    elseif role == 'tool_result' then
      local shown = m.text or ''
      local head = m.error and '↳ failed' or '↳ result'
      -- The result of the call just above joins that call's fold. Any
      -- other one (its call was written earlier, other calls since) gets
      -- a fold of its own that says which call it answers.
      local open = st.open_tool
      local joins = open ~= nil and open ~= false and (open == true or m.id == nil or open == m.id)
      if joins then
        line(head, '1')
      else
        local of = m.id and st.calls[m.id]
        line(of and ('%s of %s'):format(head, of) or head, '>1')
      end
      if shown ~= '' then
        fenced(shown, nil, '1', cfg.tool_output_lines)
      end
      line('', '0')
      st.open_tool = false
    elseif role == 'system' then
      st.open_tool = false
      for _, l in ipairs(text.lines(m.text or '')) do
        line('> ' .. l)
      end
      line('')
    end
  end
  return out
end

function M.foldexpr()
  local st = states[api.nvim_get_current_buf()]
  return st and st.levels[vim.v.lnum] or '0'
end

function M.foldtext()
  local first = vim.fn.getline(vim.v.foldstart)
  local st = states[api.nvim_get_current_buf()]
  -- Closed, and marked as that (the line itself carries the open mark).
  local icons = config.get().icons
  if first:sub(1, #icons.expanded) == icons.expanded then
    first = icons.collapsed .. first:sub(#icons.expanded + 1)
  end
  -- How much opening it shows: its lines without the fences around code,
  -- which are not drawn.
  local more = 0
  for _, l in ipairs(vim.fn.getline(vim.v.foldstart + 1, vim.v.foldend)) do
    if not l:match('^```+[%w_+-]*$') then
      more = more + 1
    end
  end
  -- The key that opens it, where the eye already is.
  local how = st
      and st.fold_key
      and (', %s opens %s'):format(st.fold_key, more == 1 and 'it' or 'them')
    or ''
  return ('%s   (%d more line%s%s)'):format(first, more, more == 1 and '' or 's', how)
end

local function window_options(win)
  local wo = vim.wo[win]
  wo.foldmethod = 'expr'
  wo.foldexpr = "v:lua.require'agent-chats.ui.conversation'.foldexpr()"
  wo.foldtext = "v:lua.require'agent-chats.ui.conversation'.foldtext()"
  wo.foldenable = true
  wo.foldlevel = config.get().conversation.fold_tools and 0 or 99
  wo.fillchars = 'eob: ,fold: '
end

--- Replace the buffer from line `from` (1-based) to its end with `lines`.
local function write(buf, from, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, from - 1, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function header(chat)
  return { '# ' .. display.title(chat), '', display.where(chat), '' }
end

--- Read what is new in the chat and bring the buffer up to date.
local function load(buf, done)
  local st = states[buf]
  if not st or st.loading then
    return
  end
  local chat = store.get(st.key)
  local p = chat and providers.get(chat.provider)
  if not chat or not p then
    return
  end
  st.loading = true
  async.run(function()
    return p.messages(chat, { cursor = st.cursor })
  end, function(ok, messages, cursor, restarted)
    st.loading = false
    if not api.nvim_buf_is_valid(buf) or states[buf] ~= st then
      return
    end
    local last = api.nvim_buf_line_count(buf)
    local first = st.header == 0

    if not ok or type(messages) ~= 'table' then
      st.mtime = chat.mtime
      -- Say it once, not on every poll.
      if st.note ~= 'failed' then
        local lines = first and header(chat) or {}
        local from = first and 1 or (last - st.tail + 1)
        if first then
          st.header = #lines
        end
        local why = ok and 'its reader gave no messages' or tostring(messages):match('[^\n]*')
        lines[#lines + 1] = '> Could not read this conversation: ' .. why
        write(buf, from, lines)
        st.tail, st.note = 1, 'failed'
      end
      return
    end

    -- A window at the end of the conversation follows it.
    local following = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if api.nvim_win_get_cursor(win)[1] >= last - 1 then
        following[#following + 1] = win
      end
    end

    local items, before, from
    if cursor == nil then
      -- No incremental reads for this agent: this is the whole
      -- conversation. Draw only what differs from what is there, so the
      -- part being read stays as it is (folds, place) while the end grows.
      st.cursorless = true
      st.marks = st.marks or {}
      local all = arrange(messages, 0)
      local old = st.shown or {}
      local k = 1
      while k <= #old and k <= #all and old[k].index == all[k].index and same(old[k].m, all[k].m) do
        k = k + 1
      end
      st.mtime = chat.mtime
      if st.shown and k > #old and k > #all then
        -- Nothing new. A remark left by a read that failed has had its day.
        if st.note == 'failed' and st.tail > 0 then
          write(buf, last - st.tail + 1, {})
          st.tail, st.note = 0, nil
        end
        if done then
          done()
        end
        return
      end
      if k <= #old then
        local mark = st.marks[k]
        from, st.heading, st.open_tool = mark.line, mark.heading, mark.open_tool
        for i = k, #old do
          st.starts[old[i].index] = nil
          st.marks[i] = nil
        end
      end
      items, before = {}, k - 1
      for i = k, #all do
        items[#items + 1] = all[i]
      end
      st.shown, st.count = all, #messages
    else
      if restarted then
        -- The reader began again from the top (the file was rewritten):
        -- so does the view, below its header.
        st.count, st.starts, st.heading, st.open_tool, st.calls = 0, {}, nil, false, {}
        if not first then
          from = st.header + 1
        end
      end
      items, before = arrange(messages, st.count), 0
      st.count = st.count + #messages
      st.cursor, st.mtime = cursor, chat.mtime
    end

    local lines = {}
    if first then
      lines = header(chat)
      st.header = #lines
      from = 1
    elseif not from then
      -- After what is there, in place of a remark at the end.
      from = last - st.tail + 1
    end
    local note = st.count == 0 and 'empty' or nil
    if #items == 0 and not first and st.note == note and from > last - st.tail then
      if done then
        done()
      end
      return
    end
    for l = from, last do
      st.levels[l] = nil
    end
    vim.list_extend(lines, M.build(st, items, p.label, from - 1 + #lines, before))
    if note == 'empty' then
      lines[#lines + 1] = '> Nothing has been said in this chat yet.'
    end
    write(buf, from, lines)
    st.tail, st.note = note and 1 or 0, note
    if not first then
      local bottom = api.nvim_buf_line_count(buf)
      for _, win in ipairs(following) do
        pcall(api.nvim_win_set_cursor, win, { bottom, 0 })
      end
    end
    if done then
      done()
    end
  end)
end

local function close(buf)
  local st = states[buf]
  if st and st.timer then
    st.timer:stop()
    if not st.timer:is_closing() then
      st.timer:close()
    end
  end
  states[buf] = nil
end

--- Line of the `index`-th message in a conversation buffer.
function M.line_of(buf, index)
  local st = states[buf]
  return st and st.starts[index] or nil
end

--- Mark every place `query` occurs in the buffer, the way the search
--- matched it. The user's own search pattern and 'hlsearch' are theirs
--- and are left alone.
---@param from integer  Line to look from.
---@return { [1]: integer, [2]: integer }?  Line and column of the first match at or after `from`.
function M.mark_matches(buf, query, from)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local smart = query:match('%u') ~= nil
  local needle = smart and query or query:lower()
  local first
  for l, s in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local hay = smart and s or s:lower()
    local init = 1
    while true do
      local a, b = hay:find(needle, init, true)
      if not a then
        break
      end
      api.nvim_buf_set_extmark(buf, ns, l - 1, a - 1, { end_col = b, hl_group = 'Search' })
      if not first and l >= from then
        first = { l, a - 1 }
      end
      init = b + 1
    end
  end
  return first
end

--- Open the conversation of `chat` in the board's pane.
---@param chat agent_chats.Chat
---@param opts { index: integer?, query: string? }?
---@return integer? buf
function M.open(chat, opts)
  opts = opts or {}
  local board = require('agent-chats.ui.board')
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'agent-chats-conversation'
  pcall(api.nvim_buf_set_name, buf, ('Agent chat: %s [%d]'):format(display.title(chat, 40), buf))
  pcall(vim.treesitter.start, buf, 'markdown')
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'Reading…' })
  vim.bo[buf].modifiable = false
  states[buf] = {
    key = chat.key,
    count = 0,
    levels = {},
    starts = {},
    calls = {},
    open_tool = false,
    header = 0,
    tail = 0,
    loading = false,
  }

  local function leave()
    board.release(buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    board.focus()
  end
  -- The same keys as on the list do the same things here, to this chat.
  -- What is bound here is what this view's title and menu name.
  local bound, left = {}, {}
  local function bind(action, fn, desc)
    bound[action], left[action] = keys.map(buf, 'n', action, fn, desc)
    return bound[action]
  end
  -- In a text to be read, `/` is Vim's own search, with `n` and `N` behind
  -- it: a long conversation is searched like any buffer. The search over
  -- every chat keeps its other key here (unless `/` was given to it by
  -- name in the options: then that is what was asked for).
  local function bind_search(fn, desc)
    if config.explicit('search') then
      return bind('search', fn, desc)
    end
    local plan = keys.resolve('search', 'n', buf)
    bound.search, left.search = {}, plan.left
    for _, lhs in ipairs(plan.bound) do
      if lhs ~= '/' and keys.set(buf, 'n', lhs, fn, desc, true) then
        bound.search[#bound.search + 1] = lhs
      end
    end
    return bound.search
  end
  --- The keys of an action in this view, for the menu opened from it.
  local function keys_here(action)
    if keys.shown(bound[action]) then
      return bound[action], false
    end
    local yours = {}
    for _, item in ipairs(left[action] or {}) do
      yours[#yours + 1] = item.lhs
    end
    return yours, #yours > 0
  end
  local function next_prompt_here()
    vim.fn.search('^## You', 'W')
  end
  local function prev_prompt_here()
    vim.fn.search('^## You', 'bW')
  end
  local function fold_here()
    if vim.fn.foldlevel('.') > 0 then
      vim.cmd('normal! za')
    else
      vim.notify(
        'The cursor is not on a tool call.',
        vim.log.levels.INFO,
        { title = 'Agent chats' }
      )
    end
  end
  --- The chat as it is now, for whatever acts on it from here.
  local function ctx()
    return {
      chat = store.get(chat.key) or chat,
      view = 'conversation',
      back = leave,
      keys = keys_here,
      -- What has a key in this view (the menu lets each of them act).
      actions = vim.tbl_keys(bound),
      -- What this view does itself with a key of its own: chosen from the
      -- menu, it happens here, not on the list.
      run = { next_prompt = next_prompt_here, prev_prompt = prev_prompt_here, toggle = fold_here },
    }
  end
  local back = bind('back', leave, 'back to the list')
  local chat_actions = {
    'queue',
    'diff',
    'rename',
    'pin',
    'move',
    'label',
    'note',
    'unread',
    'archive',
    'yank',
    'new',
    'search',
  }
  for _, action in ipairs(chat_actions) do
    local function run()
      board.run(action, ctx())
    end
    if action == 'search' then
      bind_search(run, board.descriptions[action])
    else
      bind(action, run, board.descriptions[action])
    end
  end
  local next_prompt = bind('next_prompt', next_prompt_here, 'next prompt')
  local prev_prompt = bind('prev_prompt', prev_prompt_here, 'previous prompt')
  local menu = bind('menu', function()
    board.menu(ctx())
  end, 'everything that can be done with this chat')
  -- On a tool call, the keys that fold a group on the list open and close
  -- the call. Anywhere else they do what they do in any buffer.
  local function fold_or(lhs)
    return function()
      if vim.fn.foldlevel('.') > 0 then
        vim.cmd('normal! za')
      else
        pcall(vim.cmd, 'normal! ' .. api.nvim_replace_termcodes(lhs, true, true, true))
      end
    end
  end
  local folds = {}
  for _, action in ipairs({ 'toggle', 'open' }) do
    for _, lhs in ipairs(keys.resolve(action, 'n', buf).bound) do
      if
        not lhs:lower():find('mouse', 1, true)
        and keys.set(
          buf,
          'n',
          lhs,
          fold_or(lhs),
          'open or close a tool call',
          not config.explicit(action)
        )
      then
        folds[#folds + 1] = lhs
      end
    end
  end
  states[buf].fold_key = keys.shown(folds)
  -- For the menu opened from here: the key beside "open or close". (Not
  -- Enter, which in a menu chooses the line it is on.)
  bound.toggle = vim.tbl_filter(function(lhs)
    return keys.canon(lhs) ~= keys.canon('<CR>')
  end, folds)

  -- The bar above the list names the keys this buffer has, as many as
  -- fit: the way back first, the prompts after it. It is asked again when
  -- keys change (one of them gave way to a mapping of yours), so it never
  -- names one that is not this view's any more.
  local function hints()
    local function still(list)
      return keys.shown(keys.still(buf, 'n', list))
    end
    -- The fold lines name the key that opens them: the one that still does.
    if states[buf] then
      states[buf].fold_key = still(folds)
    end
    -- Closing the window is the way back whatever is mapped: with no key
    -- for it, that is what the bar says.
    local out = { { still(back) or ':q', 'Back' } }
    local down, up = still(next_prompt), still(prev_prompt)
    if down and up then
      out[#out + 1] = { down .. ' ' .. up, 'Prompts' }
    end
    out.menu = still(menu)
    return out
  end

  -- Whose conversation this is: the list marks that chat's row.
  vim.b[buf].agent_chats_key, vim.b[buf].agent_chats_parent = chat.key, chat.parent
  local win = board.pane_show(buf, 'conversation', hints)
  if not win then
    close(buf)
    pcall(api.nvim_buf_delete, buf, { force = true })
    return nil
  end
  window_options(win)

  api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      close(buf)
    end,
  })

  load(buf, function()
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf then
      return
    end
    local target = opts.index and M.line_of(buf, opts.index)
    if target then
      target = math.min(target, api.nvim_buf_line_count(buf))
      local col = 0
      if opts.query and opts.query ~= '' then
        local at = M.mark_matches(buf, opts.query, target)
        if at then
          target, col = at[1], at[2]
        end
      end
      pcall(api.nvim_win_set_cursor, win, { target, col })
      api.nvim_win_call(win, function()
        vim.cmd('silent! normal! zvzz')
      end)
    else
      -- A conversation is read from its latest turn.
      pcall(api.nvim_win_set_cursor, win, { api.nvim_buf_line_count(buf), 0 })
      api.nvim_win_call(win, function()
        vim.cmd('silent! normal! zb')
      end)
    end
  end)

  -- Follow the chat while it is on screen.
  local st = states[buf]
  st.timer = vim.uv.new_timer()
  st.timer:start(
    M._poll_ms,
    M._poll_ms,
    vim.schedule_wrap(function()
      if not api.nvim_buf_is_valid(buf) then
        return close(buf)
      end
      local c = store.get(chat.key)
      if not c or #vim.fn.win_findbuf(buf) == 0 then
        return
      end
      -- A reader with a cursor reads only what is new, which is cheap
      -- enough to do for as long as the chat runs. One that reads the
      -- whole conversation is asked again when the index saw it change.
      -- A read that failed is tried again: nothing about the chat needs to
      -- change for a locked database to open.
      if c.mtime ~= st.mtime or (c.live and not st.cursorless) or st.note == 'failed' then
        load(buf)
      end
    end)
  )
  return buf
end

M._states = states

return M
