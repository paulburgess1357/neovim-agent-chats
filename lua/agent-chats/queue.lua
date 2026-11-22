-- Queued replies: a message that waits for its chat to finish the current
-- turn and is then typed into its terminal for you.
--
-- A reply is only ever typed into a terminal of this Neovim that has the
-- chat open. It never starts an agent: if the chat ends first (you quit
-- the agent, it crashed, Neovim was closed), its replies are kept, you
-- are told, and from then on they go only when you say so: Q on the chat
-- sends or drops them. Opening the chat again does not send them.
--
-- The queue lives in the shared state file. Taking a reply off it is a
-- locked operation, so two instances never send the same one; and the
-- next is not taken while the last one handed over is still on its way
-- (see `state.dequeue`).

local state = require('agent-chats.state')
local time = require('agent-chats.util.time')

local M = {}

local unsubscribe
local recheck ---@type uv.uv_timer_t?
local sweeping = false
-- Chats with replies queued that have been seen open in a terminal here:
-- when one of them no longer is, you are told that its replies are kept
-- (`told`: once, until it is open here again).
local open_here = {} ---@type table<string, boolean>
local told = {} ---@type table<string, boolean>
-- Chats whose terminal did not take a queued reply (it was showing
-- something of its own), and when. Nothing more is typed into one until
-- something changes there: its status, or you typing in its terminal.
local held = {} ---@type table<string, number>
-- Chats whose queued reply waits because the user is typing in that
-- terminal (said once each time).
local waiting_for_you = {} ---@type table<string, boolean>

local function busy(chat)
  return chat.status == 'working' or chat.status == 'attention'
end

--- The terminal of this Neovim that has `chat` open, if any: as the index
--- has it, and as a look at the processes confirms right now.
local function terminal(chat)
  local term = require('agent-chats.term')
  local buf = term.find(chat)
  if buf and term.still_hosts(buf, chat) then
    return buf
  end
  return nil
end

--- Whether `chat` can be handed its next queued reply right now. When it
--- cannot because the last one is still on its way, the seconds to wait
--- before looking again come back as well.
---@return boolean ready, number? wait
local function ready(chat)
  local buf = terminal(chat)
  if chat.subagent or busy(chat) or not buf or state.parked(chat.key) then
    return false
  end
  if require('agent-chats.term').has_unsent(buf) then
    -- You are typing there: a reply pasted now would run into your text,
    -- and Enter would send both as one message. It goes when what you
    -- typed has been sent or thrown away.
    if not waiting_for_you[chat.key] then
      waiting_for_you[chat.key] = true
      vim.notify(
        ('A queued reply for “%s” is waiting: its terminal holds something you typed and have not sent. It goes once that is sent, or cleared.'):format(
          require('agent-chats.display').title(chat, 50)
        ),
        vim.log.levels.INFO,
        { title = 'Agent chats' }
      )
    end
    return false, 2
  end
  waiting_for_you[chat.key] = nil
  if held[chat.key] then
    local typed = require('agent-chats.term').typed_at(buf)
    if not typed or typed <= held[chat.key] then
      return false
    end
    held[chat.key] = nil
  end
  local handed = state.claim(chat.key)
  if handed then
    -- The transcript moving on since the hand-over, or the agent itself
    -- reporting a change of its turn since (and the turn over, or it
    -- would be busy), means that reply was taken up and answered.
    if math.max(chat.updated or 0, chat.done_at or 0, chat.said_at or 0) > handed then
      state.sent(chat.key)
    else
      local left = state.SENDING_SECS - (time.precise() - handed)
      if left > 0 then
        return false, left
      end
      -- Nothing came of it. Do not hold the rest up for ever.
      state.sent(chat.key)
    end
  end
  return true
end

--- Type the next queued reply of `chat` into its terminal, if it has one
--- and can take it.
---@return boolean sent
function M.flush(chat)
  if #state.queue(chat.key) == 0 or not ready(chat) then
    return false
  end
  local item = state.dequeue(chat.key)
  if not item then
    return false
  end
  require('agent-chats.actions').deliver(chat, item.text, { queued = true }, function(ok, why)
    if not ok then
      state.requeue(chat.key, item)
      if why == 'unseen' then
        -- Said once (by `deliver`); trying again would type into whatever
        -- the terminal is showing, over and over.
        held[chat.key] = time.precise()
      end
    end
    require('agent-chats.store').touch()
  end)
  return true
end

--- Tell the user a chat ended with replies still queued (they are kept).
local function left_behind(chat)
  local n = #state.queue(chat.key)
  if n == 0 or chat.subagent then
    return
  end
  local display = require('agent-chats.display')
  vim.notify(
    ('“%s” ended with %d %s still queued. %s kept: %s on the chat sends or drops %s.'):format(
      display.title(chat, 50),
      n,
      n == 1 and 'reply' or 'replies',
      n == 1 and 'It is' or 'They are',
      require('agent-chats.keys').reach('queue'),
      n == 1 and 'it' or 'them'
    ),
    vim.log.levels.WARN,
    { title = 'Agent chats' }
  )
end

--- Look at every chat with replies queued and send what can go now. Cheap
--- when nothing is queued, so it runs whenever the index changes: a turn
--- can start and end between two looks, and then no "it just finished"
--- ever comes.
function M.sweep()
  if sweeping then
    return
  end
  sweeping = true
  local store = require('agent-chats.store')
  local soonest
  for key in pairs(state.get().queue) do
    local chat = store.get(key)
    if chat and #state.queue(key) > 0 then
      if terminal(chat) then
        open_here[key], told[key] = true, nil
      elseif chat.live ~= true then
        -- Nowhere to type them: kept until you send or drop them. Said
        -- when the chat was open here until now (not for what an earlier
        -- session left: the row shows that).
        state.park(key)
        if open_here[key] and not told[key] then
          told[key] = true
          left_behind(chat)
        end
        open_here[key] = nil
      end
      local ok, wait = ready(chat)
      if ok then
        M.flush(chat)
      elseif wait and (not soonest or wait < soonest) then
        soonest = wait
      end
    end
  end
  sweeping = false
  if soonest then
    -- Held back only by a reply on its way: look again when that is over.
    if not recheck then
      recheck = vim.uv.new_timer()
    end
    recheck:stop()
    recheck:start(math.ceil(soonest * 1000) + 200, 0, vim.schedule_wrap(M.sweep))
  end
end

function M.setup()
  if unsubscribe then
    return
  end
  local pending = false
  unsubscribe = require('agent-chats.store').on(function(ev)
    if ev.type == 'update' then
      -- Once per burst of updates, and after whoever caused it is done
      -- (an agent's input box needs a moment to come back after a turn).
      if not pending then
        pending = true
        vim.defer_fn(function()
          pending = false
          M.sweep()
        end, 600)
      end
      return
    end
    if ev.type ~= 'transition' then
      return
    end
    -- Something changed in that chat: it may take a reply again.
    held[ev.chat.key] = nil
    local key = ev.chat.key
    if ev.to == 'working' or ev.to == 'attention' then
      -- The reply it was handed has arrived.
      state.sent(key)
    elseif ev.to == 'ended' and ev.fresh and ev.from ~= nil and #state.queue(key) > 0 then
      -- It ended under us with replies waiting. (A chat that ends while it
      -- is "unread" makes no such move; the sweep notices that one.)
      state.park(key)
      if not told[key] and not ev.chat.subagent then
        told[key] = true
        left_behind(ev.chat)
      end
      open_here[key] = nil
    end
  end)
end

function M.reset()
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
  if recheck then
    recheck:stop()
    if not recheck:is_closing() then
      recheck:close()
    end
    recheck = nil
  end
  sweeping = false
  held, open_here, told, waiting_for_you = {}, {}, {}, {}
end

return M
