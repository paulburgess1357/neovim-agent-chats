local T = require('helpers.harness')
local fx = require('helpers.claude')
local fake = require('helpers.fake')
local eq, ok, no, has, hasnt = T.eq, T.ok, T.no, T.has, T.hasnt

local api = vim.api

-- Folders that are there: chats in them are listed as ones that can be
-- resumed.
local ALPHA, BETA = T.folder('alpha'), T.folder('beta')

local function board()
  return require('agent-chats.ui.board')
end
local function store()
  return require('agent-chats.store')
end
local function state()
  return require('agent-chats.state')
end
local function actions()
  return require('agent-chats.actions')
end

--- A finished chat.
local function chat(home, opts)
  opts = opts or {}
  local c = home:chat({
    cwd = opts.cwd or ALPHA,
    branch = opts.branch or 'main',
    start = os.time() - (opts.age or 600) - 5,
  })
  c:user(opts.prompt or 'Please fix the parser')
  c:title(opts.title or 'Fix the parser')
  c:tool_use('Bash', { command = 'make test' }):tool_result('3 passed')
  c:assistant(opts.reply or 'The parser is fixed.'):turn_done()
  return c:write(os.time() - (opts.age or 600))
end

--- Open the board on a home prepared by `build`, with every chat "seen".
local function open(build, extra)
  local home = fx.home(vim.tbl_deep_extend('force', { board = { spinner = false } }, extra or {}))
  local made = build and build(home) or nil
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
  store().refresh_sync()
  store().start = function() end
  board().open()
  return home, made
end

local function text_of(buf)
  return T.buf_text(buf)
end

local function list()
  return text_of(board()._state.buf)
end

local function pane()
  local S = board()._state
  return text_of(api.nvim_win_get_buf(S.pane_win))
end

local function key(c)
  return 'claude:' .. c.id
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end

--- Answer the next `vim.ui.select` / `vim.ui.input` calls with these values.
local function answer(selects, inputs)
  local real_select, real_input = vim.ui.select, vim.ui.input
  local si, ii = 0, 0
  vim.ui.select = function(items, _, cb)
    si = si + 1
    local want = selects and selects[si]
    if type(want) == 'function' then
      return cb(want(items))
    end
    cb(want and items[want] or nil)
  end
  vim.ui.input = function(_, cb)
    ii = ii + 1
    cb(inputs and inputs[ii] or nil)
  end
  return function()
    vim.ui.select, vim.ui.input = real_select, real_input
  end
end

after_each(function()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
  require('agent-chats.ui.input').cancel()
end)

describe('board', function()
  it('opens in its own tab with the list and a pane, and closes back', function()
    local before = api.nvim_get_current_tabpage()
    open(function(home)
      chat(home, { title = 'Fix the parser' })
      chat(home, { title = 'Write the docs', cwd = BETA, age = 60 })
    end)
    local S = board()._state
    ok(board().is_open())
    ok(api.nvim_get_current_tabpage() ~= before)
    eq(2, #api.nvim_tabpage_list_wins(0))
    eq(S.win, api.nvim_get_current_win())
    has(list(), '2 chats')
    has(list(), 'Ended  2')
    has(list(), 'Fix the parser')
    has(list(), 'Write the docs')
    has(list(), 'alpha')
    -- Most recent first.
    ok(list():find('Write the docs', 1, true) < list():find('Fix the parser', 1, true))

    board().close()
    no(board().is_open())
    eq(before, api.nvim_get_current_tabpage())
    eq(1, #api.nvim_list_tabpages())
  end)

  it('starts on a chat and summarises it in the pane', function()
    open(function(home)
      chat(home, { title = 'Fix the parser', reply = 'The parser is **fixed**.' })
    end)
    local c = board().current()
    ok(c)
    eq('Fix the parser', c.title)
    board()._state.pending_pane = false
    vim.wait(50)
    has(pane(), '# Fix the parser')
    has(pane(), '/alpha')
    has(pane(), 'Please fix the parser')
    has(pane(), 'The parser is **fixed**.')
  end)

  it('goes to the open board instead of opening a second one', function()
    open(function(home)
      chat(home)
    end)
    local tabs = #api.nvim_list_tabpages()
    vim.cmd('tabprevious')
    board().open()
    eq(tabs, #api.nvim_list_tabpages())
    eq(board()._state.win, api.nvim_get_current_win())
  end)

  it('narrows the rows to what is searched for: a name, a folder, a message', function()
    open(function(home)
      chat(home, { title = 'Fix the parser', cwd = ALPHA })
      chat(home, { title = 'Write the docs', cwd = BETA, reply = 'Docs mention the zebra.' })
    end)
    local function narrow(text)
      board().search(text, { conversations = false })
    end
    narrow('docs')
    has(list(), 'Write the docs')
    hasnt(list(), 'Fix the parser')
    has(list(), 'Search “docs”  1 chat')
    eq('docs', board().query())

    narrow('ALPHA')
    has(list(), 'Fix the parser')
    hasnt(list(), 'Write the docs')

    narrow('zebra')
    has(list(), 'Write the docs')

    -- Words in any order, each of them somewhere in the row.
    narrow('beta write')
    has(list(), 'Write the docs')
    hasnt(list(), 'Fix the parser')

    narrow('nothing-matches-this')
    has(list(), 'No row shows “nothing-matches-this”')
    has(vim.wo[board()._state.win].winbar, 'End Search')
    ok(board().clear())
    eq('', board().query())
    has(list(), 'Fix the parser')
    has(list(), 'Write the docs')
    no(board().clear(), 'there is nothing left to end')
  end)

  it('groups by folder, agent and status', function()
    open(function(home)
      chat(home, { cwd = ALPHA })
      chat(home, { cwd = BETA })
    end)
    has(list(), 'Ended  2')
    board().set_group('folder')
    has(list(), '/alpha  1')
    has(list(), '/beta  1')
    has(list(), 'by folder')
    board().set_group('agent')
    has(list(), 'Claude  2')
    has(list(), 'by agent')
    board().cycle_group()
    has(list(), 'by worktree')
    board().cycle_group()
    -- By status is how it comes: nothing needs saying.
    has(list(), 'Ended  2')
    hasnt(list(), 'by ')
  end)

  it('folds a group and remembers it', function()
    open(function(home)
      chat(home, { title = 'Fix the parser' })
    end)
    feed('gg')
    api.nvim_win_set_cursor(0, { 3, 0 })
    eq('group', board().row().kind)
    board().toggle_row()
    hasnt(list(), 'Fix the parser')
    has(list(), '▸ Ended  1')
    board().close()
    board().open()
    hasnt(list(), 'Fix the parser')
    api.nvim_win_set_cursor(0, { 3, 0 })
    board().toggle_row()
    has(list(), 'Fix the parser')
  end)

  it('caps long groups and shows the rest on request', function()
    open(function(home)
      for i = 1, 6 do
        chat(home, { title = 'Chat number ' .. i, age = i * 60 })
      end
    end, { board = { max_per_group = 4 } })
    has(list(), 'Chat number 4')
    hasnt(list(), 'Chat number 5')
    has(list(), '2 more')
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'more' then
        api.nvim_win_set_cursor(0, { i, 0 })
      end
    end
    board().toggle_row()
    has(list(), 'Chat number 6')
  end)

  it('shows what a note says on the row, the title giving way only so far', function()
    local name = 'A title that takes a good deal of room on the row'
    local _, c = open(function(home)
      return chat(home, { title = name, age = 1200 })
    end)
    local note = require('agent-chats.config').get().icons.note
    local S = board()._state
    local columns = vim.o.columns
    local function row(width, words)
      state().set_note(key(c), words)
      api.nvim_win_set_width(S.win, width)
      board().render()
      for i, r in ipairs(S.rows) do
        if r.kind == 'chat' then
          local line = api.nvim_buf_get_lines(S.buf, i - 1, i, false)[1]
          ok(vim.fn.strdisplaywidth(line) <= width, ('%d: %s'):format(width, line))
          return line
        end
      end
    end
    local good, err = pcall(function()
      vim.o.columns = 240
      -- Room for both: the note in full.
      has(row(140, 'ask Sam first'), name .. ' ' .. note .. ' ask Sam first   ')
      -- What a note is written on more than one line of is one line here.
      has(row(140, 'ask Sam\nfirst'), note .. ' ask Sam first   ')
      -- A long note beside a long title: both are cut, and the title keeps
      -- the larger part.
      local long = 'this note goes on and on about what is still to be done here'
      local tight = row(100, long)
      local at = tight:find(note, 1, true)
      local title = tight:sub(1, at - 1):match('(A title.-)…')
      local said = tight:sub(at + #note):match('^ (this note.-)…')
      ok(title and said, tight)
      hasnt(tight, 'done here')
      ok(vim.fn.strdisplaywidth(title) >= 2 * vim.fn.strdisplaywidth(said), tight)
      ok(#said >= 8, tight)
      -- A short one is not cut for it.
      has(row(100, 'ask Sam'), note .. ' ask Sam   ')
      -- No room worth the name: the mark alone says that there is a note.
      local narrow = row(44, long)
      has(narrow, note .. ' ')
      hasnt(narrow, 'this')
      -- (One that fits whole in the little there is, is shown.)
      has(row(44, 'ask Sam'), note .. ' ask Sam ')
      -- With its other marks, the note comes last: its words end the row.
      state().enqueue(key(c), 'then the docs')
      state().set_labels(key(c), { 'urgent' })
      has(row(140, 'ask Sam first'), '#urgent ' .. note .. ' ask Sam first   ')
      -- Found by a word of the note, the word is marked on the row.
      board().search('Sam')
      local found = false
      for _, m in ipairs(api.nvim_buf_get_extmarks(S.buf, -1, 0, -1, { details = true })) do
        found = found or m[4].hl_group == 'AgentChatsMatch'
      end
      ok(found, 'the word of the note is marked')
    end)
    vim.o.columns = columns
    assert(good, err)
  end)

  it('shows pins, labels, notes and unread state on the row', function()
    local _, c = open(function(home)
      chat(home, { title = 'Older chat', age = 900 })
      return chat(home, { title = 'Fix the parser', age = 1200 })
    end)
    local restore = answer(nil, { 'review urgent', 'waiting on CI' })
    local current = store().get(key(c))
    actions().pin(current)
    actions().labels(current)
    actions().note(current)
    restore()
    local icons = require('agent-chats.config').get().icons
    has(list(), icons.pin .. ' Fix the parser')
    has(list(), '#review')
    has(list(), '#urgent')
    -- A note in its own words, behind its mark.
    has(list(), icons.note .. ' waiting on CI')
    -- Pinned chats lead their group.
    ok(list():find('Fix the parser', 1, true) < list():find('Older chat', 1, true))

    actions().toggle_unread(store().get(key(c)))
    has(list(), 'Unread  1')
    has(list(), '1 unread')
    actions().read_all()
    hasnt(list(), 'Unread  ')
  end)

  it('archives a chat out of sight, under a heading at the end', function()
    local _, c = open(function(home)
      return chat(home, { title = 'Fix the parser' })
    end)
    actions().archive(store().get(key(c)))
    hasnt(list(), 'Fix the parser')
    has(list(), '▸ Archived  1')
    -- Again takes it out.
    actions().archive(store().get(key(c)))
    has(list(), 'Fix the parser')
    hasnt(list(), 'Archived')
  end)

  it("renames a chat without touching the agent's title", function()
    local _, c = open(function(home)
      return chat(home, { title = 'Fix the parser' })
    end)
    local restore = answer(nil, { 'Parser rewrite' })
    actions().rename(store().get(key(c)))
    restore()
    has(list(), 'Parser rewrite')
    eq('Fix the parser', store().get(key(c)).title)
  end)

  it('lists subagents under their chat when it is unfolded', function()
    local _, c = open(function(home)
      local made = chat(home, { title = 'Fix the parser' })
      made:subagent(
        'aaa111',
        { agentType = 'Explore', description = 'Find parser files', finished = true }
      )
      return made
    end)
    ok(board().goto_chat(key(c)))
    hasnt(list(), 'Find parser files')
    board().toggle_row()
    has(list(), 'Find parser files')
    has(list(), 'Explore: Find parser files')
    board().toggle_row()
    hasnt(list(), 'Find parser files')
  end)

  it('says what to do next when there is nothing to show', function()
    -- No agent to be found at all.
    open(nil, { providers = { claude = { cmd = { 'no-such-agent-command' } } } })
    has(list(), 'No agent found.')
    has(list(), 'This board lists the chats of Claude.')
    has(list(), ':checkhealth agent-chats')
    board().close()

    -- An agent, and nothing said to it yet.
    local home = open()
    fake.install(home)
    board().render()
    has(list(), 'No chats yet.')
    has(list(), '+ starts one with Claude.')
    board().close()

    -- Chats, but none recent.
    open(function(h)
      chat(h, { age = 90 * 86400 })
    end, { board = { max_age_days = 7 } })
    has(list(), 'No chats in the last 7 days.')
    has(list(), 'Enter on the line below shows the 1 older one.')
    has(list(), '1 chat older than 7 days not shown (Enter shows them)')
    board().close()

    -- Chats, all put away.
    open(function(h)
      local c = chat(h)
      state().update(function(s)
        s.archived[key(c)] = os.time() + 10
      end)
    end)
    has(list(), '0 chats')
    has(list(), '▸ Archived  1')
  end)

  it('works as a floating window too', function()
    open(function(home)
      chat(home)
    end, { board = { layout = 'float' } })
    local S = board()._state
    eq(1, #api.nvim_list_tabpages())
    ok(api.nvim_win_get_config(S.win).relative ~= '')
    ok(api.nvim_win_get_config(S.pane_win).relative ~= '')
    has(list(), 'Fix the parser')
    board().toggle_pane()
    eq(nil, S.pane_win)
    board().toggle_pane()
    ok(S.pane_win)
    board().close()
    for _, win in ipairs(api.nvim_list_wins()) do
      eq('', api.nvim_win_get_config(win).relative)
    end
  end)

  it('fits a narrow window', function()
    open(function(home)
      chat(home, { title = 'A fairly long chat title that will not fit in a narrow list' })
    end)
    api.nvim_win_set_width(board()._state.win, 40)
    board().render()
    for _, line in ipairs(api.nvim_buf_get_lines(board()._state.buf, 0, -1, false)) do
      ok(vim.fn.strdisplaywidth(line) <= 40, 'line too wide: ' .. line)
    end
    has(list(), '…')
  end)

  it('lists what can be done with a chat, in words, with the key of each that has one', function()
    local _, gone = open(function(home)
      chat(home, { title = 'Fix the parser', cwd = vim.uv.cwd(), age = 60 })
      return chat(home, { title = 'Its folder is gone', cwd = '/work/alpha' })
    end)
    local menu = require('agent-chats.ui.menu')
    local win = board().menu()
    ok(api.nvim_win_is_valid(win))
    local all = table.concat(menu.lines(), '\n')
    -- (The folder as a line of a menu has it: a long one without its start.
    -- How long this one is depends on where the tests are run.)
    local folder = require('agent-chats.util.fs').short(vim.uv.cwd(), 44)
    has(all, 'Enter  Resume it in ' .. folder)
    has(all, 'C      Read the conversation')
    -- A reply is typed in the chat itself (Enter goes there): the menu has
    -- no line for it, and none for forking a chat.
    hasnt(all, 'Reply')
    hasnt(all, 'Fork')
    has(all, '+      New chat')
    has(all, 'S      Search chats')
    -- All of it is there, under what it is about; nothing is a step down.
    has(all, '── This chat ')
    has(all, '── Keep track of it ')
    has(all, '── The list ')
    has(all, '── The board ')
    hasnt(all:gsub(vim.pesc(folder), ''), '…')
    -- Only what applies: nothing is queued, and the chat is not busy.
    hasnt(all, 'Queue')
    menu.close()
    no(menu.is_open())

    -- A chat whose folder is gone cannot be resumed: the menu offers what
    -- is left.
    board().goto_chat(key(gone))
    board().menu()
    all = table.concat(menu.lines(), '\n')
    has(all, 'Enter  Read it (its folder is gone, so it cannot be resumed)')
    hasnt(all, 'Show what changed')
    menu.close()
  end)
end)

describe('opening chats', function()
  it('resumes an ended chat in the pane and then shows its live terminal', function()
    local home, c = open(function(h)
      return chat(h, { title = 'Fix the parser', cwd = vim.uv.cwd() })
    end)
    local agent = fake.install(home)
    board().goto_chat(key(c))
    local buf = actions().open(store().get(key(c)))
    ok(buf)
    local S = board()._state
    eq(S.pane_win, api.nvim_get_current_win())
    eq(buf, api.nvim_win_get_buf(S.pane_win))
    eq('terminal', vim.bo[buf].buftype)
    ok(
      vim.fn.maparg([[<C-\><C-b>]], 't', false, true).buffer == 1,
      'the terminal can return to the list'
    )
    T.wait(3000, function()
      return agent.read():find('argv: --resume ' .. c.id, 1, true) ~= nil
    end)
    has(agent.read(), 'cwd: ' .. vim.uv.cwd())

    -- The index sees it running in this Neovim.
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local now = store().get(key(c))
      return now.live == true and now.term == buf
    end)
    eq('idle', store().get(key(c)).status)

    -- Back in the list the pane previews the live terminal.
    board().focus()
    eq(S.win, api.nvim_get_current_win())
    eq(buf, api.nvim_win_get_buf(S.pane_win))
    -- (The pane has no bar of its own: the terminal has every line of it.)
    eq('', vim.wo[S.pane_win].winbar)

    -- Opening it again goes to the same terminal.
    eq(buf, actions().open(store().get(key(c))))
    eq(1, select(2, agent.read():gsub('argv:', '')))
  end)

  it("types a reply into the chat's terminal", function()
    local home, c = open(function(h)
      return chat(h, { cwd = vim.uv.cwd() })
    end)
    local agent = fake.install(home)
    actions().open(store().get(key(c)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    store().refresh_sync({ full = false })
    local sent
    actions().deliver(store().get(key(c)), 'please also update the docs', nil, function(done)
      sent = done
    end)
    -- Known once the terminal has shown the text and Enter was pressed.
    T.wait(3000, function()
      return sent ~= nil
    end)
    eq(true, sent)
    T.wait(3000, function()
      return agent.read():find('input: please also update the docs', 1, true) ~= nil
    end)
  end)

  it('sends a multi-line reply as one paste', function()
    local home, c = open(function(h)
      return chat(h, { cwd = vim.uv.cwd() })
    end)
    local agent = fake.install(home)
    local buf = actions().open(store().get(key(c)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    ok(require('agent-chats.term').send(buf, 'line one\nline two'))
    T.wait(3000, function()
      return agent.read():find('paste: end', 1, true) ~= nil
    end)
    -- One paste, with both lines inside it: a newline typed as a key
    -- would have submitted the first line on its own.
    has(agent.read(), 'paste: begin\ninput: line one\ninput: line two\npaste: end')
  end)

  it('sends what is written in the box to a chat that is free', function()
    local home, c = open(function(h)
      return chat(h, { cwd = vim.uv.cwd() })
    end)
    local agent = fake.install(home)
    actions().open(store().get(key(c)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    store().refresh_sync({ full = false })
    board().focus()
    -- Queueing a reply with nothing for it to wait behind: what is written
    -- goes at once.
    actions().queue(store().get(key(c)))
    local input = require('agent-chats.ui.input')
    ok(input.is_open())
    has(api.nvim_win_get_config(0).title[1][1], 'Reply now (it is not busy)')
    api.nvim_buf_set_lines(0, 0, -1, false, { 'ship it' })
    input.submit()
    no(input.is_open())
    T.wait(3000, function()
      return agent.read():find('input: ship it', 1, true) ~= nil
    end)
  end)

  it('resumes an ended chat with the reply, in a terminal or in the background', function()
    local home, c = open(function(h)
      return chat(h, { cwd = vim.uv.cwd() })
    end, { reply = { ended = 'terminal' } })
    local agent = fake.install(home)
    actions().deliver(store().get(key(c)), 'carry on')
    T.wait(3000, function()
      return agent.read():find('argv: --resume ' .. c.id .. ' carry on', 1, true) ~= nil
    end)
    fake.cleanup()

    T.write(agent.log, '')
    local done
    actions().deliver(store().get(key(c)), 'and again', { how = 'background' }, function(result)
      done = result
    end)
    eq(true, done)
    T.wait(3000, function()
      return agent.read():find('headless done', 1, true) ~= nil
    end)
    has(agent.read(), 'argv: -p --resume ' .. c.id .. ' and again')
  end)

  it('asks how to resume when told to', function()
    local home, c = open(function(h)
      return chat(h, { cwd = vim.uv.cwd() })
    end)
    local agent = fake.install(home)
    local restore = answer({ 2 })
    actions().deliver(store().get(key(c)), 'in the background please')
    restore()
    T.wait(3000, function()
      return agent.read():find('headless done', 1, true) ~= nil
    end)
  end)

  it('refuses to type into a chat that runs outside this Neovim', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, status = 'idle' })
    store().refresh_sync({ full = false })
    local live = store().get(key(c))
    ok(live.live)
    eq(nil, live.term)
    has(list(), require('agent-chats.config').get().icons.elsewhere)
    local result
    actions().deliver(live, 'hello', nil, function(done)
      result = done
    end)
    eq(false, result)
    -- Opening it shows the conversation instead.
    eq(nil, actions().open(live))
    eq('agent-chats-conversation', vim.bo[api.nvim_win_get_buf(board()._state.pane_win)].filetype)
  end)

  it('reports a missing folder or command instead of failing', function()
    local home, c = open(function(h)
      return chat(h, { cwd = '/nonexistent/folder/for/tests' })
    end)
    fake.install(home)
    eq(nil, actions().open(store().get(key(c))))
    require('agent-chats.config').get().providers.claude.cmd = { 'definitely-not-a-command-xyz' }
    eq(nil, actions().open(store().get(key(c))))
  end)

  it('starts a new chat with a known id', function()
    local home = open()
    local agent = fake.install(home)
    actions().new({ provider = 'claude', cwd = vim.uv.cwd(), prompt = 'build the thing' })
    T.wait(3000, function()
      return agent.read():find('build the thing', 1, true) ~= nil
    end)
    local id = agent.read():match('%-%-session%-id (%S+)')
    ok(id and #id == 36)
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get('claude:' .. id) ~= nil
    end)
    local made = store().get('claude:' .. id)
    ok(made.term, 'the new chat is tied to its terminal')
    eq('idle', made.status)
  end)

  it('asks which agent for a new chat, and opens it with nothing more asked', function()
    local home = open()
    local agent = fake.install(home)
    local restore = answer({ 1 })
    actions().new()
    restore()
    -- No box for a first prompt: that is typed to the agent itself.
    no(require('agent-chats.ui.input').is_open())
    -- The stand-in writes its arguments, then its folder: wait for both.
    T.wait(3000, function()
      local log = agent.read()
      return log:find('argv: --session-id', 1, true) ~= nil and log:find('cwd: ', 1, true) ~= nil
    end)
    has(agent.read(), 'cwd: ' .. vim.uv.cwd())
    -- Started with no prompt at all.
    ok(agent.read():match('argv: %-%-session%-id %S+\n'), agent.read())
    eq('terminal', vim.bo.buftype, 'the cursor is in the new chat')
    -- Named at once, with no question.
    fake.cleanup()
    agent = fake.install(home)
    board().focus()
    actions().new({ provider = 'claude' })
    T.wait(3000, function()
      return agent.read():find('argv: --session-id', 1, true) ~= nil
    end)
  end)

  it('closes the terminal when the agent exits and returns to the list', function()
    local home, c = open(function(h)
      return chat(h, { cwd = vim.uv.cwd() })
    end)
    local agent = fake.install(home)
    local buf = actions().open(store().get(key(c)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    require('agent-chats.term').send(buf, '/exit')
    T.wait(3000, function()
      return not api.nvim_buf_is_valid(buf)
    end)
    ok(board().is_open())
    ok(api.nvim_win_is_valid(board()._state.pane_win))
    eq(board()._state.win, api.nvim_get_current_win())
  end)

  it('sends a queued reply when the chat finishes its turn', function()
    local home, c = open(function(h)
      return chat(h, { cwd = vim.uv.cwd() })
    end)
    local agent = fake.install(home)
    require('agent-chats.queue').setup()
    actions().open(store().get(key(c)))
    T.wait(3000, function()
      return agent.read():find('argv:', 1, true) ~= nil
    end)
    -- The agent reports that it is busy; a reply is queued meanwhile.
    local pid
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      pid = store().get(key(c)).pid
      return pid ~= nil
    end)
    home:registry(pid, { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    eq('working', store().get(key(c)).status)
    state().enqueue(key(c), 'then run the linter')
    board().render()
    has(list(), require('agent-chats.config').get().icons.queue .. '1')

    home:registry(pid, { sessionId = c.id, status = 'idle', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    T.wait(4000, function()
      return agent.read():find('input: then run the linter', 1, true) ~= nil
    end)
    eq(0, #state().queue(key(c)))
  end)

  it('goes into the chat that waits for you, resuming it', function()
    local home = open(function(h)
      chat(h, { title = 'Seen already' })
    end)
    local agent = fake.install(home)
    local unread = chat(home, { title = 'Just finished', cwd = vim.uv.cwd(), age = 1 })
    state().update(function(s)
      s.baseline = os.time() - 300
      s.seen = {}
    end)
    store().refresh_sync()
    state().mark_seen('claude:' .. store().list()[1].id)
    for _, each in ipairs(store().list()) do
      if each.title == 'Seen already' then
        state().mark_seen(each.key)
      else
        state().mark_unseen(each.key)
      end
    end
    store().touch()
    eq(1, #actions().waiting())
    actions().next()
    T.wait(3000, function()
      return agent.read():find('argv: --resume ' .. unread.id, 1, true) ~= nil
    end)
  end)
end)

describe('reading and searching', function()
  it('shows the whole conversation with tool calls folded', function()
    local _, c = open(function(h)
      return chat(h, { title = 'Fix the parser' })
    end)
    local buf = actions().read(store().get(key(c)))
    ok(buf)
    T.wait(2000, function()
      return text_of(buf):find('The parser is fixed.', 1, true) ~= nil
    end)
    local body = text_of(buf)
    has(body, '# Fix the parser')
    has(body, '## You')
    has(body, 'Please fix the parser')
    has(body, '## Claude')
    has(body, '▾ Bash · make test')
    has(body, '3 passed')
    local win = board()._state.pane_win
    eq(win, api.nvim_get_current_win())
    -- The tool call is one folded line.
    local tool_line
    for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l:find('▾ Bash', 1, true) then
        tool_line = i
      end
    end
    ok(vim.fn.foldclosed(tool_line) == tool_line, 'the tool call starts a closed fold')
    ok(vim.fn.foldclosedend(tool_line) > tool_line)
    -- Closed, it is marked as closed, and says how much there is to open:
    -- the command, "result" and its one line, without the fences.
    eq('▸ Bash · make test   (3 more lines, Tab opens them)', vim.fn.foldtextresult(tool_line))

    feed('q')
    eq(board()._state.win, api.nvim_get_current_win())
    no(api.nvim_buf_is_valid(buf))
  end)

  it('follows a conversation that is still growing', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    local buf = actions().read(store().get(key(c)))
    T.wait(2000, function()
      return text_of(buf):find('The parser is fixed.', 1, true) ~= nil
    end)
    c.ts = os.time()
    c:user('One more thing'):assistant('Done as well.'):write()
    home:registry(vim.uv.os_getpid(), { sessionId = c.id, status = 'idle' })
    store().refresh_sync({ full = false })
    T.wait(4000, function()
      return text_of(buf):find('Done as well.', 1, true) ~= nil
    end)
    eq(1, select(2, text_of(buf):gsub('Please fix the parser', '')))
  end)

  it('finds text inside conversations and opens the match', function()
    local _, made = open(function(h)
      local a = chat(h, { title = 'Fix the parser', reply = 'Renamed the tokenizer to lexer.' })
      chat(h, { title = 'Write the docs', reply = 'Docs are written.' })
      return a
    end)
    local done, hits = false, nil
    require('agent-chats.search').run('TOKENIZER', function(found, running)
      hits, done = found, not running
    end)
    T.wait(3000, function()
      return done
    end)
    -- Smart case: an uppercase query is exact, so nothing matches.
    eq(0, vim.tbl_count(hits))
    done = false
    require('agent-chats.search').run('tokenizer', function(found, running)
      hits, done = found, not running
    end)
    T.wait(3000, function()
      return done
    end)
    eq(1, vim.tbl_count(hits))
    has(hits[key(made)][1].excerpt, 'Renamed the tokenizer to lexer.')
    eq('assistant', hits[key(made)][1].role)

    actions().search('tokenizer')
    T.wait(3000, function()
      local s = board()._state.search
      return s and not s.running
    end)
    has(list(), 'Search “tokenizer”')
    has(list(), '1 chat · 1 passage')
    has(list(), 'Claude: Renamed the tokenizer')
    hasnt(list(), 'Write the docs')
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'hit' then
        api.nvim_win_set_cursor(0, { i, 0 })
      end
    end
    feed('<CR>')
    local buf = api.nvim_win_get_buf(board()._state.pane_win)
    eq('agent-chats-conversation', vim.bo[buf].filetype)
    T.wait(2000, function()
      return text_of(buf):find('tokenizer', 1, true) ~= nil
    end)
    board().focus()
    board().clear()
    has(list(), 'Write the docs')
  end)

  it('searches without rg, and tool output only when asked', function()
    local _, made = open(function(h)
      return chat(h, { reply = 'All good.' })
    end)
    local scan = require('agent-chats.search').scan
    local messages = require('agent-chats.providers.claude').messages({ path = made.path })
    eq(0, #scan(messages, '3 passed', { max_hits = 5, tools = false }))
    eq(1, #scan(messages, '3 passed', { max_hits = 5, tools = true }))
    eq(1, #scan(messages, 'make test', { max_hits = 5, tools = true }))
    eq(0, #scan(messages, 'fix the PARSER', { max_hits = 5, tools = false }))
    eq(1, #scan(messages, 'fix the parser', { max_hits = 5, tools = false }))
  end)
end)

describe('commands and status line', function()
  it('runs :Chats subcommands and completes them', function()
    open(function(h)
      chat(h)
    end)
    board().close()
    vim.cmd('runtime plugin/agent-chats.lua')
    eq(2, vim.fn.exists(':Chats'))
    eq(2, vim.fn.exists(':AgentChats'))
    vim.cmd('Chats')
    ok(board().is_open())
    vim.cmd('Chats search parser')
    eq('parser', board().query())
    vim.cmd('Chats close')
    no(board().is_open())
    local m = require('agent-chats')
    eq({ 'next', 'new' }, { m.complete('ne', 'Chats ne')[2], m.complete('ne', 'Chats ne')[1] })
    eq({ 'claude' }, m.complete('cl', 'Chats new cl'))
    eq({}, m.complete('', 'Chats search '))
  end)

  it('closes the board with :Chats when the board is what you are looking at', function()
    open(function(h)
      chat(h)
    end)
    vim.cmd('runtime plugin/agent-chats.lua')
    local S = board()._state
    -- With the cursor in its list.
    eq(S.win, api.nvim_get_current_win())
    vim.cmd('Chats')
    no(board().is_open())
    eq(1, #api.nvim_list_tabpages(), 'its tab went with it')
    -- With the cursor in its pane (the summary beside the list).
    vim.cmd('Chats')
    ok(board().is_open())
    api.nvim_set_current_win(S.pane_win)
    vim.cmd('Chats')
    no(board().is_open())
    -- In another window of the board's own tab: it is still what is on
    -- the screen.
    vim.cmd('Chats')
    vim.cmd('botright new')
    ok(api.nvim_get_current_win() ~= S.win and api.nvim_get_current_win() ~= S.pane_win)
    vim.cmd('Chats')
    no(board().is_open())
    -- A floating board is in front of you for as long as it is open.
    board().open({ layout = 'float' })
    ok(board().is_open())
    vim.cmd('Chats')
    no(board().is_open())
  end)

  it('goes to the board with :Chats from another tab, and closes it from there', function()
    open(function(h)
      chat(h)
    end)
    vim.cmd('runtime plugin/agent-chats.lua')
    local S = board()._state
    local tab = S.tab
    vim.cmd('tabnew')
    local other = api.nvim_get_current_tabpage()
    ok(other ~= tab)
    local tabs = #api.nvim_list_tabpages()
    -- Open, and not what you are looking at: it comes to the front.
    vim.cmd('Chats')
    ok(board().is_open(), 'gone to, not closed')
    eq(tab, api.nvim_get_current_tabpage())
    eq(S.win, api.nvim_get_current_win())
    eq(tabs, #api.nvim_list_tabpages(), 'the one board there was, not another')
    -- Asked for again where it is: it closes, and leads back to the tab it
    -- was asked for from.
    vim.cmd('Chats')
    no(board().is_open())
    eq(other, api.nvim_get_current_tabpage())
  end)

  it('goes to a board in another window of the tab, where it is shown in one', function()
    open(function(h)
      chat(h)
    end, { board = { layout = 'current' } })
    vim.cmd('runtime plugin/agent-chats.lua')
    local S = board()._state
    eq('current', S.layout)
    vim.cmd('botright new')
    local mine = api.nvim_get_current_win()
    vim.cmd('Chats')
    ok(board().is_open())
    eq(S.win, api.nvim_get_current_win())
    vim.cmd('Chats')
    no(board().is_open())
    ok(api.nvim_win_is_valid(mine))
  end)

  it('never closes the board with :Chats open, or with the function a key goes back by', function()
    open(function(h)
      chat(h)
    end)
    vim.cmd('runtime plugin/agent-chats.lua')
    local S = board()._state
    vim.cmd('Chats open')
    ok(board().is_open())
    eq(S.win, api.nvim_get_current_win())
    -- From the pane it is the way back to the list.
    api.nvim_set_current_win(S.pane_win)
    vim.cmd('Chats open')
    ok(board().is_open())
    eq(S.win, api.nvim_get_current_win())
    api.nvim_set_current_win(S.pane_win)
    require('agent-chats').open()
    ok(board().is_open())
    eq(S.win, api.nvim_get_current_win())
    -- `toggle` is the bare command under its own name.
    vim.cmd('Chats toggle')
    no(board().is_open())
    require('agent-chats').toggle()
    ok(board().is_open())
    require('agent-chats').toggle()
    no(board().is_open())
  end)

  it('summarises what needs you for a statusline', function()
    local home = open(function(h)
      chat(h)
    end)
    local m = require('agent-chats')
    eq('', m.statusline())
    local busy = home:chat({ start = os.time() - 20 }):user('Go'):write()
    home:registry(vim.uv.os_getpid(), { sessionId = busy.id, status = 'waiting' })
    store().refresh_sync()
    local icons = require('agent-chats.config').get().icons
    eq(icons.attention .. ' 1', m.statusline())
    eq(1, m.counts().attention)
    eq(2, #m.chats())
  end)

  it('accepts a provider registered from outside', function()
    open()
    local listed = false
    require('agent-chats').register({
      name = 'demo',
      label = 'Demo',
      home = function()
        return '/tmp'
      end,
      available = function()
        return true
      end,
      discover = function()
        listed = true
        return { { id = 'one', mtime = os.time(), size = 1 } }
      end,
      parse = function()
        return {
          title = 'A demo chat',
          cwd = T.folder('demo'),
          turn = 'done',
          updated = os.time() - 5,
        }
      end,
      messages = function()
        return { { role = 'user', text = 'hello demo' } }, nil
      end,
      resume_cmd = function(c)
        return { 'demo', 'resume', c.id }
      end,
      new_cmd = function()
        return { 'demo' }
      end,
    })
    store().refresh_sync()
    ok(listed)
    has(list(), 'A demo chat')
    has(list(), 'Demo')
    require('agent-chats.providers').reset()
  end)
end)
