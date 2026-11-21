-- Everything you can do to a chat. The board's keys and the :Chats command
-- both end up here.

local async = require('agent-chats.util.async')
local config = require('agent-chats.config')
local display = require('agent-chats.display')
local fs = require('agent-chats.util.fs')
local git = require('agent-chats.util.git')
local providers = require('agent-chats.providers')
local state = require('agent-chats.state')
local store = require('agent-chats.store')
local term = require('agent-chats.term')
local text = require('agent-chats.util.text')

local M = {}

local function info(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = 'Agent chats' })
end

local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = 'Agent chats' })
end

local function board()
  return require('agent-chats.ui.board')
end

local function changed()
  store.touch()
end

--- Refresh shortly after starting something, so its status shows up.
local function refresh_soon()
  vim.defer_fn(function()
    store.refresh({ full = true })
  end, 1200)
end

local function runnable(chat)
  local p = providers.get(chat.provider)
  if not p then
    warn(
      ('This chat belongs to "%s", an agent that is not registered any more.'):format(chat.provider)
    )
    return nil
  end
  if not providers.executable(p.name) then
    warn(
      ('Cannot start %s: `%s` is not on PATH. Set providers.%s.cmd to how you start it.'):format(
        p.label,
        config.provider(p.name).cmd[1],
        p.name
      )
    )
    return nil
  end
  return p
end

--- A subagent is part of the chat that started it: it can be read, and
--- that is all. Says so for one (naming what to do instead) and returns
--- true; otherwise false. `done` and `verb`: "pinned", "pin".
local function is_part(chat, done, verb)
  if not chat.subagent then
    return false
  end
  local parent = chat.parent and store.get(chat.parent) or nil
  info(
    ('A subagent cannot be %s; %s the chat it belongs to%s.'):format(
      done,
      verb,
      parent and (' (“' .. display.title(parent, 40) .. '”)') or ''
    )
  )
  return true
end

--- A new chat whose agent has started no session yet is listed under a
--- stand-in. What is attached to a chat (a pin, labels, a note, a name) is
--- kept under the chat's own name, which this one does not have yet. Says
--- so for one and returns true.
local function is_unnamed(chat)
  if not chat.unstarted then
    return false
  end
  info('This chat has not started yet. Send it its first prompt, then come back to this.')
  return true
end

--- A session that has not been sent a prompt has no conversation to act
--- on. Says so for one and returns true.
local function is_blank(chat, what)
  if not chat.stub then
    return false
  end
  info(('Nothing has been said in this chat yet, so there is nothing to %s.'):format(what))
  return true
end

local function enter_terminal(buf)
  local win = term.show(buf)
  if win then
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    if config.get().open.start_insert then
      vim.cmd.startinsert()
    end
  end
  return win
end

-----------------------------------------------------------------------------
-- Opening and reading
-----------------------------------------------------------------------------

--- Read the whole conversation.
---@param chat agent_chats.Chat
---@param opts { index: integer?, query: string? }?
function M.transcript(chat, opts)
  if chat.stub then
    info('Nothing has been said in this chat yet.')
    return
  end
  -- Reading it is seeing it.
  if chat.status == 'done' then
    state.mark_seen(chat.key)
    changed()
  end
  return require('agent-chats.ui.transcript').open(chat, opts)
end

--- Go to the chat: its terminal if it runs in this Neovim, a resumed
--- session if it ended, the conversation if it runs somewhere else.
---@param chat agent_chats.Chat
---@return integer? buf The terminal now showing the chat.
function M.open(chat)
  if chat.subagent then
    M.transcript(chat)
    return nil
  end
  local buf = term.find(chat)
  if buf then
    enter_terminal(buf)
    state.mark_seen(chat.key)
    changed()
    return buf
  end
  if chat.live then
    info(
      ('This chat is running outside this Neovim (pid %s), so it can only be read here.'):format(
        tostring(chat.pid or '?')
      )
    )
    M.transcript(chat)
    return nil
  end
  local p = runnable(chat)
  if not p then
    return nil
  end
  local new_buf, err = term.spawn({
    argv = p.resume_cmd(chat),
    cwd = chat.cwd,
    key = chat.key,
    provider = p.name,
    title = display.title(chat, 40),
    chat = chat,
  })
  if err then
    warn('Could not resume the chat: ' .. err)
    return nil
  end
  state.mark_seen(chat.key)
  refresh_soon()
  return new_buf
end

-----------------------------------------------------------------------------
-- Replying
-----------------------------------------------------------------------------

--- Whether typing into `chat` right now would land in a question of the
--- agent's own instead of its input box. Says so and, unless `stay`, goes
--- to the chat.
local function at_a_prompt(chat, stay)
  if chat.status ~= 'attention' or not term.find(chat) then
    return false
  end
  if chat.inferred then
    -- A guess: it has been quiet on a tool call, which is what a
    -- permission prompt looks like from outside.
    info(
      'This chat may be waiting at a question of its own (it is quiet on a tool call). Look at it first: what is typed now could go into that question.'
    )
  else
    local what = display.waiting(chat, store.get)[1]
    info(
      ('This chat is waiting for your answer%s. Answer it there first: what is typed now would go into that question.'):format(
        what and (' (' .. what .. ')') or ''
      )
    )
  end
  if not stay then
    M.open(chat)
  end
  return true
end

local CLOSED =
  "Could not type into the chat's terminal: it has closed. Open the chat again and reply there."

--- Paste `message` into the terminal `buf` that hosts `chat` and send it.
--- `cb(ok, why)` once it is known whether the terminal took it.
local function type_into(chat, buf, message, opts, cb)
  -- Everything that types into a chat comes through here, so this is where
  -- it is looked at once more, as it is now and not as it was when a menu
  -- opened or a box was being written in.
  local now = store.get(chat.key) or chat
  if not term.still_hosts(buf, now) then
    if not opts.queued then
      warn(
        'The agent of this chat is no longer running in that terminal, so nothing was typed. The board is being brought up to date.'
      )
    end
    store.refresh({ full = true })
    return cb(false, 'gone')
  end
  if opts.queued then
    if now.status == 'attention' or now.status == 'working' then
      return cb(false, 'busy')
    end
  elseif at_a_prompt(now, opts.stay) then
    return cb(false, 'prompt')
  end
  if not opts.queued then
    -- On its way from this moment: what is queued behind it waits until
    -- the chat has taken it up (a queued reply has this mark from the
    -- queue itself).
    state.hand_over(chat.key)
  end
  local started = term.send(buf, message, function(ok, why)
    if not ok and not opts.queued then
      state.sent(chat.key)
    end
    if ok then
      state.mark_seen(chat.key)
    elseif why == 'busy' then
      if not opts.queued then
        warn(
          'Another reply is being typed into this chat at this moment. Send this one again in a second.'
        )
      end
    elseif why == 'unseen' then
      warn(
        ('“%s” did not take the text: its terminal may be showing a question or a dialog of its own. Nothing was sent%s.'):format(
          display.title(chat, 40),
          config.hint('open', '; %s goes to it')
        )
      )
    else
      warn(CLOSED)
    end
    cb(ok, why)
  end)
  if not started then
    if not opts.queued then
      state.sent(chat.key)
    end
    warn(CLOSED)
    cb(false, 'closed')
  end
end

--- Get `message` to the chat. `cb(ok)` reports whether it was handed over.
---@param chat agent_chats.Chat
---@param message string
---@param opts { queued: boolean?, how: string? }?
---@param cb fun(ok: boolean)?
function M.deliver(chat, message, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  local buf = term.find(chat)
  if buf then
    return type_into(chat, buf, message, opts, cb)
  end
  if opts.queued then
    -- A queued reply is typed into a terminal that is there, or not sent.
    return cb(false)
  end
  if chat.live then
    warn(
      'This chat is running outside this Neovim, so nothing can be typed into it from here. Reply in the terminal it runs in.'
    )
    return cb(false)
  end
  local p = runnable(chat)
  if not p then
    return cb(false)
  end

  local function in_terminal()
    if not p.resume_prompt_cmd then
      warn(p.label .. ' cannot be resumed with a message. Open the chat and type the reply there.')
      return cb(false)
    end
    local _, err = term.spawn({
      argv = p.resume_prompt_cmd(chat, message),
      cwd = chat.cwd,
      key = chat.key,
      provider = p.name,
      title = display.title(chat, 40),
      chat = chat,
    })
    if err then
      warn('Could not resume the chat: ' .. err)
      return cb(false)
    end
    state.mark_seen(chat.key)
    refresh_soon()
    cb(true)
  end

  local function in_background()
    if not p.headless_cmd then
      return in_terminal()
    end
    local title = display.title(chat, 60)
    local ok, err = term.background(
      { argv = p.headless_cmd(chat, message), cwd = chat.cwd },
      function(code, stderr)
        if code ~= 0 then
          local why = vim.trim(stderr):match('[^\n]*$') or ''
          warn(
            ('The background reply to “%s” failed (exit %d). %s\nOpen the chat to see how far it got.'):format(
              title,
              code,
              why
            )
          )
        end
        store.refresh({ full = true })
      end
    )
    if not ok then
      warn('Could not start the reply: ' .. tostring(err))
      return cb(false)
    end
    info(('Reply sent to “%s” in the background.'):format(title))
    refresh_soon()
    cb(true)
  end

  local how = opts.how or config.get().reply.ended
  if how == 'terminal' then
    in_terminal()
  elseif how == 'background' then
    in_background()
  else
    vim.ui.select({ 'terminal', 'background' }, {
      prompt = 'This chat has ended. Send the reply how?',
      format_item = function(item)
        return item == 'terminal'
            and 'In a terminal: you watch it work and can approve what it asks'
          or 'In the background: it cannot ask you anything, so steps that need approval fail'
      end,
    }, function(choice)
      if choice == 'terminal' then
        in_terminal()
      elseif choice == 'background' then
        in_background()
      else
        cb(false)
      end
    end)
  end
end

-- Replies written but not sent (the box was left, the question of how to
-- send was dismissed), by chat key. Offered again the next time.
local drafts = {}

--- Ask for a message to `chat`, starting from what was written last time
--- and not sent. `cb(message)` is called only with something to send.
local function compose(chat, title, cb)
  require('agent-chats.ui.input').open(
    { title = title, text = drafts[chat.key] },
    function(message, typed)
      if message then
        drafts[chat.key] = nil
        return cb(message)
      end
      -- Not sent: keep what was written, unless it was cleared on purpose.
      if typed == nil then
        return
      end
      local kept = vim.trim(typed) ~= '' and typed or nil
      if kept and kept ~= drafts[chat.key] then
        info('Not sent. What you wrote is kept: it is there when you reply to this chat again.')
      end
      drafts[chat.key] = kept
    end
  )
end

--- A written reply could not be sent, or sending it was called off (the
--- question of how to send was dismissed). Whatever stopped it has been
--- said by whoever stopped it; this keeps the text and says so.
local function keep_unsent(chat, message)
  drafts[chat.key] = message
  info('Not sent. What you wrote is kept: it is there when you reply to this chat again.')
end

--- Write a reply to the chat and send it.
function M.reply(chat)
  if is_part(chat, 'replied to', 'reply to') then
    return
  end
  if chat.live and not term.find(chat) then
    return warn(
      'This chat is running outside this Neovim, so it cannot be replied to from here. Reply in the terminal it runs in.'
    )
  end
  if at_a_prompt(chat) then
    return
  end
  compose(chat, 'Reply to: ' .. display.title(chat, 60), function(message)
    local now = store.get(chat.key) or chat
    if at_a_prompt(now) then
      drafts[chat.key] = message
      return
    end
    M.deliver(now, message, nil, function(ok)
      if not ok then
        keep_unsent(chat, message)
      end
    end)
  end)
end

--- Write a reply to be sent when the chat finishes its current turn.
local function queue_one(chat)
  local busy = chat.status == 'working' or chat.status == 'attention'
  compose(
    chat,
    (busy and 'Send when it finishes: ' or 'Reply to: ') .. display.title(chat, 50),
    function(message)
      -- The turn may have ended while this was being written.
      local now = store.get(chat.key) or chat
      local still_busy = now.status == 'working' or now.status == 'attention'
      -- A reply sent a moment ago may not show as "working" yet: it still
      -- comes first.
      local on_its_way = state.claim(chat.key) ~= nil
      if still_busy or on_its_way or #state.queue(chat.key) > 0 then
        state.enqueue(chat.key, message)
        local buf = term.find(now)
        if buf and term.still_hosts(buf, now) then
          -- Queueing again is saying "carry on": what was kept back goes too.
          state.park(chat.key, false)
          info('Queued. It is typed into the chat when it finishes its turn.')
        else
          -- Nothing here can type it in, now or later.
          state.park(chat.key)
          info(
            ('Queued, and kept: this chat is not open in a terminal here, so nothing sends it by itself.%s'):format(
              config.hint('queue', ' %s on the chat sends it.')
            )
          )
        end
        changed()
        require('agent-chats.queue').sweep()
      else
        M.deliver(now, message, nil, function(ok)
          if not ok then
            keep_unsent(chat, message)
          end
        end)
      end
    end
  )
end

--- Queue a reply for when the chat finishes its turn; for a chat that has
--- replies queued already, also send or drop those.
function M.queue(chat)
  if is_part(chat, 'replied to', 'reply to') then
    return
  end
  local queued = state.queue(chat.key)
  if chat.live and not term.find(chat) and #queued == 0 then
    return warn(
      'This chat is running outside this Neovim, so nothing can be sent to it from here. Reply in the terminal it runs in.'
    )
  end
  if #queued == 0 then
    return queue_one(chat)
  end
  local busy = chat.status == 'working' or chat.status == 'attention'
  local hosted = term.find(chat) ~= nil
  local choices = { 'another' }
  if not busy then
    choices[#choices + 1] = 'send'
  end
  if hosted and state.parked(chat.key) then
    -- Kept back since the chat ended; it is open again.
    choices[#choices + 1] = 'carry_on'
  end
  vim.list_extend(choices, { 'drop_last', 'drop_all' })
  local labels = {
    another = 'Queue another reply',
    carry_on = #queued == 1 and 'Send it when the chat is free'
      or 'Send them one after the other, as the chat gets to them',
    send = ('Send the oldest now: %s'):format(text.oneline(queued[1].text, 60)),
    drop_last = ('Drop the newest: %s'):format(text.oneline(queued[#queued].text, 60)),
    drop_all = #queued == 1 and 'Drop it' or ('Drop all %d'):format(#queued),
  }
  if #queued == 1 then
    -- "The newest" and "all" are the same one.
    choices = vim.tbl_filter(function(c)
      return c ~= 'drop_last'
    end, choices)
  end
  vim.ui.select(choices, {
    prompt = ('%d %s queued for this chat'):format(#queued, #queued == 1 and 'reply' or 'replies'),
    format_item = function(item)
      return labels[item]
    end,
  }, function(choice)
    if choice == 'another' then
      queue_one(chat)
    elseif choice == 'carry_on' then
      state.park(chat.key, false)
      changed()
      require('agent-chats.queue').sweep()
    elseif choice == 'send' then
      local item = state.queue(chat.key)[1]
      if item then
        state.remove_queued(chat.key, 1)
        changed()
        M.deliver(store.get(chat.key) or chat, item.text, nil, function(ok)
          if not ok then
            state.requeue(chat.key, item)
            changed()
          end
        end)
      end
    elseif choice == 'drop_last' then
      state.remove_queued(chat.key, #state.queue(chat.key))
      changed()
    elseif choice == 'drop_all' then
      state.remove_queued(chat.key)
      changed()
    end
  end)
end

-----------------------------------------------------------------------------
-- Read marks, pins, labels, notes
-----------------------------------------------------------------------------

function M.toggle_unread(chat)
  if is_part(chat, 'marked read or unread', 'mark') or is_unnamed(chat) then
    return
  end
  if chat.status == 'done' then
    state.mark_seen(chat.key)
  elseif chat.turn == 'done' then
    state.mark_unseen(chat.key)
  else
    return info('Only a chat that has finished its turn can be unread.')
  end
  changed()
end

function M.read_all()
  local keys = {}
  for key, chat in pairs(store.chats) do
    if chat.status == 'done' then
      keys[#keys + 1] = key
    end
  end
  if #keys > 0 then
    state.mark_all_seen(keys)
    changed()
  end
  info(('%d chat%s marked read.'):format(#keys, #keys == 1 and '' or 's'))
end

function M.pin(chat)
  if is_part(chat, 'pinned', 'pin') or is_unnamed(chat) then
    return
  end
  state.toggle_pin(chat.key)
  changed()
end

function M.archive(chat)
  if is_part(chat, 'archived', 'archive') then
    return
  end
  if is_unnamed(chat) then
    return
  end
  local archived = state.toggle_archive(chat.key, chat.updated)
  changed()
  info(
    archived
        and ('Archived. It comes back if it moves again%s.'):format(
          config.hint('show_all', ' (%s shows archived chats)')
        )
      or 'Unarchived.'
  )
end

function M.labels(chat)
  if is_part(chat, 'labelled', 'label') or is_unnamed(chat) then
    return
  end
  vim.ui.input({
    prompt = 'Labels (space or comma separated): ',
    default = table.concat(state.labels(chat.key), ' '),
  }, function(value)
    if value == nil then
      return
    end
    local labels, seen = {}, {}
    for label in value:gmatch('[^%s,#]+') do
      if not seen[label] then
        seen[label] = true
        labels[#labels + 1] = label
      end
    end
    state.set_labels(chat.key, labels)
    changed()
  end)
end

function M.note(chat)
  if is_part(chat, 'given a note', 'put the note on') or is_unnamed(chat) then
    return
  end
  vim.ui.input({ prompt = 'Note: ', default = state.note(chat.key) or '' }, function(value)
    if value ~= nil then
      state.set_note(chat.key, vim.trim(value))
      changed()
    end
  end)
end

function M.rename(chat)
  if is_part(chat, 'renamed', 'rename') or is_unnamed(chat) then
    return
  end
  local own = state.name(chat.key)
  local offered = own or display.title(chat)
  vim.ui.input({
    prompt = "Name (empty to go back to the agent's title): ",
    default = offered,
  }, function(value)
    if value == nil then
      return
    end
    value = vim.trim(value)
    -- Accepting the agent's title as it was offered names nothing. Kept as
    -- a name of yours, it would stop following the agent from here on.
    if not own and value == offered then
      return
    end
    state.set_name(chat.key, value)
    changed()
  end)
end

local function copy(value, what)
  vim.fn.setreg('"', value)
  pcall(vim.fn.setreg, '+', value)
  info(('Copied %s: %s'):format(what, text.oneline(value, 100)))
end

function M.yank(chat)
  local p = providers.get(chat.provider)
  if chat.unstarted then
    return info('This chat has not started a session yet, so there is nothing to resume.')
  end
  if not p or chat.subagent or chat.stub then
    return M.yank_id(chat)
  end
  local cmd = text.cmdline(p.resume_cmd(chat))
  if chat.cwd then
    cmd = ('cd %s && %s'):format(vim.fn.shellescape(chat.cwd), cmd)
  end
  copy(cmd, 'the resume command')
end

function M.yank_id(chat)
  if chat.unstarted then
    return info('This chat has not started a session yet, so it has no id.')
  end
  copy(chat.id, 'the id')
end

-----------------------------------------------------------------------------
-- Changes in the chat's folder
-----------------------------------------------------------------------------

function M.diff(chat)
  local custom = config.get().diff
  if type(custom) == 'function' then
    return custom(chat)
  end
  if not chat.cwd then
    return info('This chat has no folder on record.')
  end
  local b = board()
  local was_open = b.is_open()
  async.run(function()
    return git.diff(chat.cwd)
  end, function(ok, body, err)
    -- Closed while git was running: the answer is no longer wanted.
    if was_open and not b.is_open() then
      return
    end
    if not ok or not body then
      return warn('No diff: ' .. tostring(err or body))
    end
    if vim.trim(body) == '' then
      return info('No uncommitted changes in ' .. fs.tilde(chat.cwd) .. '.')
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, '\n', { plain = true }))
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable = 'nofile', 'wipe', false
    vim.bo[buf].filetype = 'diff'
    b.pane_show(buf, 'diff', 'Uncommitted changes in ' .. fs.tilde(chat.cwd) .. '   q back')
    vim.keymap.set('n', 'q', function()
      b.release(buf)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      b.focus()
    end, { buffer = buf, nowait = true })
  end)
end

-----------------------------------------------------------------------------
-- Starting chats
-----------------------------------------------------------------------------

local function start(p, cwd, prompt)
  local id = p.preassign_id and text.uuid() or nil
  local _, err = term.spawn({
    argv = p.new_cmd({ prompt = (prompt and prompt ~= '') and prompt or nil, id = id }),
    cwd = cwd,
    key = id and (p.name .. ':' .. id) or nil,
    provider = p.name,
    title = fs.basename(cwd),
  })
  if err then
    return warn('Could not start ' .. p.label .. ': ' .. err)
  end
  refresh_soon()
end

local function worktree_path(root, name)
  local opt = config.get().worktree.path
  local ctx = { root = root, repo = fs.basename(root), parent = vim.fs.dirname(root), name = name }
  if type(opt) == 'function' then
    return opt(ctx)
  end
  return (opt:gsub('{(%w+)}', function(k)
    return ctx[k] or ('{' .. k .. '}')
  end))
end

local function ask_worktree(cwd, cb)
  async.run(function()
    return git.read(cwd)
  end, function(ok, gi)
    if not ok or type(gi) ~= 'table' or not gi.repo then
      return warn(fs.tilde(cwd) .. ' is not inside a git repository.')
    end
    vim.ui.input({ prompt = 'New branch / worktree name: ' }, function(name)
      name = name and vim.trim(name) or ''
      if name == '' then
        return
      end
      local path = worktree_path(gi.repo, (name:gsub('/', '-')))
      if fs.exists(path) then
        return warn(fs.tilde(path) .. ' already exists.')
      end
      async.run(function()
        return git.add_worktree(gi.repo, path, name, config.get().worktree.base)
      end, function(ok2, created, err)
        if not ok2 or not created then
          return warn('Could not create the worktree: ' .. tostring(err or created))
        end
        info('Created worktree ' .. fs.tilde(path))
        cb(path)
      end)
    end)
  end)
end

--- Folders worth offering for a new chat: the current one, the folder of
--- the chat under the cursor, then recently used ones.
local function recent_folders(chat)
  local out, seen = {}, {}
  local function push(dir)
    if dir and not seen[dir] and fs.is_dir(dir) then
      seen[dir] = true
      out[#out + 1] = dir
    end
  end
  push(vim.fn.getcwd())
  push(chat and chat.cwd)
  local chats = store.list({ archived = true })
  table.sort(chats, function(a, b)
    return (a.updated or 0) > (b.updated or 0)
  end)
  for _, c in ipairs(chats) do
    if #out >= 12 then
      break
    end
    push(c.cwd)
  end
  return out
end

--- Start a new chat: pick an agent, a folder (or a fresh worktree), and an
--- optional first prompt.
---@param opts { provider: string?, cwd: string?, prompt: string?, chat: agent_chats.Chat? }?
function M.new(opts)
  opts = opts or {}
  local available = {}
  for _, p in ipairs(providers.enabled()) do
    if providers.executable(p.name) then
      available[#available + 1] = p
    end
  end
  if #available == 0 then
    local tried = {}
    for _, p in ipairs(providers.enabled()) do
      tried[#tried + 1] = '`' .. config.provider(p.name).cmd[1] .. '`'
    end
    return warn(
      ('No agent to start a chat with: none of %s is on PATH. Install one, or set providers.<name>.cmd to how you start it.'):format(
        table.concat(tried, ', ')
      )
    )
  end

  local function with_prompt(p, cwd)
    if opts.prompt ~= nil then
      return start(p, cwd, opts.prompt)
    end
    require('agent-chats.ui.input').open({
      title = ('First prompt for %s in %s (empty: just open it)'):format(p.label, fs.basename(cwd)),
      allow_empty = true,
    }, function(prompt)
      if prompt ~= nil then
        start(p, cwd, prompt)
      end
    end)
  end

  local function with_folder(p)
    if opts.cwd then
      return with_prompt(p, opts.cwd)
    end
    local items = {}
    for _, dir in ipairs(recent_folders(opts.chat)) do
      items[#items + 1] = { label = fs.tilde(dir), cwd = dir }
    end
    items[#items + 1] = { label = 'New git worktree…', worktree = true }
    items[#items + 1] = { label = 'Another folder…', other = true }
    vim.ui.select(items, {
      prompt = 'Where should ' .. p.label .. ' work?',
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.worktree then
        ask_worktree((opts.chat and opts.chat.cwd) or vim.fn.getcwd(), function(path)
          with_prompt(p, path)
        end)
      elseif choice.other then
        vim.ui.input(
          { prompt = 'Folder: ', default = vim.fn.getcwd() .. '/', completion = 'dir' },
          function(dir)
            dir = dir and vim.fs.normalize(vim.trim(dir)) or ''
            if dir == '' then
              return
            end
            if not fs.is_dir(dir) then
              return warn(dir .. ' is not a folder.')
            end
            with_prompt(p, dir)
          end
        )
      else
        with_prompt(p, choice.cwd)
      end
    end)
  end

  if opts.provider then
    local p = providers.get(opts.provider)
    if not p then
      return warn(
        ('There is no agent called "%s". Try :Chats new and pick one.'):format(opts.provider)
      )
    end
    if not providers.executable(p.name) then
      return warn(
        ('Cannot start %s: `%s` is not on PATH. Set providers.%s.cmd to how you start it.'):format(
          p.label,
          config.provider(p.name).cmd[1],
          p.name
        )
      )
    end
    return with_folder(p)
  end
  if #available == 1 then
    return with_folder(available[1])
  end
  vim.ui.select(available, {
    prompt = 'Start a chat with',
    format_item = function(p)
      return p.label
    end,
  }, function(p)
    if p then
      with_folder(p)
    end
  end)
end

--- Branch the conversation into a new chat (the original is left as it is).
function M.fork(chat)
  if is_part(chat, 'forked', 'fork') or is_blank(chat, 'fork') then
    return
  end
  local p = runnable(chat)
  if not p then
    return
  end
  if not p.fork_cmd then
    return info(p.label .. ' cannot fork a chat.')
  end
  local _, err = term.spawn({
    argv = p.fork_cmd(chat),
    cwd = chat.cwd,
    provider = p.name,
    title = 'fork: ' .. display.title(chat, 30),
  })
  if err then
    return warn('Could not fork the chat: ' .. err)
  end
  refresh_soon()
end

-----------------------------------------------------------------------------
-- Handing a chat to another agent
-----------------------------------------------------------------------------

--- Notes that let another agent pick up where this chat stopped.
---@param chat agent_chats.Chat
---@param messages agent_chats.Message[]
---@return string
function M.handoff_notes(chat, messages)
  local turns = {}
  for _, m in ipairs(messages) do
    if (m.role == 'user' or m.role == 'assistant') and m.text and vim.trim(m.text) ~= '' then
      turns[#turns + 1] = m
    end
  end
  local out = {
    ('You are taking over a task from another coding agent (%s). Its conversation is summarised below.'):format(
      providers.label(chat.provider)
    ),
    'Start by checking the current state of the working tree (git status, git diff), then continue the task.',
    '',
    'Folder: '
      .. (chat.cwd or '(unknown)')
      .. (chat.branch and ('   Branch: ' .. chat.branch) or ''),
  }
  if chat.first_prompt then
    vim.list_extend(out, { '', 'Original request:', text.clip(chat.first_prompt, 2000) })
  end
  local keep = 8
  local from = math.max(1, #turns - keep + 1)
  if #turns > 0 then
    out[#out + 1] = ''
    out[#out + 1] = from > 1
        and ('Most recent exchanges (%d earlier ones left out):'):format(from - 1)
      or 'Conversation:'
    for i = from, #turns do
      local m = turns[i]
      out[#out + 1] = ''
      out[#out + 1] = (m.role == 'user' and '[user] ' or '[agent] ')
        .. text.clip(vim.trim(m.text), 1500)
    end
  end
  return table.concat(out, '\n')
end

--- Start a new chat with a different agent, seeded with this one's story.
function M.handoff(chat)
  if is_part(chat, 'handed off', 'hand off') or is_blank(chat, 'hand off') then
    return
  end
  local source = providers.get(chat.provider)
  local targets = {}
  for _, p in ipairs(providers.enabled()) do
    if providers.executable(p.name) then
      targets[#targets + 1] = p
    end
  end
  if not source or #targets == 0 then
    return warn('No agent to hand this chat to: none of the enabled ones is on PATH.')
  end
  vim.ui.select(targets, {
    prompt = 'Hand this chat to',
    format_item = function(p)
      return p.label .. (p.name == chat.provider and ' (a fresh chat with the same agent)' or '')
    end,
  }, function(target)
    if not target then
      return
    end
    async.run(function()
      return source.messages(chat, {})
    end, function(ok, messages)
      if not ok then
        return warn('Could not read the conversation: ' .. tostring(messages))
      end
      require('agent-chats.ui.input').open({
        title = 'Handoff to ' .. target.label .. ' (edit, then send)',
        text = M.handoff_notes(chat, messages),
        height = 22,
      }, function(notes)
        if notes then
          start(target, chat.cwd or vim.fn.getcwd(), notes)
        end
      end)
    end)
  end)
end

-----------------------------------------------------------------------------
-- Search
-----------------------------------------------------------------------------

--- Search inside every conversation and show the matches on the board.
---@param query string?
---@param opts { default: string? }?  What to offer when asking for the text.
function M.search(query, opts)
  local function go(q)
    q = q and vim.trim(q) or ''
    if q == '' then
      return
    end
    local b = board()
    b.open()
    b.set_search({ query = q, hits = {}, running = true })
    local function current()
      return b.is_open() and b._state.search and b._state.search.query == q
    end
    -- Started as the first thing after Neovim came up, the index may still
    -- be loading: a search over the part that is there would look complete.
    store.when_ready(function()
      if not current() then
        return
      end
      require('agent-chats.search').run(q, function(hits, running)
        if current() then
          b.set_search({ query = q, hits = hits, running = running })
        end
      end)
    end)
  end
  if query and query ~= '' then
    return go(query)
  end
  local default = opts and opts.default or nil
  vim.ui.input({
    prompt = 'Search inside all conversations: ',
    default = (default and default ~= '') and default or nil,
  }, go)
end

-----------------------------------------------------------------------------
-- From anywhere
-----------------------------------------------------------------------------

--- Chats that want you, most urgent first.
---@return agent_chats.Chat[]
function M.waiting()
  local out = {}
  for _, chat in ipairs(store.list()) do
    if chat.status == 'attention' or chat.status == 'done' then
      out[#out + 1] = chat
    end
  end
  table.sort(out, function(a, b)
    if a.status ~= b.status then
      return a.status == 'attention'
    end
    -- Whoever has waited longest goes first.
    return (a.turn_at or a.updated or 0) < (b.turn_at or b.updated or 0)
  end)
  return out
end

--- Jump straight into the next chat that needs you.
function M.next()
  if not store.initialized then
    store.refresh_sync()
  end
  local chat = M.waiting()[1]
  if not chat then
    return info('No chat needs you right now.')
  end
  local b = board()
  b.open()
  b.goto_chat(chat.key)
  M.open(chat)
end

--- Send text (a visual selection, say) to a chat running in this Neovim.
---@param message string
function M.send(message)
  if not store.initialized then
    store.refresh_sync()
  end
  local hosted = {}
  for _, chat in ipairs(store.list()) do
    if term.find(chat) then
      hosted[#hosted + 1] = chat
    end
  end
  if #hosted == 0 then
    return info('No chat is running in this Neovim to send that to.')
  end
  local function send(chat)
    local buf = chat and term.find(chat)
    if not buf then
      return
    end
    type_into(chat, buf, message, { stay = true }, function(ok)
      if ok then
        info('Sent to “' .. display.title(chat, 50) .. '”.')
      end
    end)
  end
  if #hosted == 1 then
    return send(hosted[1])
  end
  vim.ui.select(hosted, {
    prompt = 'Send to',
    format_item = function(chat)
      return display.line(chat, config.get().icons)
    end,
  }, send)
end

return M
