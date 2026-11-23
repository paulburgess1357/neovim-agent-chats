-- Telling you when a chat needs you or has finished.

local config = require('agent-chats.config')
local display = require('agent-chats.display')

local M = {}

local unsubscribe

local function in_scope(chat, scope)
  if scope == 'hosted' then
    return chat.term ~= nil
  elseif scope == 'cwd' then
    local cwd = vim.fn.getcwd()
    return chat.cwd ~= nil and (chat.cwd == cwd or chat.cwd:sub(1, #cwd + 1) == cwd .. '/')
  end
  return true
end

local function desktop(title, body)
  local cmd
  if vim.fn.executable('notify-send') == 1 then
    cmd = { 'notify-send', '--app-name=Neovim', title, body }
  elseif vim.fn.executable('terminal-notifier') == 1 then
    cmd = { 'terminal-notifier', '-title', title, '-message', body }
  elseif vim.fn.executable('osascript') == 1 then
    cmd = {
      'osascript',
      '-e',
      ('display notification %s with title %s'):format(
        vim.json.encode(body),
        vim.json.encode(title)
      ),
    }
  end
  if cmd then
    pcall(vim.system, cmd, { detach = true })
  end
end

--- Whether anything is announced at all: as it was last switched on the
--- board, else as the `notify.enabled` option has it.
---@return boolean
function M.enabled()
  local said = require('agent-chats.state').notify()
  if said ~= nil then
    return said
  end
  return config.get().notify.enabled ~= false
end

--- Switch notifications on or off (the other way round when `on` is nil),
--- and say which it is now. Returns what it is.
---@param on boolean?
---@return boolean
function M.set(on)
  if on == nil then
    on = not M.enabled()
  end
  require('agent-chats.state').set_notify(on)
  vim.notify(
    on and 'Notifications are on: you are told when a chat needs you or has finished.'
      or 'Notifications are off. The board still shows what needs you.',
    vim.log.levels.INFO,
    { title = 'Agent chats' }
  )
  -- The board says which it is.
  local store = package.loaded['agent-chats.store']
  if store and store.touch then
    store.touch()
  end
  return on
end

---@class agent_chats.NotifyEvent
---@field kind "attention"|"done"
---@field chat agent_chats.Chat
---@field from string?
---@field to string
---@field title string
---@field message string

--- Decide whether a status change is worth announcing, and announce it.
---@param ev { chat: agent_chats.Chat, from: string?, to: string, fresh: boolean }
---@return agent_chats.NotifyEvent? event The event announced, if any.
function M.handle(ev)
  local cfg = config.get().notify
  local chat = ev.chat
  if not ev.fresh or chat.subagent then
    return nil
  end
  -- A chat listed under the one that started it is spoken for by that one
  -- (see `through` in store.lua). One whose parent is not in the index is
  -- a row of its own, and announced like any other.
  local index = package.loaded['agent-chats.store']
  if chat.parent and index and index.get(chat.parent) then
    return nil
  end
  local kind = (ev.to == 'attention' or ev.to == 'done') and ev.to or nil
  if not kind then
    return nil
  end
  -- The events are for anyone who wants to react; the options below only
  -- decide whether this module also says something.
  pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = kind == 'attention' and 'AgentChatsAttention' or 'AgentChatsDone',
    modeline = false,
    data = { key = chat.key, chat = chat },
  })
  if not M.enabled() or cfg[kind] == false then
    return nil
  end
  if kind == 'attention' and chat.inferred and not cfg.inferred then
    return nil
  end
  if not in_scope(chat, cfg.scope) then
    return nil
  end
  -- Its folder is filtered out in the options: it is kept out of the way.
  if config.filtered(chat.cwd) then
    return nil
  end
  -- You are looking at it.
  local term = package.loaded['agent-chats.term']
  if term and chat.term and term.is_focused(chat.term) then
    return nil
  end

  local title = display.title(chat, 80)
  local lead = kind == 'attention' and (chat.inferred and 'May need you' or 'Needs you')
    or 'Finished'
  local lines = { ('%s: %s'):format(lead, title), display.where(chat) }
  if kind == 'attention' then
    local store = package.loaded['agent-chats.store']
    vim.list_extend(lines, display.waiting(chat, store and store.get or nil))
  end
  ---@type agent_chats.NotifyEvent
  local event = {
    kind = kind,
    chat = chat,
    from = ev.from,
    to = ev.to,
    title = title,
    message = table.concat(lines, '\n'),
  }
  if type(cfg.handler) == 'function' then
    local ok, handled = pcall(cfg.handler, event)
    if ok and handled == true then
      return event
    end
  end
  vim.notify(
    event.message,
    kind == 'attention' and vim.log.levels.WARN or vim.log.levels.INFO,
    { title = 'Agent chats' }
  )
  if cfg.desktop then
    desktop('Agent chats', event.message)
  end
  return event
end

--- Start listening to the index.
function M.setup()
  if unsubscribe then
    return
  end
  unsubscribe = require('agent-chats.store').on(function(ev)
    if ev.type == 'transition' then
      M.handle(ev)
    end
  end)
end

function M.reset()
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
end

return M
