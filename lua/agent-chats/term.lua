-- Terminals. Opening a chat means one of two things: showing the terminal
-- in this Neovim that already runs it, or starting the agent in a new one.
-- Everything here is plain Neovim (`jobstart` with `term = true`), and
-- `open.where` can be a function for people who place terminals their own
-- way.
--
-- A chat is matched to a terminal two ways: terminals this module started
-- are remembered by chat, and any other terminal is recognised when the
-- chat's process turns out to be a descendant of the terminal's job. So a
-- chat you started by hand in a `:terminal` is found too.

local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local proc = require('agent-chats.util.proc')
local text = require('agent-chats.util.text')

local M = {}

---@class agent_chats.Term
---@field key string?      Chat it runs, once known.
---@field provider string?
---@field owned boolean    Started as the terminal's own job (so the job ending means the chat ended).
---@field trust number?    For terminals opened by a user function: epoch seconds until which `key` is believed without a process to confirm it.
---@field title string?
---@field label (string|table)?  What it runs, for a window title: a chat, `{ agent, name, dir }`, or words.
---@field prompt string?   The first prompt a new chat was started with.

---@type table<integer, agent_chats.Term>
M.terms = {}

local nvim_focused = true
local did_setup = false

-- Terminal buffer -> when something was last typed into it (epoch seconds).
local typed = {}
local key_ns = vim.api.nvim_create_namespace('agent-chats-typed')

local function wall_clock()
  local sec, usec = vim.uv.gettimeofday()
  return sec + usec / 1e6
end

--- When Enter or a printable key last went into terminal `buf` from this
--- Neovim. Hooks say when an agent asks for permission but not when you
--- answer; for a chat hosted here, typing into its terminal after the
--- question is the answer.
---@return number?
function M.typed_at(buf)
  return typed[buf]
end

--- Record that something was typed into `buf` (the key watcher, and tests).
function M.note_typed(buf, at)
  typed[buf] = at or wall_clock()
end

-- What was typed into each terminal since Enter was last pressed there,
-- in the runs it was typed in: a run ends where the cursor may have moved
-- (an arrow key, Esc), so that each is text that stands together.
local runs = {} ---@type table<integer, { text: string, at: number }[]>
-- A run counts for this long: text typed and left for longer is not what
-- holds a queued reply back.
local UNSENT_SECS = 900
local UNSENT_RUNS = 3
-- Keys further apart than this are not one run of text.
local UNSENT_PAUSE = 5

--- Record a key typed into terminal `buf` (the key watcher, and tests).
---@param key string  As Neovim hands it to `vim.on_key`.
function M.note_key(buf, key)
  local b = key:byte()
  if not b then
    return
  end
  -- Enter sends what is there; Ctrl-C and Ctrl-U throw it away.
  if b == 13 or b == 3 or b == 21 then
    runs[buf] = nil
    return
  end
  local list = runs[buf]
  local last = list and list[#list]
  local now = wall_clock()
  if b == 127 or b == 8 then
    -- Backspace takes the last character back.
    if last then
      last.text = last.text:gsub('[%z\1-\127\194-\244][\128-\191]*$', '')
    end
    return
  end
  if b == 23 then
    -- Ctrl-W: the last word.
    if last then
      last.text = last.text:gsub('%S*%s*$', '')
    end
    return
  end
  local printable = (b >= 32 and b <= 126) or (b >= 194 and b <= 244)
  -- Anything else may have moved the cursor, and so may a pause: what
  -- comes next is a run of its own. (A key that answers a dialog is one
  -- key now and another much later, never a run.)
  if last and last.text ~= '' and (not printable or now - last.at > UNSENT_PAUSE) then
    last = { text = '', at = now }
    list[#list + 1] = last
    while #list > UNSENT_RUNS do
      table.remove(list, 1)
    end
  end
  if not printable then
    return
  end
  if not list then
    last = { text = '', at = now }
    list = { last }
    runs[buf] = list
  end
  last.text, last.at = last.text .. key, now
end

local function valid(buf)
  return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
end

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ''
end

--- Whether the user is looking at this terminal right now: the cursor is
--- in it, or it is shown live in the board's pane beside the list the cursor
--- is in (a reply sent from the list is watched arriving there).
function M.is_focused(buf)
  if not (nvim_focused and valid(buf)) then
    return false
  end
  if vim.api.nvim_get_current_buf() == buf then
    return true
  end
  local board = package.loaded['agent-chats.ui.board']
  return board ~= nil and board.is_showing(buf)
end

-----------------------------------------------------------------------------
-- Windows
-----------------------------------------------------------------------------

local function span(total, size)
  if size > 1 then
    return math.min(math.floor(size), total)
  end
  return math.max(10, math.floor(total * size))
end

-- A window of this tab that already holds one of our terminals.
local function reusable_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    -- Only while it still shows a terminal: the user may have put a file there.
    if
      vim.w[win].agent_chats_term
      and not is_float(win)
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == 'terminal'
    then
      return win
    end
  end
end

-- Leave a floating window (the board) for the window behind it.
local function leave_float()
  if not is_float(vim.api.nvim_get_current_win()) then
    return
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= 0 and vim.api.nvim_win_is_valid(prev) and not is_float(prev) then
    vim.api.nvim_set_current_win(prev)
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not is_float(win) then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end

--- Make a window for a terminal and show `buf` in it (a new empty buffer
--- when nil). Returns the window and the buffer.
---@param where string
---@param buf integer?
---@param label string?  What the terminal is for, for a window title.
---@return integer win, integer buf
function M.open_window(where, buf, label)
  local cfg = config.get().open
  buf = buf or vim.api.nvim_create_buf(true, false)
  if where == 'pane' then
    -- The board's right-hand pane; the board opens if it is not already.
    local win = require('agent-chats.ui.board').pane_show(buf, 'term', nil, label)
    if win then
      return win, buf
    end
    where = 'vsplit'
  end
  leave_float()

  local reuse = cfg.reuse and where ~= 'tab' and where ~= 'float' and reusable_win() or nil
  if reuse then
    vim.api.nvim_set_current_win(reuse)
    vim.api.nvim_win_set_buf(reuse, buf)
    return reuse, buf
  end

  local win
  if where == 'float' then
    local width = span(vim.o.columns - 4, cfg.size > 1 and cfg.size or math.max(cfg.size, 0.8))
    local height = span(vim.o.lines - 4, 0.8)
    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      border = config.get().board.border,
      title = ' Agent chat ',
    })
  elseif where == 'tab' then
    vim.cmd('tab split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  elseif where == 'current' then
    win = vim.api.nvim_get_current_win()
    if vim.wo[win].winfixbuf then
      vim.cmd('botright vsplit')
      win = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_win_set_buf(win, buf)
  elseif where == 'split' then
    vim.cmd('botright split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, span(vim.o.lines, cfg.size))
  else
    vim.cmd('botright vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, span(vim.o.columns, cfg.size))
  end
  vim.w[win].agent_chats_term = true
  return win, buf
end

--- Put the cursor in the window showing `buf`, opening one if it is hidden.
---@return integer? win
function M.show(buf)
  if not valid(buf) then
    return nil
  end
  local cfg = config.get().open
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end
  local elsewhere = vim.fn.win_findbuf(buf)[1]
  if elsewhere then
    vim.api.nvim_set_current_win(elsewhere)
    return elsewhere
  end
  local where = type(cfg.where) == 'string' and cfg.where or 'vsplit'
  local win = M.open_window(where, buf)
  if vim.w[win].agent_chats_pane then
    vim.w[win].agent_chats_term = nil
  end
  return win
end

-----------------------------------------------------------------------------
-- Starting agents
-----------------------------------------------------------------------------

-- An agent that exits this soon after it was started did not do what it
-- was started for.
local QUICK_EXIT_SECS = 4

local function on_exit(buf, code)
  local term = M.terms[buf]
  M.terms[buf] = nil
  runs[buf] = nil
  -- (Not one that was killed: closing its terminal, or Neovim, is not the
  -- agent failing.)
  local killed = code > 128 or vim.v.exiting ~= vim.NIL
  if
    term
    and term.quick
    and not killed
    and (vim.uv.hrtime() - (term.born or 0)) / 1e9 < QUICK_EXIT_SECS
  then
    -- Whoever started it gets to keep what it was started with.
    local quick = term.quick
    vim.schedule(function()
      pcall(quick, code)
    end)
  end
  vim.schedule(function()
    if term and term.owned and valid(buf) then
      if code == 0 and config.get().open.close_on_exit then
        local board = package.loaded['agent-chats.ui.board']
        -- Back to the list, but only for someone who was in the board.
        local was_here = board and board.release(buf) and board.has_focus()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        if was_here then
          board.focus()
        end
      else
        -- Keep the exit message readable; let go of the buffer once hidden.
        vim.bo[buf].bufhidden = 'wipe'
        local board = package.loaded['agent-chats.ui.board']
        if board then
          board.pane_ended(buf, code)
        end
      end
    end
    local store = package.loaded['agent-chats.store']
    if store and store.initialized then
      if term and term.owned and term.key then
        store.exited(term.key)
      end
      store.refresh({})
    end
  end)
end

-----------------------------------------------------------------------------
-- A chat's terminal: the ways back, and the user's own setup
-----------------------------------------------------------------------------

local complained = false

--- The chat that terminal `buf` holds, as far as is known.
---@return agent_chats.Chat?
local function chat_in(buf)
  local store = package.loaded['agent-chats.store']
  if not store then
    return nil
  end
  local term = M.terms[buf]
  if term and term.key and store.chats[term.key] then
    return store.chats[term.key]
  end
  for _, chat in pairs(store.chats) do
    if chat.term == buf then
      return chat
    end
  end
  return nil
end

--- Make terminal `buf` a chat's terminal, once: map the way back to the
--- list, and, for a terminal this plugin started, hand it to the user's own
--- setup (`open.on_open`, and the User event AgentChatsTerminal). Whatever
--- that sets is the last word: nothing here is applied to the buffer again.
---
--- A terminal the user made (a chat started by hand in a `:terminal`, one
--- from `open.where`) is theirs: it gets the one key that goes back while
--- typing, as it always has, and is otherwise left as they set it up.
---@param chat agent_chats.Chat?  The chat it holds, when the caller knows.
---@return string? typing, string? normal  The keys that go back to the list from it now: while typing, and in its normal mode.
function M.prepare(buf, chat)
  if not valid(buf) or vim.bo[buf].buftype ~= 'terminal' then
    return nil, nil
  end
  if vim.b[buf].agent_chats_ready then
    return M.back_keys(buf)
  end
  vim.b[buf].agent_chats_ready = true
  local cfg = config.get().open
  local keys = require('agent-chats.keys')
  local function to_list()
    -- The board when it is open, else a new one: either way, the list.
    require('agent-chats.ui.board').open()
  end
  local back = false
  if type(cfg.back_key) == 'string' and cfg.back_key ~= '' then
    -- While typing, every plain key belongs to the agent. The default
    -- gives way to a terminal mapping of yours on it; a key you chose
    -- yourself is bound, as with `keys`.
    if
      keys.map_key(buf, 't', cfg.back_key, to_list, 'back to the list', config.explicit_back_key())
    then
      back = cfg.back_key
    end
  end
  vim.b[buf].agent_chats_back = back
  vim.b[buf].agent_chats_back_normal = false
  local term = M.terms[buf]
  if not (term and term.owned) then
    return M.back_keys(buf)
  end
  -- In the terminal's normal mode the board's own "back" does it too.
  local bound = keys.map(buf, 'n', 'back', to_list, 'back to the list')
  for _, lhs in ipairs(bound) do
    if keys.shown({ lhs }) then
      vim.b[buf].agent_chats_back_normal = lhs
      break
    end
  end

  chat = chat or chat_in(buf)
  if type(cfg.on_open) == 'function' then
    local ok, said = pcall(cfg.on_open, buf, chat)
    if not ok and not complained then
      complained = true
      vim.schedule(function()
        vim.notify('agent-chats: open.on_open failed: ' .. tostring(said), vim.log.levels.WARN)
      end)
    elseif ok and type(said) == 'table' then
      -- Keys of its own that go back to the list, which it vouches for:
      -- the title names them in place of the ones it mapped over.
      local function key(lhs)
        return type(lhs) == 'string' and lhs ~= '' and lhs or false
      end
      local named = { normal = key(said.back), typing = key(said.back_typing) }
      vim.b[buf].agent_chats_said = named
      local unmapped = {}
      if named.normal and not keys.yours(named.normal, 'n', buf) then
        unmapped[#unmapped + 1] = ('back = %q'):format(named.normal)
      end
      if named.typing and not keys.yours(named.typing, 't', buf) then
        unmapped[#unmapped + 1] = ('back_typing = %q'):format(named.typing)
      end
      if #unmapped > 0 and not complained then
        complained = true
        vim.schedule(function()
          vim.notify(
            ('agent-chats: open.on_open returned %s, but nothing of yours is mapped there in the terminal, so the title does not name it'):format(
              table.concat(unmapped, ' and ')
            ),
            vim.log.levels.WARN
          )
        end)
      end
    end
  end
  pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = 'AgentChatsTerminal',
    modeline = false,
    data = { buf = buf, key = chat and chat.key or nil, chat = chat },
  })
  return M.back_keys(buf)
end

--- The keys that go back to the list from terminal `buf` as it is now: the
--- one for while typing, and the one for its normal mode. A key your own
--- setup has since put something else on is not named: it is yours now.
---@return string? typing, string? normal
function M.back_keys(buf)
  if not valid(buf) then
    return nil, nil
  end
  local keys = require('agent-chats.keys')
  local typing, normal = vim.b[buf].agent_chats_back, vim.b[buf].agent_chats_back_normal
  typing = type(typing) == 'string' and keys.is_ours(buf, 't', typing) and typing or nil
  normal = type(normal) == 'string' and keys.is_ours(buf, 'n', normal) and normal or nil
  -- What `open.on_open` said its own mappings are comes first, where there
  -- is a mapping of yours on the key it named: a title must not name a key
  -- that does nothing.
  local said = vim.b[buf].agent_chats_said
  if type(said) == 'table' then
    if type(said.typing) == 'string' and keys.yours(said.typing, 't', buf) then
      typing = said.typing
    end
    if type(said.normal) == 'string' and keys.yours(said.normal, 'n', buf) then
      normal = said.normal
    end
  end
  return typing, normal
end

---@class agent_chats.SpawnSpec
---@field argv string[]
---@field cwd string?
---@field key string?       Chat key, when it is known before the agent starts.
---@field provider string?
---@field title string?
---@field label (string|table)?  What it runs, for a window title: a chat, `{ agent, name, dir }`, or words; `title` when nil.
---@field prompt string?    The first prompt, for a chat that is new.
---@field on_quick_exit fun(code: integer)?  Called when the agent exits within a few seconds of starting: it did not do what it was started for.
---@field chat agent_chats.Chat?
---@field env table<string, string>?

--- Start an agent in a terminal.
---@param spec agent_chats.SpawnSpec
---@return integer? buf, string? err
function M.spawn(spec)
  local cfg = config.get().open
  if spec.cwd and not fs.is_dir(spec.cwd) then
    return nil, ('its folder no longer exists (%s)'):format(fs.tilde(spec.cwd))
  end
  if vim.fn.executable(spec.argv[1]) ~= 1 then
    return nil, ('%s is not on PATH'):format(spec.argv[1])
  end
  local long = M.too_long(spec.argv)
  if long then
    return nil, long
  end

  if type(cfg.where) == 'function' then
    local ok, buf = pcall(cfg.where, {
      argv = spec.argv,
      cmdline = text.cmdline(spec.argv),
      cwd = spec.cwd,
      env = spec.env,
      title = spec.title,
      chat = spec.chat,
    })
    if not ok then
      return nil, 'open.where failed: ' .. tostring(buf)
    end
    if valid(buf) then
      -- Whatever runs there is the user's business (a shell the command was
      -- typed into, say), so the chat is only assumed to live there briefly,
      -- until its process confirms it.
      M.terms[buf] = {
        key = spec.key,
        provider = spec.provider,
        owned = false,
        trust = os.time() + 20,
        title = spec.title,
        label = spec.label,
      }
      M.prepare(buf, spec.chat)
      return buf, nil
    end
    return nil, nil
  end

  local win, buf = M.open_window(cfg.where, nil, spec.label or spec.title)
  local ok, job = pcall(vim.api.nvim_buf_call, buf, function()
    return vim.fn.jobstart(spec.argv, {
      term = true,
      cwd = spec.cwd,
      env = spec.env,
      on_exit = function(_, code)
        on_exit(buf, code)
      end,
    })
  end)
  if not ok or type(job) ~= 'number' or job <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil, 'could not start ' .. spec.argv[1] .. (ok and '' or (': ' .. tostring(job)))
  end
  -- A new chat of an agent that names its session itself has no key yet.
  -- It is listed under a stand-in until the session shows up (store.lua),
  -- or there would be no way back to this terminal from the board.
  -- (The process id keeps the stand-in apart from those of other
  -- Neovims and of earlier sessions: buffer numbers repeat.)
  local standin = not spec.key
      and ('%s:term-%d-%d'):format(spec.provider or 'agent', vim.uv.os_getpid(), buf)
    or nil
  M.terms[buf] = {
    key = spec.key or standin,
    -- Kept when the terminal goes by its chat's real key: what was written
    -- for the stand-in is found by it (see `store.current_key`).
    standin = standin,
    unstarted = spec.key == nil or nil,
    started_for = spec.key,
    born = vim.uv.hrtime(),
    quick = spec.on_quick_exit,
    provider = spec.provider,
    owned = true,
    title = spec.title,
    label = spec.label,
    prompt = spec.prompt,
    cwd = spec.cwd,
    started = os.time(),
  }
  vim.b[buf].agent_chats = true
  M.prepare(buf, spec.chat)
  -- The pane was titled before there was a terminal in it: now it can say
  -- how to get back.
  local shown = package.loaded['agent-chats.ui.board']
  if shown then
    shown.pane_entered(buf, spec.chat or spec.label or spec.title)
  end
  if spec.title then
    -- Named as the conversation of a chat is ("Agent chat: ..."), and not
    -- like a path: a tab line cuts what looks like one down to initials.
    local agent = spec.provider and require('agent-chats.providers').label(spec.provider) or nil
    -- (What it is called on its row, where that is known: a new chat is
    -- its first prompt there, not the folder it was started in.)
    local called = (type(spec.label) == 'table' and not spec.label.key and spec.label.name)
      or spec.title
    pcall(
      vim.api.nvim_buf_set_name,
      buf,
      ('Agent chat: %s%s [%d]'):format(
        (called:gsub('[/\\]', '∕')),
        agent and (' · ' .. agent) or '',
        buf
      )
    )
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    -- A terminal window follows output only with the cursor on the last line.
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    M.start_typing(buf)
  end
  return buf, nil
end

--- Go into typing in terminal `buf` (when `open.start_insert` is on and
--- the cursor is still there), a moment from now. Not at once: when this is
--- reached from a box that was being typed in, that insert mode is still
--- being left, and Neovim ignores `:startinsert` until it has been. The
--- cursor would be left in the terminal's normal mode, where nothing that
--- is typed reaches the agent.
function M.start_typing(buf)
  if not config.get().open.start_insert then
    return
  end
  vim.schedule(function()
    if
      valid(buf)
      and vim.api.nvim_get_current_buf() == buf
      and vim.bo[buf].buftype == 'terminal'
      and vim.api.nvim_get_mode().mode ~= 't'
    then
      vim.cmd.startinsert()
    end
  end)
end

-- The most one argument of a command may hold (Linux: 128 KiB, the
-- terminator included). A program started with more does not start: the
-- terminal would open and close on nothing, and the text would be gone.
local ARG_MAX = 128 * 1024 - 1

--- Why `argv` cannot be run at all, in words; nil when it can.
---@param argv string[]
---@return string?
function M.too_long(argv)
  for _, a in ipairs(argv) do
    if #a > ARG_MAX then
      return ('what it would be started with is too long for a program to be given when it starts (%d KB; the limit is %d KB). Start it with less and paste the rest into its terminal'):format(
        math.ceil(#a / 1024),
        math.floor(ARG_MAX / 1024)
      )
    end
  end
  return nil
end

-- Chats a reply is being answered for in the background right now (their
-- agent runs with no terminal): chat key -> the process.
local backgrounds = {} ---@type table<string, { pid: integer, started: integer }>

--- Whether a reply to `chat` that was sent from here is being answered in
--- the background at this moment. Such a chat is running, and not in any
--- terminal: there is nothing to type into, here or elsewhere.
---@return boolean
function M.in_background(chat)
  local run = backgrounds[chat.key]
  if not run then
    return false
  end
  if not proc.alive(run.pid) then
    backgrounds[chat.key] = nil
    return false
  end
  return true
end

--- Run an agent with no terminal (a background reply). `cb(code, stderr)`.
---@param spec agent_chats.SpawnSpec
---@param cb fun(code: integer, stderr: string)?
---@return boolean ok, string? err, integer? pid
function M.background(spec, cb)
  if spec.cwd and not fs.is_dir(spec.cwd) then
    return false, ('its folder no longer exists (%s)'):format(fs.tilde(spec.cwd))
  end
  if vim.fn.executable(spec.argv[1]) ~= 1 then
    return false, ('%s is not on PATH'):format(spec.argv[1])
  end
  local long = M.too_long(spec.argv)
  if long then
    return false, long
  end
  local job
  local ok, err = pcall(function()
    job = vim.system(
      spec.argv,
      { cwd = spec.cwd, env = spec.env, text = true, stdin = false },
      function(res)
        vim.schedule(function()
          if
            spec.key
            and job
            and backgrounds[spec.key]
            and backgrounds[spec.key].pid == job.pid
          then
            backgrounds[spec.key] = nil
          end
          if cb then
            cb(res.code, res.stderr or '')
          end
        end)
      end
    )
  end)
  if not ok or not job then
    return false, tostring(err)
  end
  if spec.key then
    backgrounds[spec.key] = { pid = job.pid, started = os.time() }
  end
  return true, nil, job.pid
end

-----------------------------------------------------------------------------
-- Matching chats to terminals
-----------------------------------------------------------------------------

--- The terminal whose job process `pid` is, or runs under: its buffer and
--- how many processes lie between. nil when there is none, and when an
--- editor lies between: an agent inside a Neovim that runs in a terminal
--- of this one is that Neovim's, and keys sent to our terminal would go to
--- the editor, not the agent.
---@param jobs table<integer, integer>  Job process id -> terminal buffer.
---@return integer? buf, integer? hops
function M.job_above(pid, jobs)
  if jobs[pid] then
    return jobs[pid], 0
  end
  for i, anc in ipairs(proc.ancestors(pid, 12)) do
    local st = proc.stat(anc)
    if st and (st.comm == 'nvim' or st.comm == 'vim') then
      return nil
    end
    if jobs[anc] then
      return jobs[anc], i
    end
  end
  return nil
end

--- Whether the terminal `buf` has `chat` in it right now. The index says
--- so as of its last look, which can be seconds old, or older with the
--- watcher off: an agent started inside a shell of yours may have exited
--- since, and what is typed then goes to the shell.
---@return boolean
function M.still_hosts(buf, chat)
  if not valid(buf) or vim.bo[buf].buftype ~= 'terminal' then
    return false
  end
  local term = M.terms[buf]
  if term and term.owned then
    -- Started here for a chat: it is forgotten the moment its job ends.
    return true
  end
  local ok, job = pcall(vim.fn.jobpid, vim.bo[buf].channel)
  if not ok or type(job) ~= 'number' or not chat.pid or not proc.alive(chat.pid) then
    return false
  end
  return M.job_above(chat.pid, { [job] = buf }) == buf
end

--- Whether the agent of `chat` is what reads terminal `buf` right now.
--- An agent that was started by hand in a shell and then suspended
--- (Ctrl-Z), or sent to the background, leaves the shell reading: what is
--- pasted would be run by the shell as commands. A terminal the plugin
--- started for the chat has no shell in between.
---@return boolean
function M.reads(buf, chat)
  local term = M.terms[buf]
  if term and term.owned then
    return true
  end
  if not chat.pid then
    return true
  end
  return proc.foreground(chat.pid) ~= false
end

--- Set `chat.term` for every chat hosted by a terminal of this Neovim.
---@param chats table<string, agent_chats.Chat>
---@return boolean changed
function M.attach(chats)
  local now = os.time()
  local by_key = {}
  for buf, term in pairs(M.terms) do
    if not valid(buf) then
      M.terms[buf] = nil
    elseif term.key and (term.owned or (term.trust and now < term.trust)) then
      by_key[term.key] = buf
    end
  end

  local jobs, any = {}, false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == 'terminal' then
      local ok, pid = pcall(vim.fn.jobpid, vim.bo[buf].channel)
      if ok and type(pid) == 'number' and pid > 0 then
        jobs[pid] = buf
        any = true
      end
    end
  end

  -- The process is the evidence that counts: a terminal belongs to the chat
  -- whose agent runs in it now, whatever chat it was started for (the user
  -- may have switched conversations inside the agent).
  -- Two sessions can sit under one terminal (an agent that started another
  -- agent): the terminal is that of the one nearest to its job.
  local found, claimed = {}, {}
  if any then
    --- Whether chat `a` started chat `b`, directly or through others.
    local function above(a, b)
      local up, hops = chats[b] and chats[b].parent, 0
      while up and hops < 16 do
        if up == a then
          return true
        end
        up, hops = chats[up] and chats[up].parent, hops + 1
      end
      return false
    end
    --- Between two sessions equally near to the job of `buf` (an opencode
    --- chat and the subagent sessions it runs share one process): the one
    --- the terminal was started for, else the one that started the other.
    local function wins(key, hops, best, buf)
      if not best then
        return true
      end
      if hops ~= best.hops then
        return hops < best.hops
      end
      local started_for = M.terms[buf] and M.terms[buf].started_for
      if started_for == key or started_for == best.key then
        return started_for == key
      end
      if above(key, best.key) or above(best.key, key) then
        return above(key, best.key)
      end
      return key < best.key
    end
    local nearest = {} ---@type table<integer, { key: string, hops: integer }>
    for key, chat in pairs(chats) do
      if chat.live and chat.pid then
        local buf, hops = M.job_above(chat.pid, jobs)
        if buf and wins(key, hops, nearest[buf], buf) then
          nearest[buf] = { key = key, hops = hops }
        end
      end
    end
    for buf, best in pairs(nearest) do
      found[best.key], claimed[buf] = buf, best.key
      if M.terms[buf] then
        M.terms[buf].key, M.terms[buf].unstarted = best.key, nil
      end
    end
  end
  -- Otherwise, what a terminal was started for (the agent may not have
  -- registered yet), unless a running chat has claimed that terminal.
  for key, buf in pairs(by_key) do
    if not found[key] and not claimed[buf] and chats[key] then
      found[key] = buf
    end
  end

  local changed = false
  for key, chat in pairs(chats) do
    if chat.term ~= found[key] then
      chat.term = found[key]
      changed = true
    end
  end
  return changed
end

--- The terminal of this Neovim that hosts `chat`, if any.
---@return integer?
function M.find(chat)
  if valid(chat.term) then
    return chat.term
  end
  for buf, term in pairs(M.terms) do
    if
      term.key == chat.key
      and valid(buf)
      and (term.owned or (term.trust and os.time() < term.trust))
    then
      return buf
    end
  end
end

-----------------------------------------------------------------------------
-- Typing into a terminal
-----------------------------------------------------------------------------

-- How often the terminal is looked at for the text just pasted into it.
local ECHO_POLL_MS = 40
-- Terminals a reply is being typed into right now (pasted, Enter to come).
local typing = {} ---@type table<integer, boolean>

--- The end of what the terminal `buf` holds: its screen and a little above.
local function tail_text(buf, lines)
  local n = vim.api.nvim_buf_line_count(buf)
  return table.concat(
    vim.api.nvim_buf_get_lines(buf, math.max(0, n - (lines or 200)), n, false),
    '\n'
  )
end

--- Whether terminal `buf` holds text of the user's that has not been sent:
--- something typed there since Enter was last pressed, and still to be
--- seen on its screen. Anything pasted now would run into that text, and
--- Enter would send both as one message.
---
--- By what is on the screen, not by the keys alone: a key that answers a
--- dialog is typed and gone, and so is text that was deleted again.
---@return boolean
function M.has_unsent(buf)
  local list = runs[buf]
  if not list or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local screen
  for _, run in ipairs(list) do
    local text = vim.trim(run.text)
    local n = vim.fn.strchars(text)
    -- (Shorter than this it is on any screen somewhere.) Its end is what
    -- is looked for: the start may be keys that went elsewhere.
    if n >= 4 and wall_clock() - run.at < UNSENT_SECS then
      screen = screen or tail_text(buf, 60)
      if screen:find(vim.fn.strcharpart(text, math.max(0, n - 6)), 1, true) then
        return true
      end
    end
  end
  return false
end

local function occurrences(haystack, needle)
  if needle == '' then
    return 0
  end
  local n, from = 0, 1
  while true do
    local s, e = haystack:find(needle, from, true)
    if not s then
      return n
    end
    n, from = n + 1, e + 1
  end
end

-- What an input box puts around the text in it: its prompt mark and the
-- lines of its frame.
local FRAME =
  { '│', '┃', '║', '|', '❯', '›', '»', '>', '▌', '▎', '█', '•', '●', '➜' }

--- A line of a terminal without what frames it: the text an input box
--- holds, when the line is one of an input box.
---@return string
function M._core(line)
  local s = vim.trim(line)
  local again = true
  while again do
    again = false
    for _, mark in ipairs(FRAME) do
      if s:sub(1, #mark) == mark then
        s, again = vim.trim(s:sub(#mark + 1)), true
      end
      if #s >= #mark and s:sub(-#mark) == mark then
        s, again = vim.trim(s:sub(1, #s - #mark)), true
      end
    end
  end
  return s
end

--- Paste `message` into the terminal `buf` and press Enter, once the
--- terminal shows that it took the text.
---
--- An agent may be showing a dialog of its own that nothing reports: a
--- permission prompt, "trust this folder?", "update now?". Keys typed into
--- one are answers to it, and Enter confirms whatever it has selected. So
--- the text goes in as a paste, which a dialog does not act on, and Enter
--- is pressed only after the text has appeared on the screen: in an input
--- box it does, in a dialog it does not. When it does not appear, nothing
--- is sent.
---
--- `done(ok, why)`: `why` is "unseen" when the terminal never showed the
--- text, "closed" when it went away meanwhile.
---@param done fun(ok: boolean, why: string?)?
---@return boolean started  false when there is no terminal to type into.
function M.send(buf, message, done)
  done = done or function() end
  if not valid(buf) or vim.bo[buf].buftype ~= 'terminal' then
    return false
  end
  local chan = vim.bo[buf].channel
  if not chan or chan <= 0 then
    return false
  end
  if typing[buf] then
    -- One at a time: a second paste before the first one's Enter would
    -- end up in the same message.
    vim.schedule(function()
      done(false, 'busy')
    end)
    return true
  end
  typing[buf] = true
  local finished = done
  done = function(...)
    typing[buf] = nil
    return finished(...)
  end
  local body = message:gsub('\r\n?', '\n')
  -- Nothing in it may end the paste early (the rest would be typed as keys)
  -- or drive the terminal: no escape and no control character but the
  -- line break and the tab.
  body = body:gsub('\27%[20[01]~', ''):gsub('[%z\1-\8\11-\31\127]', '')
  --- Blanks as a screen has them: a tab is shown as spaces.
  local function flat(str)
    return (str:gsub('[ \t]+', ' '))
  end
  -- What to look for: the start of its first line, short enough to sit on
  -- one screen line of any input box.
  local first = flat(vim.trim(body:match('[^\n]*%S[^\n]*') or ''))
  local probe = vim.trim(text.clip(first, 16))
  -- A very short text ("2", "yes") is on every screen somewhere: a dialog
  -- with a countdown would seem to show it. It counts as shown only on a
  -- line of its own, as an input box has it.
  local short = vim.fn.strchars(first) <= 6
  --- How often `tail` shows the text as an agent's input box would.
  local function shown_in(tail)
    tail = flat(tail)
    if short then
      local n = 0
      for line in (tail .. '\n'):gmatch('([^\n]*)\n') do
        if M._core(line) == first then
          n = n + 1
        end
      end
      return n
    end
    -- Not what the terminal itself echoes while its program is not reading
    -- yet (an agent still starting): that echo shows the paste's own
    -- brackets, `^[[200~`, which no input box does.
    return occurrences(tail, probe) - occurrences(tail, '^[[200~' .. probe)
  end
  local before = tail_text(buf)
  local seen, folded = shown_in(before), occurrences(before:lower(), 'pasted')
  -- Bracketed paste also keeps a multi-line message one message; without
  -- it each newline would submit what came before.
  if not pcall(vim.api.nvim_chan_send, chan, '\27[200~' .. body .. '\27[201~') then
    typing[buf] = nil
    return false
  end
  local cfg = config.get().reply
  local started = vim.uv.hrtime()
  local function enter()
    if not valid(buf) then
      return done(false, 'closed')
    end
    pcall(vim.api.nvim_chan_send, vim.bo[buf].channel, '\r')
    done(true)
  end
  local function look()
    if not valid(buf) then
      return done(false, 'closed')
    end
    local now = tail_text(buf)
    -- A long paste is shown folded ("[Pasted text #1 +12 lines]") by every
    -- agent that folds them.
    local shown = probe == '' or shown_in(now) > seen or occurrences(now:lower(), 'pasted') > folded
    local waited = (vim.uv.hrtime() - started) / 1e6
    if shown then
      -- The input box needs a moment to take the text in before Enter.
      return vim.defer_fn(enter, math.max(0, math.floor(cfg.paste_delay - waited)))
    end
    if waited >= cfg.echo_wait then
      return done(false, 'unseen')
    end
    vim.defer_fn(look, ECHO_POLL_MS)
  end
  vim.defer_fn(look, ECHO_POLL_MS)
  return true
end

-----------------------------------------------------------------------------
-- Setup
-----------------------------------------------------------------------------

function M.setup()
  if did_setup then
    return
  end
  did_setup = true
  local group = vim.api.nvim_create_augroup('AgentChatsTerm', { clear = true })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      nvim_focused = true
    end,
  })
  vim.api.nvim_create_autocmd('FocusLost', {
    group = group,
    callback = function()
      nvim_focused = false
    end,
  })
  -- Looking at a chat's terminal is reading it.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'FocusGained' }, {
    group = group,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].buftype ~= 'terminal' then
        return
      end
      local store = package.loaded['agent-chats.store']
      if not store or not store.initialized then
        return
      end
      for key, chat in pairs(store.chats) do
        if chat.term == buf and chat.status == 'done' then
          require('agent-chats.state').mark_seen(key)
          store.touch()
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(ev)
      -- A terminal wiped out by hand takes its agent with it. The job's own
      -- exit is reported after this, to a terminal that is forgotten by
      -- then: the chat is said to be over here.
      local term = M.terms[ev.buf]
      M.terms[ev.buf] = nil
      typed[ev.buf], runs[ev.buf] = nil, nil
      if term and term.owned and term.key then
        vim.schedule(function()
          local store = package.loaded['agent-chats.store']
          if store and store.initialized then
            store.exited(term.key)
            store.refresh({})
          end
        end)
      end
    end,
  })
  -- Runs for every key, so it does as little as it can, and only while
  -- typing into a terminal.
  vim.on_key(function(key, as_typed)
    local k = (as_typed and as_typed ~= '') and as_typed or key
    if k == '' or vim.api.nvim_get_mode().mode ~= 't' then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= 'terminal' then
      return
    end
    -- Enter and printable keys are an answer to what the agent asked.
    local b = k:byte()
    if #k == 1 and (b == 13 or (b >= 32 and b <= 126)) then
      typed[buf] = wall_clock()
    end
    M.note_key(buf, k)
  end, key_ns)
end

--- Forget every terminal (tests).
function M.reset()
  M.terms = {}
  backgrounds = {}
  typed = {}
  runs = {}
  typing = {}
  nvim_focused = true
  complained = false
end

return M
