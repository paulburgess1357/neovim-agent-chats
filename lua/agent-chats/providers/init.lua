-- The set of agents the plugin knows how to read. Each one is a table that
-- follows `agent_chats.Provider` (see types.lua); the four built-ins live
-- next to this file and anything else can be added with `register`.

local config = require('agent-chats.config')

local M = {}

M.builtin = { 'claude', 'codex', 'qwen', 'opencode' }

---@type table<string, agent_chats.Provider>
local registry = {}
---@type string[]
local order = {}
local loaded = false

local REQUIRED =
  { 'name', 'label', 'home', 'available', 'discover', 'parse', 'messages', 'resume_cmd', 'new_cmd' }

--- Add a provider (or replace one of the same name).
---@param provider agent_chats.Provider
function M.register(provider)
  for _, field in ipairs(REQUIRED) do
    if provider[field] == nil then
      error(('agent-chats: provider %q lacks %s'):format(tostring(provider.name), field), 2)
    end
  end
  if not registry[provider.name] then
    order[#order + 1] = provider.name
  end
  registry[provider.name] = provider
end

local function load()
  if loaded then
    return
  end
  loaded = true
  for _, name in ipairs(M.builtin) do
    local ok, provider = pcall(require, 'agent-chats.providers.' .. name)
    if ok and type(provider) == 'table' then
      -- A provider registered by the user under a built-in name wins.
      if not registry[name] then
        M.register(provider)
      end
    else
      vim.schedule(function()
        vim.notify(
          ('agent-chats: could not load provider %s: %s'):format(name, tostring(provider)),
          vim.log.levels.ERROR
        )
      end)
    end
  end
  -- Built-ins first, in their documented order, then the rest as registered.
  local rank = {}
  for i, name in ipairs(M.builtin) do
    rank[name] = i
  end
  local pos = {}
  for i, name in ipairs(order) do
    pos[name] = i
  end
  table.sort(order, function(a, b)
    local ra, rb = rank[a] or (100 + pos[a]), rank[b] or (100 + pos[b])
    return ra < rb
  end)
end

---@return agent_chats.Provider?
function M.get(name)
  load()
  return registry[name]
end

--- Every registered provider, built-ins first.
---@return agent_chats.Provider[]
function M.all()
  load()
  local out = {}
  for _, name in ipairs(order) do
    out[#out + 1] = registry[name]
  end
  return out
end

--- Providers switched on in the options.
---@return agent_chats.Provider[]
function M.enabled()
  local out = {}
  for _, p in ipairs(M.all()) do
    if config.provider(p.name).enabled ~= false then
      out[#out + 1] = p
    end
  end
  return out
end

--- Whether the agent's command is on PATH (needed to open or start chats,
--- not to list them).
function M.executable(name)
  local cmd = config.provider(name).cmd
  return vim.fn.executable(cmd[1]) == 1
end

--- Whether an agent says itself what its sessions are doing, with no hooks
--- installed. `exact` is true, or a function for agents where that depends
--- on what is on the machine.
---@param p agent_chats.Provider
function M.exact(p)
  local v = p.exact
  if type(v) == 'function' then
    local ok, res = pcall(v)
    return ok and res == true
  end
  return v == true
end

--- Display name for a provider id.
function M.label(name)
  local p = M.get(name)
  return p and p.label or name
end

--- Forget everything (tests).
function M.reset()
  registry, order, loaded = {}, {}, false
  for _, name in ipairs(M.builtin) do
    package.loaded['agent-chats.providers.' .. name] = nil
  end
end

return M
