-- Everything you can do to a chat. The board's keys, its menu and the
-- :Chats command all end up here.

local async = require('agent-chats.util.async')
local config = require('agent-chats.config')
local display = require('agent-chats.display')
local fs = require('agent-chats.util.fs')
local git = require('agent-chats.util.git')
local keys = require('agent-chats.keys')
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
  info('This chat has not started yet. Say something to it first, then come back to this.')
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

local function enter_terminal(buf, chat)
  local win = term.show(buf)
  if win then
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    -- In the board's pane the title now says how to get back to the list.
    board().pane_entered(buf, chat)
    term.start_typing(buf)
  end
  return win
end

--- What to say about a chat whose folder is no longer there: its agent
--- cannot be started in it, and no agent resumes a chat from anywhere else.
local function folder_gone(chat)
  return ('The folder of “%s” is gone (%s), so it cannot be resumed. It can still be read%s.'):format(
    display.title(chat, 40),
    fs.tilde(chat.cwd),
    config.hint('pass', ', and %s passes it on to a new chat in a folder you choose')
  )
end

-----------------------------------------------------------------------------
-- Opening and reading
-----------------------------------------------------------------------------

--- Read the whole conversation.
---@param chat agent_chats.Chat
---@param opts { index: integer?, query: string? }?  Where to open it: at a message, on a text.
function M.read(chat, opts)
  if chat.stub then
    info('Nothing has been said in this chat yet.')
    return
  end
  -- Reading it is seeing it.
  if chat.status == 'done' then
    state.mark_seen(chat.key)
    changed()
  end
  return require('agent-chats.ui.conversation').open(chat, opts)
end

--- Go to the chat: its terminal if it runs in this Neovim, a resumed
--- session if it ended, the conversation if it runs somewhere else.
---@param chat agent_chats.Chat
---@return integer? buf The terminal now showing the chat.
function M.open(chat)
  if chat.subagent then
    M.read(chat)
    return nil
  end
  local buf = term.find(chat)
  if buf then
    enter_terminal(buf, chat)
    state.mark_seen(chat.key)
    changed()
    return buf
  end
  if chat.live then
    if term.in_background(chat) then
      info(
        'A reply to this chat is being answered in the background, so for now it can only be read.'
      )
    else
      info(
        ('This chat is running outside this Neovim (pid %s), so it can only be read here.'):format(
          tostring(chat.pid or '?')
        )
      )
    end
    M.read(chat)
    return nil
  end
  if chat.cwd and not fs.is_dir(chat.cwd) then
    -- Nothing to go into; what was said is still there to read.
    info(folder_gone(chat))
    M.read(chat)
    return nil
  end
  local p = runnable(chat)
  if not p then
    return nil
  end
  -- Always in the chat's own folder: that is where its agent keeps it, and
  -- where it expects to be.
  local new_buf, err = term.spawn({
    argv = p.resume_cmd(chat),
    cwd = chat.cwd,
    key = chat.key,
    provider = p.name,
    title = display.title(chat, 40),
    label = chat,
    chat = chat,
  })
  if err then
    warn('Could not resume the chat: ' .. err)
    return nil
  end
  state.mark_seen(chat.key)
  -- Open from this moment, and listed as that.
  store.started()
  refresh_soon()
  return new_buf
end

-----------------------------------------------------------------------------
-- Sending text to a chat from the list
--
-- A reply is typed in the chat itself (Enter goes there). What is sent from
-- the list is a reply that was queued to wait for a turn to end, and lines
-- sent with `:Chats send`.
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
  "Could not type into the chat's terminal: it has closed. Open the chat again and type it there."

-- Keeps a reply that was written and then not sent (defined with the
-- drafts, further down).
local keep_unsent

--- A chat whose terminal is known only by a guess: why nothing is typed
--- into it from the list.
local function unsure_words(chat)
  local label = (providers.get(chat.provider) or {}).label or 'its agent'
  return ('More than one %s runs in this folder, and %s does not say which of them has which chat: what is typed from here could go to the wrong one. Open the chat and type there. (With the status hooks set up, %s says it: %s.)'):format(
    label,
    label,
    label,
    config.command('hooks install')
  )
end

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
  if now.unsure then
    -- Which terminal it is in is a guess (see the provider): nothing is
    -- typed on a guess.
    if not opts.queued then
      warn(unsure_words(now))
    end
    return cb(false, 'gone')
  end
  if not term.reads(buf, now) then
    -- Suspended (Ctrl-Z) or in the background of a shell in that terminal:
    -- the shell would run what is pasted.
    if not opts.queued then
      warn(
        'The agent of this chat is not what that terminal is reading now (it is suspended, or in the background of a shell), so nothing was typed. Bring it to the foreground there, then send again.'
      )
    end
    return cb(false, 'gone')
  end
  if term.has_unsent(buf) then
    -- Something typed there and not sent: a reply pasted now would run
    -- into it, and Enter would send the two as one message. (A queued
    -- reply waits for this by itself: see queue.lua.)
    if not opts.queued then
      warn(
        ('The terminal of “%s” holds something you typed there and have not sent, so nothing was typed behind it. Send or clear that first%s.'):format(
          display.title(now, 40),
          config.hint('open', ' (%s goes to the chat)')
        )
      )
    end
    return cb(false, 'unsent')
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
    -- (Refused because another reply is being typed at this moment: that
    -- one is still on its way, and what is queued goes on waiting for it.)
    if not ok and not opts.queued and why ~= 'busy' then
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
        ('“%s” did not take the text: its terminal did not show it arriving (it may be showing a question or a dialog of its own), so Enter was not pressed. Nothing was sent.%s'):format(
          display.title(chat, 40),
          config.hint('open', ' %s goes to the chat: the text may be sitting there.')
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
      'This chat is running outside this Neovim, so nothing can be typed into it from here. Type in the terminal it runs in.'
    )
    return cb(false)
  end
  local p = runnable(chat)
  if not p then
    return cb(false)
  end
  if chat.cwd and not fs.is_dir(chat.cwd) then
    warn(folder_gone(chat))
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
      label = chat,
      chat = chat,
      -- An agent that is gone again at once has not answered anything.
      on_quick_exit = function(code)
        warn(
          ('%s exited as soon as it was started (code %d), so your reply to “%s” was not sent.'):format(
            p.label,
            code,
            display.title(chat, 40)
          )
        )
        keep_unsent(chat, message)
      end,
    })
    if err then
      warn('Could not resume the chat: ' .. err)
      return cb(false)
    end
    state.mark_seen(chat.key)
    store.started()
    refresh_soon()
    cb(true)
  end

  local function in_background()
    if not p.headless_cmd then
      return in_terminal()
    end
    local title = display.title(chat, 60)
    local ok, err = term.background(
      { argv = p.headless_cmd(chat, message), cwd = chat.cwd, key = chat.key },
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
          -- It may not have been taken at all: it is there to send again.
          keep_unsent(chat, message)
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
      -- (Asked each time unless the option answers it.)
      prompt = 'This chat has ended. Send the reply how? (reply.ended in setup() answers this for good)',
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

--- The name a draft for `chat` is kept under: the one the chat goes by now
--- (a chat started here is first listed under a stand-in; see store.lua).
local function draft_key(chat)
  return store.current_key(chat.key)
end

--- A chat that was listed under the stand-in `from` goes by `to` now: what
--- was written for it and not sent goes with it.
function M.moved(from, to)
  if drafts[from] ~= nil then
    drafts[to] = drafts[to] or drafts[from]
    drafts[from] = nil
  end
end

--- Ask for a message to `chat`, starting from what was written last time
--- and not sent. `cb(message)` is called only with something to send.
local function compose(chat, title, cb)
  require('agent-chats.ui.input').open(
    { title = title, text = drafts[draft_key(chat)] },
    function(message, typed)
      local key = draft_key(chat)
      if message then
        drafts[key] = nil
        return cb(message)
      end
      -- Not sent: keep what was written, unless it was cleared on purpose.
      if typed == nil then
        return
      end
      local kept = vim.trim(typed) ~= '' and typed or nil
      if kept and kept ~= drafts[key] then
        info('Not sent. What you wrote is kept: it is there the next time you write to this chat.')
      end
      drafts[key] = kept
    end
  )
end

--- A written reply could not be sent, or sending it was called off (the
--- question of how to send was dismissed). Whatever stopped it has been
--- said by whoever stopped it; this keeps the text and says so.
keep_unsent = function(chat, message)
  drafts[draft_key(chat)] = message
  info('Not sent. What you wrote is kept: it is there the next time you write to this chat.')
end

--- Why nothing can be sent to `chat` from here at all, in words; nil when
--- something can. Said before a box is opened, not after a reply has been
--- written into it.
---@return string?
local function out_of_reach(chat)
  if term.find(chat) then
    return chat.unsure and unsure_words(chat) or nil
  end
  if chat.live then
    if term.in_background(chat) then
      return 'A reply to this chat is still being answered in the background. Another can be sent when that is done.'
    end
    return 'This chat is running outside this Neovim, so nothing can be sent to it from here. Type in the terminal it runs in.'
  end
  if chat.cwd and not fs.is_dir(chat.cwd) then
    -- A reply to a chat that is not open resumes it, and this one cannot be.
    return folder_gone(chat)
  end
  return nil
end

--- Write a reply to be sent when the chat finishes its current turn.
local function queue_one(chat)
  local busy = chat.status == 'working' or chat.status == 'attention'
  local behind = #state.queue(chat.key) > 0 or state.claim(chat.key) ~= nil
  -- The title says what will become of it: a reply to a chat that is free,
  -- with nothing ahead of it, has nothing to wait for.
  local title = busy and 'Reply when it finishes its turn: '
    or (behind and 'Reply after what is ahead of it: ' or 'Reply now (it is not busy): ')
  compose(chat, title .. display.title(chat, 50), function(message)
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
        if still_busy then
          info('Queued. It is sent when the chat finishes its turn.')
        else
          info(
            'Queued behind the reply before it: it is sent when the chat has finished with that one.'
          )
        end
      else
        -- Nothing here can type it in, now or later.
        state.park(chat.key)
        info(
          ('Queued, and kept: this chat is not open in a terminal here, so nothing sends it by itself. %s on the chat sends it.'):format(
            keys.reach('queue')
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
  end)
end

--- Queue a reply for when the chat finishes its turn; for a chat that has
--- replies queued already, also send or drop those.
function M.queue(chat)
  if is_part(chat, 'replied to', 'reply to') then
    return
  end
  local queued = state.queue(chat.key)
  local why = out_of_reach(chat)
  if why and #queued == 0 then
    return warn(why)
  end
  if #queued == 0 then
    return queue_one(chat)
  end
  local busy = chat.status == 'working' or chat.status == 'attention'
  local hosted = term.find(chat) ~= nil
  local choices = {}
  if not why then
    choices[#choices + 1] = 'another'
    if not busy then
      choices[#choices + 1] = 'send'
    end
    if hosted and state.parked(chat.key) then
      -- Kept back since the chat ended; it is open again.
      choices[#choices + 1] = 'carry_on'
    end
  end
  vim.list_extend(choices, { 'drop_last', 'drop_all' })
  local labels = {
    another = 'Queue another reply',
    carry_on = #queued == 1 and 'Send it when the chat is free'
      or 'Send them one after the other, as the chat gets to them',
    send = ('Send the oldest now: %s'):format(text.oneline(queued[1].text, 60)),
    drop_last = ('Drop the newest: %s'):format(text.oneline(queued[#queued].text, 60)),
    drop_all = #queued == 1 and ('Drop it: %s'):format(text.oneline(queued[1].text, 60))
      or ('Drop all %d'):format(#queued),
  }
  if #queued == 1 then
    -- "The newest" and "all" are the same one.
    choices = vim.tbl_filter(function(c)
      return c ~= 'drop_last'
    end, choices)
  end
  local prompt = ('%d %s queued for this chat'):format(
    #queued,
    #queued == 1 and 'reply' or 'replies'
  )
  if why then
    -- Nothing can be sent to it from here: what is left is to let them go.
    prompt = prompt
      .. (
        chat.live and '. It runs outside this Neovim, so nothing can be sent to it from here'
        or '. Its folder is gone, so it cannot be resumed to send them'
      )
  end
  vim.ui.select(choices, {
    prompt = prompt,
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
    archived and 'Archived. It comes back if it moves again, and a search still finds it.'
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

--- Put the chat in a group of your own, or take it out of the one it is
--- in. A group is made by naming it here, and is gone when the last chat
--- has left it: there is nothing else to look after.
---@param chat agent_chats.Chat
---@param done fun(name: string?)?  Called once it is moved, with the group it is in now (nil: in none).
function M.move(chat, done)
  if is_part(chat, 'put in a group', 'move') or is_unnamed(chat) then
    return
  end
  local now = state.group(chat.key)
  local title = display.title(chat, 40)
  local function into(name)
    -- One line, and no longer than a heading can show: it is a heading.
    name = name and text.oneline(vim.trim(name), 40) or ''
    if name == '' then
      return
    end
    state.set_group(chat.key, name)
    changed()
    if done then
      done(name)
    end
  end
  local function ask_name()
    vim.ui.input({ prompt = 'Name of the new group: ' }, into)
  end
  local items = {}
  -- (Of the chats there are: a group whose chats are all gone is no group.)
  local names, counts = state.groups(function(key)
    return store.get(key) ~= nil
  end)
  for _, name in ipairs(names) do
    if name ~= now then
      items[#items + 1] = { name = name }
    end
  end
  if #items == 0 and not now then
    -- No group to choose yet: the first one is named.
    return ask_name()
  end
  items[#items + 1] = { new = true }
  if now then
    items[#items + 1] = { out = true }
  end
  vim.ui.select(items, {
    prompt = now and ('“%s” is in “%s”. Move it to'):format(title, now)
      or ('Put “%s” in the group'):format(title),
    format_item = function(item)
      if item.name then
        return ('%s  (%d)'):format(item.name, counts[item.name] or 0)
      elseif item.new then
        return 'A new group…'
      end
      -- Out of every group: where its status puts it.
      return ('No group: back under “%s”'):format(
        require('agent-chats.status').labels[chat.status] or 'its status'
      )
    end,
  }, function(choice)
    if not choice then
      return
    elseif choice.new then
      ask_name()
    elseif choice.out then
      state.set_group(chat.key, nil)
      changed()
      if done then
        done(nil)
      end
    else
      into(choice.name)
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
    return info('This chat has not been sent a prompt yet, so there is nothing to resume.')
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
    return info('This chat has not been sent a prompt yet, so it has no id.')
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
    local bound = keys.map(buf, 'n', 'back', function()
      b.release(buf)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      b.focus()
    end, 'back to the list')
    b.pane_show(buf, 'diff', function()
      -- Closing the window goes back too, whatever is mapped.
      local back = keys.shown(keys.still(buf, 'n', bound)) or ':q'
      return { 'Uncommitted changes in ' .. fs.tilde(chat.cwd), { { back .. ' back', 1 } } }
    end)
  end)
end

-----------------------------------------------------------------------------
-- Starting chats
-----------------------------------------------------------------------------

--- Start a new chat with agent `p` in `cwd`. `name`: what to call it until
--- its agent has given it a title of its own.
---@param gone fun(code: integer)?  The agent exited as soon as it was started: what it was started with has not been taken.
local function start(p, cwd, prompt, gone)
  local id = p.preassign_id and text.uuid() or nil
  prompt = (prompt and prompt ~= '') and prompt or nil
  local buf, err = term.spawn({
    argv = p.new_cmd({ prompt = prompt, id = id }),
    cwd = cwd,
    key = id and (p.name .. ':' .. id) or nil,
    provider = p.name,
    title = fs.basename(cwd),
    -- Called by what it was asked from the first moment, as its row will be.
    label = {
      agent = p.label,
      -- (Its first line, as its row has it: notes for a chat that is
      -- passed on are a page long.)
      name = (prompt and text.oneline(text.first_line(prompt) or prompt, 60)) or 'new chat',
      dir = cwd,
    },
    prompt = prompt,
    on_quick_exit = prompt and function(code)
      warn(('%s exited as soon as it was started (code %d).'):format(p.label, code))
      if gone then
        gone(code)
      end
    end or nil,
  })
  if err then
    warn('Could not start ' .. p.label .. ': ' .. err)
    return false
  end
  -- The next new chat starts from the same agent.
  state.set_last_agent(p.name)
  -- The new chat has a row at once, and the list's cursor goes to it, so
  -- that going back lands on it.
  board().follow(buf)
  store.started()
  refresh_soon()
  return true
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

--- Make a new git worktree beside the repository `cwd` is in. `cb(path)`,
--- or `cb(nil)` when it was called off or could not be made.
local function ask_worktree(cwd, cb)
  async.run(function()
    return git.read(cwd)
  end, function(ok, gi)
    if not ok or type(gi) ~= 'table' or not gi.repo then
      warn(fs.tilde(cwd) .. ' is not inside a git repository.')
      return cb(nil)
    end
    -- Which repository: the one the folder that was chosen is in.
    local ask = ('New branch and worktree of %s, called: '):format(fs.basename(gi.repo))
    vim.ui.input({ prompt = ask }, function(name)
      name = name and vim.trim(name) or ''
      if name == '' then
        return cb(nil)
      end
      local path = worktree_path(gi.repo, (name:gsub('/', '-')))
      if fs.exists(path) then
        warn(fs.tilde(path) .. ' already exists.')
        return cb(nil)
      end
      async.run(function()
        -- Run in the folder that was chosen: the new branch starts where
        -- that folder is, which for a worktree is not where the main
        -- checkout is.
        return git.add_worktree(gi.root or cwd, path, name, config.get().worktree.base)
      end, function(ok2, created, err)
        if not ok2 or not created then
          warn('Could not create the worktree: ' .. tostring(err or created))
          return cb(nil)
        end
        info('Created worktree ' .. fs.tilde(path))
        cb(path)
      end)
    end)
  end)
end

--- Folders worth offering for a new chat: the one chosen so far, the
--- current one, the folder of the chat under the cursor, then recently
--- used ones.
local function recent_folders(chat, from)
  local out, seen = {}, {}
  local function push(dir)
    if dir and not seen[dir] and fs.is_dir(dir) then
      seen[dir] = true
      out[#out + 1] = dir
    end
  end
  push(from)
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

--- Ask where an agent should work: a folder used lately, a new git
--- worktree, or any folder. `cb(dir)`, or `cb(nil)` when called off.
---@param chat agent_chats.Chat?  The chat under the cursor, whose folder is offered.
---@param prompt string?
---@param from string?  The folder chosen so far: a new worktree is made of the repository it is in, and "another folder" starts from it.
local function pick_folder(label, chat, cb, prompt, from)
  if not (from and fs.is_dir(from)) then
    from = chat and chat.cwd and fs.is_dir(chat.cwd) and chat.cwd or vim.fn.getcwd()
  end
  local items = {}
  for _, dir in ipairs(recent_folders(chat, from)) do
    items[#items + 1] = { label = fs.tilde(dir), cwd = dir }
  end
  -- A worktree is one of a repository: offered where the folder is in one,
  -- and named by it. (Found by looking for `.git` on the way up; git itself
  -- is asked only when this is chosen.)
  local dotgit = vim.fs.find('.git', { path = from, upward = true })[1]
  if dotgit then
    items[#items + 1] = {
      label = ('New git worktree of %s…'):format(fs.tilde(vim.fs.dirname(dotgit))),
      worktree = true,
    }
  end
  items[#items + 1] = { label = 'Another folder…', other = true }
  vim.ui.select(items, {
    prompt = prompt or ('Where should ' .. label .. ' work?'),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return cb(nil)
    end
    if choice.worktree then
      ask_worktree(from, cb)
    elseif choice.other then
      vim.ui.input(
        { prompt = 'Folder: ', default = from:gsub('/$', '') .. '/', completion = 'dir' },
        function(dir)
          dir = dir and vim.trim(dir) or ''
          if dir == '' then
            return cb(nil)
          end
          -- Made whole now, from the folder Neovim is in: a path left
          -- relative would be another folder after the next `:cd`.
          dir = vim.fn.fnamemodify(vim.fs.normalize(dir), ':p')
          if #dir > 1 then
            dir = dir:gsub('/+$', '')
          end
          if not fs.is_dir(dir) then
            warn(dir .. ' is not a folder.')
            return cb(nil)
          end
          cb(dir)
        end
      )
    else
      cb(choice.cwd)
    end
  end)
end

--- Start a new chat: the agent is picked, and its terminal opens to be
--- typed in. Nothing asks what to say to it first. That is typed to the
--- agent itself, where its model and everything else about it is chosen
--- too.
---@param opts { provider: string?, cwd: string?, prompt: string?, chat: agent_chats.Chat? }?  With `provider`, that agent is started at once. `prompt` is for a script that starts a chat with its first prompt.
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

  local cwd = opts.cwd or vim.fn.getcwd()
  if opts.provider then
    local agent = providers.get(opts.provider)
    if not agent then
      return warn(
        ('There is no agent called "%s". Try %s and pick one.'):format(
          opts.provider,
          config.command('new')
        )
      )
    end
    if not providers.executable(agent.name) then
      return warn(
        ('Cannot start %s: `%s` is not on PATH. Set providers.%s.cmd to how you start it.'):format(
          agent.label,
          config.provider(agent.name).cmd[1],
          agent.name
        )
      )
    end
    return start(agent, cwd, opts.prompt)
  end

  -- Which agent: the one used last comes first, so that Enter picks it.
  -- The folder is the one Neovim is in, said in the question; the last line
  -- leads to another (one used lately, a new git worktree, any other).
  local last = state.last_agent()
  local function ask(dir)
    local items = {}
    for _, first in ipairs({ true, false }) do
      for _, p in ipairs(available) do
        if (p.name == last) == first then
          items[#items + 1] = { agent = p }
        end
      end
    end
    items[#items + 1] = { folder = true }
    vim.ui.select(items, {
      prompt = ('New chat in %s. Which agent?'):format(fs.short(dir, 44)),
      format_item = function(item)
        return item.agent and item.agent.label or 'In another folder…'
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.folder then
        return pick_folder('the new chat', opts.chat, function(picked)
          -- Back to the agents, for the folder that was chosen (the one
          -- before, when none was).
          ask(picked or dir)
        end, nil, dir)
      end
      start(choice.agent, dir, opts.prompt)
    end)
  end
  ask(cwd)
end

-----------------------------------------------------------------------------
-- Passing a chat to another agent
-----------------------------------------------------------------------------

--- Notes that let another agent pick up where this chat stopped.
---@param chat agent_chats.Chat
---@param messages agent_chats.Message[]
---@param dir string?  The folder the new chat works in, when it is not the chat's own (which is gone).
---@return string
function M.notes_for(chat, messages, dir)
  local turns = {}
  for _, m in ipairs(messages) do
    if (m.role == 'user' or m.role == 'assistant') and m.text and vim.trim(m.text) ~= '' then
      -- Not the commands typed to the agent's own program (`/exit`,
      -- `/model x`): they say nothing about the task.
      local command = m.command or (m.role == 'user' and vim.trim(m.text):match('^/[%w%-_:]+$'))
      if not command then
        turns[#turns + 1] = m
      end
    end
  end
  local moved = type(dir) == 'string' and dir ~= chat.cwd
  local out = {
    -- The first line is what the new chat is called on the board (an agent
    -- titles a chat by its first prompt), so it names the task.
    ('Taking over “%s” from %s.'):format(
      display.title(chat, 70),
      providers.label(chat.provider)
    ),
    '',
    'You are taking over a task from another coding agent. What it was first asked and the most recent exchanges of its conversation are below, as they were said.',
    'Start by checking the current state of the working tree (git status, git diff), then continue the task.',
    '',
  }
  if moved then
    -- The folder the work was done in is gone: naming it as the place to
    -- look would send the agent to nothing.
    out[#out + 1] = 'Folder: ' .. dir
    out[#out + 1] = ('(The other agent worked in %s, which is no longer there.)'):format(
      chat.cwd or 'a folder that is not known'
    )
  else
    out[#out + 1] = 'Folder: '
      .. (chat.cwd or '(unknown)')
      .. (
        (chat.branch and chat.branch ~= '' and chat.branch ~= 'HEAD')
          and ('   Branch: ' .. chat.branch)
        or ''
      )
  end
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

--- Pass the chat to another agent: a new chat with the agent you pick, in
--- the same folder, started with notes on this one that you can edit first.
function M.pass(chat)
  if is_part(chat, 'passed on', 'pass on') or is_blank(chat, 'pass on') then
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
    return warn('No agent to pass this chat to: none of the enabled ones is on PATH.')
  end
  vim.ui.select(targets, {
    prompt = 'Pass this chat to',
    format_item = function(p)
      return p.label .. (p.name == chat.provider and ' (a fresh chat with the same agent)' or '')
    end,
  }, function(target)
    if not target then
      return
    end
    local function write_notes(dir)
      async.run(function()
        return source.messages(chat, {})
      end, function(ok, messages)
        if not ok then
          return warn('Could not read the conversation: ' .. tostring(messages))
        end
        -- Notes that were edited and then not sent (the box was left, the
        -- agent did not start) are there the next time.
        local kept_as = '\0pass:' .. chat.key .. ':' .. target.name
        local written = M.notes_for(chat, messages, dir)
        local function keep(notes)
          drafts[kept_as] = notes
          info('Your notes are kept: they are there when you pass this chat on again.')
        end
        require('agent-chats.ui.input').open({
          title = ('Notes for %s in %s (edit, then send)'):format(target.label, fs.short(dir, 44)),
          text = drafts[kept_as] or written,
          height = 22,
          -- There to be read and changed, not written from nothing.
          review = true,
        }, function(notes, typed)
          if notes then
            drafts[kept_as] = nil
            local function gone()
              keep(notes)
            end
            if not start(target, dir, notes, gone) then
              keep(notes)
            end
          elseif typed and vim.trim(typed) ~= '' and typed ~= written then
            keep(typed)
          end
        end)
      end)
    end
    if chat.cwd and fs.is_dir(chat.cwd) then
      return write_notes(chat.cwd)
    end
    -- Its own folder is gone (or was never known): this is the one case
    -- where the new chat has to start somewhere else, so it is asked.
    pick_folder(target.label, nil, function(dir)
      if dir then
        write_notes(dir)
      end
    end, ('The folder of this chat is gone. Where should %s work?'):format(target.label))
  end)
end

-----------------------------------------------------------------------------
-- Search
-----------------------------------------------------------------------------

--- Search every chat for `query`, asking for it when none is given. The
--- board's rows are narrowed to those that show the text, and the
--- conversations are read for it too: one search, wherever the text is.
---@param query string?
function M.search(query)
  local b = board()
  b.open()
  if not b.is_open() then
    return
  end
  if query and vim.trim(query) ~= '' then
    return b.search(query)
  end
  b.search_prompt()
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
  -- With nothing watching in the background, the index is as old as the
  -- last look: look now.
  if not store.initialized or not store.is_watching() then
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
  if not store.initialized or not store.is_watching() then
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
