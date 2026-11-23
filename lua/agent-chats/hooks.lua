-- Installing, removing and inspecting the hooks through which an agent
-- reports its own status (see events.lua for what they write).
--
-- Each provider says how its hooks are set up (`hooks.config()`): either a
-- JSON file that lists commands per event, as Claude Code, Qwen Code and
-- Codex have, or a file of the agent's own to drop in place, as opencode's
-- plugins are.
--
-- A JSON file is the user's: it is edited as text, so nothing but the lines
-- that are added or removed changes (no reordered keys, no lost comments).
-- The result is checked before anything is written (it must decode, and
-- must say exactly what the file said before, plus or minus our entries),
-- the old file is kept as a backup, and the new one is written in one step.

local config = require('agent-chats.config')
local events = require('agent-chats.events')
local fs = require('agent-chats.util.fs')
local jsontext = require('agent-chats.util.jsontext')
local providers = require('agent-chats.providers')

local uv = vim.uv

local M = {}

-- What marks a hook command as ours, wherever the script was put.
local MARK = 'agent-chats-hook.sh'
-- What marks a plugin file as ours.
local FILE_MARK = 'agent-chats.nvim'

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

---@class agent_chats.HookConfig
---@field kind "json"|"file"
---@field path string              The file that is edited ("json") or written ("file").
---@field events string[]?         "json": the events to hook.
---@field timeout number?          "json": seconds a hook may take; nil leaves the agent's default.
---@field timeouts table<string, number|false>?  "json": per event; false leaves the default.
---@field source string?           "file": name of the shipped file under scripts/.
---@field note string?             What the user has to know after installing.

---@class agent_chats.HookStatus
---@field name string
---@field label string
---@field state "installed"|"missing"|"outdated"|"broken"|"unsupported"|"none"
---@field path string?
---@field detail string

-----------------------------------------------------------------------------
-- The script and the command that runs it
-----------------------------------------------------------------------------

--- The hook script as shipped with the plugin.
function M.script_source()
  return plugin_root .. '/scripts/agent-chats-hook.sh'
end

--- Where the copy the agents run is kept: outside the plugin, so that
--- updating or moving the plugin never leaves an agent pointing at nothing.
function M.script_path()
  local opt = config.get().hooks.script
  if type(opt) == 'string' and opt ~= '' then
    return (vim.fs.normalize(opt))
  end
  local data = vim.env.XDG_DATA_HOME
  if not data or data == '' then
    data = fs.home .. '/.local/share'
  end
  return vim.fs.normalize(data) .. '/agent-chats/' .. MARK
end

local function quote(s)
  if s:match('^[%w%-%._/=:@%%+,]+$') then
    return s
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- The command an agent runs for each hooked event. Whatever happens to
--- the script, the command says nothing and succeeds: to these agents a
--- failing hook can mean "block what you were about to do". It names the
--- folder to write to outright: left to work that out for itself, the
--- script would go by the agent's environment, which need not be Neovim's.
---@param agent string
function M.command(agent)
  return ('AGENT_CHATS_EVENTS_DIR=%s sh %s %s 2>/dev/null || true'):format(
    quote(events.dir()),
    quote(M.script_path()),
    agent
  )
end

local function is_ours(hook)
  return type(hook) == 'table'
    and type(hook.command) == 'string'
    and hook.command:find(MARK, 1, true) ~= nil
end

local function supported()
  return vim.fn.has('win32') == 0 and vim.fn.executable('sh') == 1
end

--- Whether the installed copy of the script is the shipped one.
local function script_current()
  local shipped = fs.read_file(M.script_source())
  return shipped ~= nil and fs.read_file(M.script_path()) == shipped
end

local function install_script()
  local shipped = fs.read_file(M.script_source())
  if not shipped then
    return false, 'the hook script is missing from the plugin (' .. M.script_source() .. ')'
  end
  local path = M.script_path()
  if fs.read_file(path) == shipped then
    return true
  end
  if not fs.write_atomic(path, shipped, 493) then
    return false, 'could not write ' .. fs.tilde(path)
  end
  return true
end

-----------------------------------------------------------------------------
-- JSON hook files
-----------------------------------------------------------------------------

local function encode(v)
  -- Older Neovim escapes every slash, which is valid and unreadable. Undone
  -- escape by escape, so that a real backslash before a slash stays one.
  return (
    vim.json.encode(v):gsub('\\(.)', function(c)
      return c == '/' and '/' or ('\\' .. c)
    end)
  )
end

local function timeout_for(cfg, event)
  local t = cfg.timeouts and cfg.timeouts[event]
  if t == false then
    return nil
  end
  return t or cfg.timeout
end

--- One entry of an event's list, on one line.
local function group_text(cfg, agent, event)
  local timeout = timeout_for(cfg, event)
  return ('{ "hooks": [{ "type": "command", "command": %s%s }] }'):format(
    encode(M.command(agent)),
    timeout and (', "timeout": ' .. encode(timeout)) or ''
  )
end

--- Our hooks in a decoded document: event -> list of hook tables.
local function ours_in(doc)
  local have = {}
  local hooks = type(doc) == 'table' and doc.hooks or nil
  if type(hooks) ~= 'table' then
    return have
  end
  for event, groups in pairs(hooks) do
    if type(groups) == 'table' then
      for _, group in ipairs(groups) do
        if type(group) == 'table' and type(group.hooks) == 'table' then
          for _, hook in ipairs(group.hooks) do
            if is_ours(hook) then
              have[event] = have[event] or {}
              table.insert(have[event], hook)
            end
          end
        end
      end
    end
  end
  return have
end

--- What one of our hook commands runs, read back from its text: the script
--- it names, the agent it is for, and whether it is written so that it
--- cannot fail the agent.
---@return { script: string?, agent: string?, safe: boolean, dir: string? }
local function read_command(command)
  local out = { safe = command:find('||%s*true%s*$') ~= nil }
  local mark = vim.pesc(MARK)
  local function expand(path)
    return (path:gsub('^~', fs.home):gsub('^%$HOME', fs.home):gsub('^%${HOME}', fs.home))
  end
  -- The folder it is told to write to; left unsaid, the script's own choice.
  local dir = command:match("AGENT_CHATS_EVENTS_DIR='([^']*)'")
    or command:match('AGENT_CHATS_EVENTS_DIR="([^"]*)"')
    or command:match('AGENT_CHATS_EVENTS_DIR=(%S+)')
  out.dir = dir and vim.fs.normalize(expand(dir)) or events.unset_dir()
  -- The script: the word that ends in its name, quoted or not.
  local script = command:match("'([^']*" .. mark .. ")'")
    or command:match('"([^"]*' .. mark .. ')"')
    or command:match('(%S*' .. mark .. ')')
  if script then
    out.script = expand(script)
    local _, stop = command:find(MARK, 1, true)
    out.agent = command:sub(stop + 1):match('^[\'"]?%s+([%w_%-]+)')
  end
  return out
end

--- How a decoded document compares with what should be installed. An
--- entry made by hand counts as long as it does the same thing: runs the
--- hook script for this agent, for the same events, in a way that cannot
--- fail the agent.
---@return "installed"|"missing"|"outdated", string? why
local function compare(doc, cfg, agent)
  local have = ours_in(doc)
  if next(have) == nil then
    return 'missing'
  end
  local exact = M.command(agent)
  local wanted = {}
  for _, event in ipairs(cfg.events) do
    wanted[event] = true
    local list = have[event]
    if not list then
      return 'outdated', 'not every event is hooked'
    end
    if #list ~= 1 then
      return 'outdated', 'an event is hooked more than once'
    end
    local command = list[1].command
    if command ~= exact then
      local read = read_command(command)
      if read.agent ~= agent then
        return 'outdated', 'a hook does not name this agent'
      elseif not read.safe then
        return 'outdated', 'a hook could fail the agent (it does not end in "|| true")'
      elseif not read.script or not fs.is_file(read.script) then
        return 'outdated', 'a hook runs a script that is not there'
      elseif read.dir ~= events.dir() then
        return 'outdated', 'its hooks write to a folder this Neovim does not read'
      end
    end
  end
  for event in pairs(have) do
    if not wanted[event] then
      return 'outdated', 'an event is hooked that is no longer used'
    end
  end
  return 'installed'
end

--- Whether every hook in a decoded document is exactly what this version
--- would write (as opposed to an equivalent made by hand).
local function canonical(doc, cfg, agent)
  local have = ours_in(doc)
  local command = M.command(agent)
  for _, event in ipairs(cfg.events) do
    local list = have[event]
    if
      not list
      or #list ~= 1
      or list[1].command ~= command
      or list[1].timeout ~= timeout_for(cfg, event)
    then
      return false
    end
  end
  return true
end

--- A copy of a decoded document without our hooks, and without the lists
--- and tables that hold nothing once they are gone. Two documents that are
--- equal after this differ only in our entries.
local function without_ours(doc)
  if type(doc) ~= 'table' then
    return doc
  end
  local out = vim.deepcopy(doc)
  if type(out.hooks) ~= 'table' then
    return out
  end
  for event, groups in pairs(out.hooks) do
    if type(groups) == 'table' then
      local kept = {}
      for _, group in ipairs(groups) do
        if type(group) == 'table' and type(group.hooks) == 'table' then
          local hooks = {}
          for _, hook in ipairs(group.hooks) do
            if not is_ours(hook) then
              hooks[#hooks + 1] = hook
            end
          end
          if #hooks > 0 or #group.hooks == 0 then
            group.hooks = hooks
            kept[#kept + 1] = group
          end
        else
          kept[#kept + 1] = group
        end
      end
      out.hooks[event] = #kept > 0 and kept or nil
    end
  end
  if next(out.hooks) == nil then
    out.hooks = nil
  end
  return out
end

--- Edits that take our hooks out of `text`.
---@return agent_chats.JsonEdit[]
local function removal_edits(text, root)
  local edits = {}
  local holder = jsontext.member(root, 'hooks')
  if not holder or holder.value.kind ~= 'object' then
    return edits
  end
  local all = holder.value
  local gone_events, n_gone_events = {}, 0
  for ei, entry in ipairs(all.members) do
    local list = entry.value
    if list.kind == 'array' then
      local gone_groups, n_gone_groups, inner = {}, 0, {}
      for gi, group in ipairs(list.items) do
        local hooks = group.kind == 'object' and jsontext.member(group, 'hooks') or nil
        if hooks and hooks.value.kind == 'array' then
          local gone, n = {}, 0
          for hi, hook in ipairs(hooks.value.items) do
            if hook.kind == 'object' and is_ours(jsontext.value(text, hook)) then
              gone[hi], n = true, n + 1
            end
          end
          if n > 0 and n == #hooks.value.items then
            -- The entry held nothing but our hook.
            gone_groups[gi], n_gone_groups = true, n_gone_groups + 1
          elseif n > 0 then
            vim.list_extend(inner, jsontext.remove(text, hooks.value, gone))
          end
        end
      end
      -- A list or table that held only ours goes with them, unless someone
      -- wrote a comment in it: that is theirs, and stays with its brackets.
      if
        n_gone_groups > 0
        and n_gone_groups == #list.items
        and #jsontext.comments(text:sub(list.s, list.e)) == 0
      then
        gone_events[ei], n_gone_events = true, n_gone_events + 1
      else
        vim.list_extend(edits, inner)
        if n_gone_groups > 0 then
          vim.list_extend(edits, jsontext.remove(text, list, gone_groups))
        end
      end
    end
  end
  if
    n_gone_events > 0
    and n_gone_events == #all.members
    and #jsontext.comments(text:sub(all.s, all.e)) == 0
  then
    for i, m in ipairs(root.members) do
      if m == holder then
        vim.list_extend(edits, jsontext.remove(text, root, { [i] = true }))
      end
    end
  elseif n_gone_events > 0 then
    vim.list_extend(edits, jsontext.remove(text, all, gone_events))
  end
  return edits
end

--- Edits that add our hooks to `text` (which holds none of them).
---@return agent_chats.JsonEdit[]
local function addition_edits(text, root, cfg, agent)
  local unit, nl = jsontext.style(text, root)
  local function entry(event)
    return ('%s: [%s]'):format(encode(event), group_text(cfg, agent, event))
  end
  local holder = jsontext.member(root, 'hooks')
  if not holder then
    local lines = {}
    for _, event in ipairs(cfg.events) do
      lines[#lines + 1] = unit .. unit .. entry(event)
    end
    local piece = '"hooks": {' .. nl .. table.concat(lines, ',' .. nl) .. nl .. unit .. '}'
    return { jsontext.append(text, root, piece, '', unit, nl) }
  end
  if holder.value.kind ~= 'object' then
    error('its "hooks" entry is not a table of events', 0)
  end
  local edits, fresh = {}, {}
  for _, event in ipairs(cfg.events) do
    local existing = jsontext.member(holder.value, event)
    if not existing then
      fresh[#fresh + 1] = entry(event)
    elseif existing.value.kind ~= 'array' then
      error(('its hooks for %s are not a list'):format(event), 0)
    else
      edits[#edits + 1] =
        jsontext.append(text, existing.value, group_text(cfg, agent, event), unit .. unit, unit, nl)
    end
  end
  if #fresh > 0 then
    -- One edit, so the events keep their order.
    local piece = table.concat(fresh, ',' .. nl .. unit .. unit)
    edits[#edits + 1] = jsontext.append(text, holder.value, piece, unit, unit, nl)
  end
  return edits
end

local function fresh_document(cfg, agent)
  local lines = {}
  for _, event in ipairs(cfg.events) do
    lines[#lines + 1] = ('    %s: [%s]'):format(encode(event), group_text(cfg, agent, event))
  end
  return '{\n  "hooks": {\n' .. table.concat(lines, ',\n') .. '\n  }\n}\n'
end

--- What the JSON file should hold after `action`, checked against what it
--- holds now. Raises a plain message when the file cannot be edited safely.
---@return string? after  nil: nothing to change.
local function json_after(before, cfg, agent, action)
  local blank = before == nil or before:match('^%s*$') ~= nil
  if blank then
    return action == 'install' and fresh_document(cfg, agent) or nil
  end
  local doc, err = jsontext.decode(before)
  if doc == nil then
    error('it is not valid JSON (' .. tostring(err) .. ')', 0)
  end
  if type(doc) ~= 'table' or (vim.islist(doc) and next(doc) ~= nil) then
    error('it does not hold a JSON object', 0)
  end
  if action == 'install' and compare(doc, cfg, agent) == 'installed' then
    return nil
  end
  if action == 'uninstall' and next(ours_in(doc)) == nil then
    return nil
  end

  local root, scan_err = jsontext.scan(before)
  if not root or root.kind ~= 'object' then
    error('it could not be read (' .. tostring(scan_err or 'not an object') .. ')', 0)
  end
  -- Ours out first, whatever shape an earlier version left them in.
  local after = jsontext.apply(before, removal_edits(before, root))
  if action == 'install' then
    local root2, err2 = jsontext.scan(after)
    if not root2 then
      error('editing it went wrong (' .. tostring(err2) .. '); nothing was changed', 0)
    end
    after = jsontext.apply(after, addition_edits(after, root2, cfg, agent))
  end

  -- The proof: it still decodes, everything that is not ours is untouched,
  -- and ours are all there (or all gone).
  local result, err3 = jsontext.decode(after)
  if result == nil then
    error('editing it went wrong (' .. tostring(err3) .. '); nothing was changed', 0)
  end
  if not vim.deep_equal(without_ours(doc), without_ours(result)) then
    error('editing it would have changed other settings; nothing was changed', 0)
  end
  if not vim.deep_equal(jsontext.comments(before), jsontext.comments(after)) then
    error('editing it would have dropped a comment; nothing was changed', 0)
  end
  local as_meant
  if action == 'install' then
    as_meant = canonical(result, cfg, agent)
  else
    as_meant = next(ours_in(result)) == nil
  end
  if not as_meant then
    error('editing it did not give the expected result; nothing was changed', 0)
  end
  return after
end

-----------------------------------------------------------------------------
-- Files of the agent's own (opencode plugins)
-----------------------------------------------------------------------------

--- The content of a shipped file, told where to write when that is not the
--- default place.
local function file_content(cfg)
  local text = fs.read_file(plugin_root .. '/scripts/' .. cfg.source)
  if not text then
    return nil
  end
  -- Named outright, for the reason `command` gives.
  text = text:gsub('const FIXED_DIR = null', function()
    return 'const FIXED_DIR = ' .. encode(events.dir())
  end, 1)
  return text
end

-----------------------------------------------------------------------------
-- Status
-----------------------------------------------------------------------------

-- Why a path that is there cannot be worked with.
local UNUSABLE = {
  unreadable = 'the file cannot be read (check its permissions)',
  ['not a file'] = 'something that is not a file is in its place',
  ['dangling link'] = 'it is a link to a file that is not there',
}

--- Whether the agent a hook config belongs to has been set up on this
--- machine: its own folder is there. (For a plugin file, the folder its
--- plugins go under may not exist yet; the one above it must.)
---@param cfg agent_chats.HookConfig
local function set_up(cfg)
  local dir = vim.fs.dirname(cfg.path)
  if cfg.kind == 'file' then
    return fs.is_dir(dir) or fs.is_dir(vim.fs.dirname(dir))
  end
  return fs.is_dir(dir)
end

---@param p agent_chats.Provider
---@return agent_chats.HookConfig?
local function config_of(p)
  local spec = type(p.hooks) == 'table' and p.hooks or nil
  if not spec or type(spec.config) ~= 'function' then
    return nil
  end
  local ok, cfg = pcall(spec.config)
  if ok and type(cfg) == 'table' and type(cfg.path) == 'string' then
    return cfg
  end
  return nil
end

--- Whether the hooks of one agent are installed.
---@param name string Provider name.
---@return agent_chats.HookStatus
function M.status(name)
  local p = providers.get(name)
  local out = { name = name, label = p and p.label or name, state = 'none', detail = '' }
  local cfg = p and config_of(p)
  if not p or not cfg then
    out.detail = 'has no hooks this plugin can install'
    return out
  end
  out.path = cfg.path
  if cfg.kind == 'json' and not supported() then
    out.state, out.detail =
      'unsupported', 'its hooks run a POSIX shell script, which this system lacks'
    return out
  end
  local kind = fs.kind(cfg.path)
  if kind ~= 'file' and kind ~= 'missing' then
    out.state, out.detail = 'broken', UNUSABLE[kind]
    return out
  end
  local text = fs.read_file(cfg.path)
  if cfg.kind == 'file' then
    local wanted = file_content(cfg)
    if not text then
      out.state, out.detail = 'missing', 'not installed'
    elseif text == wanted then
      out.state, out.detail = 'installed', 'installed'
    elseif text:find(FILE_MARK, 1, true) then
      out.state, out.detail = 'outdated', 'installed, from an older version of this plugin'
    else
      out.state, out.detail = 'broken', 'another file is in its place'
    end
    return out
  end

  if not text or text:match('^%s*$') then
    out.state, out.detail = 'missing', 'not installed'
    return out
  end
  local doc, err = jsontext.decode(text)
  if doc == nil then
    out.state, out.detail = 'broken', 'the file is not valid JSON (' .. tostring(err) .. ')'
    return out
  end
  local state, why = compare(doc, cfg, name)
  if state == 'installed' and canonical(doc, cfg, name) and not script_current() then
    out.state, out.detail = 'outdated', 'installed, but the hook script needs updating'
  elseif state == 'installed' then
    out.state, out.detail = 'installed', 'installed'
  elseif state == 'outdated' then
    out.state, out.detail = 'outdated', 'installed, but ' .. tostring(why)
  else
    out.state, out.detail = 'missing', 'not installed'
  end
  return out
end

--- Providers whose hooks can be installed here: enabled, with a recipe, and
--- set up on this machine.
---@return agent_chats.Provider[]
function M.candidates()
  local out = {}
  for _, p in ipairs(providers.enabled()) do
    local cfg = config_of(p)
    if cfg and set_up(cfg) then
      out[#out + 1] = p
    end
  end
  return out
end

-- Asked on every redraw of the board, answered from the files at most
-- every few seconds.
local lacking_cache = { at = 0, names = {} }

--- Labels of the agents in use whose hooks are not installed.
---@return string[]
function M.lacking()
  local now = uv.now()
  if now - lacking_cache.at < 5000 and lacking_cache.valid then
    return lacking_cache.names
  end
  local names = {}
  for _, p in ipairs(M.candidates()) do
    local ok_avail, available = pcall(p.available)
    if ok_avail and available then
      local st = M.status(p.name)
      if st.state == 'missing' or st.state == 'outdated' then
        names[#names + 1] = p.label
      end
    end
  end
  lacking_cache = { at = now, names = names, valid = true }
  return names
end

--- Forget what was worked out (tests).
function M.reset()
  lacking_cache = { at = 0, names = {} }
end

-----------------------------------------------------------------------------
-- Plans
-----------------------------------------------------------------------------

---@class agent_chats.HookPlan
---@field name string
---@field label string
---@field action "install"|"uninstall"
---@field kind "json"|"file"
---@field path string        The file as named.
---@field real string        The file it resolves to (a link is followed, not replaced).
---@field before string?     Its content now; nil when it does not exist.
---@field after string?      Its content afterwards; nil when it is to be deleted.
---@field changed boolean    Whether the file changes at all.
---@field script boolean     Whether the hook script is to be written or updated.
---@field note string?

--- Work out what `action` would change for one agent, without changing it.
---@param name string
---@param action "install"|"uninstall"
---@return agent_chats.HookPlan? plan, string? err
function M.plan(name, action)
  local p = providers.get(name)
  if not p then
    return nil, ('there is no agent called "%s"'):format(tostring(name))
  end
  local cfg = config_of(p)
  if not cfg then
    return nil, p.label .. ' has no hooks this plugin can install'
  end
  if cfg.kind == 'json' and action == 'install' and not supported() then
    return nil, p.label .. "'s hooks run a POSIX shell script, which this system lacks"
  end
  -- The user's settings are followed through a link, so that the file the
  -- link points at is edited and the link stays. A plugin file is ours to
  -- place: there the path itself is worked on, never what it points at.
  local real = cfg.kind == 'json' and uv.fs_realpath(cfg.path) or cfg.path
  local kind = fs.kind(real)
  if kind ~= 'file' and kind ~= 'missing' then
    return nil, ('%s was left alone: %s'):format(fs.tilde(cfg.path), UNUSABLE[kind])
  end
  local before = fs.read_file(real)
  if kind == 'file' and before == nil then
    return nil, ('%s was left alone: %s'):format(fs.tilde(cfg.path), UNUSABLE.unreadable)
  end
  local plan = {
    name = name,
    label = p.label,
    action = action,
    kind = cfg.kind,
    path = cfg.path,
    real = real,
    before = before,
    after = before,
    changed = false,
    script = false,
    note = action == 'install' and cfg.note or nil,
  }
  if action == 'install' and not set_up(cfg) then
    return nil,
      ('%s does not seem to be set up here (%s does not exist)'):format(
        p.label,
        fs.tilde(vim.fs.dirname(cfg.path))
      )
  end

  if cfg.kind == 'file' then
    local lst = uv.fs_lstat(cfg.path)
    local linked = lst ~= nil and lst.type == 'link'
    if action == 'install' then
      local wanted = file_content(cfg)
      if not wanted then
        return nil, 'scripts/' .. tostring(cfg.source) .. ' is missing from the plugin'
      end
      if before and before ~= wanted and not before:find(FILE_MARK, 1, true) then
        return nil,
          ('%s exists and was not written by this plugin; it was left alone'):format(fs.tilde(real))
      end
      if linked and before ~= wanted then
        -- Someone keeps this file somewhere else and links to it.
        return nil,
          ('%s is a link you keep yourself; it was left alone. Point it at the current %s, or remove it and install again.'):format(
            fs.tilde(real),
            'scripts/' .. cfg.source
          )
      end
      plan.after = wanted
    else
      if before and not before:find(FILE_MARK, 1, true) then
        return nil, ('%s was not written by this plugin; it was left alone'):format(fs.tilde(real))
      end
      plan.after = nil
    end
    plan.changed = plan.after ~= before
    return plan, nil
  end

  if before ~= nil and not uv.fs_access(real, 'W') then
    return nil, ('%s was left alone: it is read-only'):format(fs.tilde(cfg.path))
  end
  local ok, after = pcall(json_after, before, cfg, name, action)
  if not ok then
    return nil, ('%s was left alone: %s'):format(fs.tilde(real), tostring(after))
  end
  if after ~= nil then
    plan.after, plan.changed = after, true
  end
  plan.script = action == 'install' and not script_current()
  return plan, nil
end

--- A unified diff of what a plan changes, for showing before it is applied.
---@param plan agent_chats.HookPlan
---@return string[]
function M.diff(plan)
  local out = {}
  local where = fs.tilde(plan.real)
  if not plan.changed then
    out[#out + 1] = ('# %s: %s needs no change'):format(plan.label, where)
  elseif plan.after == nil then
    out[#out + 1] = ('# %s: delete %s'):format(plan.label, where)
  elseif plan.before == nil then
    out[#out + 1] = ('# %s: create %s'):format(plan.label, where)
    for _, line in ipairs(vim.split(plan.after, '\n', { plain = true })) do
      out[#out + 1] = '+' .. line
    end
    if out[#out] == '+' then
      out[#out] = nil
    end
  else
    out[#out + 1] = ('# %s: edit %s'):format(plan.label, where)
    -- `vim.diff` until Neovim 0.12 renamed it.
    local differ = (vim.text and vim.text.diff) or vim.diff
    local diff = differ(plan.before, plan.after, { result_type = 'unified', ctxlen = 2 })
    for _, line in
      ipairs(vim.split(diff --[[@as string]], '\n', { plain = true, trimempty = true }))
    do
      out[#out + 1] = line
    end
  end
  if plan.script then
    out[#out + 1] = ('# write the hook script to %s'):format(fs.tilde(M.script_path()))
  end
  return out
end

-----------------------------------------------------------------------------
-- Applying
-----------------------------------------------------------------------------

local BACKUPS_KEPT = 3

--- Keep the file as it was beside it, and only the last few such copies.
--- Names end in the time and a count that only ever goes up, so the newest
--- always sorts last, also when several are made within a second.
local function backup(real, content)
  local dir, base = vim.fs.dirname(real), vim.fs.basename(real)
  local prefix = base .. '.agent-chats-backup-'
  local stamp = os.date('%Y%m%d-%H%M%S')
  local old, n = {}, 0
  for _, e in ipairs(fs.scandir(dir)) do
    -- Only names of exactly this make: a copy you named alike is yours.
    local at, count
    if e.type == 'file' and e.name:sub(1, #prefix) == prefix then
      at, count = e.name:sub(#prefix + 1):match('^(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)%.(%d%d%d)$')
    end
    if at then
      old[#old + 1] = e.name
      if at == stamp then
        n = math.max(n, tonumber(count) or 0)
      end
    end
  end
  local name = ('%s%s.%03d'):format(prefix, stamp, n + 1)
  local st = uv.fs_stat(real)
  if not fs.write_atomic(dir .. '/' .. name, content, st and bit.band(st.mode, 511) or 384) then
    return nil
  end
  table.sort(old)
  for i = 1, #old - (BACKUPS_KEPT - 1) do
    uv.fs_unlink(dir .. '/' .. old[i])
  end
  return dir .. '/' .. name
end

--- Put `data` in the file at `path`, which exists. Normally a new file is
--- written and moved into place, so that no reader ever sees half of it. A
--- file with other names (hard links) is written in place instead: moving
--- a new one over it would leave those names with the old content.
local function replace(path, data)
  local st = uv.fs_stat(path)
  if st and (st.nlink or 1) > 1 then
    local fd = uv.fs_open(path, 'w', bit.band(st.mode, 511))
    if not fd then
      return false
    end
    local written = uv.fs_write(fd, data, 0)
    uv.fs_fsync(fd)
    uv.fs_close(fd)
    return written == #data
  end
  return fs.write_atomic(path, data, st and bit.band(st.mode, 511) or 420)
end

--- Carry out a plan made by `plan()`.
---@param plan agent_chats.HookPlan
---@return boolean ok, string? err, string? backup
function M.apply(plan)
  lacking_cache.valid = false
  if fs.read_file(plan.real) ~= plan.before then
    return false, fs.tilde(plan.real) .. ' changed in the meantime; nothing was written. Try again.'
  end
  local saved
  -- The user's file is kept as it was, before anything else is touched. A
  -- file that is ours from start to end (a plugin dropped into the agent's
  -- folder) is not worth a copy.
  if plan.changed and plan.before ~= nil and plan.kind == 'json' then
    saved = backup(plan.real, plan.before)
    if not saved then
      return false, 'could not back up ' .. fs.tilde(plan.real) .. '; nothing was written'
    end
  end
  if plan.script then
    local ok, err = install_script()
    if not ok then
      return false, err
    end
  end
  if plan.changed then
    if plan.after == nil then
      -- The name itself: of a link, the link and not what it points at.
      if not uv.fs_unlink(plan.real) then
        return false, 'could not delete ' .. fs.tilde(plan.real)
      end
    elseif not replace(plan.real, plan.after) then
      return false, 'could not write ' .. fs.tilde(plan.real)
    end
  end
  if plan.action == 'uninstall' then
    -- What its hooks said so far would only go stale.
    events.clear(plan.name)
    local store = package.loaded['agent-chats.store']
    if store and store.initialized then
      store.refresh({ full = true })
    end
  else
    fs.mkdirp(events.dir(), 448)
  end
  return true, nil, saved
end

---@param names string[]?  Provider names; nil: every agent in use.
---@param action "install"|"uninstall"
---@return agent_chats.HookPlan[] plans, string[] problems
function M.plans(names, action)
  if not names or #names == 0 then
    names = {}
    for _, p in ipairs(M.candidates()) do
      names[#names + 1] = p.name
    end
  end
  local plans, problems = {}, {}
  for _, name in ipairs(names) do
    local plan, err = M.plan(name, action)
    if plan then
      plans[#plans + 1] = plan
    else
      problems[#problems + 1] = err
    end
  end
  return plans, problems
end

--- Apply several plans. Returns one line per agent on what happened.
---@param plans agent_chats.HookPlan[]
---@return string[] lines, boolean all_ok
function M.apply_all(plans)
  local lines, all_ok = {}, true
  for _, plan in ipairs(plans) do
    if not plan.changed and not plan.script then
      lines[#lines + 1] = ('%s: %s'):format(
        plan.label,
        plan.action == 'install' and 'already installed' or 'nothing to remove'
      )
    else
      local ok, err, saved = M.apply(plan)
      if ok then
        local line = ('%s: %s'):format(
          plan.label,
          plan.action == 'install' and 'hooks installed' or 'hooks removed'
        )
        if saved then
          line = line .. ' (the old file is kept as ' .. vim.fs.basename(saved) .. ')'
        end
        lines[#lines + 1] = line
        if plan.note then
          lines[#lines + 1] = '  ' .. plan.note
        end
      else
        all_ok = false
        lines[#lines + 1] = ('%s: %s'):format(plan.label, tostring(err))
      end
    end
  end
  return lines, all_ok
end

--- Install hooks without asking (for a setup script; `:Chats hooks install`
--- is the one that shows the changes first).
---@param names string[]?  Provider names; nil: every agent in use.
---@return string[] lines   What happened, one line per agent.
---@return boolean ok
function M.install(names)
  local plans, problems = M.plans(names, 'install')
  local lines, ok = M.apply_all(plans)
  vim.list_extend(lines, problems)
  return lines, ok and #problems == 0
end

--- Remove hooks without asking.
---@param names string[]?
---@return string[] lines, boolean ok
function M.uninstall(names)
  local plans, problems = M.plans(names, 'uninstall')
  local lines, ok = M.apply_all(plans)
  vim.list_extend(lines, problems)
  return lines, ok and #problems == 0
end

-----------------------------------------------------------------------------
-- By hand
-----------------------------------------------------------------------------

--- What to do to install an agent's hooks without this plugin editing
--- anything: the exact text for this machine.
---@param name string
---@return string[] lines
function M.manual(name)
  local p = providers.get(name)
  local cfg = p and config_of(p)
  if not p or not cfg then
    return { ('%s has no hooks this plugin can install.'):format(p and p.label or tostring(name)) }
  end
  local out = {}
  if cfg.kind == 'file' then
    vim.list_extend(out, {
      ('%s: copy one file.'):format(p.label),
      '',
      ('  cp %s \\'):format(quote(plugin_root .. '/scripts/' .. cfg.source)),
      ('     %s'):format(quote(cfg.path)),
    })
  else
    vim.list_extend(out, {
      ('%s: two steps.'):format(p.label),
      '',
      '1. Put the hook script where the agents can find it:',
      '',
      ('  mkdir -p %s'):format(quote(vim.fs.dirname(M.script_path()))),
      ('  cp %s \\'):format(quote(M.script_source())),
      ('     %s'):format(quote(M.script_path())),
      '',
      ('2. Add this to %s (merge it into "hooks" if you already have some):'):format(
        fs.tilde(cfg.path)
      ),
      '',
    })
    for _, line in ipairs(vim.split(fresh_document(cfg, name), '\n', { trimempty = true })) do
      out[#out + 1] = '  ' .. line
    end
  end
  if cfg.note then
    vim.list_extend(out, { '', cfg.note })
  end
  return out
end

return M
