-- The five states a chat can be in on the board, and the rule that picks one.
--
--   attention  "Needs you": the agent is blocked on you (a permission prompt,
--              a question)
--   working    "Working": the agent is mid-turn
--   done       "Unread": the turn finished and you have not looked at it since
--   idle       "Idle": the turn finished, you have seen it, the agent is still
--              open
--   ended      "Ended": no process has the chat open; it can be resumed
--
-- The names on the left are what the code and the API call them; the words
-- in quotes are what the board says.

local M = {}

---@type agent_chats.Status[]
M.order = { 'attention', 'working', 'done', 'idle', 'ended' }

M.rank = {}
for i, s in ipairs(M.order) do
  M.rank[s] = i
end

M.labels = {
  attention = 'Needs you',
  working = 'Working',
  done = 'Unread',
  idle = 'Idle',
  ended = 'Ended',
}

-- What each one means, in a few words: shown beside its heading on the
-- board, so that no table is needed to tell "Idle" from "Ended".
M.about = {
  attention = 'waiting for your answer',
  working = 'in the middle of a turn',
  done = 'finished since you last looked',
  idle = 'open, nothing new',
  ended = 'not open, can be resumed',
}

-- The same in fewer cells, for a narrow list.
M.about_short = {
  attention = 'waits for your answer',
  working = 'mid-turn',
  done = 'finished, not yet read',
  idle = 'open, nothing new',
  ended = 'not open, resumable',
}

M.hl = {
  attention = 'AgentChatsAttention',
  working = 'AgentChatsWorking',
  done = 'AgentChatsDone',
  idle = 'AgentChatsIdle',
  ended = 'AgentChatsEnded',
}

--- Pick the board status for a chat.
---@param chat agent_chats.Chat
---@param seen number     Epoch seconds the user last looked at this chat.
---@param now number
---@param opts { stall_after: number|false|nil, working_timeout: number? }
---@return agent_chats.Status status, boolean inferred
function M.derive(chat, seen, now, opts)
  local turn = chat.turn or 'unknown'
  local quiet = now - (chat.updated or chat.mtime or now)

  if turn == 'waiting' and chat.live ~= false then
    return 'attention', false
  end

  if turn == 'working' then
    local running = chat.live
    if running == nil then
      -- No way to see the process: believe the transcript while it is fresh.
      running = quiet < (opts.working_timeout or 900)
    end
    if running then
      if chat.asking then
        return 'attention', false
      end
      -- A tool call with no result and no writes for a while is, more often
      -- than not, an approval prompt. Agents that report their own state
      -- (chat.exact) never need this guess.
      local stall = opts.stall_after
      if not chat.exact and chat.pending_tool and stall and quiet >= stall then
        return 'attention', true
      end
      return 'working', false
    end
    -- Mid-turn with nothing running: it was interrupted or killed.
    return 'ended', false
  end

  -- Unread: the turn ended after you last looked. When its end was reported
  -- by a hook, that report dates it, even before the transcript shows it.
  local ended_at = math.max(chat.turn_at or chat.updated or 0, chat.done_at or 0)
  -- A session that has not been sent a prompt has finished nothing, however
  -- idle its agent says it is.
  if turn == 'done' and not chat.stub and ended_at > seen then
    return 'done', false
  end
  if chat.live then
    return 'idle', false
  end
  return 'ended', false
end

return M
