-- agent-chats.nvim: see and manage every AI agent chat on this machine.
--
--   require('agent-chats').setup({ ... })   -- optional; the defaults work
--   :Chats                                  -- open the board
--
-- Nothing below loads until it is used: `setup` only stores options and,
-- a moment after startup, starts the background watcher that drives
-- notifications and the statusline.

local M = {}

local wired = false

--- Hook the pieces that react to index changes together (once).
local function wire()
  if wired then
    return
  end
  wired = true
  require('agent-chats.ui.highlights').setup()
  require('agent-chats.term').setup()
  require('agent-chats.notify').setup()
  require('agent-chats.queue').setup()
  local store = require('agent-chats.store')
  store.on(function(ev)
    if ev.type == 'update' then
      pcall(vim.cmd.redrawstatus)
    end
  end)
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('AgentChats', { clear = true }),
    callback = function()
      store.stop()
      pcall(store.flush)
    end,
  })
end

local function watch()
  wire()
  local store = require('agent-chats.store')
  if not store.is_watching() then
    store.start()
  end
end

--- Set options (see `:help agent-chats-options`). Optional.
---@param opts table?
function M.setup(opts)
  local cfg = require('agent-chats.config').setup(opts)
  if cfg.watch.enabled then
    -- After startup, so the first screen is never held up.
    vim.defer_fn(watch, vim.v.vim_did_enter == 1 and 0 or 800)
  end
end

--- Open the board (or go to it).
---@param opts { layout: string?, group_by: string?, filter: string? }?
function M.open(opts)
  wire()
  require('agent-chats.ui.board').open(opts)
end

function M.close()
  require('agent-chats.ui.board').close()
end

--- Open the board; close it when the cursor is already in it.
function M.toggle(opts)
  wire()
  require('agent-chats.ui.board').toggle(opts)
end

--- Start a new chat.
---@param opts { provider: string?, cwd: string?, prompt: string? }?
function M.new(opts)
  wire()
  require('agent-chats.actions').new(opts)
end

--- Search inside every conversation (asks for the text when none is given).
---@param query string?
function M.search(query)
  wire()
  require('agent-chats.actions').search(query)
end

--- Jump into the next chat that needs you or has finished.
function M.next()
  wire()
  require('agent-chats.actions').next()
end

--- Send text to a chat running in this Neovim.
---@param message string
function M.send(message)
  wire()
  require('agent-chats.actions').send(message)
end

--- Look for changes now.
function M.refresh()
  wire()
  require('agent-chats.store').refresh({ full = true })
end

--- How many chats are in each status:
--- `{ attention, working, done, idle, ended }`. Starts the watcher on first use.
---@return table<string, integer>
function M.counts()
  local store = require('agent-chats.store')
  if not store.is_watching() and require('agent-chats.config').get().watch.enabled then
    watch()
  end
  return store.counts()
end

--- A short statusline segment such as `● 2  ◐ 3  ✓ 1`; empty when nothing
--- is going on. For lualine: `{ require('agent-chats').statusline }`.
---@return string
function M.statusline()
  local c = M.counts()
  local icons = require('agent-chats.config').get().icons
  local parts = {}
  for _, name in ipairs({ 'attention', 'working', 'done' }) do
    if c[name] > 0 then
      parts[#parts + 1] = ('%s %d'):format(icons[name], c[name])
    end
  end
  return table.concat(parts, '  ')
end

--- Every chat in the index.
---@return agent_chats.Chat[]
function M.chats()
  return require('agent-chats.store').list({ archived = true })
end

--- Set up, inspect or remove the hooks through which agents report their
--- own status. `action`: nil (the overview), "install", "uninstall", "show"
--- (the steps to do it by hand) or "status" (returns one line per agent).
--- `names`: provider names; none means every agent in use.
---@param action string?
---@param names string[]?
---@return string[]?
function M.hooks(action, names)
  wire()
  local ui = require('agent-chats.ui.hooks')
  if action == nil or action == '' or action == 'open' then
    ui.open()
  elseif action == 'install' or action == 'uninstall' then
    ui.change(action, names)
  elseif action == 'show' then
    ui.show(names)
  elseif action == 'status' then
    return (ui.report())
  else
    vim.notify(
      ('Chats hooks: no such action "%s". Try: install, uninstall, show, status'):format(action),
      vim.log.levels.ERROR
    )
  end
end

--- Add support for another agent. `provider` follows `agent_chats.Provider`
--- (see `:help agent-chats-providers`).
---@param provider agent_chats.Provider
function M.register(provider)
  require('agent-chats.providers').register(provider)
  local store = require('agent-chats.store')
  if store.initialized then
    store.refresh({ full = true })
  end
end

-----------------------------------------------------------------------------
-- :Chats
-----------------------------------------------------------------------------

local function selection(opts)
  local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
  local name = vim.fn.expand('%:.')
  local where = name ~= '' and ('%s:%d-%d'):format(name, opts.line1, opts.line2) or nil
  local ft = vim.bo.filetype
  return ('%s```%s\n%s\n```'):format(where and (where .. '\n') or '', ft, table.concat(lines, '\n'))
end

local SUBCOMMANDS = {
  open = function()
    M.open()
  end,
  toggle = function()
    M.toggle()
  end,
  close = function()
    M.close()
  end,
  new = function(args)
    M.new({ provider = args[1] })
  end,
  search = function(args)
    M.search(table.concat(args, ' '))
  end,
  filter = function(args)
    M.open({ filter = table.concat(args, ' ') })
  end,
  next = function()
    M.next()
  end,
  refresh = function()
    M.refresh()
  end,
  send = function(args, opts)
    local message = #args > 0 and table.concat(args, ' ') or selection(opts)
    M.send(message)
  end,
  health = function()
    vim.cmd('checkhealth agent-chats')
  end,
  hooks = function(args)
    local action = table.remove(args, 1)
    local lines = M.hooks(action, args)
    if lines then
      vim.notify(
        #lines > 0 and table.concat(lines, '\n') or 'No agent with hooks to set up was found.',
        vim.log.levels.INFO,
        { title = 'Agent chats' }
      )
    end
  end,
}

local HOOK_ACTIONS = { 'install', 'uninstall', 'show', 'status' }

--- Run `:Chats <args>`.
function M.command(opts)
  local args = vim.split(vim.trim(opts.args or ''), '%s+', { trimempty = true })
  local sub = table.remove(args, 1) or 'open'
  local fn = SUBCOMMANDS[sub]
  if not fn then
    vim.notify(
      ('Chats: no such subcommand "%s". Try: %s'):format(sub, table.concat(M.complete(''), ', ')),
      vim.log.levels.ERROR
    )
    return
  end
  fn(args, opts)
end

--- Completion for `:Chats`.
function M.complete(lead, line)
  -- What follows the command's name. Before it there may be a range or
  -- modifiers (`:tab Chats`, `:'<,'>Chats send`), which are not arguments.
  -- (A range may end in a letter, as in `:'a,'bChats`: the name is looked
  -- for as it is, not as a word of its own.)
  local rest = line or ''
  local _, stop = rest:find('Chats!?')
  if stop then
    rest = rest:sub(stop + 1)
  end
  local words = vim.split(rest, '%s+', { trimempty = true })
  local past_sub = #words > 1 or (#words == 1 and rest:match('%s$') ~= nil)
  if past_sub then
    local function agents(only_hooked)
      local names = {}
      for _, p in ipairs(require('agent-chats.providers').enabled()) do
        if p.name:sub(1, #lead) == lead and (not only_hooked or type(p.hooks) == 'table') then
          names[#names + 1] = p.name
        end
      end
      return names
    end
    if words[1] == 'new' then
      return agents(false)
    elseif words[1] == 'hooks' then
      local past_action = #words > 2 or (#words == 2 and rest:match('%s$') ~= nil)
      if past_action then
        return words[2] == 'status' and {} or agents(true)
      end
      return vim.tbl_filter(function(a)
        return a:sub(1, #lead) == lead
      end, HOOK_ACTIONS)
    end
    return {}
  end
  local out = {}
  for name in pairs(SUBCOMMANDS) do
    if name:sub(1, #lead) == lead then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

return M
