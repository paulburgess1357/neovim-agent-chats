-- What the board is like to use: its keys and yours, the bar that names
-- them, the menu, the one search, the way back, the summary, the first
-- opening, and a chat's terminal.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local fake = require('helpers.fake')
local eq, ok, no, has, hasnt = T.eq, T.ok, T.no, T.has, T.hasnt

local api = vim.api

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
local function keys()
  return require('agent-chats.keys')
end
local function menu()
  return require('agent-chats.ui.menu')
end

--- A finished chat. Its folder exists unless `opts.cwd` says otherwise.
local function chat(home, opts)
  opts = opts or {}
  local c = home:chat({
    cwd = opts.cwd or vim.uv.cwd(),
    branch = opts.branch or 'main',
    start = os.time() - (opts.age or 600) - 5,
  })
  c:user(opts.prompt or 'Please fix the parser')
  c:title(opts.title or 'Fix the parser')
  c:assistant(opts.reply or 'The parser is fixed.')
  if opts.then_prompt then
    c:user(opts.then_prompt):assistant(opts.then_reply or 'Done as well.')
  end
  c:turn_done()
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

local function list()
  return T.buf_text(board()._state.buf)
end

local function pane()
  return T.buf_text(api.nvim_win_get_buf(board()._state.pane_win))
end

--- The bar above the list, as it reads: the highlight codes taken out.
local function bar(win)
  local raw = vim.wo[win or board()._state.win].winbar
  return (raw:gsub('%%#%w+#', ''):gsub('%%%*', ''):gsub('%%=', ' | '))
end

-- The right of the bar: the keys that are there on every row. On a list of
-- ordinary width, where the keys of a row have their room first; and on a
-- wide one, all of them.
local ALWAYS = ' | + New Chat  S Search  ? Menu '
local ALL = ' | + New Chat  S Search  R Refresh  ? Menu '

--- What the pane has for a bar of its own: nothing, whatever it shows.
local function pane_bar()
  return vim.wo[board()._state.pane_win].winbar
end

local function key(c)
  return 'claude:' .. c.id
end

local function feed(lhs)
  api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), 'xt', false)
end

--- Everything `vim.notify` is told while `fn` runs.
local function notes(fn)
  local said = {}
  local real = vim.notify
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  local good, err = pcall(fn)
  -- What is said a moment later (an options warning) counts too.
  vim.wait(20)
  vim.notify = real
  assert(good, err)
  return table.concat(said, '\n')
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

--- Open `c` in a terminal of this Neovim, running the stand-in agent, and
--- wait until the index has it there.
local function hosted(home, c)
  local agent = fake.install(home)
  local buf = actions().open(store().get(key(c)))
  T.wait(3000, function()
    store().refresh_sync({ full = false })
    local now = store().get(key(c))
    return now.term == buf and now.pid ~= nil
  end)
  vim.cmd('stopinsert')
  return agent, buf
end

-- Global mappings a test makes, taken away again after it.
local mapped = {}
local function user_map(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, opts or {})
  mapped[#mapped + 1] = { mode, lhs }
end

after_each(function()
  for _, m in ipairs(mapped) do
    pcall(vim.keymap.del, m[1], m[2])
  end
  mapped = {}
  pcall(function()
    menu().close()
  end)
  require('agent-chats.ui.input').cancel()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
  pcall(api.nvim_del_augroup_by_name, 'AgentChatsTestUser')
end)

describe('keys: yours are left alone', function()
  it('takes no lowercase letter but q, and neither H nor L, anywhere', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    local theirs = vim.split('H L G N F Q P M n b e w j k h l a d f i o p r s t u v x y', ' ')
    local function untouched(where)
      for _, lhs in ipairs(theirs) do
        eq('', vim.fn.maparg(lhs, 'n'), ('%s is mapped %s'):format(lhs, where))
      end
    end
    untouched('on the list')
    -- In a conversation.
    local buf = actions().read(store().get(key(c)))
    eq(buf, api.nvim_get_current_buf())
    untouched('in a conversation')
    feed('q')
    -- In a chat's terminal, in its normal mode.
    local _, term = hosted(home, c)
    eq(term, api.nvim_get_current_buf())
    untouched("in a chat's terminal")
  end)

  it('gives a default key up to a mapping of yours, and says where the action went', function()
    local pressed = {}
    user_map('n', 'C', function()
      pressed[#pressed + 1] = 'C'
    end, { desc = 'my own C' })
    user_map('n', 'S', function()
      pressed[#pressed + 1] = 'S'
    end)
    user_map('n', '?', function()
      pressed[#pressed + 1] = '?'
    end)
    open(function(h)
      chat(h)
    end)
    local function reading()
      return vim.bo.filetype == 'agent-chats-conversation'
    end
    -- Yours run; the board's do not.
    feed('C')
    feed('S')
    feed('?')
    eq({ 'C', 'S', '?' }, pressed)
    no(reading(), 'no conversation was opened')
    no(menu().is_open())
    eq(nil, board()._state.search)
    -- Not one of them is mapped on the list.
    for _, lhs in ipairs({ 'C', 'S', '?' }) do
      no(vim.fn.maparg(lhs, 'n', false, true).buffer == 1, lhs)
    end
    -- The second key of an action takes over where there is one.
    eq('/', keys().key('search'))
    eq('g?', keys().key('menu'))
    eq(nil, keys().key('read'))
    -- What the screen says follows: no hint for a key that is not bound.
    hasnt(bar(), 'Conversation')
    has(bar(), 'g? Menu')
    has(bar(), '/ Search')
    -- And it is said which keys were left, and to what.
    local left = {}
    for _, l in ipairs(keys().left()) do
      left[#left + 1] = ('%s %s %s'):format(l.action, l.lhs, l.by)
    end
    eq({ 'menu ? a mapping of yours', 'read C my own C', 'search S a mapping of yours' }, left)
    local health = {}
    for _, line in ipairs(require('agent-chats.health').keys()) do
      health[#health + 1] = line.text
    end
    has(table.concat(health, '\n'), 'C is yours (my own C)')
    has(table.concat(health, '\n'), 'S is yours')
    has(table.concat(health, '\n'), '/ does that')

    -- The action is still one step away: in the menu, where its key picks it.
    feed('g?')
    ok(menu().is_open())
    local shown = table.concat(menu().lines(), '\n')
    has(shown, 'C*     Read the conversation')
    has(shown, 'a key of yours, which the board leaves alone')
    feed('C')
    no(menu().is_open())
    ok(reading(), 'the menu ran the action')
    eq({ 'C', 'S', '?' }, pressed, 'and your mapping was not what ran')
  end)

  it('binds a key you name in the options although it is mapped', function()
    local pressed = 0
    user_map('n', 'q', function()
      pressed = pressed + 1
    end)
    user_map('n', 'C', function()
      pressed = pressed + 1
    end)
    open(function(h)
      chat(h)
    end, { keys = { back = 'q' } })
    ok(vim.fn.maparg('q', 'n', false, true).buffer == 1)
    no(vim.fn.maparg('C', 'n', false, true).buffer == 1, 'only what was named')
    feed('q')
    no(board().is_open())
    eq(0, pressed)
  end)

  it('does not take a mapping to nothing, or one of Neovim itself, for yours', function()
    user_map('n', 'C', '<Nop>')
    user_map('n', 'S', '')
    local defaults = require('agent-chats.config').defaults.keys
    local before = defaults.yank
    -- `Y` is mapped by Neovim (to y$): nobody made that mapping.
    defaults.yank = 'Y'
    local good, err = pcall(function()
      open(function(h)
        chat(h)
      end)
      ok(vim.fn.maparg('C', 'n', false, true).buffer == 1)
      ok(vim.fn.maparg('S', 'n', false, true).buffer == 1)
      ok(vim.fn.maparg('Y', 'n', false, true).buffer == 1)
      eq({}, keys().left())
    end)
    defaults.yank = before
    assert(good, err)
  end)

  it('counts a mapping you put on the board buffer yourself', function()
    local pressed = 0
    api.nvim_create_autocmd('FileType', {
      group = api.nvim_create_augroup('AgentChatsTestUser', { clear = true }),
      pattern = 'agent-chats',
      callback = function(ev)
        vim.keymap.set('n', 'C', function()
          pressed = pressed + 1
        end, { buffer = ev.buf, desc = 'mine, on this buffer' })
      end,
    })
    local _, c = open(function(h)
      return chat(h)
    end)
    feed('C')
    eq(1, pressed)
    eq(board()._state.win, api.nvim_get_current_win(), 'no conversation was opened')
    eq(nil, keys().key('read'))
    hasnt(bar(), 'Conversation')
    ok(store().get(key(c)))
  end)

  it('gives way in a conversation and in a terminal as well', function()
    local pressed = {}
    user_map('n', ']]', function()
      pressed[#pressed + 1] = ']]'
    end)
    user_map('n', '[[', function()
      pressed[#pressed + 1] = '[['
    end)
    user_map('n', 'q', function()
      pressed[#pressed + 1] = 'q'
    end)
    user_map('t', [[<C-\><C-b>]], function()
      pressed[#pressed + 1] = 'term'
    end)
    local home, c = open(function(h)
      return chat(h, { then_prompt = 'And the lexer?' })
    end)
    local buf = actions().read(store().get(key(c)))
    T.wait(2000, function()
      return T.buf_text(buf):find('And the lexer', 1, true) ~= nil
    end)
    feed(']]')
    feed('q')
    eq({ ']]', 'q' }, pressed)
    eq(buf, api.nvim_get_current_buf(), 'still in the conversation')
    -- The title names what is bound here: the second keys for the prompts,
    -- and, with no key to go back, the command that does.
    has(bar(), 'J K Prompts')
    has(bar(), ':q Back')
    -- J goes to the next prompt.
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed('J')
    has(api.nvim_get_current_line(), '## You')
    -- Closing the window is still the way back.
    vim.cmd('close')
    T.wait(1000, function()
      return api.nvim_get_current_win() == board()._state.win
    end)

    local _, term = hosted(home, c)
    no(vim.fn.maparg([[<C-\><C-b>]], 't', false, true).buffer == 1)
    no(vim.fn.maparg('q', 'n', false, true).buffer == 1)
    eq(term, api.nvim_get_current_buf())
    -- No key at all: closing the window is the way back, and it says so.
    has(bar(), ':q Back')
  end)

  it('says so when two actions are given one key, and which of them it does', function()
    local said = notes(function()
      open(function(h)
        chat(h)
      end, { keys = { pin = 'X', archive = 'X' } })
    end)
    has(said, 'keys.archive and keys.pin are both on X')
    has(said, 'it does "archive"')
    has(vim.fn.maparg('X', 'n', false, true).desc, 'archive')
  end)

  it('reads the names keys went by before, and says what they are now', function()
    local said = notes(function()
      fx.home({ keys = { transcript = 'gt', handoff = 'gp', yank_id = 'gy', nonsense = 'gz' } })
      vim.wait(30)
    end)
    has(said, 'keys.transcript is now keys.read')
    has(said, 'keys.handoff is gone: passing a chat on to another agent was taken out')
    has(said, 'keys.yank_id is gone')
    has(said, 'keys.nonsense is not an action')
    local cfg = require('agent-chats.config').get()
    eq('gt', cfg.keys.read)
    eq(nil, cfg.keys.pass)
    eq(nil, cfg.keys.handoff)
    eq(nil, cfg.keys.transcript)
    eq(nil, cfg.keys.nonsense)
  end)

  it('has no way from one chat that needs you to the next, and says so to a key for it', function()
    local said = notes(function()
      open(function(h)
        chat(h, { title = 'Unread one', age = 30 })
      end, { keys = { next_attention = '<F7>', prev_attention = '<F8>' } })
      vim.wait(30)
    end)
    has(
      said,
      'keys.next_attention is gone: going from one chat that needs you to the next was taken out'
    )
    has(said, 'keys.prev_attention is gone')
    local cfg = require('agent-chats.config').get()
    eq(nil, cfg.keys.next_attention)
    eq(nil, cfg.keys.prev_attention)
    eq('', vim.fn.maparg('<F7>', 'n'))
    eq(nil, board().jump_attention)
    eq(nil, board().descriptions.next_attention)
    -- Nor a line for it in the menu, with a chat that is unread.
    state().update(function(s)
      s.baseline = os.time() - 3000
      s.seen = {}
    end)
    store().touch()
    ok(store().counts().done > 0)
    board().menu()
    local lines = table.concat(menu().lines(), '\n')
    has(lines, 'Mark every chat read')
    hasnt(lines, 'needs you')
    menu().close()
  end)

  it('describes every mapping it makes', function()
    open(function(h)
      chat(h)
    end)
    local seen = 0
    for _, m in ipairs(api.nvim_buf_get_keymap(board()._state.buf, 'n')) do
      ok(
        type(m.desc) == 'string' and m.desc:find('^Agent chats: %l'),
        m.lhs .. ' has no description'
      )
      seen = seen + 1
    end
    ok(seen >= 12, 'the list has its keys: ' .. seen)
  end)
end)

describe('the bar above the list', function()
  it('names what can be done with the row under the cursor, by its state', function()
    local home, made = open(function(h)
      local c = chat(h, { title = 'Hosted here', age = 30 })
      local gone = chat(h, { title = 'Folder gone', cwd = '/nonexistent/for/tests', age = 60 })
      local sub = chat(h, { title = 'Has a subagent', age = 90 })
      sub:subagent('aaa111', { agentType = 'Explore', description = 'Find files', finished = true })
      local away = chat(h, { title = 'Runs elsewhere', age = 120 })
      h:registry(vim.uv.os_getpid(), { sessionId = away.id, status = 'idle' })
      return { c = c, gone = gone, sub = sub, away = away }
    end)
    local c = made.c
    local function on(k)
      ok(board().goto_chat(k), k)
      return bar()
    end

    -- An ended chat: Enter resumes it, and what is said to it is typed there.
    -- (At the right, the keys that are there on every row.)
    local always = ALWAYS
    eq(' Enter Resume  C Conversation  A Archive' .. always, on(key(c)))
    -- One whose folder is gone can only be read. (The key for the
    -- conversation is named all the same: it is where it is on every chat.
    -- Why Enter only reads it is said where there is room: see below.)
    eq(' Enter Read  C Conversation  A Archive' .. always, on(key(made.gone)))
    -- So can one that runs outside this Neovim.
    eq(' Enter Read  C Conversation  A Archive' .. always, on(key(made.away)))

    -- In a terminal of this Neovim: Enter goes to it.
    local _, term = hosted(home, c)
    board().focus()
    eq(' Enter Open  C Conversation  A Archive' .. ALWAYS, on(key(c)))
    local pid = store().get(key(c)).pid
    -- Busy: the same two. (A reply can be queued for it from the menu.)
    home:registry(pid, { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    eq(' Enter Open  C Conversation  A Archive' .. ALWAYS, on(key(c)))
    -- Asking: Enter goes to answer it.
    home:registry(
      pid,
      { sessionId = c.id, status = 'waiting', waitingFor = 'permission', cwd = vim.uv.cwd() }
    )
    store().refresh_sync({ full = false })
    eq(' Enter Answer  C Conversation  A Archive' .. ALWAYS, on(key(c)))
    -- With something queued, its row says so; the bar names no key for
    -- what has none.
    state().enqueue(key(c), 'then the docs')
    board().render()
    eq(' Enter Answer  C Conversation  A Archive' .. ALWAYS, bar())
    has(list(), '»1')
    ok(api.nvim_buf_is_valid(term))

    -- A subagent can be read, and that is all.
    board().goto_chat(key(made.sub))
    board().toggle_row()
    for i, row in ipairs(board()._state.rows) do
      if row.chat and row.chat.subagent then
        api.nvim_win_set_cursor(board()._state.win, { i, 1 })
      end
    end
    board().focus()
    eq(' Enter Read' .. ALWAYS, bar())

    -- A heading folds; the top of the list is about the board itself.
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'group' then
        api.nvim_win_set_cursor(board()._state.win, { i, 1 })
        break
      end
    end
    board().focus()
    eq(' Enter Fold' .. ALWAYS, bar())
    board().toggle_row()
    eq(' Enter Unfold' .. ALWAYS, bar())
    board().toggle_row()
    api.nvim_win_set_cursor(board()._state.win, { 1, 0 })
    board().focus()
    -- (On no row: what can be done with the list is all there is to name.)
    eq(' ' .. ALWAYS, bar())
  end)

  it('names the keys you give to what has none by default', function()
    local home, c = open(function(h)
      return chat(h, { title = 'Hosted here', age = 30 })
    end, { keys = { queue = 'Q' } })
    hosted(home, c)
    board().focus()
    board().goto_chat(key(c))
    -- (Nothing to queue behind: the chat is not in the middle of a turn.)
    eq(' Enter Open  C Conversation  A Archive' .. ALWAYS, bar())
    home:registry(
      store().get(key(c)).pid,
      { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() }
    )
    store().refresh_sync({ full = false })
    board().render()
    -- (Beside the keys that are always there, the row has room for three.)
    has(bar(), 'Enter Open  Q Queue a Reply  C Conversation | + New Chat')
    api.nvim_win_set_width(board()._state.win, 100)
    board().render()
    has(bar(), 'Enter Open  Q Queue a Reply  C Conversation  A Archive | + New Chat')
    state().enqueue(key(c), 'then the docs')
    board().render()
    has(bar(), 'Q Queued Replies (1)')
  end)

  it('drops hints from the right when narrow, and never the way to the rest', function()
    open(function(h)
      chat(h)
    end)
    local win = board()._state.win
    local function at(width)
      api.nvim_win_set_width(win, width)
      board().render()
      return bar()
    end
    -- The key that is needed least goes first, and a long label is
    -- shortened; then the keys of the row give way to a new chat and the
    -- search, the last of them first; then those go, and last what Enter
    -- does.
    local row = ' Enter Resume  C Conversation  A Archive'
    eq(row .. ' | + New Chat  S Search  R Refresh  ? Menu ', at(84))
    eq(row .. ' | + New Chat  S Search  ? Menu ', at(76))
    eq(row .. ' | + New  S Search  ? Menu ', at(68))
    eq(' Enter Resume  C Conversation | + New  S Search  ? Menu ', at(56))
    eq(' Enter Resume | + New  S Search  ? Menu ', at(48))
    eq(' Enter Resume | + New  S Search  ? Menu ', at(39))
    eq(' Enter Resume | + New  ? Menu ', at(30))
    eq(' Enter Resume | ? Menu ', at(24))
    eq('  | ? Menu ', at(12))
    -- What is shown fits.
    for _, width in ipairs({ 84, 76, 68, 56, 48, 39, 30, 24, 12 }) do
      local shown = at(width):gsub(' | ', '  ')
      ok(vim.fn.strdisplaywidth(shown) <= width, ('%d: %s'):format(width, shown))
    end
  end)

  it('names the command when the menu has no key', function()
    open(function(h)
      chat(h)
    end, { keys = { menu = false } })
    has(bar(), 'S Search  :Chats menu ')
    vim.cmd('runtime plugin/agent-chats.lua')
    vim.cmd('Chats menu')
    ok(menu().is_open())
  end)

  it('is kept current in every window that shows the list', function()
    open(function(h)
      chat(h, { title = 'Chat A', age = 10 })
      chat(h, { title = 'Folder gone', cwd = '/nonexistent/for/tests', age = 20 })
    end)
    vim.cmd('split')
    local second = api.nvim_get_current_win()
    -- (The chat that cannot be resumed is under a heading of its own, at
    -- the end, folded.)
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'group' and row.gone then
        api.nvim_win_set_cursor(second, { i, 1 })
      end
    end
    board().focus()
    board().render()
    has(bar(board()._state.win), 'Enter Resume')
    has(bar(second), 'Enter Unfold')
    api.nvim_win_close(second, true)
  end)
end)

describe('the menu', function()
  it('picks an action by its key, in either case, or with Enter', function()
    local _, c = open(function(h)
      return chat(h)
    end)
    local function conversation_open()
      return vim.bo[api.nvim_win_get_buf(board()._state.pane_win)].filetype
        == 'agent-chats-conversation'
    end
    feed('?')
    ok(menu().is_open())
    feed('C')
    no(menu().is_open())
    ok(conversation_open())
    feed('q')
    no(conversation_open())

    feed('?')
    feed('c')
    ok(conversation_open(), 'a small c will do')
    feed('q')

    -- Down to the second line, and Enter.
    feed('?')
    feed('j')
    has(api.nvim_get_current_line(), 'Read the conversation')
    feed('<CR>')
    ok(conversation_open())
    feed('q')

    -- The key that opened it closes it; so do q and Esc.
    feed('?')
    feed('?')
    no(menu().is_open())
    feed('?')
    feed('<Esc>')
    no(menu().is_open())
    eq(board()._state.win, api.nvim_get_current_win())
    ok(store().get(key(c)))
  end)

  it('is one list, all of it in view, in parts under headings', function()
    open(function(h)
      chat(h, { cwd = T.folder('alpha') })
      chat(h, { cwd = T.folder('beta'), age = 700 })
    end)
    feed('?')
    local lines = menu().lines()
    local all = table.concat(lines, '\n')
    -- Nothing is a step down: what is about the chat, about your marks on
    -- it, about the list and about the board is all there, in that order.
    hasnt(all, '…')
    local at = {}
    for i, l in ipairs(lines) do
      for _, words in ipairs({
        'This chat',
        'Keep track of it',
        'The list',
        'The board',
        'Rename',
        'Group by folder',
        'Turn notifications',
        'Close the board',
      }) do
        if l:find(words, 1, true) then
          at[words] = at[words] or i
        end
      end
    end
    eq(1, at['This chat'])
    ok(at['This chat'] < at['Keep track of it'])
    ok(at['Keep track of it'] < at['Rename'])
    ok(at['Rename'] < at['The list'])
    ok(at['The list'] < at['Group by folder'])
    ok(at['Group by folder'] < at['The board'])
    ok(at['The board'] < at['Turn notifications'])
    eq(#lines, at['Close the board'])
    has(all, 'Show older chats')
    has(all, 'Status hooks of the agents: see or set up')
    has(all, 'Pin to the top of its group')
    has(all, 'Mark unread')
    has(all, 'Archive it: out of the way, at the end of the list')
    has(all, 'Copy the command that resumes it')
    hasnt(all, 'Group by status')
    -- A heading is a rule with its words in it, and no choice.
    eq('   This chat ', (lines[1]:gsub('─', '')))
    -- As wide as the choices under it, and no wider.
    local widest = 0
    for i = 2, #lines do
      widest = math.max(widest, vim.fn.strdisplaywidth(lines[i]))
    end
    eq(widest, vim.fn.strdisplaywidth(lines[1]))
    no(menu().pick('This chat'))
    ok(menu().is_open())
    -- q closes it: there is nowhere to go back to.
    feed('q')
    no(menu().is_open())

    feed('?')
    ok(menu().pick('Group by folder'))
    no(menu().is_open())
    has(list(), '/alpha  1')
    has(list(), 'by folder')

    feed('?')
    ok(menu().pick('Pin to the top of its group'))
    local pinned = 0
    for _, each in ipairs(store().list()) do
      pinned = pinned + (state().pinned(each.key) and 1 or 0)
    end
    eq(1, pinned)
  end)

  it('keeps the cursor on what can be chosen', function()
    open(function(h)
      chat(h)
    end)
    feed('?')
    local win = api.nvim_get_current_win()
    local function line()
      return api.nvim_get_current_line()
    end
    -- It opens on what Enter does, under the first heading.
    eq(2, api.nvim_win_get_cursor(win)[1])
    has(line(), 'Enter  Resume it in')
    -- Up from the first choice is the last one: it goes round.
    feed('k')
    has(line(), 'Close the board')
    feed('k')
    has(line(), 'Turn notifications')
    feed('j')
    feed('j')
    has(line(), 'Enter  Resume it in')
    -- The top and the bottom are the first choice and the last.
    feed('G')
    has(line(), 'Close the board')
    feed('gg')
    has(line(), 'Enter  Resume it in')
    -- Moving steps over a heading.
    local lines = menu().lines()
    local heading
    for i, l in ipairs(lines) do
      if l:find('Keep track of it', 1, true) then
        heading = i
      end
    end
    api.nvim_win_set_cursor(win, { heading - 1, 2 })
    feed('j')
    eq(heading + 1, api.nvim_win_get_cursor(win)[1])
    feed('k')
    eq(heading - 1, api.nvim_win_get_cursor(win)[1])
    -- Put on a heading some other way (a click, a page key), it goes on to
    -- the choice next to it.
    api.nvim_win_set_cursor(win, { heading, 2 })
    vim.cmd('doautocmd CursorMoved')
    eq(heading + 1, api.nvim_win_get_cursor(win)[1])
    api.nvim_win_set_cursor(win, { 1, 2 })
    vim.cmd('doautocmd CursorMoved')
    eq(2, api.nvim_win_get_cursor(win)[1])
    menu().close()
  end)

  it('lists only what applies', function()
    local home, made = open(function(h)
      local c = chat(h, { title = 'Hosted here', age = 30 })
      local sub = chat(h, { title = 'Has a subagent', age = 90 })
      sub:subagent('aaa111', { agentType = 'Explore', description = 'Find files', finished = true })
      return { c = c, sub = sub }
    end)
    local c = made.c
    local function shown()
      board().menu()
      local text = table.concat(menu().lines(), '\n')
      menu().close()
      return text
    end
    hosted(home, c)
    board().focus()
    board().goto_chat(key(c))
    local idle = shown()
    has(idle, 'Enter  Open: go to its terminal')
    -- What is said to it is typed there: the menu offers no reply.
    hasnt(idle, 'Reply')
    hasnt(idle, 'Queue')

    local pid = store().get(key(c)).pid
    home:registry(pid, { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    -- Queueing has no key of its own: this line is the way to it.
    has(shown(), '\n         Queue a reply for when it finishes its turn')

    home:registry(
      pid,
      { sessionId = c.id, status = 'waiting', waitingFor = 'permission', cwd = vim.uv.cwd() }
    )
    store().refresh_sync({ full = false })
    local asking = shown()
    has(asking, 'Enter  Go to its terminal and answer')
    hasnt(asking, 'Reply')
    state().enqueue(key(c), 'then the docs')
    has(shown(), '\n         Queued replies (1): send, add or drop')

    -- A heading, and a subagent.
    board().goto_chat(key(made.sub))
    board().menu()
    has(table.concat(menu().lines(), '\n'), 'Show its subagents')
    menu().pick('Show its subagents')
    has(list(), 'Explore: Find files')
    for i, row in ipairs(board()._state.rows) do
      if row.chat and row.chat.subagent then
        api.nvim_win_set_cursor(board()._state.win, { i, 1 })
      end
    end
    local sub = shown()
    has(sub, '── This subagent ')
    has(sub, 'Read what this subagent did')
    hasnt(sub, 'Reply')
    hasnt(sub, 'Fork')
    -- Nothing of your own can be put on a subagent.
    hasnt(sub, 'Keep track of it')
    hasnt(sub, 'Rename')
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'group' then
        api.nvim_win_set_cursor(board()._state.win, { i, 1 })
        break
      end
    end
    local heading = shown()
    has(heading, '── This group ')
    has(heading, 'Fold this group')
    has(heading, 'New chat')
    hasnt(heading, 'Reply')
    hasnt(heading, 'Keep track of it')
  end)

  it('acts on the chat of a conversation from inside it', function()
    local _, c = open(function(h)
      chat(h, { title = 'Another one', age = 10 })
      return chat(h, { title = 'The one being read', age = 500 })
    end, { keys = { queue = 'Q' } })
    -- The cursor of the list is on the other chat.
    board().goto_chat(key(c))
    local buf = actions().read(store().get(key(c)))
    api.nvim_win_set_cursor(board()._state.win, { 4, 1 })
    eq(buf, api.nvim_get_current_buf())
    feed('?')
    ok(menu().is_open())
    local shown = table.concat(menu().lines(), '\n')
    has(shown, 'Back to the list')
    hasnt(shown, 'Read the conversation')
    -- In parts here as well: the chat, your marks on it, the conversation,
    -- and what starts or finds another chat. The list's own is on the
    -- list's menu.
    has(shown, '── This chat ')
    has(shown, '── Keep track of it ')
    has(shown, '── This conversation ')
    has(shown, '── Chats ')
    hasnt(shown, 'The board')
    hasnt(shown, 'Group by')
    -- A line chosen here acts on the chat being read.
    local asked
    vim.ui.input = function(opts, cb)
      asked = opts.default
      cb(nil)
    end
    ok(menu().pick('Rename'))
    eq('The one being read', asked)
    feed('?')
    -- So does a key pressed in the menu.
    feed('Q')
    ok(require('agent-chats.ui.input').is_open())
    has(api.nvim_win_get_config(0).title[1][1], 'The one being read')
    require('agent-chats.ui.input').cancel()
    -- And the same key in the conversation does the same.
    api.nvim_set_current_win(board()._state.pane_win)
    feed('Q')
    ok(require('agent-chats.ui.input').is_open())
    has(api.nvim_win_get_config(0).title[1][1], 'The one being read')
  end)

  it('goes away with the board, and when left for another window', function()
    open(function(h)
      chat(h)
    end)
    feed('?')
    ok(menu().is_open())
    api.nvim_set_current_win(board()._state.win)
    vim.wait(50)
    no(menu().is_open())
    feed('?')
    board().close()
    no(menu().is_open())
  end)

  it('says so when a key for a chat is pressed where there is none', function()
    open(function(h)
      chat(h)
    end)
    api.nvim_win_set_cursor(board()._state.win, { 1, 0 })
    local said = notes(function()
      feed('C')
    end)
    has(said, 'Move to a chat first')
    eq(board()._state.win, api.nvim_get_current_win())
  end)
end)

describe('one search', function()
  it('is asked for on one key, narrows as it is typed, and reads the conversations', function()
    local _, deep = open(function(h)
      chat(h, { title = 'Fix the parser' })
      local c =
        chat(h, { title = 'Street layout', prompt = 'Where do people cross?', reply = 'Noted.' })
      c.ts = os.time() - 500
      c:user('And the animals?'):assistant('The zebra crossing is over there.')
      c:user('Thanks'):assistant('You are welcome.'):turn_done():write(os.time() - 400)
      return c
    end)
    -- A name: found from the rows.
    feed('Sparser<CR>')
    eq('parser', board().query())
    has(list(), 'Search “parser”  1 chat')
    has(list(), 'Fix the parser')
    hasnt(list(), 'Street layout')
    -- A passage in the middle of a conversation: found by the same key.
    feed('S<C-u>zebra<CR>')
    T.wait(3000, function()
      local s = board()._state.search
      return s and s.read and not s.running
    end)
    has(list(), 'Search “zebra”  1 chat · 1 passage')
    has(list(), 'zebra crossing')
    eq(key(deep), board()._state.rows[4].chat.key)
    -- The bar says how to end it and how to change it.
    has(bar(), 'q End Search')
    has(bar(), 'S New Search')
    -- Enter on the passage opens the conversation there.
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'hit' then
        api.nvim_win_set_cursor(board()._state.win, { i, 1 })
      end
    end
    board().focus()
    has(bar(), 'Enter Read This Passage')
    feed('<CR>')
    local buf = api.nvim_get_current_buf()
    eq('agent-chats-conversation', vim.bo[buf].filetype)
    T.wait(2000, function()
      return api.nvim_get_current_line():find('zebra', 1, true) ~= nil
    end)
    -- Back to the results, back to all chats, and out.
    feed('q')
    has(list(), 'Search “zebra”')
    feed('q')
    eq('', board().query())
    has(list(), 'Fix the parser')
    feed('q')
    no(board().is_open())
  end)

  it('puts the cursor on the first chat it finds, so that Enter goes into it', function()
    open(function(h)
      chat(h, { title = 'Fix the parser', age = 100 })
      chat(h, { title = 'Write the docs', age = 200 })
      chat(h, { title = 'Docs for the parser', age = 300 })
    end)
    -- From wherever the cursor was: here, a chat the search does not find.
    board().goto_chat('claude:' .. store().list()[1].id)
    feed('Sdocs<CR>')
    local row = board().row()
    eq('chat', row.kind, 'not the heading above it')
    eq('Write the docs', row.chat.title)
    has(bar(), 'Enter Resume')
    -- Changing the search starts from its first result again.
    feed('jS<C-u>parser<CR>')
    eq('Fix the parser', board().row().chat.title)
    -- Ending it leaves the cursor on the chat it was on.
    feed('j')
    board().focus()
    local at = board().row().chat.title
    feed('q')
    eq(at, board().row().chat.title)
  end)

  it('puts back what was there when the question is called off', function()
    open(function(h)
      chat(h, { title = 'Fix the parser' })
      chat(h, { title = 'Write the docs' })
    end)
    feed('Sdocs<CR>')
    has(list(), 'Search “docs”  1 chat')
    -- Typed over, then Esc: the search that was on is still on.
    feed('S<C-u>nothing-like-it<Esc>')
    eq('docs', board().query())
    has(list(), 'Write the docs')
    hasnt(list(), 'Fix the parser')
    -- Emptied and accepted: the search is over.
    feed('S<C-u><CR>')
    eq('', board().query())
    has(list(), 'Fix the parser')
    -- Called off with nothing on before: nothing is on after.
    feed('Sdocs<Esc>')
    eq('', board().query())
    eq(nil, board()._state.search)
  end)

  it('reads the conversations once the typing pauses, and only for what is there then', function()
    open(function(h)
      chat(h, { title = 'Fix the parser', reply = 'Renamed the tokenizer to lexer.' })
    end)
    local search = require('agent-chats.search')
    local real, asked = search.run, {}
    search.run = function(query, cb)
      asked[#asked + 1] = query
      return real(query, cb)
    end
    board().search('tok', { delay = 40 })
    board().search('toke', { delay = 40 })
    board().search('tokenizer', { delay = 40 })
    no(board()._state.search.read, 'nothing is read while the keys still come')
    T.wait(3000, function()
      local s = board()._state.search
      return s and s.read and not s.running
    end)
    search.run = real
    eq({ 'tokenizer' }, asked)
    has(list(), 'Renamed the tokenizer')
    -- Accepting the same text does not read it all again.
    search.run = function(query, cb)
      asked[#asked + 1] = query
      return real(query, cb)
    end
    board().search('tokenizer')
    search.run = real
    eq({ 'tokenizer' }, asked)
  end)

  it('says what it did not look at', function()
    open(function(h)
      chat(h, { title = 'Recent one', age = 3600 })
      chat(h, { title = 'Ancient one about a wombat', age = 90 * 86400 })
    end, { board = { max_age_days = 7 } })
    eq(1, store().older)
    board().search('wombat')
    T.wait(3000, function()
      local s = board()._state.search
      return s and s.read and not s.running
    end)
    has(list(), 'No chat has “wombat” in it.')
    has(list(), '1 chat older than 7 days was not looked at')
  end)

  it('opens the board searched from the command line', function()
    open(function(h)
      chat(h, { title = 'Fix the parser' })
      chat(h, { title = 'Write the docs' })
    end)
    board().close()
    vim.cmd('runtime plugin/agent-chats.lua')
    vim.cmd('Chats search docs')
    ok(board().is_open())
    eq('docs', board().query())
    hasnt(list(), 'Fix the parser')
  end)
end)

describe('going back', function()
  it('treats closing the pane as "back", however it is closed', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    local S = board()._state
    for _, how in ipairs({ 'close', 'quit', 'normal! ZZ' }) do
      local buf = actions().read(store().get(key(c)))
      eq(buf, api.nvim_get_current_buf())
      vim.cmd(how)
      T.wait(1000, function()
        return api.nvim_get_current_win() == S.win and S.pane_win ~= nil
      end, how)
      ok(api.nvim_win_is_valid(S.pane_win), how .. ': the pane is back')
      eq('agent-chats-summary', vim.bo[api.nvim_win_get_buf(S.pane_win)].filetype, how)
      no(api.nvim_buf_is_valid(buf), how .. ': the conversation is gone')
    end

    -- A chat's terminal: closing its window goes back to the list, and the
    -- agent keeps running.
    local _, term = hosted(home, c)
    eq(S.pane_win, api.nvim_get_current_win())
    vim.cmd('close')
    T.wait(1000, function()
      return api.nvim_get_current_win() == S.win and S.pane_win ~= nil
    end)
    ok(api.nvim_buf_is_valid(term), 'the terminal is still there')
    eq(term, api.nvim_win_get_buf(S.pane_win), 'and the pane shows it again')

    -- Closing the summary itself is asking for the pane to go.
    board().goto_chat(key(c))
    api.nvim_set_current_win(S.pane_win)
    api.nvim_win_set_buf(S.pane_win, S.preview_buf)
    S.pane_mode = 'preview'
    vim.cmd('close')
    vim.wait(60)
    eq(nil, S.pane_win)
    no(S.pane_on)
  end)

  it("goes back to the list from a chat's terminal: a key while typing, q otherwise", function()
    local home, c = open(function(h)
      return chat(h)
    end)
    local _, term = hosted(home, c)
    local S = board()._state
    eq(term, api.nvim_get_current_buf())
    -- The pane has no bar of its own: the chat has every line of it. Which
    -- chat it is, the list says, on the row that is marked.
    eq('', pane_bar())
    -- The bar above the list names the key that goes back in the mode the
    -- terminal is in: one while typing, another in its normal mode. They
    -- are the only keys there are in a chat, and all it names.
    eq(' q Back |  ', bar())
    hasnt(bar(), [[<C-\><C-b>]])
    T.typing(function()
      has(bar(), [[<C-\><C-b> Back]])
      hasnt(bar(), 'q Back')
    end)
    has(bar(), 'q Back')
    -- In the terminal's normal mode, q.
    feed('q')
    eq(S.win, api.nvim_get_current_win())
    hasnt(bar(), 'Back')
    -- While typing, the terminal's own key.
    actions().open(store().get(key(c)))
    eq(term, api.nvim_get_current_buf())
    local back = vim.fn.maparg([[<C-\><C-b>]], 't', false, true)
    eq(1, back.buffer)
    has(back.desc, 'back to the list')
    back.callback()
    eq(S.win, api.nvim_get_current_win())
    -- With the board closed, the same keys open it again.
    board().close()
    vim.cmd('enew')
    api.nvim_win_set_buf(0, term)
    feed('q')
    ok(board().is_open())
    eq(board()._state.win, api.nvim_get_current_win())
  end)

  it('titles the terminal again when the cursor goes in with a window command', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    hosted(home, c)
    local S = board()._state
    board().focus()
    hasnt(bar(), 'Back')
    vim.cmd('wincmd l')
    eq(S.pane_win, api.nvim_get_current_win())
    has(bar(), 'q Back')
    T.typing(function()
      has(bar(), [[<C-\><C-b> Back]])
    end)
    vim.cmd('wincmd h')
    vim.wait(30)
    hasnt(bar(), 'Back')
  end)
end)

describe('the summary', function()
  it('shows the first prompt, the last prompt and the last reply, each once', function()
    local _, made = open(function(h)
      local two = chat(h, {
        title = 'Two prompts',
        prompt = 'Rename the tokenizer.',
        reply = 'Renamed.',
        then_prompt = 'And update the docs.',
        then_reply = 'The docs are updated.',
      })
      local one = chat(h, {
        title = 'One prompt',
        prompt = 'Only ever asked this.',
        reply = 'Answered.',
        age = 700,
      })
      return { two = two, one = one }
    end)
    local function count(haystack, needle)
      return select(2, haystack:gsub(vim.pesc(needle), ''))
    end
    board().goto_chat(key(made.two))
    local two = pane()
    local first = two:find('## First prompt', 1, true)
    local last = two:find('## Last prompt', 1, true)
    local reply = two:find('## Last reply', 1, true)
    ok(first and last and reply and first < last and last < reply, two)
    ok(first < two:find('Rename the tokenizer.', 1, true))
    ok(two:find('Rename the tokenizer.', 1, true) < last)
    ok(last < two:find('And update the docs.', 1, true))
    ok(reply < two:find('The docs are updated.', 1, true))
    eq(1, count(two, 'Rename the tokenizer.'))
    eq(1, count(two, 'And update the docs.'))
    hasnt(two, 'Renamed.', 'only the last reply')

    -- First and last are the same prompt: it is there once, under one heading.
    board().goto_chat(key(made.one))
    local one = pane()
    has(one, '## Prompt')
    hasnt(one, '## First prompt')
    hasnt(one, '## Last prompt')
    eq(1, count(one, 'Only ever asked this.'))
    has(one, '## Last reply')
  end)

  it('says first what state the chat is in, then where it is', function()
    local _, made = open(function(h)
      local here = chat(h, { title = 'Folder is here' })
      local gone = chat(h, { title = 'Folder is gone', cwd = '/nonexistent/for/tests', age = 700 })
      local away = chat(h, { title = 'Runs elsewhere', age = 800 })
      h:registry(vim.uv.os_getpid(), {
        sessionId = away.id,
        status = 'waiting',
        waitingFor = 'permission to use Bash',
      })
      return { here = here, gone = gone, away = away }
    end)
    local tilde = vim.fn.fnamemodify(vim.uv.cwd(), ':~')
    local function lines_of(k)
      board().goto_chat(k)
      return vim.split(pane(), '\n', { plain = true })
    end
    -- An ended chat: what Enter does, and in which folder.
    local here = lines_of(key(made.here))
    eq('# Folder is here', here[1])
    has(here[3], '· Ended 10m ago.')
    eq('  Enter resumes it in ' .. tilde .. '.', here[4])
    eq('Folder  ' .. tilde .. ' · main', here[6])
    has(here[7], 'Agent   Claude')
    -- Its folder gone: said twice, where it matters.
    local gone = table.concat(lines_of(key(made.gone)), '\n')
    has(gone, 'Its folder is gone, so it cannot be resumed. Enter reads it.')
    has(gone, 'Folder  /nonexistent/for/tests · main · gone')
    -- Waiting for you, in a terminal that is not ours.
    local away = lines_of(key(made.away))
    eq('● Needs you: permission to use Bash', away[3])
    has(table.concat(away, '\n'), 'It runs outside this Neovim')
    has(table.concat(away, '\n'), "Status  known from the agent's own list of running sessions")
  end)

  it('says when queued replies go, and when they will not', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    state().enqueue(key(c), 'then run the linter')
    board().render()
    board().goto_chat(key(c))
    -- Not open here: nothing can send it by itself.
    has(pane(), 'Queued  1 reply, not sent until you send it')
    has(pane(), '1. then run the linter')
    -- Queueing has no key of its own: the way to it is the menu.
    has(pane(), '? (the menu) sends, adds or drops.')
    hosted(home, c)
    board().focus()
    board().render()
    -- The pane shows the terminal now; the summary's words are asked for directly.
    local text = table.concat(require('agent-chats.ui.preview').lines(store().get(key(c))), '\n')
    has(text, 'Queued  1 reply, sent when the chat finishes its turn')
    state().park(key(c))
    text = table.concat(require('agent-chats.ui.preview').lines(store().get(key(c))), '\n')
    has(text, 'Queued  1 reply, not sent until you send it')
  end)
end)

describe('the first opening', function()
  it('introduces the board once, until the cursor moves', function()
    local _, made = open(function(h)
      local a = chat(h, { title = 'Chat A', age = 10 })
      local b = chat(h, { title = 'Chat B', age = 20 })
      return { a = a, b = b }
    end, { board = { intro = true } })
    eq('', pane_bar())
    local intro = pane()
    has(intro, '# Agent chats')
    has(intro, 'Enter  Open: go into a chat and type')
    has(intro, 'C      Conversation: read the whole of it')
    has(intro, '+      New Chat: pick the agent, and it opens')
    has(intro, 'S      Search: every chat')
    has(intro, 'q      Back')
    has(intro, 'R      Refresh: look for changes now')
    -- A reply is typed in the chat: no key of the list is for it. Nor is
    -- there one for what is done now and then: that is in the menu.
    hasnt(intro, 'Reply')
    hasnt(intro, 'fork')
    hasnt(intro, 'Queue a Reply')
    hasnt(intro, 'Notifications: on or off')
    has(intro, '?      Menu: everything else')
    -- q is the one lowercase key the board has: said, not contradicted.
    has(intro, 'Capital letters act; apart from q, lowercase keys stay what they are.')
    -- The key that is pressed while typing to an agent, where no bar is.
    has(intro, [[<C-\><C-b> comes back to]])
    -- And what the marks on a row are.
    has(intro, '»2 two replies wait to be sent to it')
    has(intro, 'shown once')
    eq(1, state().intro())
    -- A redraw does not take it away; moving does.
    board().render()
    has(pane(), '# Agent chats')
    board().goto_chat(key(made.b))
    has(pane(), '# Chat B')
    board().goto_chat(key(made.a))
    has(pane(), '# Chat A')
    -- Never again.
    board().close()
    board().open()
    has(pane(), '# Chat A')
    hasnt(pane(), 'shown once')
  end)

  it('names only the keys that are bound, and can be switched off', function()
    -- One key is a mapping of yours, one action has been given no key.
    user_map('n', 'S', '<cmd>echo<cr>')
    open(function(h)
      chat(h)
    end, { board = { intro = true }, keys = { new = false, read = 'v' } })
    local intro = pane()
    hasnt(intro, 'S      Search')
    has(intro, '/      Search: every chat')
    hasnt(intro, 'New Chat: pick the agent')
    has(intro, 'v      Conversation: read the whole of it')
    hasnt(intro, 'Capital letters act', 'not true of these keys')
    board().close()

    open(function(h)
      chat(h, { title = 'Fix the parser' })
    end, { board = { intro = false } })
    has(pane(), '# Fix the parser')
    eq(0, state().intro())
  end)
end)

describe("a chat's terminal", function()
  it('is handed to your own setup once, with its buffer and its chat', function()
    local calls, events = {}, {}
    api.nvim_create_autocmd('User', {
      group = api.nvim_create_augroup('AgentChatsTestUser', { clear = true }),
      pattern = 'AgentChatsTerminal',
      callback = function(ev)
        events[#events + 1] = ev.data
      end,
    })
    local home, c = open(function(h)
      return chat(h)
    end, {
      open = {
        on_open = function(buf, opened)
          calls[#calls + 1] = { buf = buf, key = opened and opened.key }
          -- What a user would do here: keys of their own for this terminal.
          vim.keymap.set('t', '<C-h>', [[<C-\><C-n><C-w>h]], { buffer = buf, desc = 'mine' })
          vim.keymap.set('n', 'q', '<cmd>echo "mine"<cr>', { buffer = buf, desc = 'mine' })
        end,
      },
    })
    local _, term = hosted(home, c)
    --- The mapping on `lhs` as the terminal has it.
    local function in_term(lhs, mode)
      return api.nvim_buf_call(term, function()
        return vim.fn.maparg(lhs, mode, false, true)
      end)
    end
    eq({ { buf = term, key = key(c) } }, calls)
    eq(1, #events)
    eq(term, events[1].buf)
    eq(key(c), events[1].key)
    eq(key(c), events[1].chat.key)
    eq('mine', in_term('<C-h>', 't').desc)
    -- Nothing of it is set again, and nothing of yours is overwritten:
    -- not when the list shows the terminal in its pane, not when the
    -- cursor goes back in.
    board().focus()
    board().render()
    actions().open(store().get(key(c)))
    board().focus()
    eq(1, #calls)
    eq(1, #events)
    eq('mine', in_term('<C-h>', 't').desc)
    eq('mine', in_term('q', 'n').desc, 'your q, set last, is the one there')
    -- The way back while typing is still there beside yours.
    eq(1, in_term([[<C-\><C-b>]], 't').buffer)
  end)

  it('leaves a terminal you made yourself as you set it up', function()
    local calls = {}
    local home, c = open(function(h)
      return chat(h)
    end, {
      open = {
        on_open = function(buf)
          calls[#calls + 1] = buf
        end,
      },
    })
    local agent = fake.install(home)
    board().close()
    -- A chat started by hand in a plain terminal.
    vim.cmd('enew')
    local buf = api.nvim_get_current_buf()
    vim.fn.jobstart({ agent.bin, '--resume', c.id }, { term = true })
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(c)).term == buf
    end)
    -- Out of sight, as a terminal that was toggled away is.
    vim.cmd('enew')
    board().open()
    board().goto_chat(key(c))
    board().render()
    -- The board shows it, and gives it the one key that goes back while typing.
    eq(buf, api.nvim_win_get_buf(board()._state.pane_win))
    local function in_term(lhs, mode)
      return api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, mode, false, true)
      end)
    end
    eq(1, in_term([[<C-\><C-b>]], 't').buffer)
    -- Nothing else of it is touched: not its normal-mode keys, and your
    -- setup for chat terminals is not run over a terminal that has yours.
    no(in_term('q', 'n').buffer == 1)
    eq({}, calls)
  end)

  it('binds a way back you chose yourself, whatever is mapped on it', function()
    user_map('t', '<C-g>', '<Nop>')
    user_map('t', [[<C-\><C-b>]], function() end)
    local home, c = open(function(h)
      return chat(h)
    end, { open = { back_key = '<C-g>' } })
    local _, term = hosted(home, c)
    eq(term, api.nvim_get_current_buf())
    eq(1, vim.fn.maparg('<C-g>', 't', false, true).buffer)
    T.typing(function()
      has(bar(), '<C-g> Back')
    end)
    no(vim.fn.maparg([[<C-\><C-b>]], 't', false, true).buffer == 1)
  end)

  it('carries on when your setup fails, and says so once', function()
    local home, c = open(function(h)
      return chat(h)
    end, {
      open = {
        on_open = function()
          error('my setup is broken')
        end,
      },
    })
    local term
    local said = notes(function()
      local _, buf = hosted(home, c)
      term = buf
    end)
    has(said, 'open.on_open failed')
    has(said, 'my setup is broken')
    eq('terminal', vim.bo[term].buftype)
    eq(1, vim.fn.maparg([[<C-\><C-b>]], 't', false, true).buffer, 'its own keys are still set')
    local again = notes(function()
      require('agent-chats.term').prepare(term)
    end)
    eq('', again)
  end)
end)

describe('a new chat', function()
  --- A second agent, so that there is one to choose between.
  local function with_demo()
    require('agent-chats').register({
      name = 'demo',
      label = 'Demo',
      home = function()
        return '/nonexistent'
      end,
      available = function()
        return false
      end,
      discover = function()
        return {}
      end,
      parse = function()
        return nil
      end,
      messages = function()
        return {}, nil
      end,
      resume_cmd = function(c)
        return { 'sh', '-c', 'read _', c.id }
      end,
      new_cmd = function()
        return { 'sh', '-c', 'read _' }
      end,
    })
  end

  it('asks one thing, which agent, and opens that agent to be typed to', function()
    local home = open()
    local agent = fake.install(home)
    local asked, offered
    local restore = answer({
      function(items)
        offered = items
        return items[1]
      end,
    })
    local real = vim.ui.select
    vim.ui.select = function(items, o, cb)
      asked = o.prompt
      return real(items, o, cb)
    end
    feed('+')
    restore()
    -- The question says where the chat will start.
    eq(('New chat in %s. Which agent?'):format(vim.fn.fnamemodify(vim.uv.cwd(), ':~')), asked)
    eq(2, #offered)
    ok(offered[1].agent and offered[1].agent.label == 'Claude')
    ok(offered[2].folder, 'the last line leads to another folder')
    -- No box, no first prompt: its terminal, to be typed in.
    no(require('agent-chats.ui.input').is_open())
    T.wait(3000, function()
      local log = agent.read()
      return log:find('argv: ', 1, true) ~= nil and log:find('cwd: ', 1, true) ~= nil
    end)
    ok(agent.read():match('argv: %-%-session%-id %S+\n'), 'started with a prompt: ' .. agent.read())
    has(agent.read(), 'cwd: ' .. vim.uv.cwd())
    eq('terminal', vim.bo.buftype)
    eq('claude', state().last_agent())
  end)

  it('starts nothing when the question is called off', function()
    local home = open()
    local agent = fake.install(home)
    local restore = answer({})
    feed('+')
    restore()
    vim.wait(100)
    eq('', agent.read())
    eq(board()._state.win, api.nvim_get_current_win())
  end)

  it(
    'puts the agent used last first, and leads to another folder from the same question',
    function()
      local elsewhere = T.tmpdir()
      local home = open(function(h)
        chat(h, { title = 'Works elsewhere', cwd = elsewhere })
      end, { providers = { demo = { cmd = { 'sh' } } } })
      local agent = fake.install(home)
      with_demo()
      local prompts, lists = {}, {}
      local real = vim.ui.select
      local function labels(items)
        local out = {}
        for _, item in ipairs(items) do
          out[#out + 1] = item.agent and item.agent.label or item.label or 'In another folder…'
        end
        return out
      end
      --- Answer the questions that come with `picks` (an index each, or a function).
      local function asking(picks, fn)
        local n = 0
        vim.ui.select = function(items, o, cb)
          n = n + 1
          prompts[#prompts + 1], lists[#lists + 1] = o.prompt, labels(items)
          local pick = picks[n]
          if type(pick) == 'function' then
            return cb(pick(items))
          end
          cb(pick and items[pick] or nil)
        end
        local good, err = pcall(fn)
        vim.ui.select = real
        assert(good, err)
      end
      -- The first time: the agents as they come, then the way to another folder.
      asking({ 3, 2, 2 }, function()
        actions().new({ chat = board().current() })
      end)
      eq({ 'Claude', 'Demo', 'In another folder…' }, lists[1])
      -- Folders: this one, the one the chat under the cursor works in, a new
      -- worktree of the repository this one is in, any other.
      eq('Where should the new chat work?', prompts[2])
      eq(vim.fn.fnamemodify(vim.uv.cwd(), ':~'), lists[2][1])
      eq(vim.fn.fnamemodify(elsewhere, ':~'), lists[2][2])
      eq(
        ('New git worktree of %s…'):format(vim.fn.fnamemodify(vim.uv.cwd(), ':~')),
        lists[2][#lists[2] - 1]
      )
      eq('Another folder…', lists[2][#lists[2]])
      -- Back at the agents, for the folder that was picked.
      eq(('New chat in %s. Which agent?'):format(vim.fn.fnamemodify(elsewhere, ':~')), prompts[3])
      eq('demo', state().last_agent())
      eq('', agent.read(), 'Demo was started, not Claude')

      -- The next time, the agent used last is the first line: Enter picks it.
      board().focus()
      prompts, lists = {}, {}
      asking({ 2 }, function()
        feed('+')
      end)
      eq({ 'Demo', 'Claude', 'In another folder…' }, lists[1])
      T.wait(3000, function()
        return agent.read():find('cwd: ', 1, true) ~= nil
      end)
      has(agent.read(), 'cwd: ' .. vim.uv.cwd())
      -- A folder question that is called off leads back to the agents.
      board().focus()
      prompts, lists = {}, {}
      asking({ 3, false, false }, function()
        feed('+')
      end)
      eq(3, #prompts)
      has(prompts[3], 'Which agent?')
      require('agent-chats.providers').reset()
    end
  )
end)

describe('a menu taller than the screen', function()
  local function footer()
    local f = api.nvim_win_get_config(0).footer
    return f and f[1][1] or ''
  end

  it('says in its footer that there is more of it, and which way', function()
    open(function(h)
      chat(h)
    end)
    local items = {}
    for i = 1, 80 do
      items[i] = { text = ('Choice %d'):format(i), run = function() end }
    end
    local win = menu().open(items, { title = 'Many' })
    ok(api.nvim_win_get_height(win) < 80, 'not all of it fits')
    eq(' ↓ More · Enter Choose · q Close ', footer())
    feed('G')
    vim.wait(30)
    eq(' ↑ More · Enter Choose · q Close ', footer())
    -- Half way back up: the window scrolls to it, and both ends are out of sight.
    api.nvim_win_set_cursor(win, { 20, 2 })
    api.nvim_exec_autocmds('CursorMoved', { buffer = api.nvim_win_get_buf(win) })
    vim.wait(30)
    eq(' ↑↓ More · Enter Choose · q Close ', footer())
    feed('gg')
    vim.wait(30)
    eq(' ↓ More · Enter Choose · q Close ', footer())
    menu().close()
    -- All of it in view: only its keys.
    menu().open({ { text = 'One', run = function() end } }, { title = 'Few' })
    eq(' Enter Choose · q Close ', footer())
  end)

  it('keeps that there is more when there is room for little else', function()
    eq(' ↓ More ', menu().footer('↓', 20))
    eq(' ↑↓ More · Enter Choose · q Close ', menu().footer('↑↓', 40))
    eq(' Enter Choose · q Close ', menu().footer(nil, 10))
  end)
end)

describe('with the mouse, or in a borrowed window', function()
  it('opens a chat on a double click and the menu on a right click, where the click was', function()
    local _, made = open(function(h)
      local a = chat(h, { title = 'Chat A', age = 10 })
      local b = chat(h, { title = 'Chat B', age = 20 })
      return { a = a, b = b }
    end)
    local S = board()._state
    local line_of = {}
    for i, row in ipairs(S.rows) do
      if row.chat then
        line_of[row.chat.title] = i
      end
    end
    eq('Chat A', board().current().title)
    -- Where the mouse is said to be: on the row of the other chat.
    local real = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = S.win, line = line_of['Chat B'], column = 5, winrow = 1, wincol = 5 }
    end
    local good, err = pcall(function()
      feed('<RightMouse>')
      ok(menu().is_open())
      eq('Chat B', board()._state.rows[api.nvim_win_get_cursor(S.win)[1]].chat.title)
      has(api.nvim_win_get_config(0).title[1][1], 'Chat B')
      menu().close()
      feed('<2-LeftMouse>')
    end)
    vim.fn.getmousepos = real
    assert(good, err)
    -- A double click does what Enter does: here, its folder being there, it resumes.
    ok(store().get(key(made.b)))
    eq(S.pane_win, api.nvim_get_current_win())
    -- A click anywhere but on the list does nothing to it.
    board().focus()
    vim.fn.getmousepos = function()
      return { winid = S.pane_win, line = 1, column = 1, winrow = 1, wincol = 1 }
    end
    good, err = pcall(function()
      feed('<RightMouse>')
      no(menu().is_open())
    end)
    vim.fn.getmousepos = real
    assert(good, err)
  end)

  it('gives a borrowed window back with the bar it had', function()
    local home = fx.home({ board = { spinner = false, layout = 'current', pane = false } })
    chat(home)
    store().refresh_sync()
    store().start = function() end
    local win = api.nvim_get_current_win()
    vim.wo[win].winbar = 'my own bar'
    board().open()
    has(vim.wo[win].winbar, 'Menu')
    board().close()
    eq('my own bar', vim.wo[win].winbar)
    vim.wo[win].winbar = ''
  end)
end)

-- What someone found who had only the README and the board to go by, and
-- who then tried to break the keys with odd options and mappings.

local function tc(lhs)
  return api.nvim_replace_termcodes(lhs, true, false, true)
end

--- The mode Neovim is in once it has acted on what is pending. A
--- `:startinsert` only takes effect when Neovim next waits for a key, which
--- a script never does: here a harmless key is run and the mode is read
--- from a timer while Neovim waits for the next one. `then_type` is typed
--- in that mode before it is left again.
local function settled_mode(then_type)
  vim.wait(40)
  local seen
  vim.defer_fn(function()
    seen = api.nvim_get_mode().mode
    api.nvim_feedkeys((then_type or '') .. tc([[<C-\><C-n>]]), 'n', false)
  end, 60)
  -- (Setting a mark: a command that changes nothing that is looked at.)
  api.nvim_feedkeys('mz', 'x!', false)
  T.wait(1000, function()
    return seen ~= nil
  end)
  return seen
end

describe('typing, where it is expected', function()
  it('is on in a new chat as soon as its agent is picked', function()
    local home = open()
    local agent = fake.install(home)
    local restore = answer({ 1 })
    feed('+')
    restore()
    eq('terminal', vim.bo.buftype)
    -- What is typed next reaches the agent.
    eq('t', settled_mode())
    T.wait(3000, function()
      return agent.read():find('argv: ', 1, true) ~= nil
    end)
  end)

  it('opens a reply that was kept ready to go on', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    fake.install(home)
    local input = require('agent-chats.ui.input')
    actions().queue(store().get(key(c)))
    api.nvim_buf_set_lines(0, 0, -1, false, { 'first line', 'and then' })
    input.cancel()
    actions().queue(store().get(key(c)))
    eq('first line\nand then', T.buf_text(api.nvim_get_current_buf()))
    eq('i', settled_mode(' this'))
    eq('first line\nand then this', T.buf_text(api.nvim_get_current_buf()))
    input.cancel()
  end)
end)

describe('the list is shown once', function()
  local function lists()
    local S = board()._state
    local n = 0
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == S.buf then
        n = n + 1
      end
    end
    return { n, #api.nvim_tabpage_list_wins(0) }
  end

  it('whatever runs :windo or :tabdo from it', function()
    open(function(h)
      chat(h)
    end)
    local S = board()._state
    eq(S.win, api.nvim_get_current_win())
    -- What netrw does as Neovim starts, and plenty of others later: Neovim
    -- splits a window that is fixed to its buffer if it has no other to go to.
    vim.cmd('windo let g:agent_chats_seen = 1')
    eq({ 1, 2 }, lists())
    board().focus()
    vim.cmd('tabdo let g:agent_chats_seen = 2')
    eq({ 1, 2 }, lists())
    -- The same when the pane was closed and has come back.
    board().toggle_pane()
    board().toggle_pane()
    board().focus()
    vim.cmd('windo let g:agent_chats_seen = 3')
    eq({ 1, 2 }, lists())
    -- And after a visit to the pane.
    board().focus()
    vim.cmd('wincmd l')
    vim.cmd('wincmd h')
    vim.cmd('windo let g:agent_chats_seen = 4')
    eq({ 1, 2 }, lists())
  end)
end)

describe('keys: what changes while the board is open', function()
  it('gives a key back to a mapping made since, when the list next has the cursor', function()
    open(function(h)
      chat(h)
    end)
    eq(1, vim.fn.maparg('C', 'n', false, true).buffer)
    has(bar(), 'C Conversation')
    -- A plugin loads late and maps C.
    local pressed = 0
    user_map('n', 'C', function()
      pressed = pressed + 1
    end, { desc = 'made later' })
    vim.cmd('wincmd l')
    vim.cmd('wincmd h')
    vim.wait(30)
    no(vim.fn.maparg('C', 'n', false, true).buffer == 1)
    hasnt(bar(), 'C Conversation')
    feed('C')
    eq(1, pressed)
    eq(board()._state.win, api.nvim_get_current_win(), 'no conversation was opened')
    -- And takes the key again when that mapping is gone.
    vim.keymap.del('n', 'C')
    board().focus()
    eq(1, vim.fn.maparg('C', 'n', false, true).buffer)
    has(bar(), 'C Conversation')
  end)

  it('takes its keys from the options again when setup() is called with it open', function()
    open(function(h)
      chat(h)
    end)
    local opts = vim.deepcopy(require('agent-chats.config').get())
    opts.keys = { read = 'x' }
    require('agent-chats.config').setup(opts)
    eq(1, vim.fn.maparg('x', 'n', false, true).buffer)
    no(vim.fn.maparg('C', 'n', false, true).buffer == 1)
    has(bar(), 'x Conversation')
    hasnt(bar(), 'C Conversation')
  end)

  it('leaves a mapping of yours alone whatever its description says', function()
    user_map('n', 'C', function() end, { desc = 'Agent chats: my own key' })
    open(function(h)
      chat(h)
    end)
    no(vim.fn.maparg('C', 'n', false, true).buffer == 1)
    eq(nil, keys().key('read'))
  end)
end)

describe('keys: one key, one action', function()
  it('gives a key you name to that action alone, here and in a conversation', function()
    local c
    local said = notes(function()
      local _, made = open(function(h)
        return chat(h)
      end, { keys = { archive = 'C' } })
      c = made
    end)
    has(said, 'keys.archive is on C, which "read" has by default: "read" has no key now')
    has(vim.fn.maparg('C', 'n', false, true).desc, 'archive the chat')
    eq(nil, keys().key('read'))
    hasnt(bar(), 'Conversation')
    -- The menu lists the action without a key: there is none that picks it.
    feed('?')
    local read
    for _, line in ipairs(menu().lines()) do
      if line:find('Read the conversation', 1, true) then
        read = line
      end
    end
    ok(read and read:match('^%s+Read'), vim.inspect(read))
    hasnt(table.concat(menu().lines(), '\n'), '*')
    menu().close()
    -- In a conversation too, where a default used to win.
    actions().read(store().get(key(c)))
    has(vim.fn.maparg('C', 'n', false, true).desc, 'archive the chat')
  end)

  it('knows two spellings of a key for the same key', function()
    local said = notes(function()
      open(function(h)
        chat(h)
      end, { keys = { pin = '<cr>', archive = '<CR>' } })
    end)
    has(said, 'keys.archive and keys.pin are both on <cr>; it does "archive"')
    has(said, 'which "open" has by default')
    has(vim.fn.maparg('<CR>', 'n', false, true).desc, 'archive the chat')
    eq(nil, keys().key('pin'))
    eq(nil, keys().key('open'))
    hasnt(bar(), 'Enter Resume')
    has(bar(), 'Enter Archive')
  end)

  it('says once, of an old and a new name both given, which is read', function()
    local said = notes(function()
      open(function(h)
        chat(h)
      end, { keys = { transcript = 'x', read = 'y' } })
    end)
    has(said, 'keys.transcript is now keys.read, which is set as well: keys.transcript is ignored')
    eq('y', keys().key('read'))
  end)
end)

describe('options that are not what they should be', function()
  it('are said, and never stop the board from opening', function()
    local long = string.rep('x', 60)
    local cases = {
      { { keys = false }, 'keys must be a table of options' },
      { { keys = 'x' }, 'keys must be a table of options' },
      { { board = 3 }, 'board must be a table of options' },
      { { open = 'pane' }, 'open must be a table of options' },
      {
        { keys = { queue = { [2] = 'q' } } },
        'keys.queue must be a key, a list of keys, or false',
      },
      { { keys = { queue = { a = 'x' } } }, 'keys.queue must be a key, a list of keys, or false' },
      { { keys = { queue = 7 } }, 'keys.queue must be a key, a list of keys, or false' },
      { { open = { back_key = 42 } }, 'open.back_key must be a key or false' },
      { { keys = { queue = long } }, long .. ' cannot be mapped' },
      -- A key for something that was taken out: said, and nothing else.
      { { keys = { reply = 'R' } }, 'keys.reply is gone: Enter goes into the chat' },
      { { keys = { fork = 'F' } }, 'keys.fork is gone' },
      { { keys = { pass = 'P' } }, 'keys.pass is gone: passing a chat on' },
    }
    for _, case in ipairs(cases) do
      local said = notes(function()
        open(function(h)
          chat(h)
        end, case[1])
      end)
      ok(board().is_open(), vim.inspect(case[1]))
      has(said, case[2])
      has(list(), 'Fix the parser', vim.inspect(case[1]))
      board().close()
    end
  end)

  it('takes a key option it cannot read for "no key", and says which', function()
    local said = notes(function()
      open(function(h)
        chat(h)
      end, { keys = { new = { [2] = 'q' }, read = { x = 'C' } } })
    end)
    has(said, 'keys.new must be a key, a list of keys, or false; { [2] = "q" } is none of these')
    has(said, 'so the action has no key')
    eq(nil, keys().key('new'))
    eq(nil, keys().key('read'))
    -- The rest is as it was, and nothing is out of reach: the menu lists both.
    has(bar(), 'Enter Resume')
    feed('?')
    local shown = table.concat(menu().lines(), '\n')
    has(shown, 'New chat')
    has(shown, 'Read the conversation')
  end)

  it('keeps a key that Neovim will not take off the screen', function()
    local long = string.rep('x', 60)
    notes(function()
      open(function(h)
        chat(h)
      end, { keys = { read = long } })
    end)
    hasnt(bar(), long)
    hasnt(bar(), 'Conversation')
  end)
end)

describe("a chat's terminal: the way back, again", function()
  it('binds the way back you name although it is the default, and mapped', function()
    user_map('t', [[<C-\><C-b>]], function() end)
    local home, c = open(function(h)
      return chat(h)
    end, { open = { back_key = [[<C-\><C-b>]] } })
    local _, term = hosted(home, c)
    eq(term, api.nvim_get_current_buf())
    eq(1, vim.fn.maparg([[<C-\><C-b>]], 't', false, true).buffer)
  end)

  it('does not name a key that your setup has put something else on', function()
    local home, c = open(function(h)
      return chat(h)
    end, {
      open = {
        on_open = function(buf)
          vim.keymap.set('n', 'q', function() end, { buffer = buf })
          vim.keymap.set('t', [[<C-\><C-b>]], function() end, { buffer = buf })
        end,
      },
    })
    hosted(home, c)
    -- Closing the window still goes back, and that is what it says.
    has(bar(), ' :q Back |')
    T.typing(function()
      has(bar(), [[<C-\><C-n> then :q Back]])
    end)
  end)

  it('names the keys your setup says go back', function()
    local home, c = open(function(h)
      return chat(h)
    end, {
      open = {
        on_open = function(buf)
          vim.keymap.set('n', 'q', function()
            require('agent-chats').open()
          end, { buffer = buf })
          vim.keymap.set('t', '<C-x>', function()
            require('agent-chats').open()
          end, { buffer = buf })
          return { back = 'q', back_typing = '<C-x>' }
        end,
      },
    })
    hosted(home, c)
    has(bar(), ' q Back |')
    T.typing(function()
      has(bar(), ' <C-x> Back |')
    end)
    feed('q')
    eq(board()._state.win, api.nvim_get_current_win())
  end)

  it('names it on the bar above the list, however narrow that is', function()
    local home, c = open(function(h)
      return chat(h, { title = 'A chat with a name that goes on for quite a while' })
    end)
    hosted(home, c)
    local S = board()._state
    for _, width in ipairs({ 60, 44, 30, 12 }) do
      api.nvim_win_set_width(S.win, width)
      board().pane_entered(api.nvim_win_get_buf(S.pane_win))
      has(bar(), ' q Back ')
      eq('', pane_bar())
    end
  end)
end)

describe('the menu: its own keys, and where it is opened from', function()
  it("names a key that is the menu's own after the words, and keeps the key", function()
    local _, c = open(function(h)
      return chat(h)
    end)
    feed('?')
    has(table.concat(menu().lines(), '\n'), 'Close the board (q)')
    -- q closes the menu, as its footer says; not the board.
    feed('q')
    no(menu().is_open())
    ok(board().is_open())
    ok(store().get(key(c)))
  end)

  it('puts a key of your own for that in the column, where it acts', function()
    open(function(h)
      chat(h)
    end, { keys = { back = 'X' } })
    feed('?')
    local shown = table.concat(menu().lines(), '\n')
    has(shown, 'X      Close the board')
    feed('X')
    no(menu().is_open())
    no(board().is_open())
  end)

  it('starts on the line Enter stands beside', function()
    open(function(h)
      chat(h)
    end)
    feed('?')
    has(menu().lines()[api.nvim_win_get_cursor(0)[1]], 'Enter  Resume it in')
    menu().close()
    -- On a group, that is folding it.
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'group' then
        api.nvim_win_set_cursor(board()._state.win, { i, 1 })
        break
      end
    end
    feed('?')
    has(menu().lines()[api.nvim_win_get_cursor(0)[1]], 'Enter  Fold this group')
    feed('<CR>')
    hasnt(list(), 'Fix the parser')
  end)

  it('lists the diff with the chat, where its folder is there', function()
    local _, made = open(function(h)
      local here = chat(h)
      local gone = chat(h, { title = 'Folder is gone', cwd = '/nonexistent/for/tests', age = 700 })
      return { here = here, gone = gone }
    end)
    board().goto_chat(key(made.here))
    feed('?')
    local lines = menu().lines()
    local diff, marks
    for i, l in ipairs(lines) do
      if l:find('Show what changed in its folder', 1, true) then
        diff = i
      elseif l:find('Keep track of it', 1, true) then
        marks = i
      end
    end
    -- Under the chat, not among your own marks on it.
    ok(diff and marks and diff < marks, vim.inspect(lines))
    menu().close()
    board().goto_chat(key(made.gone))
    feed('?')
    hasnt(table.concat(menu().lines(), '\n'), 'Show what changed')
  end)

  it('lists, from a conversation, the keys that work in the conversation', function()
    local _, c = open(function(h)
      return chat(h)
    end)
    actions().read(store().get(key(c)))
    -- What has a key on the list has it here.
    for _, lhs in ipairs({ '+', 'S', 'q', '?' }) do
      eq(1, vim.fn.maparg(lhs, 'n', false, true).buffer, lhs)
    end
    -- No key replies or forks here either, and what has no key on the
    -- list has none here.
    for _, lhs in ipairs({ 'R', 'F', 'Q', 'P', 'M' }) do
      eq('', vim.fn.maparg(lhs, 'n'), lhs)
    end
    feed('?')
    local shown = table.concat(menu().lines(), '\n')
    has(shown, 'Back to the list (q)')
    hasnt(shown, 'Reply')
    hasnt(shown, 'Fork')
    has(shown, '+    New chat')
    has(shown, 'S    Search chats')
    -- And what moves in the conversation itself, which its title names
    -- only where there is room.
    has(shown, ']]   Go to the next prompt')
    has(shown, '[[   Go to the prompt before')
    has(shown, 'Tab  Open or close the tool call under the cursor')
    -- Enter does not open a chat from here, so it is not put beside that.
    hasnt(shown, 'Enter')
    -- What is about the list as a whole is on the list's own menu.
    hasnt(shown, 'The board')
    hasnt(shown, 'Turn notifications')
    -- The cursor starts on the first choice: there is none Enter stands beside.
    eq(2, api.nvim_win_get_cursor(0)[1])
    has(api.nvim_get_current_line(), 'Back to the list')
    -- A key shown here acts here.
    local restore = answer({})
    feed('+')
    restore()
    no(menu().is_open())
  end)
end)

describe('a chat that is open here', function()
  it('is listed as open from the moment its terminal is there', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    fake.install(home)
    -- An agent that never registers itself: no look at the processes will
    -- find this chat running.
    require('agent-chats.config').get().providers.claude.cmd = { 'sh', '-c', 'sleep 30' }
    eq('ended', store().get(key(c)).status)
    local buf = actions().open(store().get(key(c)))
    store().refresh_sync({ full = false })
    local now = store().get(key(c))
    ok(not now.live, 'nothing has seen its process')
    eq('idle', now.status)
    board().focus()
    hasnt(list(), 'Ended')
    has(list(), 'Idle  1')
    -- When its terminal is gone, it has ended.
    vim.fn.jobstop(vim.bo[buf].channel)
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return store().get(key(c)).status == 'ended'
    end)
  end)
end)

describe('the cursor in the list', function()
  local function moved_to(line)
    local S = board()._state
    api.nvim_win_set_cursor(S.win, { line, 0 })
    api.nvim_exec_autocmds('CursorMoved', { buffer = S.buf })
    return api.nvim_win_get_cursor(S.win)[1]
  end

  it('passes over the lines that stand for nothing, the way it was going', function()
    local home = open(function(h)
      chat(h, { title = 'Ended one', age = 100 })
      chat(h, { title = 'Ended two', age = 200 })
    end)
    local waiting = chat(home, { title = 'Waits for you', age = 5 })
    home:registry(vim.uv.os_getpid(), { sessionId = waiting.id, status = 'waiting' })
    store().refresh_sync()
    board().focus()
    local S = board()._state
    local kinds = {}
    for i, row in ipairs(S.rows) do
      kinds[i] = row.kind
    end
    -- header, blank, group, chat, blank, group, chat, chat, blank
    eq({ 'header', 'blank', 'group', 'chat', 'blank', 'group', 'chat', 'chat', 'blank' }, kinds)
    -- Down from the last chat of a group onto the gap: the next heading.
    eq(4, moved_to(4))
    eq(6, moved_to(5))
    -- Up from that heading onto the gap: the chat above.
    eq(4, moved_to(5))
    -- gg and G: the first and the last line that can be acted on.
    eq(3, moved_to(1))
    eq(8, moved_to(9))
    -- The bar is about a row at every stop.
    board().render()
    has(bar(), 'Enter')
  end)

  it('stays with the chat when a search is ended from a passage it found', function()
    local _, deep = open(function(h)
      chat(h, { title = 'Fix the parser' })
      local c =
        chat(h, { title = 'Street layout', prompt = 'Where do people cross?', reply = 'Noted.' })
      c.ts = os.time() - 500
      c:user('And the animals?'):assistant('The zebra crossing is over there.')
      c:user('Thanks'):assistant('You are welcome.'):turn_done():write(os.time() - 400)
      return c
    end)
    feed('Szebra<CR>')
    T.wait(3000, function()
      return list():find('zebra crossing', 1, true) ~= nil and not board()._state.search.running
    end)
    local S = board()._state
    for i, row in ipairs(S.rows) do
      if row.kind == 'hit' then
        api.nvim_win_set_cursor(S.win, { i, 1 })
        break
      end
    end
    eq('hit', board().row().kind)
    feed('q')
    eq(nil, S.search)
    eq('chat', board().row().kind)
    eq(key(deep), board().row().chat.key)
  end)
end)

describe('a chat started from the board', function()
  it('has a row from the start, and the cursor on it', function()
    local home = open(function(h)
      chat(h, { title = 'An older chat' })
    end)
    fake.install(home)
    eq('An older chat', board().row().chat.title)
    local restore = answer({ 1 })
    feed('+')
    restore()
    eq('terminal', vim.bo.buftype)
    local term = api.nvim_get_current_buf()
    has(bar(), 'Back')
    local row
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local S = board()._state
      row = S.rows[api.nvim_win_get_cursor(S.win)[1]]
      return row and row.chat and row.chat.term == term
    end)
    -- Nothing has been said to it yet: its row has no prompt to show.
    eq(nil, row.chat.first_prompt)
    -- Back lands on it: the pane shows that terminal, not another chat.
    feed('q')
    eq(board()._state.win, api.nvim_get_current_win())
    eq(term, api.nvim_win_get_buf(board()._state.pane_win))
  end)

  it('is called by the prompt it was started with, where it was given one', function()
    local home = open(function(h)
      chat(h, { title = 'An older chat' })
    end)
    fake.install(home)
    -- (As a script starts one.)
    actions().new({ provider = 'claude', prompt = 'build the thing' })
    eq('terminal', vim.bo.buftype)
    local term = api.nvim_get_current_buf()
    -- Its terminal is called by the prompt from the first moment.
    has(api.nvim_buf_get_name(term), 'build the thing')
    local row
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      local S = board()._state
      row = S.rows[api.nvim_win_get_cursor(S.win)[1]]
      return row and row.chat and row.chat.term == term
    end)
    -- Before its agent has written a word: the prompt it was given.
    eq('build the thing', require('agent-chats.display').title(row.chat))
    hasnt(list(), '(no prompt yet)')
  end)

  it('leaves the cursor where it was put since, when the new row comes', function()
    local home = open(function(h)
      chat(h, { title = 'An older chat', age = 100 })
      chat(h, { title = 'Another one', age = 200 })
    end)
    fake.install(home)
    actions().new({ provider = 'claude', prompt = 'build the thing' })
    -- Back at once, and on to another row, before the new chat has one.
    board().focus()
    local S = board()._state
    for i, r in ipairs(S.rows) do
      if r.chat and r.chat.title == 'Another one' then
        api.nvim_win_set_cursor(S.win, { i, 1 })
      end
    end
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return list():find('build the thing', 1, true) ~= nil
    end)
    eq('Another one', board().row().chat.title)
  end)
end)

describe('another folder for a new chat', function()
  --- Ask for a new chat in `dir`, go on to "in another folder", and there
  --- pick what `folder(items)` returns. What was offered and asked comes back.
  local function folders(dir, folder)
    local seen = { prompts = {} }
    local real_select, real_input = vim.ui.select, vim.ui.input
    local n = 0
    vim.ui.select = function(items, o, cb)
      n = n + 1
      seen.prompts[n] = o.prompt
      if n == 1 then
        return cb(items[#items])
      elseif n == 2 then
        seen.offered = items
        return cb(folder(items))
      end
      cb(nil)
    end
    vim.ui.input = function(o, cb)
      seen.asked, seen.default = o.prompt, o.default
      cb(nil)
    end
    local good, err = pcall(function()
      actions().new({ cwd = dir })
      T.wait(3000, function()
        return seen.asked ~= nil
      end)
    end)
    vim.ui.select, vim.ui.input = real_select, real_input
    assert(good, err)
    return seen
  end

  it('offers a new worktree of the repository the folder is in', function()
    local elsewhere = T.tmpdir()
    vim.fn.system({ 'git', '-C', elsewhere, 'init', '-q' })
    local home = open()
    fake.install(home)
    local seen = folders(elsewhere, function(items)
      for _, item in ipairs(items) do
        if item.worktree then
          return item
        end
      end
    end)
    -- Not the folder Neovim is in: the one the question named.
    has(seen.prompts[1], vim.fn.fnamemodify(elsewhere, ':~'))
    eq(vim.fn.fnamemodify(elsewhere, ':~'), seen.offered[1].label)
    eq(
      ('New git worktree of %s…'):format(vim.fn.fnamemodify(elsewhere, ':~')),
      seen.offered[#seen.offered - 1].label
    )
    has(seen.asked, ('New branch and worktree of %s'):format(vim.fs.basename(elsewhere)))
  end)

  it('starts "another folder" from the folder the question named', function()
    local elsewhere = T.tmpdir()
    local home = open()
    fake.install(home)
    local seen = folders(elsewhere, function(items)
      return items[#items]
    end)
    eq(elsewhere .. '/', seen.default)
  end)
end)

describe('queueing, again', function()
  it('says before the box that nothing can be sent to a chat whose folder is gone', function()
    local _, c = open(function(h)
      return chat(h, { title = 'Folder gone', cwd = '/nonexistent/for/tests' })
    end)
    local input = require('agent-chats.ui.input')
    local said = notes(function()
      actions().queue(store().get(key(c)))
    end)
    no(input.is_open())
    has(said, 'is gone (/nonexistent/for/tests), so it cannot be resumed')
    actions().read(store().get(key(c)))
    has(bar(), 'q Back')
  end)

  it('only offers to drop what is queued for a chat that runs somewhere else', function()
    local _, c = open(function(h)
      local away = chat(h, { title = 'Runs elsewhere' })
      h:registry(vim.uv.os_getpid(), { sessionId = away.id, status = 'idle', cwd = vim.uv.cwd() })
      return away
    end)
    state().enqueue(key(c), 'left from before')
    board().render()
    local offered, prompt
    local real = vim.ui.select
    vim.ui.select = function(items, o, cb)
      offered, prompt = items, o.prompt
      cb(nil)
    end
    actions().queue(store().get(key(c)))
    vim.ui.select = real
    eq({ 'drop_all' }, offered)
    has(prompt, 'It runs outside this Neovim, so nothing can be sent to it from here')
    -- The summary says the same of it.
    has(pane(), 'Queued  1 reply, not sent: nothing can send it to this chat from here')
    has(pane(), '? (the menu) drops it.')
  end)

  it('says in the title of the box whether the reply goes now or waits for the turn', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    local _, term = hosted(home, c)
    board().focus()
    local function title()
      return api.nvim_win_get_config(0).title[1][1]
    end
    local input = require('agent-chats.ui.input')
    -- Free, nothing ahead: it goes at once.
    actions().queue(store().get(key(c)))
    has(title(), 'Reply now (it is not busy): ')
    input.cancel()
    -- Busy: it waits for the turn.
    home:registry(
      store().get(key(c)).pid,
      { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() }
    )
    store().refresh_sync({ full = false })
    board().focus()
    actions().queue(store().get(key(c)))
    has(title(), 'Reply when it finishes its turn: ')
    input.cancel()
    ok(api.nvim_buf_is_valid(term))
  end)
end)

describe('one search, again', function()
  it('names the keys of the prompt while the text is being typed', function()
    open(function(h)
      chat(h, { title = 'Fix the parser' })
    end)
    local during
    local group = api.nvim_create_augroup('AgentChatsTestUser', { clear = true })
    api.nvim_create_autocmd('CmdlineChanged', {
      group = group,
      callback = function()
        vim.schedule(function() end)
        during = bar()
      end,
    })
    feed('Sparser<CR>')
    -- While it was typed: Enter and Esc, which are what count at a prompt.
    has(during, 'Enter Keep Search')
    has(during, 'Esc Cancel')
    hasnt(during, 'End Search')
    hasnt(during, 'Menu')
    -- Once it is kept: the board's own keys again.
    has(bar(), 'q End Search')
    has(bar(), 'S New Search')
    hasnt(bar(), 'Enter Keep Search')
  end)

  it('marks in a row what was searched for, also when it is in the folder', function()
    local dir = T.tmpdir() .. '/zebra-crossing'
    vim.fn.mkdir(dir, 'p')
    open(function(h)
      chat(h, { title = 'Fix the parser', cwd = dir })
      chat(h, { title = 'Something else' })
    end)
    feed('Szebra<CR>')
    has(list(), 'Fix the parser')
    hasnt(list(), 'Something else')
    local S = board()._state
    local ns = api.nvim_get_namespaces()['agent-chats-board']
    local marked = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(S.buf, ns, 0, -1, { details = true })) do
      if m[4].hl_group == 'AgentChatsMatch' then
        local line = api.nvim_buf_get_lines(S.buf, m[2], m[2] + 1, false)[1]
        marked[#marked + 1] = line:sub(m[3] + 1, m[4].end_col)
      end
    end
    eq({ 'zebra' }, marked)
  end)

  it('keeps the key that changes the search as the list narrows', function()
    open(function(h)
      chat(h, { title = 'Fix the parser' })
    end)
    feed('Sparser<CR>')
    T.wait(3000, function()
      return not board()._state.search.running
    end)
    local S = board()._state
    local function at(width)
      api.nvim_win_set_width(S.win, width)
      board().render()
      return api.nvim_buf_get_lines(S.buf, 0, 1, false)[1], bar()
    end
    local function keys_at(width)
      return (select(2, at(width)))
    end
    has(at(80), 'Search “parser”  1 chat · 2 passages')
    has(keys_at(80), 'q End Search  S New Search  ? Menu')
    -- Narrower: words go before a key does.
    has(keys_at(62), 'q End  S New Search  ? Menu')
    has(at(44), 'Search “parser”  1 chat · 2 passages')
    hasnt(at(30), 'Search “')
    has(at(30), '“parser”  1 chat')
    -- Then the key that changes it, and last the one that ends it.
    has(keys_at(48), 'Enter Resume | q End  S New Search  ? Menu')
    has(keys_at(36), 'q End  ? Menu')
    hasnt(keys_at(36), 'S New Search')
    hasnt(keys_at(24), 'q End')
    has(keys_at(24), '? Menu')
    for _, width in ipairs({ 80, 66, 56, 40, 36, 24 }) do
      local line, keys_ = at(width)
      ok(vim.fn.strdisplaywidth(line) <= width, ('%d: %s'):format(width, line))
      local shown = keys_:gsub(' | ', '  ')
      ok(vim.fn.strdisplaywidth(shown) <= width, ('%d: %s'):format(width, shown))
    end
  end)
end)

describe('a conversation, again', function()
  it('opens and closes a tool call with the keys that fold on the list', function()
    local _, c = open(function(h)
      local made = h:chat({ cwd = vim.uv.cwd(), branch = 'main', start = os.time() - 700 })
      made:user('Run the tests'):title('Run the tests')
      made:tool_use('Bash', { command = 'make test' })
      made:tool_result('line one\nline two\nline three\n3 passed')
      made:assistant('They pass.'):turn_done()
      return made:write(os.time() - 600)
    end)
    local buf = actions().read(store().get(key(c)))
    T.wait(3000, function()
      return T.buf_text(buf):find('They pass.', 1, true) ~= nil
    end)
    local win = api.nvim_get_current_win()
    local call
    for i = 1, api.nvim_buf_line_count(buf) do
      if vim.fn.foldclosed(i) == i then
        call = i
        break
      end
    end
    ok(call, 'a tool call is folded')
    -- Its own line says how to open it.
    api.nvim_win_set_cursor(win, { call, 0 })
    has(vim.fn.foldtextresult(call), 'Tab opens them')
    feed('<Tab>')
    eq(-1, vim.fn.foldclosed(call))
    feed('<CR>')
    eq(call, vim.fn.foldclosed(call))
    -- Anywhere else Enter is what it is in any buffer: the next line.
    api.nvim_win_set_cursor(win, { 1, 0 })
    feed('<CR>')
    eq(2, api.nvim_win_get_cursor(win)[1])
  end)
end)

describe(':checkhealth, again', function()
  it(
    'speaks of the keys as the open board has them, and says where each action is instead',
    function()
      open(function(h)
        chat(h)
      end)
      local S = board()._state
      -- A mapping on the list's own buffer (a FileType autocommand of yours).
      vim.keymap.set('n', 'C', function() end, { buffer = S.buf, desc = 'my C here' })
      user_map('n', ']]', function() end)
      user_map('n', 'J', function() end)
      board().focus()
      local health = {}
      for _, line in ipairs(require('agent-chats.health').keys()) do
        health[#health + 1] = line.text
      end
      local report = table.concat(health, '\n')
      has(report, 'C is yours (my C here), so the board does not take it for "read"')
      has(report, '"read": that is in the menu, and has no key')
      -- What is done in a conversation is in the menu there, not the list's.
      has(report, '"next_prompt": that is in the menu of a conversation, and has no key')
    end
  )
end)

describe('every status heading', function()
  it('says what it means, or none does', function()
    local home = open(function(h)
      chat(h, { title = 'Ended one', age = 100 })
    end)
    local busy = chat(home, { title = 'Busy one', age = 5 })
    home:registry(vim.uv.os_getpid(), { sessionId = busy.id, status = 'busy' })
    store().refresh_sync()
    board().render()
    has(list(), 'Working  1   in the middle of a turn')
    has(list(), 'Ended  1   not open, can be resumed')
  end)
end)

describe('every status heading, on a narrow list', function()
  it('is explained in fewer words, and all of them or none', function()
    local home = open(function(h)
      chat(h, { title = 'Ended one', age = 100 })
    end)
    local busy = chat(home, { title = 'Busy one', age = 5 })
    home:registry(vim.uv.os_getpid(), { sessionId = busy.id, status = 'busy' })
    -- A second chat that runs needs a second process.
    local job = vim.fn.jobstart({ 'sleep', '30' })
    local asking = chat(home, { title = 'Asking one', age = 6 })
    home:registry(vim.fn.jobpid(job), { sessionId = asking.id, status = 'waiting' })
    store().refresh_sync()
    local S = board()._state
    local function at(width)
      api.nvim_win_set_width(S.win, width)
      board().render()
      return list()
    end
    has(at(80), 'Needs you  1   waiting for your answer')
    has(at(80), 'Ended  1   not open, can be resumed')
    -- Narrower: the short forms, for every heading.
    has(at(39), 'Needs you  1   waits for your answer')
    has(at(39), 'Working  1   mid-turn')
    has(at(39), 'Ended  1   not open, resumable')
    hasnt(at(39), 'can be resumed')
    -- Where one of them does not fit, none is there.
    hasnt(at(30), 'resumable')
    hasnt(at(30), 'mid-turn')
    hasnt(at(30), 'waits for')
    vim.fn.jobstop(job)
  end)
end)

describe('keys: a mapping of yours made while the cursor is on the list', function()
  it('has its key from the first press, without the cursor leaving the list', function()
    open(function(h)
      chat(h)
    end)
    eq(1, vim.fn.maparg('S', 'n', false, true).buffer)
    -- A plugin loads late and maps S. Nothing else happens: no window is
    -- entered, the cursor does not move.
    local pressed = 0
    user_map('n', 'S', function()
      pressed = pressed + 1
    end, { desc = 'made a moment ago' })
    feed('S')
    eq(1, pressed, 'your mapping ran')
    eq(nil, board()._state.search, 'and the board did not search')
    no(vim.fn.maparg('S', 'n', false, true).buffer == 1)
    -- What the screen says follows: the other key of the action is named.
    vim.wait(30)
    eq('/', keys().key('search'))
    has(bar(), '/ Search')
    feed('S')
    eq(2, pressed)
  end)

  it('keeps a key you named in the options, whatever is mapped on it later', function()
    open(function(h)
      chat(h)
    end, { keys = { search = 'S' } })
    local pressed = 0
    user_map('n', 'S', function()
      pressed = pressed + 1
    end)
    local restore = answer(nil, {})
    feed('Sparser<CR>')
    restore()
    eq(0, pressed)
    eq('parser', board().query())
  end)

  it('gives way in a conversation as well', function()
    local _, c = open(function(h)
      return chat(h)
    end)
    actions().read(store().get(key(c)))
    eq(1, vim.fn.maparg('+', 'n', false, true).buffer)
    local pressed = 0
    user_map('n', '+', function()
      pressed = pressed + 1
    end)
    -- (A new chat would ask which agent, and a question nobody answers
    -- fails the test.)
    feed('+')
    eq(1, pressed)
    no(vim.fn.maparg('+', 'n', false, true).buffer == 1)
  end)
end)

describe('the menu: a key you gave an action', function()
  it('picks it there, wherever in the list it is, and in its own case', function()
    local _, c = open(function(h)
      return chat(h)
    end, { keys = { read = 'c', rename = 'C', pin = 'p' } })
    local function reading()
      return vim.bo.filetype == 'agent-chats-conversation'
    end
    -- p pins, which is listed further down, among your marks on the chat.
    feed('?')
    has(table.concat(menu().lines(), '\n'), 'p      Pin to the top of its group')
    feed('p')
    no(menu().is_open())
    ok(state().pinned(key(c)))
    -- C is rename here, not "read" in another case.
    local asked
    local real = vim.ui.input
    vim.ui.input = function(o, cb)
      asked = o.prompt
      cb(nil)
    end
    feed('?')
    feed('C')
    vim.ui.input = real
    has(asked or '', 'ame')
    no(reading(), 'no conversation was opened')
    -- And c reads.
    feed('?')
    feed('c')
    no(menu().is_open())
    ok(reading())
  end)
end)

describe('a key that cannot be mapped', function()
  it('is said in a few words', function()
    local long = '<Plug>(' .. string.rep('x', 60) .. ')'
    local said = notes(function()
      open(function(h)
        chat(h)
      end, { keys = { read = long } })
    end)
    has(said, long .. ' cannot be mapped (LHS exceeds maximum map length), so it does nothing')
    hasnt(said, 'vim/keymap')
  end)
end)

describe('the summary, when the cursor ends up in it', function()
  it('has the way back, and names it', function()
    open(function(h)
      chat(h)
    end)
    local S = board()._state
    hasnt(bar(), 'Back')
    -- A window command, a click or `:windo` can put the cursor there.
    vim.cmd('wincmd l')
    eq(S.pane_win, api.nvim_get_current_win())
    -- The keys there are the list's, on the chat it shows; the one that
    -- goes back is named with them.
    eq(' Enter Resume  C Conversation  A Archive  q Back' .. ALWAYS, bar())
    eq('', pane_bar())
    feed('q')
    eq(S.win, api.nvim_get_current_win())
    ok(board().is_open(), 'back is one step: to the list, not out of the board')
    vim.wait(30)
    eq(' Enter Resume  C Conversation  A Archive' .. ALWAYS, bar())
  end)

  it('leaves the key to you there too, and then names the command', function()
    user_map('n', 'q', function() end)
    open(function(h)
      chat(h)
    end)
    vim.cmd('wincmd l')
    no(vim.fn.maparg('q', 'n', false, true).buffer == 1)
    api.nvim_win_set_width(board()._state.win, 100)
    board().summary_entered()
    eq(' Enter Resume  C Conversation  A Archive  :Chats Back' .. ALL, bar())
  end)
end)

-- A second look by the same reader, after the first round of fixes.

describe('a chat started here has a row at once', function()
  it('whichever agent it is, and before that agent has said anything of itself', function()
    local home = open(function(h)
      chat(h, { title = 'An older chat' })
    end)
    fake.install(home)
    -- An agent that is told its session's id and then neither writes a
    -- transcript nor puts itself on its list of running sessions.
    require('agent-chats.config').get().providers.claude.cmd = { 'sh', '-c', 'sleep 30' }
    -- (Started with a prompt, as a script starts one.)
    actions().new({ provider = 'claude', prompt = 'build the thing' })
    local term = api.nvim_get_current_buf()
    eq('terminal', vim.bo[term].buftype)
    -- No look at the agents' files has happened: the row is there already,
    -- named by the prompt, and the list's cursor is on it.
    has(list(), 'build the thing')
    local S = board()._state
    local row = S.rows[api.nvim_win_get_cursor(S.win)[1]]
    ok(row and row.chat, 'the cursor is on a chat')
    eq(term, row.chat.term)
    eq('build the thing', require('agent-chats.display').title(row.chat))
    -- It stays through every later look, for as long as its terminal does.
    for _ = 1, 3 do
      store().refresh_sync({ full = false })
    end
    store().refresh_sync()
    has(list(), 'build the thing')
    feed('q')
    eq(S.win, api.nvim_get_current_win())
    eq(term, api.nvim_win_get_buf(S.pane_win), 'back lands on the new chat')
    -- And goes with it.
    vim.fn.jobstop(vim.bo[term].channel)
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      return list():find('build the thing', 1, true) == nil
    end)
  end)
end)

describe('the menu: every key of the board acts in it', function()
  it('does what the key does on the list, also for what this row does not offer', function()
    local _, made = open(function(h)
      local away = chat(h, { title = 'Runs elsewhere' })
      h:registry(vim.uv.os_getpid(), { sessionId = away.id, status = 'idle', cwd = vim.uv.cwd() })
      return away
    end, { keys = { queue = 'Q' } })
    -- Queueing a reply is not offered for a chat that runs somewhere else.
    -- Its key says why, as it does on the list, instead of being left to Vim.
    feed('?')
    hasnt(table.concat(menu().lines(), '\n'), 'Queue')
    vim.cmd('messages clear')
    local said = notes(function()
      feed('Q')
    end)
    no(menu().is_open())
    has(said, 'running outside this Neovim')
    -- Not Vim's own Q, which would leave the board for Ex mode.
    eq('n', api.nvim_get_mode().mode)
    hasnt(vim.fn.execute('messages'), 'E21')
    -- The conversation is read with Enter there; its own key reads it too.
    feed('?')
    feed('C')
    no(menu().is_open())
    eq('agent-chats-conversation', vim.bo.filetype)
    ok(store().get(key(made)))
  end)

  it("takes the other case of a letter only when that is nobody else's", function()
    local pressed = 0
    user_map('n', 's', function()
      pressed = pressed + 1
    end)
    local _, c = open(function(h)
      return chat(h)
    end)
    feed('?')
    feed('s')
    -- My s is mine in the menu too: it did not stand in for S, and no
    -- search was started.
    eq(1, pressed)
    eq(nil, board()._state.search)
    -- c is nobody's: it will do for C.
    menu().close()
    board().focus()
    feed('?')
    feed('c')
    eq('agent-chats-conversation', vim.bo.filetype)
    ok(store().get(key(c)))
  end)
end)

describe('a key that gives way: what names it follows, wherever it was', function()
  it('in a conversation', function()
    local _, c = open(function(h)
      return chat(h)
    end)
    actions().read(store().get(key(c)))
    has(bar(), 'q Back')
    has(bar(), ']] [[ Prompts')
    local pressed = {}
    user_map('n', ']]', function()
      pressed[#pressed + 1] = ']]'
    end)
    user_map('n', 'q', function()
      pressed[#pressed + 1] = 'q'
    end)
    feed(']]')
    feed('q')
    eq({ ']]', 'q' }, pressed)
    eq('agent-chats-conversation', vim.bo.filetype, 'still in the conversation')
    vim.wait(30)
    -- The other key for the next prompt is named now.
    hasnt(bar(), ']] [[ Prompts')
    has(bar(), 'J [[ Prompts')
    -- No key goes back: closing the window does, and that is said.
    hasnt(bar(), ' q Back')
    has(bar(), ' :q Back')
  end)

  it("in a chat's terminal", function()
    local home, c = open(function(h)
      return chat(h)
    end)
    hosted(home, c)
    has(bar(), ' q Back |')
    local pressed = 0
    user_map('n', 'q', function()
      pressed = pressed + 1
    end)
    feed('q')
    eq(1, pressed)
    eq('terminal', vim.bo.buftype, 'still in the terminal')
    vim.wait(30)
    has(bar(), ' :q Back |')
  end)

  it('on the list, for a mapping put on the list itself', function()
    open(function(h)
      chat(h)
    end)
    local S = board()._state
    has(bar(), 'C Conversation')
    local pressed = 0
    vim.keymap.set('n', 'C', function()
      pressed = pressed + 1
    end, { buffer = S.buf })
    -- As after the command that made it.
    api.nvim_exec_autocmds('CmdlineLeave', {})
    vim.wait(30)
    hasnt(bar(), 'C Conversation')
    feed('C')
    eq(1, pressed)
    -- Or, made some other way, at the next move of the cursor.
    has(bar(), '+ New Chat')
    vim.keymap.set('n', '+', function() end, { buffer = S.buf })
    api.nvim_exec_autocmds('CursorMoved', { buffer = S.buf })
    vim.wait(30)
    hasnt(bar(), '+ New')
  end)

  it('is typed again as it was: with its count, and ahead of what follows', function()
    open(function(h)
      chat(h)
    end)
    local counts, got = {}, {}
    user_map('n', 'C', function()
      counts[#counts + 1] = vim.v.count
    end)
    feed('3C')
    feed('2C')
    eq({ 3, 2 }, counts)
    -- A mapping that reads what is typed behind it gets that, the first time too.
    user_map('n', 'S', function()
      got[#got + 1] = vim.fn.getcharstr() .. vim.fn.getcharstr()
    end)
    feed('Sab')
    feed('Scd')
    eq({ 'ab', 'cd' }, got)
    eq(nil, board()._state.search)
  end)
end)

describe('the bar: why Enter only reads a chat', function()
  it('is said where there is room beside the keys, in full or in short', function()
    local _, made = open(function(h)
      local gone = chat(h, { title = 'Folder gone', cwd = '/nonexistent/for/tests', age = 60 })
      local away = chat(h, { title = 'Runs elsewhere', age = 120 })
      h:registry(vim.uv.os_getpid(), { sessionId = away.id, status = 'idle' })
      return { gone = gone, away = away }
    end)
    local S = board()._state
    local function at(width, c)
      api.nvim_win_set_width(S.win, width)
      board().goto_chat(key(c))
      board().render()
      return bar()
    end
    -- (Behind what Enter does: that is what it is about.)
    local rest = '  C Conversation  A Archive'
    eq(' Enter Read (it runs outside this Neovim)' .. rest .. ALL, at(112, made.away))
    eq(' Enter Read (runs elsewhere)' .. rest .. ALL, at(98, made.away))
    eq(' Enter Read (its folder is gone)' .. rest .. ALL, at(102, made.gone))
    eq(' Enter Read (folder gone)' .. rest .. ALL, at(96, made.gone))
    -- With less room the keys stay, and where they are: the summary says
    -- why as well, and so does the mark on the row or the heading above it.
    eq(' Enter Read' .. rest .. ALWAYS, at(79, made.away))
    eq(' Enter Read' .. rest .. ALWAYS, at(79, made.gone))
    eq(' Enter Read | + New  S Search  ? Menu ', at(40, made.away))
  end)
end)

describe('the summary, with the cursor in it: the keys of the list', function()
  it('act on the chat it shows, as the bar beside it says', function()
    local home, c = open(function(h)
      return chat(h)
    end, { keys = { queue = 'Q' } })
    local agent = fake.install(home)
    local S = board()._state
    vim.cmd('wincmd l')
    eq(S.pane_win, api.nvim_get_current_win())
    for _, lhs in ipairs({ '<CR>', 'Q', 'C', '+', 'S', '?', 'q' }) do
      eq(1, vim.fn.maparg(lhs, 'n', false, true).buffer, lhs)
    end
    -- What has no key on the list has none here.
    for _, lhs in ipairs({ 'P', 'M' }) do
      no(vim.fn.maparg(lhs, 'n', false, true).buffer == 1, lhs)
    end
    -- No lowercase key, and no click: a text is still a text.
    for _, lhs in ipairs({ 'j', 'k', 'w', '<2-LeftMouse>', '<RightMouse>' }) do
      no(vim.fn.maparg(lhs, 'n', false, true).buffer == 1, lhs)
    end
    -- The menu, for the chat the summary is about.
    feed('?')
    ok(menu().is_open())
    has(api.nvim_win_get_config(0).title[1][1], 'Fix the parser')
    menu().close()
    -- The key that writes to it.
    api.nvim_set_current_win(S.pane_win)
    feed('Q')
    ok(require('agent-chats.ui.input').is_open())
    has(api.nvim_win_get_config(0).title[1][1], 'Reply now (it is not busy): Fix the parser')
    require('agent-chats.ui.input').cancel()
    -- Enter does what the summary says it does: it resumes the chat.
    api.nvim_set_current_win(S.pane_win)
    feed('<CR>')
    T.wait(3000, function()
      return agent.read():find('--resume ' .. c.id, 1, true) ~= nil
    end)
    eq('terminal', vim.bo.buftype)
  end)

  it('follows the options when setup() is called again', function()
    open(function(h)
      chat(h)
    end)
    local S = board()._state
    local opts = vim.deepcopy(require('agent-chats.config').get())
    opts.keys = { read = 'x' }
    require('agent-chats.config').setup(opts)
    vim.cmd('wincmd l')
    eq(S.pane_win, api.nvim_get_current_win())
    eq(1, vim.fn.maparg('x', 'n', false, true).buffer)
    no(vim.fn.maparg('C', 'n', false, true).buffer == 1)
  end)
end)

describe("a chat's terminal: what your setup says goes back", function()
  it('is named only where something of yours is mapped on it', function()
    local said = notes(function()
      local home, c = open(function(h)
        return chat(h)
      end, {
        open = {
          on_open = function()
            return { back = 'Z', back_typing = '<C-z>' }
          end,
        },
      })
      hosted(home, c)
    end)
    -- The keys the plugin bound are the ones that go back, and are named.
    has(bar(), ' q Back |')
    T.typing(function()
      has(bar(), [[<C-\><C-b> Back]])
    end)
    has(
      said,
      'open.on_open returned back = "Z" and back_typing = "<C-z>", but nothing of yours is mapped there'
    )
  end)
end)

describe('a key named for one action that another had by default', function()
  it('says what that other action is left with, once all of them are settled', function()
    local both = notes(function()
      open(function(h)
        chat(h)
      end, { keys = { pin = 'J', unread = ']]' } })
    end)
    has(both, 'keys.pin is on J, which "next_prompt" has by default: "next_prompt" has no key now')
    has(
      both,
      'keys.unread is on ]], which "next_prompt" has by default: "next_prompt" has no key now'
    )
    hasnt(both, 'keeps')
    board().close()
    local one = notes(function()
      open(function(h)
        chat(h)
      end, { keys = { pin = 'J' } })
    end)
    has(one, 'keys.pin is on J, which "next_prompt" has by default: "next_prompt" keeps ]]')
  end)
end)

describe('a new git worktree', function()
  local function offered_for(dir)
    local home = open()
    fake.install(home)
    local items
    local real = vim.ui.select
    local n = 0
    vim.ui.select = function(list, _, cb)
      n = n + 1
      if n == 1 then
        -- Which agent? In another folder.
        return cb(list[#list])
      elseif n == 2 then
        items = list
      end
      cb(nil)
    end
    local good, err = pcall(actions().new, { cwd = dir })
    vim.ui.select = real
    assert(good, err)
    board().close()
    local labels = {}
    for _, item in ipairs(items) do
      labels[#labels + 1] = item.label
    end
    return labels
  end

  it('is offered where the folder is in a repository, and names that repository', function()
    local repo = T.tmpdir()
    vim.fn.system({ 'git', '-C', repo, 'init', '-q' })
    vim.fn.mkdir(repo .. '/src/deep', 'p')
    local labels = offered_for(repo .. '/src/deep')
    -- Asked from a folder inside it: the repository, not that folder.
    ok(
      vim.tbl_contains(labels, ('New git worktree of %s…'):format(vim.fn.fnamemodify(repo, ':~'))),
      vim.inspect(labels)
    )
  end)

  it('is not offered for a folder that is in none', function()
    local plain = T.tmpdir()
    local labels = offered_for(plain)
    for _, label in ipairs(labels) do
      hasnt(label, 'worktree')
    end
    eq('Another folder…', labels[#labels])
  end)
end)

describe('a reply queued behind one that is on its way', function()
  it('is said to wait for that one, not for a turn nobody can see', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    hosted(home, c)
    board().focus()
    state().hand_over(key(c))
    state().enqueue(key(c), 'and then the docs')
    board().goto_chat(key(c))
    board().toggle_pane()
    board().toggle_pane()
    local preview = require('agent-chats.ui.preview')
    local text = table.concat((preview.lines(store().get(key(c)), nil, board()._state.rows)), '\n')
    has(text, 'Queued  1 reply, sent when the chat has finished with the reply before it')
    state().sent(key(c))
    text = table.concat((preview.lines(store().get(key(c)), nil, board()._state.rows)), '\n')
    has(text, 'Queued  1 reply, sent when the chat finishes its turn')
  end)
end)

-- Found by driving the real agents.

describe('a new chat of an agent that names its session itself', function()
  it('keeps the cursor on it when its session takes the place of the stand-in', function()
    local home = open(function(h)
      chat(h, { title = 'An older chat', age = 300 })
      chat(h, { title = 'Another older chat', age = 400 })
    end)
    fake.install(home)
    -- Started without an id of its own (as Codex and opencode are): listed
    -- under a stand-in until its session shows up.
    local buf = assert(require('agent-chats.term').spawn({
      argv = { 'sh', '-c', 'sleep 30' },
      cwd = vim.uv.cwd(),
      provider = 'claude',
      title = 'new',
      label = { agent = 'Claude', name = 'new chat', dir = vim.uv.cwd() },
      prompt = 'What is new',
    }))
    board().follow(buf)
    store().started()
    board().focus()
    local S = board()._state
    local function at()
      return S.rows[api.nvim_win_get_cursor(S.win)[1]]
    end
    eq('What is new', require('agent-chats.display').title(at().chat))
    ok(at().chat.unstarted)
    -- Another chat is open as well, and newer than the session about to
    -- appear: it is what sits where the stand-in was once that is gone.
    local job = vim.fn.jobstart({ 'sleep', '30' })
    local other = chat(home, { title = 'Open somewhere else', age = 10 })
    home:registry(vim.fn.jobpid(job), { sessionId = other.id, status = 'idle', cwd = vim.uv.cwd() })
    store().refresh_sync()
    ok(at().chat.unstarted, 'still on the stand-in')
    -- Its session shows up: a chat of its own, which the terminal is then
    -- found to belong to (by its process). The stand-in goes in the same look.
    local real = chat(home, { title = 'The session itself', age = 50 })
    home:registry(vim.fn.jobpid(vim.bo[buf].channel), {
      sessionId = real.id,
      status = 'idle',
      cwd = vim.uv.cwd(),
    })
    T.wait(3000, function()
      store().refresh_sync()
      local c = store().get(key(real))
      return c and c.term == buf
    end)
    vim.fn.jobstop(job)
    hasnt(list(), 'What is new')
    eq('The session itself', at().chat.title, 'the cursor went with the chat, not to its neighbour')
  end)
end)

describe('a reply watched arriving in the pane', function()
  it('is not unread: its terminal is in front of you, beside the list', function()
    local home, made = open(function(h)
      local a = chat(h, { title = 'Watched', age = 30 })
      local b = chat(h, { title = 'Not watched', age = 40 })
      return { a = a, b = b }
    end)
    local _, term = hosted(home, made.a)
    board().focus()
    board().goto_chat(key(made.a))
    board().render()
    local S = board()._state
    eq(term, api.nvim_win_get_buf(S.pane_win), 'the pane shows its terminal, live')
    eq(S.win, api.nvim_get_current_win(), 'and the cursor is in the list')
    local pid = store().get(key(made.a)).pid
    -- A turn runs and ends while you look on (it has been in the pane for
    -- some seconds by then).
    home:registry(pid, { sessionId = made.a.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    eq('working', store().get(key(made.a)).status)
    made.a.ts = os.time() + 2
    made.a:user('one more'):assistant('there it is'):turn_done():write(os.time() + 3)
    home:registry(pid, { sessionId = made.a.id, status = 'idle', cwd = vim.uv.cwd() })
    S.shown_since = vim.uv.hrtime() - 5e9
    store().refresh_sync()
    eq('idle', store().get(key(made.a)).status, 'seen as it came')
    -- With the cursor on another row the pane shows something else: then it
    -- is news.
    board().goto_chat(key(made.b))
    board().render()
    ok(api.nvim_win_get_buf(S.pane_win) ~= term)
    home:registry(pid, { sessionId = made.a.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync({ full = false })
    made.a.ts = os.time() + 5
    made.a:user('and again'):assistant('once more'):turn_done():write(os.time() + 6)
    home:registry(pid, { sessionId = made.a.id, status = 'idle', cwd = vim.uv.cwd() })
    store().refresh_sync()
    eq('done', store().get(key(made.a)).status, 'unread')
  end)
end)

describe("a chat's terminal: the row that is marked follows the chat", function()
  it('takes the name the agent gives the chat while you are in it', function()
    local home, c = open(function(h)
      return chat(h, { title = 'First name' })
    end)
    local _, term = hosted(home, c)
    has(T.buf_text(board()._state.buf), 'First name')
    c:title('A better name'):write(os.time())
    store().refresh_sync()
    -- The row that is marked as the one in the pane has the new name.
    local S = board()._state
    local ns = api.nvim_get_namespaces()['agent-chats-shown']
    local mark = api.nvim_buf_get_extmarks(S.buf, ns, 0, -1, {})[1]
    ok(mark, 'a row is marked')
    has(api.nvim_buf_get_lines(S.buf, mark[2], mark[2] + 1, false)[1], 'A better name')
    eq(term, api.nvim_win_get_buf(S.pane_win))
    has(bar(), ' q Back |')
  end)
end)

describe('what a chat is called', function()
  it('is the first line of its prompt, not the start of the next run on behind it', function()
    local title = require('agent-chats.display').title
    eq(
      'Fix the parser.',
      title({ key = 'x:1', first_prompt = 'Fix the parser.\n\nIt fails on empty input.' })
    )
    eq(
      'second line says it',
      title({ key = 'x:2', first_prompt = '\n   \nsecond line says it\nthird' })
    )
    eq('from the last prompt', title({ key = 'x:3', last_prompt = 'from the last prompt\nmore' }))
    -- A title of the agent's own is used as it is.
    eq('Its own title', title({ key = 'x:4', title = 'Its own title', first_prompt = 'a\nb' }))
  end)
end)

describe('a reply that is being answered in the background', function()
  it('is said to be that, not a chat running in some other terminal', function()
    local home, c = open(function(h)
      return chat(h)
    end)
    -- A background run that takes a while: the chat is running, and in no
    -- terminal anywhere.
    local ok_, err, pid = require('agent-chats.term').background({
      argv = { 'sleep', '30' },
      cwd = vim.uv.cwd(),
      key = key(c),
    })
    ok(ok_, err)
    home:registry(pid, { sessionId = c.id, status = 'busy', cwd = vim.uv.cwd() })
    store().refresh_sync()
    local now = store().get(key(c))
    eq(true, now.live)
    ok(require('agent-chats.term').in_background(now))
    board().goto_chat(key(c))
    board().render()
    local S = board()._state
    api.nvim_win_set_width(S.win, 112)
    board().render()
    has(bar(), 'Enter Read (answering in the background)')
    hasnt(bar():lower(), 'queue')
    has(pane():gsub('\n%s*', ' '), 'A reply sent from here is being answered in the background')
    hasnt(pane(), 'type in its own terminal')
    local said = notes(function()
      actions().queue(now)
    end)
    has(said, 'still being answered in the background')
    no(require('agent-chats.ui.input').is_open())
    -- Enter reads it, and says why that is all it does.
    local opened = notes(function()
      actions().open(now)
    end)
    has(opened, 'being answered in the background, so for now it can only be read')
    hasnt(opened, 'outside this Neovim')
    board().focus()
    -- When it is over, the chat is as any other that ended.
    vim.uv.kill(pid, 15)
    T.wait(3000, function()
      return not require('agent-chats.term').in_background(now)
    end)
  end)
end)

describe('a new chat known only as a running process', function()
  it('is called by its prompt in the same look that finds it', function()
    local home = open(function(h)
      chat(h, { title = 'An older chat' })
    end)
    fake.install(home)
    actions().new({ provider = 'claude', prompt = 'build the thing' })
    local term = api.nvim_get_current_buf()
    -- The stand-in agent puts itself on the list of running sessions and
    -- writes no transcript: every look from then on finds a chat with no
    -- words of its own.
    local found
    T.wait(3000, function()
      store().refresh_sync({ full = false })
      for _, c in pairs(store().chats) do
        if c.term == term and c.stub and not c.unstarted then
          found = c
        end
      end
      return found ~= nil
    end)
    eq('build the thing', require('agent-chats.display').title(found))
    eq(term, found.term)
  end)
end)

-- Found under the user's own config, with a real chat in a folder whose
-- path is very long.

describe('a very long folder path', function()
  local deep
  before_each(function()
    deep = T.tmpdir() .. '/' .. string.rep('a-very-long-folder-name/', 6) .. 'the-project'
    vim.fn.mkdir(deep, 'p')
  end)

  it('does not push the question for a new chat out of sight', function()
    local home = open()
    fake.install(home)
    local asked
    local real = vim.ui.select
    vim.ui.select = function(_, o, cb)
      asked = o.prompt
      cb(nil)
    end
    local good, err = pcall(actions().new, { cwd = deep })
    vim.ui.select = real
    assert(good, err)
    -- What is asked comes first and stays; the end of the path stays too.
    has(asked, 'New chat in …')
    has(asked, 'the-project. Which agent?')
    ok(vim.fn.strdisplaywidth(asked) <= 72, ('%d cells'):format(vim.fn.strdisplaywidth(asked)))
  end)

  it('does not stretch the menu across the screen', function()
    open(function(h)
      chat(h, { cwd = deep })
    end)
    feed('?')
    local cfg = api.nvim_win_get_config(0)
    ok(cfg.width <= 72, 'the menu is ' .. cfg.width .. ' cells wide')
    -- (Under the heading of its part, which is no wider than the rest.)
    local first = menu().lines()[2]
    has(first, 'Enter  Resume it in …')
    has(first, 'the-project')
    for _, line in ipairs(menu().lines()) do
      ok(vim.fn.strdisplaywidth(line) <= cfg.width, line)
    end
  end)

  it('keeps the sentence of the summary readable, and gives the folder in full below it', function()
    local _, c = open(function(h)
      return chat(h, { cwd = deep })
    end)
    local lines =
      require('agent-chats.ui.preview').lines(store().get(key(c)), nil, board()._state.rows)
    local text = table.concat(lines, '\n')
    has(text, 'Enter resumes it in …')
    has(text, 'the-project.')
    has(text, 'Folder  ' .. deep)
  end)
end)

describe('the footer of a box', function()
  it('says less on a narrow screen, and always how to send', function()
    local input = require('agent-chats.ui.input')
    -- Every key the box has is named where there is room.
    eq(' <C-s> Send · Enter Send (normal mode) · q / Esc Cancel ', input.footer())
    eq(' <C-s> Send · Enter Send (normal) · q / Esc Cancel ', input.footer(52))
    -- How to call it off is kept longer than a second way to send.
    eq(' <C-s> Send · q / Esc Cancel ', input.footer(40))
    eq(' <C-s> Send ', input.footer(20))
  end)
end)

describe('the board as it opens, while the index is still being read', function()
  it('keeps the cursor on the first chat, and the list at its top', function()
    local home = fx.home({ board = { spinner = false } })
    local old = chat(home, { title = 'Read first, and old', age = 5000 })
    state().update(function(s)
      s.baseline = os.time() + 10
    end)
    -- The first look is under way: one chat is known so far.
    store().refresh_sync()
    store().initialized = false
    store().start = function() end
    board().open()
    local S = board()._state
    local function at()
      return S.rows[api.nvim_win_get_cursor(S.win)[1]]
    end
    eq('Read first, and old', at().chat.title)
    -- The rest arrives: many chats, all newer, so the first one known is
    -- carried far down the list.
    for i = 1, 30 do
      chat(home, { title = ('Newer %02d'):format(i), age = 100 + i })
    end
    store().refresh_sync()
    eq(
      'Newer 01',
      at().chat.title,
      'the first chat of the list, not the one that happened to be read first'
    )
    eq(1, vim.fn.line('w0', S.win), 'and the list starts at its first line')
    ok(store().get(key(old)))
    -- From then on the cursor stays with its chat, wherever that goes.
    chat(home, { title = 'Newest of all', age = 1 })
    store().refresh_sync()
    eq('Newer 01', at().chat.title)
  end)

  it('leaves the cursor where it was moved to in the meantime', function()
    local home = fx.home({ board = { spinner = false } })
    chat(home, { title = 'One', age = 300 })
    chat(home, { title = 'Two', age = 400 })
    state().update(function(s)
      s.baseline = os.time() + 10
    end)
    store().refresh_sync()
    store().initialized = false
    store().start = function() end
    board().open()
    local S = board()._state
    -- Moved by hand before the index is whole.
    for i, row in ipairs(S.rows) do
      if row.chat and row.chat.title == 'Two' then
        api.nvim_win_set_cursor(S.win, { i, 1 })
      end
    end
    chat(home, { title = 'Zero, newer', age = 10 })
    store().refresh_sync()
    eq('Two', S.rows[api.nvim_win_get_cursor(S.win)[1]].chat.title)
  end)
end)
