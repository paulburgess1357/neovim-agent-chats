-- Which keys are bound, and which are left to you.
--
-- Everything this plugin maps is local to its own buffers. A buffer-local
-- mapping still hides a global one: with `H` mapped on the board, the `H`
-- you switch tabs with would do something else there. So a default key is
-- bound only where nothing of yours is mapped on that key:
--
--   * a key you mapped yourself (or a plugin of yours did), globally or on
--     that buffer, is left alone, and the action stays reachable through
--     the menu and `:Chats`;
--   * a key you name in the `keys` option is always bound: that is you
--     saying so. It is also taken away from any other action that only had
--     it by default;
--   * Neovim's own default mappings, and a key mapped to `<Nop>`, are not
--     "yours": nobody made the first, and the second does nothing.
--
-- "On that key" is exact: a longer mapping of yours that merely begins with
-- one of these keys is not counted (every key here acts at once, without
-- waiting for more).
--
-- This is settled when a buffer gets its keys, again whenever the list gets
-- the cursor, and once more when a default key is pressed: if a mapping of
-- yours has turned up on it since (a plugin that loaded later), the key
-- takes itself off the buffer and is typed again, so that yours runs.
--
-- Every hint, title and menu asks this module which key to name, so what
-- the screen says is what is bound.

local api = vim.api
local config = require('agent-chats.config')

local M = {}

-- How every mapping made here starts its description (for which-key and `:map`).
local OURS = 'Agent chats: '

-- Keys as people call them.
local NAMES = {
  ['<cr>'] = 'Enter',
  ['<tab>'] = 'Tab',
  ['<esc>'] = 'Esc',
  ['<space>'] = 'Space',
  ['<bs>'] = 'Backspace',
}

--- A key as it is named in a hint.
---@param lhs string
---@return string
function M.name(lhs)
  if lhs == ' ' then
    return 'Space'
  end
  return NAMES[lhs:lower()] or lhs
end

local function is_mouse(lhs)
  return lhs:lower():find('mouse', 1, true) ~= nil
end

--- One spelling for a key however it was written: `<cr>`, `<CR>` and
--- `<Enter>` are the same key.
---@param lhs string
---@return string
function M.canon(lhs)
  local ok, raw = pcall(api.nvim_replace_termcodes, lhs, true, true, true)
  if not ok then
    return lhs
  end
  local ok2, out = pcall(vim.fn.keytrans, raw)
  return ok2 and out or lhs
end
local canon = M.canon

--- The first of `keys` that can be pressed (a mouse button is bound, but a
--- hint names a key), as text; nil when there is none.
---@param keys string[]?
---@return string?
function M.shown(keys)
  for _, lhs in ipairs(keys or {}) do
    if not is_mouse(lhs) then
      return M.name(lhs)
    end
  end
  return nil
end

local function warn(msg)
  vim.schedule(function()
    vim.notify('agent-chats: ' .. msg, vim.log.levels.WARN)
  end)
end

-----------------------------------------------------------------------------
-- What the options come to
-----------------------------------------------------------------------------

-- Action -> the keys it has once the options are reconciled (see `effective`).
local settled ---@type table<string, string[]>?

--- The keys each action has, once the options are reconciled with each
--- other. A key you name for one action is taken away from an action that
--- only had it by default; of two actions you gave the same key, the first
--- in the alphabet keeps it. Each of these is said once.
---@return table<string, string[]>
local function effective()
  if settled then
    return settled
  end
  local actions = vim.tbl_keys(config.get().keys)
  table.sort(actions)
  local out, claimed = {}, {} ---@type table<string, string[]>, table<string, string>
  for _, action in ipairs(actions) do
    out[action] = {}
    if config.explicit(action) then
      for _, lhs in ipairs(config.configured(action)) do
        local key = canon(lhs)
        if claimed[key] == nil then
          claimed[key] = action
          out[action][#out[action] + 1] = lhs
        elseif claimed[key] ~= action then
          warn(
            ('keys.%s and keys.%s are both on %s; it does "%s"'):format(
              claimed[key],
              action,
              lhs,
              claimed[key]
            )
          )
        end
      end
    end
  end
  for _, action in ipairs(actions) do
    if not config.explicit(action) then
      local seen, lost = {}, {}
      for _, lhs in ipairs(config.configured(action)) do
        local key = canon(lhs)
        if claimed[key] then
          lost[#lost + 1] = { lhs = lhs, by = claimed[key] }
        elseif not seen[key] then
          seen[key] = true
          out[action][#out[action] + 1] = lhs
        end
      end
      -- Said once all of its keys are settled: what it keeps is what is
      -- left when every key that was taken is gone, not just this one.
      local kept = #out[action] > 0 and ('keeps ' .. table.concat(out[action], ', '))
        or 'has no key now'
      for _, item in ipairs(lost) do
        warn(
          ('keys.%s is on %s, which "%s" has by default: "%s" %s'):format(
            item.by,
            item.lhs,
            action,
            action,
            kept
          )
        )
      end
    end
  end
  settled = out
  return out
end

-----------------------------------------------------------------------------
-- Whose a key is
-----------------------------------------------------------------------------

-- Buffer -> mode and key -> the function this module mapped there. A
-- mapping on one of our buffers is ours only while it is still that one.
local mine = {} ---@type table<integer, table<string, function>>

local function slot(mode, lhs)
  return mode .. ' ' .. canon(lhs)
end

local function is_nop(m)
  if m.callback then
    return false
  end
  local rhs = m.rhs
  return rhs == nil or rhs == '' or rhs:lower() == '<nop>'
end

--- Whether Neovim itself made this mapping: one of its defaults (`Y`,
--- `]a`, `gc`), or one from a script it ships (matchit's `%`).
local function is_builtin(m)
  if m.callback then
    local src = debug.getinfo(m.callback, 'S').source or ''
    -- A default's callback is defined in the defaults module itself. (A
    -- mapping of yours onto `vim.lsp.buf.hover` is not: its source is the
    -- module that function lives in.)
    if src:match('^@?vim/_defaults') or src:match('^@?vim/_core/defaults') then
      return true
    end
  end
  if type(m.desc) == 'string' and m.desc:match('^:help .+%-default$') then
    return true
  end
  local runtime = vim.env.VIMRUNTIME or ''
  if runtime ~= '' and type(m.sid) == 'number' and m.sid > 0 then
    local ok, info = pcall(vim.fn.getscriptinfo, { sid = m.sid })
    local name = ok and type(info) == 'table' and info[1] and info[1].name or ''
    if name:sub(1, #runtime) == runtime then
      return true
    end
  end
  return false
end

--- What a mapping of yours is, in a few words, for saying what holds a key.
local function describe(m)
  local what = (type(m.desc) == 'string' and m.desc ~= '') and m.desc or m.rhs
  if type(what) ~= 'string' or what == '' then
    return 'a mapping of yours'
  end
  what = what:gsub('%s+', ' ')
  if #what > 48 then
    what = what:sub(1, 47) .. '…'
  end
  return what
end

-- A buffer nobody maps anything on: from it only global mappings are seen.
local scratch ---@type integer?

--- Your global mapping on exactly `lhs` in `mode`; nil when there is none.
local function global(lhs, mode)
  if not (scratch and api.nvim_buf_is_valid(scratch)) then
    scratch = api.nvim_create_buf(false, true)
  end
  local ok, m = pcall(api.nvim_buf_call, scratch, function()
    return vim.fn.maparg(lhs, mode, false, true)
  end)
  if not ok or type(m) ~= 'table' or next(m) == nil or m.buffer == 1 then
    return nil
  end
  if is_nop(m) or is_builtin(m) then
    return nil
  end
  return m
end

--- The mapping of yours on exactly `lhs` in `mode` as buffer `buf` has it:
--- one you put on that buffer, else a global one. What this module mapped
--- there itself is not yours.
local function theirs(lhs, mode, buf)
  if buf and api.nvim_buf_is_valid(buf) then
    local key = canon(lhs)
    local ours = mine[buf] and mine[buf][slot(mode, lhs)]
    for _, m in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
      if canon(m.lhs) == key then
        if (ours == nil or m.callback ~= ours) and not is_nop(m) then
          return m
        end
        break
      end
    end
  end
  return global(lhs, mode)
end

--- Whether `lhs` in `mode` is a key of yours (as buffer `buf` has it, when
--- given): mapped by you, to something.
---@param lhs string
---@param mode string
---@param buf integer?
---@return boolean
function M.yours(lhs, mode, buf)
  return theirs(lhs, mode, buf) ~= nil
end

---@class agent_chats.KeyPlan
---@field bound string[]                      Keys to map for the action.
---@field left { lhs: string, by: string }[]  Keys left alone, and what holds each.

--- Which keys of `action` to bind in `mode` on `buf` (nil: any buffer).
---@param action string
---@param mode string
---@param buf integer?
---@return agent_chats.KeyPlan
function M.resolve(action, mode, buf)
  local wanted = effective()[action] or {}
  local plan = { bound = {}, left = {} }
  if config.explicit(action) then
    plan.bound = vim.deepcopy(wanted)
    return plan
  end
  for _, lhs in ipairs(wanted) do
    local m = theirs(lhs, mode, buf)
    if m then
      plan.left[#plan.left + 1] = { lhs = lhs, by = describe(m) }
    else
      plan.bound[#plan.bound + 1] = lhs
    end
  end
  return plan
end

-- Keys that could not be mapped at all, said once each.
local refused = {} ---@type table<string, boolean>

--- Map `fn` on `lhs` in `buf`, and remember that it is ours. A key Neovim
--- will not take (too long, say) is reported once and left unmapped.
---@param gives_way boolean?  For a default key. Should a mapping of yours turn up on it after it was taken (a plugin that loads while the board is open), the key is yours from the first press on: this mapping takes itself away and the key is typed again.
---@return boolean mapped
function M.set(buf, mode, lhs, fn, desc, gives_way)
  local run = fn
  if gives_way then
    local gone = false
    run = function()
      if not gone and theirs(lhs, mode, buf) ~= nil then
        gone = true
        M.unset(buf, mode, lhs)
        -- What the screen says about this key follows.
        local board = package.loaded['agent-chats.ui.board']
        if board and board.is_open() then
          vim.schedule(board.rekey)
        end
        -- Typed again as it was typed: with its count and its register,
        -- and ahead of whatever was typed behind it.
        local before = ''
        if mode == 'n' then
          local count, reg = vim.v.count, vim.v.register
          -- The register nobody named is `"`, or the clipboard's.
          local unnamed = '"'
          if vim.o.clipboard:find('unnamedplus', 1, true) then
            unnamed = '+'
          elseif vim.o.clipboard:find('unnamed', 1, true) then
            unnamed = '*'
          end
          if reg ~= '' and reg ~= unnamed then
            before = '"' .. reg
          end
          if count > 0 then
            before = before .. tostring(count)
          end
        end
        api.nvim_feedkeys(before .. api.nvim_replace_termcodes(lhs, true, true, true), 'mi', false)
        return
      end
      return fn()
    end
  end
  local ok, err = pcall(
    vim.keymap.set,
    mode,
    lhs,
    run,
    { buffer = buf, nowait = true, silent = true, desc = OURS .. desc }
  )
  if not ok then
    if not refused[lhs] then
      refused[lhs] = true
      -- The reason, without where in Neovim it was found and without the
      -- key said twice.
      local why = tostring(err):match('[^\n]*$'):gsub('^.-:%d+: ', '')
      why = why:gsub(': ' .. vim.pesc(lhs) .. '$', '')
      warn(('%s cannot be mapped (%s), so it does nothing'):format(lhs, why))
    end
    return false
  end
  if not mine[buf] then
    -- A buffer new to this: a moment to forget those that are gone (every
    -- conversation that was read was one).
    for known in pairs(mine) do
      if not api.nvim_buf_is_valid(known) then
        mine[known] = nil
      end
    end
    mine[buf] = {}
  end
  mine[buf][slot(mode, lhs)] = run
  return true
end

--- Take a mapping of ours on `lhs` off `buf` again (one of yours is left).
function M.unset(buf, mode, lhs)
  local ours = mine[buf] and mine[buf][slot(mode, lhs)]
  if not ours or not api.nvim_buf_is_valid(buf) then
    return
  end
  mine[buf][slot(mode, lhs)] = nil
  local key = canon(lhs)
  for _, m in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
    if canon(m.lhs) == key and m.callback == ours then
      pcall(vim.keymap.del, mode, lhs, { buffer = buf })
      return
    end
  end
end

--- Whether the mapping on `lhs` in `buf` is still the one this module made
--- (your own setup may have put another in its place since).
---@return boolean
function M.is_ours(buf, mode, lhs)
  local ours = mine[buf] and mine[buf][slot(mode, lhs)]
  if not ours or not api.nvim_buf_is_valid(buf) then
    return false
  end
  local key = canon(lhs)
  for _, m in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
    if canon(m.lhs) == key then
      return m.callback == ours
    end
  end
  return false
end

--- Those of `list` that are still this module's mappings on `buf`: a key
--- that has given way to a mapping of yours since is not named any more.
---@param list string[]?
---@return string[]
function M.still(buf, mode, list)
  local out = {}
  for _, lhs in ipairs(list or {}) do
    if M.is_ours(buf, mode, lhs) then
      out[#out + 1] = lhs
    end
  end
  return out
end

--- Map `fn` on the keys of `action` in `buf`. Returns the keys bound.
---@param buf integer
---@param mode string
---@param action string
---@param fn fun()
---@param desc string  What it does, for which-key and `:map`.
---@return string[] bound, { lhs: string, by: string }[] left
function M.map(buf, mode, action, fn, desc)
  local plan = M.resolve(action, mode, buf)
  local bound = {}
  for _, lhs in ipairs(plan.bound) do
    if M.set(buf, mode, lhs, fn, desc, not config.explicit(action)) then
      bound[#bound + 1] = lhs
    end
  end
  return bound, plan.left
end

--- Map `fn` on one key that is not an action of the `keys` option (the
--- way back out of a terminal). Left alone when the key is yours, unless
--- `always` (you named the key yourself).
---@return boolean bound
function M.map_key(buf, mode, lhs, fn, desc, always)
  if not always and theirs(lhs, mode, buf) ~= nil then
    return false
  end
  return M.set(buf, mode, lhs, fn, desc, not always)
end

-----------------------------------------------------------------------------
-- The board's list: the keys every hint speaks of
-----------------------------------------------------------------------------

-- Action -> plan, as worked out for the list. Made when the board opens
-- and whenever it gets the cursor again (with its buffer, so mappings you
-- put on that buffer count too), or the first time a hint asks, from the
-- global mappings alone.
local plans ---@type table<string, agent_chats.KeyPlan>?

--- Work out the keys of every action for the list in `buf`.
---@param buf integer?
---@return table<string, agent_chats.KeyPlan>
function M.plan(buf)
  local out = {}
  for action in pairs(config.get().keys) do
    out[action] = M.resolve(action, 'n', buf)
  end
  plans = out
  return out
end

local function plan_of(action)
  if not plans then
    M.plan(nil)
  end
  return plans[action] or { bound = {}, left = {} }
end

--- The keys bound to `action` on the list.
---@param action string
---@return string[]
function M.of(action)
  return plan_of(action).bound
end

--- The key to name for `action` in a hint; nil when it has none.
---@param action string
---@return string?
function M.key(action)
  return M.shown(plan_of(action).bound)
end

--- `fmt` with the key of `action` filled in, or '' when it has none.
---@param action string
---@param fmt string
---@return string
function M.hint(action, fmt)
  local key = M.key(action)
  return key and fmt:format(key) or ''
end

--- How to reach `action`, for a message that has to say what to do next:
--- its key when it has one, else the menu, which lists it.
---@param action string
---@return string
function M.reach(action)
  local key = M.key(action)
  if key then
    return key
  end
  local menu = M.key('menu')
  return menu and (menu .. ' (the menu)') or config.command('menu')
end

--- The keys an action has in the options, bound or not.
---@param action string
---@return string[]
function M.wanted(action)
  -- Not a key Neovim would not take: nothing can be done with one, here
  -- or in the menu, and nothing may name it.
  return vim.tbl_filter(function(lhs)
    return not refused[lhs]
  end, effective()[action] or {})
end

--- Whether `lhs` is a key of any action in the options.
---@param lhs string
---@return boolean
function M.is_given(lhs)
  local key = canon(lhs)
  for _, list in pairs(effective()) do
    for _, each in ipairs(list) do
      if canon(each) == key then
        return true
      end
    end
  end
  return false
end

--- Default keys that were left alone because they are yours, in a fixed
--- order: `{ action, lhs, by }`.
---@return { action: string, lhs: string, by: string }[]
function M.left()
  if not plans then
    M.plan(nil)
  end
  local out = {}
  for action, plan in pairs(plans) do
    for _, item in ipairs(plan.left) do
      out[#out + 1] = { action = action, lhs = item.lhs, by = item.by }
    end
  end
  table.sort(out, function(a, b)
    if a.action ~= b.action then
      return a.action < b.action
    end
    return a.lhs < b.lhs
  end)
  return out
end

--- Forget what was worked out (the options changed; tests).
function M.reset()
  plans, settled = nil, nil
  refused = {}
  for buf in pairs(mine) do
    if not api.nvim_buf_is_valid(buf) then
      mine[buf] = nil
    end
  end
end

return M
