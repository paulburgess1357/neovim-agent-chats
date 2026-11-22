-- Groups of your own: a chat is put in one from the menu, stays there
-- whatever it does, and goes back under its status when it is taken out.

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
local function menu()
  return require('agent-chats.ui.menu')
end

--- A finished chat in a folder that exists.
local function chat(home, opts)
  opts = opts or {}
  local c = home:chat({
    cwd = opts.cwd or vim.uv.cwd(),
    branch = 'main',
    start = os.time() - (opts.age or 600) - 5,
  })
  c:user(opts.prompt or 'Please fix the parser')
  c:title(opts.title or 'Fix the parser')
  c:assistant(opts.reply or 'The parser is fixed.')
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
  vim.wait(20)
  vim.notify = real
  assert(good, err)
  return table.concat(said, '\n')
end

--- Run `fn` with the questions it asks answered: `selects` are what is
--- chosen of each list (by what it reads as; false calls it off), `inputs`
--- what is typed for each name. Returns what was asked: for each list its
--- prompt and its lines, and the prompts of what was typed.
local function asked(selects, inputs, fn)
  local real_select, real_input = vim.ui.select, vim.ui.input
  local seen = { lists = {}, prompts = {}, typed = {} }
  local si, ii = 0, 0
  vim.ui.select = function(items, opts, cb)
    si = si + 1
    local lines = {}
    for i, item in ipairs(items) do
      lines[i] = opts.format_item and opts.format_item(item) or tostring(item)
    end
    seen.lists[#seen.lists + 1] = lines
    seen.prompts[#seen.prompts + 1] = opts.prompt
    local want = selects[si]
    for i, line in ipairs(lines) do
      if want and line:find(want, 1, true) then
        return cb(items[i])
      end
    end
    cb(nil)
  end
  vim.ui.input = function(opts, cb)
    ii = ii + 1
    seen.typed[#seen.typed + 1] = opts.prompt
    cb(inputs[ii])
  end
  local good, err = pcall(fn)
  vim.ui.select, vim.ui.input = real_select, real_input
  assert(good, err)
  return seen
end

--- The lines of the list from the heading that starts with `name` up to
--- the next heading.
local function under(name)
  local out, inside = {}, false
  for i, row in ipairs(board()._state.rows) do
    local line = api.nvim_buf_get_lines(board()._state.buf, i - 1, i, false)[1]
    if row.kind == 'group' then
      inside = line:find(name, 1, true) ~= nil
    elseif inside and row.kind == 'chat' then
      out[#out + 1] = line
    end
  end
  return table.concat(out, '\n')
end

--- The headings of the list, top to bottom, without what follows the name.
local function headings()
  local out = {}
  for i, row in ipairs(board()._state.rows) do
    if row.kind == 'group' then
      local line = api.nvim_buf_get_lines(board()._state.buf, i - 1, i, false)[1]
      out[#out + 1] = vim.trim((line:gsub('^%s*%S+%s+', '', 1):gsub('%s%s+.*$', '')))
    end
  end
  return out
end

after_each(function()
  pcall(function()
    menu().close()
  end)
  require('agent-chats.ui.input').cancel()
  fake.cleanup()
  pcall(function()
    board().close()
  end)
end)

describe('a group of your own', function()
  it('is made by naming it, from the menu of a chat', function()
    local _, made = open(function(h)
      local a = chat(h, { title = 'Parser work', age = 100 })
      local b = chat(h, { title = 'Docs work', age = 200 })
      return { a = a, b = b }
    end)
    eq({ 'Ended' }, headings())
    board().goto_chat(key(made.a))
    feed('?')
    has(table.concat(menu().lines(), '\n'), 'Put it in a group of your own')
    -- No group yet: there is nothing to choose from, so the name is asked.
    local seen = asked({}, { '  Release  ' }, function()
      ok(menu().pick('move'))
    end)
    eq({}, seen.lists)
    eq({ 'Name of the new group: ' }, seen.typed)
    eq('Release', state().group(key(made.a)))
    -- Its own heading, above the chats that are where their status puts them.
    eq({ 'Release', 'Ended' }, headings())
    has(list(), 'Release  1')
    has(under('Release'), 'Parser work')
    hasnt(under('Ended'), 'Parser work')
    has(under('Ended'), 'Docs work')
    -- The cursor is still on the chat.
    eq(key(made.a), board().current().key)
    -- Its summary says where it is, and its menu what can be done about it.
    has(pane(), 'Group   Release')
    feed('?')
    has(table.concat(menu().lines(), '\n'), 'Move it out of “Release”, or to another group')
    menu().close()
  end)

  it('is offered to the next chat, with a new one; a chat in one is offered the way out', function()
    local _, made = open(function(h)
      local a = chat(h, { title = 'Parser work', age = 100 })
      local b = chat(h, { title = 'Docs work', age = 200 })
      local c = chat(h, { title = 'Third one', age = 300 })
      return { a = a, b = b, c = c }
    end)
    state().set_group(key(made.a), 'Release')
    store().touch()
    board().render()
    -- A chat in no group: the groups there are, or a new one.
    local seen = asked({ 'Release' }, {}, function()
      actions().move(store().get(key(made.b)))
    end)
    eq({ { 'Release  (1)', 'A new group…' } }, seen.lists)
    eq('Put “Docs work” in the group', seen.prompts[1])
    eq('Release', state().group(key(made.b)))
    has(list(), 'Release  2')
    -- A new one, from the same list.
    seen = asked({ 'A new group' }, { 'Later' }, function()
      actions().move(store().get(key(made.c)))
    end)
    eq({ 'Name of the new group: ' }, seen.typed)
    eq({ 'Later', 'Release' }, headings())
    -- A chat in a group: the other groups, a new one, and out of them all.
    seen = asked({ 'No group' }, {}, function()
      actions().move(store().get(key(made.a)))
    end)
    eq({ { 'Later  (1)', 'A new group…', 'No group: back under “Ended”' } }, seen.lists)
    eq('“Parser work” is in “Release”. Move it to', seen.prompts[1])
    eq(nil, state().group(key(made.a)))
    -- Back where its status puts it.
    eq({ 'Later', 'Release', 'Ended' }, headings())
    has(under('Ended'), 'Parser work')
    has(list(), 'Release  1')
    -- From one group to another.
    asked({ 'Later' }, {}, function()
      actions().move(store().get(key(made.b)))
    end)
    eq('Later', state().group(key(made.b)))
    -- The group nothing is left in is gone: there was nothing else to it.
    eq({ 'Later', 'Ended' }, headings())
    eq({ 'Later' }, (state().groups()))
  end)

  it('is not changed by a question that is called off, or a name of blanks', function()
    local _, c = open(function(h)
      return chat(h)
    end)
    asked({}, { nil }, function()
      actions().move(store().get(key(c)))
    end)
    eq(nil, state().group(key(c)))
    asked({}, { '   ' }, function()
      actions().move(store().get(key(c)))
    end)
    eq(nil, state().group(key(c)))
    state().set_group(key(c), 'Kept')
    asked({ false }, {}, function()
      actions().move(store().get(key(c)))
    end)
    eq('Kept', state().group(key(c)))
    eq({ 'Ended' }, headings(), 'the list was not drawn again for nothing')
  end)

  it('has a name of one short line, whatever is typed for it', function()
    local _, c = open(function(h)
      return chat(h)
    end)
    asked({}, { 'Release\twork,\n  the second half ' .. string.rep('and on ', 12) }, function()
      actions().move(store().get(key(c)))
    end)
    local name = state().group(key(c))
    ok(not name:find('[%c]'), 'no control characters in it')
    has(name, 'Release work, the second half and on')
    ok(vim.fn.strdisplaywidth(name) <= 40, name)
    has(list(), name)
  end)

  it('keeps its chats whatever they do, and says on its heading what wants a look', function()
    local home, made = open(function(h)
      local a = chat(h, { title = 'Asks something', age = 100 })
      local b = chat(h, { title = 'Is ended', age = 200 })
      local c = chat(h, { title = 'Outside', age = 300 })
      return { a = a, b = b, c = c }
    end)
    state().set_group(key(made.a), 'Release')
    state().set_group(key(made.b), 'Release')
    home:registry(vim.uv.os_getpid(), {
      sessionId = made.a.id,
      status = 'waiting',
      waitingFor = 'permission to use Bash',
    })
    store().refresh_sync()
    board().render()
    eq('attention', store().get(key(made.a)).status)
    -- Both are in the group still: no "Needs you" heading took one away.
    eq({ 'Release', 'Ended' }, headings())
    has(under('Release'), 'Asks something')
    has(under('Release'), 'Is ended')
    -- The one that needs you first, and the heading says there is one.
    ok(
      under('Release'):find('Asks something', 1, true) < under('Release'):find('Is ended', 1, true)
    )
    local icons = require('agent-chats.config').get().icons
    has(list(), 'Release  2   ' .. icons.attention .. '1')
    -- The first line counts it like any chat that needs you.
    has(api.nvim_buf_get_lines(board()._state.buf, 0, 1, false)[1], '1 needs you')
    -- A status heading is still explained; a group of yours needs no words.
    has(list(), 'Ended  1   not open, can be resumed')
  end)

  it('folds like any group, and is found by a search for its name', function()
    local _, made = open(function(h)
      local a = chat(h, { title = 'Parser work', age = 100 })
      local b = chat(h, { title = 'Docs work', age = 200 })
      return { a = a, b = b }
    end)
    state().set_group(key(made.a), 'Release')
    store().touch()
    board().render()
    for i, row in ipairs(board()._state.rows) do
      if row.kind == 'group' then
        api.nvim_win_set_cursor(board()._state.win, { i, 1 })
        break
      end
    end
    feed('<CR>')
    hasnt(list(), 'Parser work')
    has(list(), 'Release  1')
    feed('<CR>')
    has(list(), 'Parser work')
    board().search('release')
    has(list(), 'Parser work')
    hasnt(list(), 'Docs work')
  end)

  it('keeps a chat listed that would be too old for the list', function()
    local old = 40 * 86400
    local _, made = open(function(h)
      local a = chat(h, { title = 'Old but kept', age = old })
      local b = chat(h, { title = 'Old and left', age = old + 50 })
      chat(h, { title = 'New one', age = 100 })
      return { a = a, b = b }
    end)
    hasnt(list(), 'Old but kept')
    eq(nil, store().get(key(made.a)))
    state().set_group(key(made.a), 'Keep')
    store().refresh_sync({ full = true })
    board().render()
    has(under('Keep'), 'Old but kept')
    hasnt(list(), 'Old and left')
  end)

  it('is said to be there where the list is grouped by something else', function()
    local _, c = open(function(h)
      return chat(h, { title = 'Parser work' })
    end)
    board().set_group('folder')
    board().goto_chat(key(c))
    local said = notes(function()
      asked({}, { 'Release' }, function()
        feed('?')
        ok(menu().pick('move'))
      end)
    end)
    has(
      said,
      'It is in “Release”. Your own groups are shown when the list is grouped by status.'
    )
    hasnt(list(), 'Release')
    has(pane(), 'Group   Release')
    board().set_group('status')
    eq({ 'Release' }, headings())
    -- Where it shows at once, nothing needs saying.
    said = notes(function()
      asked({ 'A new group' }, { 'Other' }, function()
        feed('?')
        ok(menu().pick('move'))
      end)
    end)
    eq('', said)
    eq({ 'Other' }, headings())
  end)

  it('can be chosen from the conversation of the chat, and not for a subagent', function()
    local _, made = open(function(h)
      local a = chat(h, { title = 'Parser work', age = 100 })
      a:subagent('aaa111', { agentType = 'Explore', description = 'Find files', finished = true })
      return a
    end)
    actions().read(store().get(key(made)))
    asked({}, { 'Release' }, function()
      feed('?')
      ok(menu().pick('move'))
    end)
    eq('Release', state().group(key(made)))
    feed('q')
    board().goto_chat(key(made))
    board().toggle_row()
    local sub
    for _, row in ipairs(board()._state.rows) do
      if row.chat and row.chat.subagent then
        sub = row.chat
      end
    end
    ok(sub)
    local said = notes(function()
      actions().move(sub)
    end)
    has(said, 'A subagent cannot be put in a group')
  end)

  it('has no key by default, and takes the one you give it', function()
    local _, c = open(function(h)
      return chat(h)
    end, { keys = { move = 'gm' } })
    feed('?')
    has(table.concat(menu().lines(), '\n'), 'gm     Put it in a group of your own')
    menu().close()
    asked({}, { 'Release' }, function()
      feed('gm')
    end)
    eq('Release', state().group(key(c)))
  end)
end)

describe('the groups you have made', function()
  it('are listed by name, whatever the case, with how many chats each has', function()
    open(function(h)
      chat(h)
    end)
    state().set_group('claude:one', 'beta')
    state().set_group('claude:two', 'Alpha')
    state().set_group('claude:three', 'beta')
    local names, counts = state().groups()
    eq({ 'Alpha', 'beta' }, names)
    eq({ Alpha = 1, beta = 2 }, counts)
    state().set_group('claude:two', '')
    state().set_group('claude:one', nil)
    names, counts = state().groups()
    eq({ 'beta' }, names)
    eq({ beta = 1 }, counts)
    -- Kept in the state file, with the other marks.
    state().reset()
    eq('beta', state().group('claude:three'))
  end)
end)
