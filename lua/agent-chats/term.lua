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

local function valid(buf)
  return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
end

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ''
end

--- Whether the user is looking at this terminal right now.
function M.is_focused(buf)
  return nvim_focused and valid(buf) and vim.api.nvim_get_current_buf() == buf
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

local function on_exit(buf, code)
  local term = M.terms[buf]
  M.terms[buf] = nil
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

---@class agent_chats.SpawnSpec
---@field argv string[]
---@field cwd string?
---@field key string?       Chat key, when it is known before the agent starts.
---@field provider string?
---@field title string?
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
      }
      return buf, nil
    end
    return nil, nil
  end

  local win, buf = M.open_window(cfg.where, nil, spec.title)
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
  M.terms[buf] = {
    -- A new chat of an agent that names its session itself has no key yet.
    -- It is listed under a stand-in until the session shows up (store.lua),
    -- or there would be no way back to this terminal from the board.
    -- (The process id keeps the stand-in apart from those of other
    -- Neovims and of earlier sessions: buffer numbers repeat.)
    key = spec.key or ('%s:term-%d-%d'):format(spec.provider or 'agent', vim.uv.os_getpid(), buf),
    unstarted = spec.key == nil or nil,
    started_for = spec.key,
    provider = spec.provider,
    owned = true,
    title = spec.title,
    cwd = spec.cwd,
    started = os.time(),
  }
  vim.b[buf].agent_chats = true
  if spec.title then
    pcall(
      vim.api.nvim_buf_set_name,
      buf,
      ('agent-chats://%s/%s#%d'):format(spec.provider or 'agent', spec.title, buf)
    )
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    -- A terminal window follows output only with the cursor on the last line.
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    if cfg.start_insert then
      vim.cmd.startinsert()
    end
  end
  return buf, nil
end

--- Run an agent with no terminal (a background reply). `cb(code, stderr)`.
---@param spec agent_chats.SpawnSpec
---@param cb fun(code: integer, stderr: string)?
---@return boolean ok, string? err
function M.background(spec, cb)
  if spec.cwd and not fs.is_dir(spec.cwd) then
    return false, ('its folder no longer exists (%s)'):format(fs.tilde(spec.cwd))
  end
  if vim.fn.executable(spec.argv[1]) ~= 1 then
    return false, ('%s is not on PATH'):format(spec.argv[1])
  end
  local ok, err = pcall(
    vim.system,
    spec.argv,
    { cwd = spec.cwd, env = spec.env, text = true, stdin = false },
    function(res)
      if cb then
        vim.schedule(function()
          cb(res.code, res.stderr or '')
        end)
      end
    end
  )
  if not ok then
    return false, tostring(err)
  end
  return true, nil
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
local function tail_text(buf)
  local n = vim.api.nvim_buf_line_count(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, math.max(0, n - 200), n, false), '\n')
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
  -- What to look for: the start of its first line, short enough to sit on
  -- one screen line of any input box.
  local probe = vim.trim(text.clip(vim.trim(body:match('[^\n]*%S[^\n]*') or ''), 16))
  local before = tail_text(buf)
  local seen, folded = occurrences(before, probe), occurrences(before:lower(), 'pasted')
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
    local shown = probe == ''
      or occurrences(now, probe) > seen
      or occurrences(now:lower(), 'pasted') > folded
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
      M.terms[ev.buf] = nil
      typed[ev.buf] = nil
    end,
  })
  -- Runs for every key, so it does as little as it can: only Enter and
  -- printable keys count, and only while typing into a terminal.
  vim.on_key(function(key, as_typed)
    local k = (as_typed and as_typed ~= '') and as_typed or key
    if #k ~= 1 then
      return
    end
    local b = k:byte()
    if b ~= 13 and (b < 32 or b > 126) then
      return
    end
    if vim.api.nvim_get_mode().mode ~= 't' then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype == 'terminal' then
      typed[buf] = wall_clock()
    end
  end, key_ns)
end

--- Forget every terminal (tests).
function M.reset()
  M.terms = {}
  typed = {}
  typing = {}
  nvim_focused = true
end

return M
