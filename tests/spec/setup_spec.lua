-- Setting the hooks up from inside Neovim: the command, the preview that
-- asks first, the overview, the board's reminder and :checkhealth.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local hk = require('helpers.hooks')
local eq, ok, no, has, hasnt = T.eq, T.ok, T.no, T.has, T.hasnt
local api = vim.api

local function hooks()
  return require('agent-chats.hooks')
end

local function ui()
  return require('agent-chats.ui.hooks')
end

local function board()
  return require('agent-chats.ui.board')
end

local function store()
  return require('agent-chats.store')
end

-- The commands are defined by the plugin file, which a test run does not source.
vim.cmd('runtime plugin/agent-chats.lua')

local function read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

--- Everything `vim.notify` is told while `fn` runs.
local function notified(fn)
  local said = {}
  local real = vim.notify
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  local good, err = pcall(fn)
  vim.notify = real
  ok(good, tostring(err))
  return table.concat(said, '\n')
end

--- What :checkhealth would print, as "level: text" lines.
local function health()
  local out = {}
  local real = vim.health
  vim.health = setmetatable({}, {
    __index = function(_, level)
      return function(text)
        out[#out + 1] = level .. ': ' .. tostring(text)
      end
    end,
  })
  local good, err = pcall(require('agent-chats.health').check)
  vim.health = real
  ok(good, tostring(err))
  return table.concat(out, '\n')
end

after_each(function()
  ui()._answer(false)
  pcall(function()
    board().close()
  end)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative ~= '' then
      pcall(api.nvim_win_close, win, true)
    end
  end
end)

describe(':Chats hooks', function()
  it('shows every change and writes nothing until told to', function()
    local home = fx.home()
    local path = home.dir .. '/settings.json'
    T.write(path, '{\n  "model": "opus"\n}\n')
    vim.cmd('Chats hooks install claude')
    ok(ui().is_asking())
    local shown = T.buf_text(api.nvim_get_current_buf())
    has(shown, 'Claude: edit')
    has(shown, '+    "Stop": [{ "hooks": [{ "type": "command"')
    has(shown, 'write the hook script to')
    has(shown, 'backed up')
    -- The one line of the user's that changes: it gains the comma JSON wants.
    has(shown, '-  "model": "opus"\n+  "model": "opus",')
    eq('{\n  "model": "opus"\n}\n', read(path), 'nothing is written while it asks')

    ui()._answer(false)
    no(ui().is_asking())
    eq('{\n  "model": "opus"\n}\n', read(path))
    eq('missing', hooks().status('claude').state)

    vim.cmd('Chats hooks install claude')
    local said = notified(function()
      ui()._answer(true)
    end)
    has(said, 'Claude: hooks installed')
    has(said, 'kept as settings.json.agent-chats-backup-')
    has(said, 'reloads its settings')
    eq('installed', hooks().status('claude').state)

    -- Again: nothing to ask about.
    said = notified(function()
      vim.cmd('Chats hooks install claude')
    end)
    no(ui().is_asking())
    has(said, 'already installed for Claude')
  end)

  it('answers y and n from the keyboard', function()
    local home = fx.home()
    T.write(home.dir .. '/settings.json', '{}\n')
    vim.cmd('Chats hooks install claude')
    api.nvim_feedkeys('n', 'xt', false)
    eq('missing', hooks().status('claude').state)
    vim.cmd('Chats hooks install claude')
    notified(function()
      api.nvim_feedkeys('y', 'xt', false)
    end)
    eq('installed', hooks().status('claude').state)
  end)

  it('sets up every agent in use when none is named, and removes them again', function()
    local home = fx.home()
    T.write(home.dir .. '/settings.json', '{}\n')
    vim.cmd('Chats hooks install')
    has(T.buf_text(api.nvim_get_current_buf()), 'Claude:')
    notified(function()
      ui()._answer(true)
    end)
    eq('installed', hooks().status('claude').state)
    hk.event('claude', 'some-session', 'Stop')
    vim.cmd('Chats hooks uninstall')
    has(T.buf_text(api.nvim_get_current_buf()), '-    "Stop"')
    local said = notified(function()
      ui()._answer(true)
    end)
    has(said, 'Claude: hooks removed')
    eq('{}\n', read(home.dir .. '/settings.json'))
  end)

  it('says why when it cannot', function()
    local home = fx.home()
    T.write(home.dir .. '/settings.json', '{ broken')
    local said = notified(function()
      vim.cmd('Chats hooks install claude')
    end)
    no(ui().is_asking())
    has(said, 'not valid JSON')
    has(said, 'left alone')
    said = notified(function()
      vim.cmd('Chats hooks install nosuchagent')
    end)
    has(said, 'no agent called "nosuchagent"')
    said = notified(function()
      vim.cmd('Chats hooks frobnicate')
    end)
    has(said, 'no such action')
  end)

  it('reports where things stand, and lists the steps to do it by hand', function()
    local home = fx.home()
    T.write(home.dir .. '/settings.json', '{}\n')
    local said = notified(function()
      vim.cmd('Chats hooks status')
    end)
    has(said, 'Claude')
    has(said, 'not installed')
    has(said, 'settings.json')
    vim.cmd('Chats hooks show claude')
    local shown = T.buf_text(api.nvim_get_current_buf())
    has(shown, 'two steps')
    has(shown, '"PermissionRequest"')
    has(shown, hooks().script_path())
  end)

  it('opens an overview to install from', function()
    local home = fx.home()
    T.write(home.dir .. '/settings.json', '{}\n')
    vim.cmd('Chats hooks')
    local buf = api.nvim_get_current_buf()
    has(T.buf_text(buf), 'Claude')
    has(T.buf_text(buf), 'not installed')
    api.nvim_feedkeys('i', 'xt', false)
    ok(ui().is_asking())
    notified(function()
      ui()._answer(true)
    end)
    eq('installed', hooks().status('claude').state)
    -- Back in the overview, which now says so.
    T.wait(1000, function()
      return T.buf_text(api.nvim_get_current_buf()):find('✓ Claude', 1, true) ~= nil
    end)
    api.nvim_feedkeys('q', 'xt', false)
  end)

  it('completes its actions and the agents that have hooks', function()
    fx.home()
    local agent_chats = require('agent-chats')
    ok(vim.tbl_contains(agent_chats.complete('ho', 'Chats ho'), 'hooks'))
    eq({ 'install' }, agent_chats.complete('i', 'Chats hooks i'))
    eq({ 'claude' }, agent_chats.complete('', 'Chats hooks install '))
    eq({}, agent_chats.complete('', 'Chats hooks status '))
  end)
end)

describe('the board', function()
  it('says once, in one line, when an agent can only guess', function()
    local qx = require('helpers.qwen')
    local home = qx.home({ board = { spinner = false } })
    home:chat({ start = os.time() - 60 }):turn('Hello', 'Hi.'):write()
    store().refresh_sync()
    store().start = function() end
    board().open()
    local list = T.buf_text(board()._state.buf)
    has(list, 'Qwen can only guess "needs you". gh sets up its hooks, once.')
    ok(vim.fn.maparg('gh', 'n', false, true).buffer == 1)

    T.write(home.dir .. '/settings.json', '{}\n')
    ok(hooks().apply(assert(hooks().plan('qwen', 'install'))))
    board().render()
    hasnt(T.buf_text(board()._state.buf), 'can only guess')
  end)

  it('keeps quiet about it when told to, and for agents that need no hooks to be exact', function()
    local qx = require('helpers.qwen')
    local home = qx.home({ board = { spinner = false }, hooks = { remind = false } })
    home:chat({ start = os.time() - 60 }):turn('Hello', 'Hi.'):write()
    store().refresh_sync()
    store().start = function() end
    board().open()
    hasnt(T.buf_text(board()._state.buf), 'can only guess')
    board().close()

    local claude = fx.home({ board = { spinner = false } })
    claude:chat():user('Hi'):assistant('Hello.'):turn_done():write()
    store().refresh_sync()
    store().start = function() end
    board().open()
    hasnt(T.buf_text(board()._state.buf), 'can only guess')
  end)

  it('shows in the pane who says what a running chat is doing', function()
    local home = fx.home({ board = { spinner = false } })
    local chat = home:chat({ start = os.time() - 60 }):user('Go')
    chat:tool_use('Bash', { command = 'make deploy' }):write()
    home:registry(vim.uv.os_getpid(), { sessionId = chat.id, status = 'not-a-known-status' })
    hk.event('claude', chat.id, 'PermissionRequest', { tool = 'Bash' })
    store().refresh_sync()
    store().start = function() end
    board().open()
    board().goto_chat('claude:' .. chat.id)
    local pane = T.buf_text(api.nvim_win_get_buf(board()._state.pane_win))
    has(pane, 'status from its hooks')
    has(pane, 'permission to use Bash')
    has(pane, 'Bash: make deploy')
  end)
end)

describe(':checkhealth', function()
  it('says for each agent where its status comes from', function()
    local home = fx.home()
    home:chat():user('Hi'):assistant('Hello.'):turn_done():write()
    T.write(home.dir .. '/settings.json', '{}\n')
    local report = health()
    has(report, 'ok: Claude: 1 chat in')
    has(report, 'info: Claude: status comes from its session registry')
    has(report, ':Chats hooks install claude')
    has(report, 'info: Hook events: ')
    hasnt(report, 'error:')

    ok(hooks().apply(assert(hooks().plan('claude', 'install'))))
    hk.event('claude', 'some-session', 'Stop')
    report = health()
    has(report, 'ok: Claude: hooks installed (1 session has reported, the last just now)')
    has(report, 'whichever spoke last is believed')
  end)

  it('warns when an agent can only guess, and when hooks need another look', function()
    local qx = require('helpers.qwen')
    local home = qx.home()
    home:chat({ start = os.time() - 60 }):turn('Hello', 'Hi.'):write()
    local report = health()
    has(report, 'warn: Qwen: "needs you" is a guess')

    T.write(home.dir .. '/settings.json', '{}\n')
    ok(hooks().apply(assert(hooks().plan('qwen', 'install'))))
    report = health()
    has(report, 'ok: Qwen: hooks installed (no session has reported yet)')
    has(report, 'info: Qwen: for a session that has not reported')
    hasnt(report, '"needs you" is a guess')

    vim.uv.fs_unlink(hooks().script_path())
    has(health(), 'warn: Qwen: hooks installed, but the hook script needs updating')
    T.write(home.dir .. '/settings.json', '{ nope')
    has(health(), 'warn: Qwen: hooks cannot be read')
  end)

  it('says so when there is nothing to show at all', function()
    fx.home({ providers = { claude = { home = '/nonexistent/.claude' } } })
    has(health(), 'warn: No chats of any agent were found')
  end)
end)
