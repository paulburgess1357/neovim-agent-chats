-- A chat that runs in a terminal you made yourself, under a config that
-- keeps its terminal windows to itself.
--
-- The config staged here is of a kind that is common: each terminal buffer
-- claims whatever window shows it (a buffer-local BufWinEnter marks the
-- window), and a global BufWinEnter puts the terminal back, with a warning,
-- when any other buffer lands in a window so marked. The board's pane shows
-- one buffer after another as the cursor moves: claimed once, it would be
-- stuck on that terminal, and every move of the cursor would warn.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local fake = require('helpers.fake')
local eq, ok, has, hasnt = T.eq, T.ok, T.has, T.hasnt

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

local function key(c)
  return 'claude:' .. c.id
end

local function chat(home, title, age)
  local c = home:chat({ cwd = vim.uv.cwd(), branch = 'main', start = os.time() - (age or 600) - 5 })
  c:user('Please ' .. title:lower())
  c:title(title)
  c:assistant('Done.')
  c:turn_done()
  return c:write(os.time() - (age or 600))
end

local function pane_buf()
  return api.nvim_win_get_buf(board()._state.pane_win)
end

local function pane_text()
  return T.buf_text(pane_buf())
end

--- Let what was scheduled run (the pane follows the cursor a moment later,
--- and so does a config that puts its terminal back).
local function settle()
  vim.wait(60, function()
    return false
  end, 10)
end

--- Move the list's cursor to the row of `c`, as a key would.
local function go(c)
  board().focus()
  board().goto_chat(key(c))
  api.nvim_exec_autocmds('CursorMoved', { buffer = board()._state.buf })
  settle()
end

--- The warnings of the staged config, and what it marked.
local said = {}

--- A terminal made outside the plugin, in its own tab, running the agent
--- of `c`; with the autocommands of a config that keeps the window of a
--- terminal for that terminal.
---@return integer buf, integer win, integer tab
local function own_terminal(home, c)
  local agent = fake.install(home)
  vim.cmd('tabnew')
  local buf, win, tab =
    api.nvim_get_current_buf(), api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  vim.fn.jobstart({ agent.bin, '--resume', c.id }, { term = true, cwd = vim.uv.cwd() })
  local group = api.nvim_create_augroup('AgentChatsTestUser', { clear = true })
  local function is_float(w)
    return api.nvim_win_get_config(w).relative ~= ''
  end
  -- The window that shows this terminal is this terminal's.
  vim.w[win].term_slot = buf
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function()
      if not is_float(api.nvim_get_current_win()) then
        vim.w.term_slot = buf
      end
    end,
  })
  -- Another buffer in such a window is sent away again, and that is said.
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function()
      local owner = vim.w.term_slot
      if not (owner and api.nvim_buf_is_valid(owner)) then
        vim.w.term_slot = nil
        return
      end
      local here, intruder = api.nvim_get_current_win(), api.nvim_get_current_buf()
      if intruder == owner then
        return
      end
      vim.schedule(function()
        if api.nvim_win_is_valid(here) and api.nvim_win_get_buf(here) == intruder then
          api.nvim_win_set_buf(here, owner)
          said[#said + 1] = 'the terminal was put back'
        end
      end)
    end,
  })
  T.wait(3000, function()
    store().refresh_sync({ full = false })
    local now = store().get(key(c))
    return now ~= nil and now.term == buf and now.pid ~= nil
  end, 'the chat is found in the terminal it was started in by hand')
  vim.cmd('stopinsert')
  return buf, win, tab
end

--- Put the terminal out of sight the way its owner does: its window is
--- closed, and it goes on running.
local function hide(win)
  api.nvim_win_close(win, true)
end

--- A home with three chats, the board open in a tab of its own.
local function scene(extra)
  local home = fx.home(
    vim.tbl_deep_extend('force', { board = { spinner = false, intro = false } }, extra or {})
  )
  local made = {
    mine = chat(home, 'Runs in my own terminal', 30),
    other = chat(home, 'Another chat', 600),
    third = chat(home, 'A third chat', 900),
  }
  state().update(function(s)
    s.baseline = os.time() + 10
  end)
  store().refresh_sync()
  store().start = function() end
  return home, made
end

before_each(function()
  said = {}
end)

after_each(function()
  pcall(api.nvim_del_augroup_by_name, 'AgentChatsTestUser')
  fake.cleanup()
  pcall(function()
    board().close()
  end)
end)

describe('a terminal you made yourself', function()
  it('is not claimed for the pane by a config that keeps its windows', function()
    local home, made = scene()
    local buf, win = own_terminal(home, made.mine)
    -- Out of sight, as a terminal that was toggled away is: the pane is
    -- then the one place it can be seen.
    hide(win)
    eq({}, vim.fn.win_findbuf(buf))
    board().open()
    local S = board()._state
    go(made.mine)
    eq(buf, pane_buf(), 'the pane shows the live terminal')
    eq(nil, vim.w[S.pane_win].term_slot, 'and is not marked as that terminal’s window')
    -- Down the list and back, as a hand on `j` does.
    for _ = 1, 3 do
      go(made.other)
      eq('agent-chats-summary', vim.bo[pane_buf()].filetype)
      has(pane_text(), '# Another chat')
      go(made.third)
      has(pane_text(), '# A third chat')
      go(made.mine)
      eq(buf, pane_buf())
    end
    eq({}, said, 'nothing was put back, and nothing was said')
  end)

  it('is not claimed when the chat is gone into, or left again', function()
    local home, made = scene()
    local buf, win = own_terminal(home, made.mine)
    hide(win)
    board().open()
    local S = board()._state
    go(made.other)
    -- Straight from the summary of another chat: the terminal is put in
    -- the pane and entered in one step.
    eq(buf, actions().open(store().get(key(made.mine))))
    vim.cmd('stopinsert')
    settle()
    eq(S.pane_win, api.nvim_get_current_win())
    eq(buf, pane_buf())
    eq(nil, vim.w[S.pane_win].term_slot)
    go(made.other)
    has(pane_text(), '# Another chat')
    -- A conversation takes the pane with the cursor in it.
    actions().read(store().get(key(made.third)))
    settle()
    eq('agent-chats-conversation', vim.bo[pane_buf()].filetype)
    go(made.mine)
    eq(buf, pane_buf())
    go(made.third)
    eq({}, said)
  end)

  it('stays in its own window when it is on screen there, and Enter goes to it', function()
    local home, made = scene()
    local buf, win, tab = own_terminal(home, made.mine)
    board().open()
    local S = board()._state
    ok(api.nvim_get_current_tabpage() ~= tab, 'the board is in a tab of its own')
    go(made.mine)
    -- One terminal, one window: Neovim sizes a terminal for the largest
    -- window that shows it, so a second one would be cut off, or cut the
    -- first one off.
    eq('agent-chats-summary', vim.bo[pane_buf()].filetype)
    has(pane_text(), '# Runs in my own terminal')
    has(pane_text():gsub('\n%s*', ' '), 'Its terminal is open in tab 2. Enter goes there.')
    eq({ win }, vim.fn.win_findbuf(buf))
    for _ = 1, 3 do
      go(made.other)
      go(made.mine)
    end
    eq({}, said)
    eq(buf, actions().open(store().get(key(made.mine))))
    vim.cmd('stopinsert')
    eq(win, api.nvim_get_current_win(), 'Enter went to the window it is in')
    eq(tab, api.nvim_get_current_tabpage())
    -- The key that goes back to the list while typing is there too.
    local back = vim.fn.maparg([[<C-\><C-b>]], 't', false, true)
    eq(1, back.buffer)
    ok(api.nvim_win_is_valid(S.pane_win))
    eq({}, said)
  end)

  it('is let go of by the pane when it is opened in a window of your own', function()
    local home, made = scene()
    local buf, win = own_terminal(home, made.mine)
    hide(win)
    local mine = api.nvim_get_current_win()
    board().open()
    go(made.mine)
    eq(buf, pane_buf())
    -- Back in the other tab, the terminal is brought up again there.
    api.nvim_set_current_win(mine)
    vim.cmd('buffer ' .. buf)
    settle()
    eq({ mine }, vim.fn.win_findbuf(buf), 'the pane no longer holds a second window on it')
    eq('agent-chats-summary', vim.bo[pane_buf()].filetype)
    eq({}, said)
  end)
end)

describe('a terminal that is deleted while the pane shows it', function()
  --- What a config does that keeps no dead terminals: when the shell of
  --- one exits, its buffer is deleted. Neovim closes every window that
  --- shows it, the pane among them.
  local function delete(buf)
    local job = vim.bo[buf].channel
    vim.fn.jobstop(job)
    vim.fn.jobwait({ job }, 3000)
    api.nvim_buf_delete(buf, { force = true })
    settle()
  end

  for _, layout in ipairs({ 'tab', 'float' }) do
    it(('does not take the pane with it (%s)'):format(layout), function()
      local home, made = scene({ board = { layout = layout } })
      local buf, win = own_terminal(home, made.mine)
      hide(win)
      board().open()
      local S = board()._state
      go(made.mine)
      eq(buf, pane_buf(), 'the pane shows the live terminal')
      local width = api.nvim_win_get_width(S.win)
      delete(buf)
      -- Nobody asked for the list alone: with the pane gone there would be
      -- one window on the board, and none beside it to go to.
      ok(S.pane_on, 'the pane is still wanted')
      ok(S.pane_win and api.nvim_win_is_valid(S.pane_win), 'and it is there again')
      eq('agent-chats-summary', vim.bo[pane_buf()].filetype)
      eq(S.win, api.nvim_get_current_win(), 'the cursor has not left the list')
      eq(width, api.nvim_win_get_width(S.win), 'which is as wide as it was')
      -- It follows the cursor as it did.
      go(made.other)
      has(pane_text(), '# Another chat')
      go(made.third)
      has(pane_text(), '# A third chat')
    end)
  end

  it('is another thing than the pane being closed, which is asking for the list alone', function()
    local home, made = scene()
    local buf, win = own_terminal(home, made.mine)
    hide(win)
    board().open()
    local S = board()._state
    go(made.mine)
    eq(buf, pane_buf())
    -- `:only` on the list: its terminal is still there, the pane is not.
    vim.cmd('only')
    settle()
    ok(api.nvim_buf_is_valid(buf))
    eq(nil, S.pane_win)
    ok(not S.pane_on, 'the pane stays away')
    eq({ S.win }, api.nvim_tabpage_list_wins(0))
    -- Until it is asked for again.
    board().toggle_pane()
    settle()
    ok(S.pane_win and api.nvim_win_is_valid(S.pane_win))
    eq(buf, pane_buf())
  end)
end)

describe('the pane is the board’s own window', function()
  it('says nothing of a buffer being shown in a window, for anything put in it', function()
    local home, made = scene()
    local buf, win = own_terminal(home, made.mine)
    hide(win)
    pcall(api.nvim_del_augroup_by_name, 'AgentChatsTestUser')
    local heard = {}
    local group = api.nvim_create_augroup('AgentChatsTestUser', { clear = true })
    api.nvim_create_autocmd({ 'BufWinEnter', 'BufWinLeave', 'BufHidden' }, {
      group = group,
      callback = function(ev)
        heard[#heard + 1] = ('%s %s'):format(
          ev.event,
          vim.bo[ev.buf].buftype == 'terminal' and 'a terminal' or vim.bo[ev.buf].filetype
        )
      end,
    })
    board().open()
    heard = {}
    go(made.mine)
    go(made.other)
    actions().open(store().get(key(made.mine)))
    vim.cmd('stopinsert')
    settle()
    go(made.third)
    actions().read(store().get(key(made.third)))
    settle()
    go(made.other)
    eq({}, heard)
    -- Closed with a chat's terminal in the pane, and with the cursor there.
    actions().open(store().get(key(made.mine)))
    vim.cmd('stopinsert')
    settle()
    eq(buf, pane_buf())
    board().close()
    -- (The list is a window like any other: its leaving is said.)
    eq({ 'BufWinLeave agent-chats' }, heard)
    ok(api.nvim_buf_is_valid(buf), 'the terminal is still there, out of sight as before')
    hasnt(table.concat(said, '\n'), 'put back')
  end)
end)
