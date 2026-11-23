-- :checkhealth agent-chats

local M = {}

--- Where each agent's status comes from, in words.
---@param p agent_chats.Provider
---@return { level: "ok"|"info"|"warn", text: string, advice: string[]? }[]
function M.sources(p)
  local hooks = require('agent-chats.hooks')
  local events = require('agent-chats.events')
  local time = require('agent-chats.util.time')
  local out = {}
  local label = p.label
  local has_recipe = type(p.hooks) == 'table' and type(p.hooks.config) == 'function'
  local st = has_recipe and hooks.status(p.name) or nil
  local install = require('agent-chats.config').command('hooks install ' .. p.name)
  local ignored = false

  if st and st.state == 'installed' then
    local count, newest = events.summary(p.name)
    local heard = count == 0 and 'no session has reported yet'
      or ('%d session%s reported, the last %s'):format(
        count,
        count == 1 and ' has' or 's have',
        time.since(newest)
      )
    if require('agent-chats.config').get().hooks.enabled == false then
      -- Installed, and deliberately not listened to.
      out[#out + 1] = {
        level = 'info',
        text = ('%s: hooks installed (%s), but hooks.enabled is false in the options: what they report is ignored'):format(
          label,
          heard
        ),
      }
      st, ignored = nil, true
    else
      out[#out + 1] = {
        level = 'ok',
        text = ('%s: hooks installed (%s). Sessions that report say themselves when they need you'):format(
          label,
          heard
        ),
      }
    end
  elseif st and st.state == 'outdated' then
    out[#out + 1] = {
      level = 'warn',
      text = ('%s: hooks %s'):format(label, st.detail),
      advice = { 'Run ' .. install .. ' to bring them up to date.' },
    }
  elseif st and st.state == 'broken' then
    out[#out + 1] = {
      level = 'warn',
      text = ('%s: hooks cannot be read: %s'):format(label, st.detail),
      advice = { 'Look at ' .. tostring(st.path) .. '.' },
    }
  elseif st and st.state == 'unsupported' then
    out[#out + 1] = { level = 'info', text = ('%s: %s'):format(label, st.detail) }
  end

  local installed = st and st.state == 'installed'
  local exact = require('agent-chats.providers').exact(p)
  if exact then
    out[#out + 1] = {
      level = 'info',
      text = installed
          and ('%s: its session registry is read as well; whichever spoke last is believed'):format(
            label
          )
        or ('%s: status comes from its session registry, so "needs you" is exact.%s'):format(
          label,
          (has_recipe and not ignored)
              and (' Its hooks (%s) say the same through a documented interface'):format(install)
            or ''
        ),
    }
  elseif not installed then
    local text = ('%s: "needs you" is a guess: a tool call with no result and nothing written for status.stall_after seconds'):format(
      label
    )
    local off = require('agent-chats.config').get().hooks.enabled == false
    if has_recipe and off then
      -- Installing would change nothing while they are not listened to.
      out[#out + 1] = {
        level = 'info',
        text = text
          .. '. hooks.enabled is false in the options: with it on and the hooks installed, the agent says so itself',
      }
    elseif has_recipe and st and st.state == 'missing' then
      out[#out + 1] = {
        level = 'warn',
        text = text,
        advice = { 'Run ' .. install .. ' and the agent says so itself.' },
      }
    else
      out[#out + 1] = { level = 'info', text = text }
    end
  end
  if installed and not exact then
    out[#out + 1] = {
      level = 'info',
      text = ('%s: for a session that has not reported (started before the hooks, or not trusted by the agent) "needs you" stays a guess'):format(
        label
      ),
    }
  end
  return out
end

--- What there is to say about the board's keys: which default keys were
--- left alone because they are mappings of yours, and what does their work.
---@return { level: "ok"|"info", text: string, advice: string[]? }[]
function M.keys()
  local config = require('agent-chats.config')
  local keys = require('agent-chats.keys')
  local out = {}
  local actions = vim.tbl_keys(config.get().keys)
  table.sort(actions)
  -- As the board has them when it is open (a mapping you put on its buffer
  -- counts); otherwise as seen from any buffer: the global mappings.
  local board = package.loaded['agent-chats.ui.board']
  local buf = board and board.buf() or nil
  -- What is done in a conversation is in the menu that is opened there.
  local in_conversation = { next_prompt = true, prev_prompt = true }
  for _, action in ipairs(actions) do
    local plan = keys.resolve(action, 'n', buf)
    local other = keys.shown(plan.bound)
    for _, item in ipairs(plan.left) do
      local rest
      if other then
        rest = other .. ' does that'
      elseif action == 'menu' then
        -- The menu cannot be what lists its own way in.
        rest = ('%s opens it, and it has no key'):format(config.command('menu'))
      elseif in_conversation[action] then
        rest = 'that is in the menu of a conversation, and has no key'
      else
        rest = 'that is in the menu, and has no key'
      end
      out[#out + 1] = {
        level = 'info',
        text = ('%s is yours (%s), so the board does not take it for "%s": %s'):format(
          item.lhs,
          item.by,
          action,
          rest
        ),
      }
    end
  end
  -- The way back out of a chat's terminal while typing is a key of its
  -- own (`open.back_key`), and gives way in the same manner.
  local back = config.get().open.back_key
  if type(back) == 'string' and not config.explicit_back_key() and keys.yours(back, 't') then
    out[#out + 1] = {
      level = 'info',
      text = ("%s is yours while typing in a terminal, so a chat's terminal does not take it for going back to the list: leave typing mode there first, or set open.back_key"):format(
        back
      ),
    }
  end
  if #out == 0 then
    return { { level = 'ok', text = "None of the board's default keys is a mapping of yours" } }
  end
  -- (A line of its own: `vim.health.info` takes no advice.)
  out[#out + 1] = {
    level = 'info',
    text = 'To have the board take a key all the same, name it in the options: keys = { <action> = "<key>" }',
  }
  return out
end

function M.check()
  local h = vim.health
  local config = require('agent-chats.config')
  local providers = require('agent-chats.providers')
  local fs = require('agent-chats.util.fs')

  h.start('agent-chats')
  if vim.fn.has('nvim-0.11') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.11 or newer is required')
  end
  local proc = require('agent-chats.util.proc')
  if proc.has_procfs then
    h.ok('Process inspection through /proc')
  elseif vim.fn.executable('ps') == 1 then
    h.ok('Process inspection through ps (less precise than on Linux)')
  else
    h.warn(
      'Cannot inspect processes: chats of agents without a session registry will not show as running'
    )
  end
  h.info('Saved state: ' .. fs.tilde(require('agent-chats.state').path()))
  h.info('Hook events: ' .. fs.tilde(require('agent-chats.events').dir()))
  local filtered = config.get().filter_out
  if #filtered > 0 then
    -- Why some chats are not among the others, for whoever looks for one.
    h.info(
      ('Folders filtered out (filter_out): %s. Their chats are under "Filtered out" at the end of the list'):format(
        table.concat(filtered, ', ')
      )
    )
  end

  h.start('agent-chats: agents')
  local found = 0
  for _, p in ipairs(providers.all()) do
    local opts = config.provider(p.name)
    if opts.enabled == false then
      h.info(p.label .. ': disabled in the options')
    else
      local ok_home, home = pcall(p.home)
      local ok_avail, available = pcall(p.available)
      local exe = opts.cmd[1]
      local runnable = vim.fn.executable(exe) == 1
      if ok_avail and available then
        found = found + 1
        local ok_n, entries = pcall(p.discover)
        h.ok(
          ('%s: %s chat%s in %s'):format(
            p.label,
            ok_n and #entries or '?',
            (ok_n and #entries == 1) and '' or 's',
            ok_home and fs.tilde(home) or '?'
          )
        )
      else
        h.info(
          ('%s: no chats found (%s)'):format(
            p.label,
            ok_home and fs.tilde(home) or 'no data folder'
          )
        )
      end
      if runnable then
        h.ok(('%s: `%s` is on PATH'):format(p.label, exe))
      elseif ok_avail and available then
        h.warn(
          ('%s: `%s` is not on PATH, so its chats can be read but not opened'):format(p.label, exe),
          { ('Set providers.%s.cmd to how you start it.'):format(p.name) }
        )
      end
      if (ok_avail and available) or runnable then
        for _, line in ipairs(M.sources(p)) do
          h[line.level](line.text, line.advice)
        end
        if type(p.check) == 'function' then
          local ok_check, lines = pcall(p.check)
          for _, line in ipairs(ok_check and type(lines) == 'table' and lines or {}) do
            h[line.level](line.text, line.advice)
          end
        end
      end
    end
  end
  if found == 0 then
    h.warn('No chats of any agent were found', {
      'Start a chat with Claude Code, Codex, Qwen Code or opencode, or point providers.<name>.home at where its data lives.',
    })
  end

  h.start('agent-chats: notifications')
  local notify = require('agent-chats.notify')
  if notify.enabled() then
    h.ok('Notifications are on')
  elseif config.get().notify.enabled == false and require('agent-chats.state').notify() == nil then
    h.info('Notifications are off (notify.enabled = false in the options)')
  else
    h.info(
      ('Notifications are off: switched off on the board. %s switches them on again'):format(
        require('agent-chats.keys').key('notify') or config.command('notify on')
      )
    )
  end

  h.start('agent-chats: keys')
  for _, line in ipairs(M.keys()) do
    h[line.level](line.text)
  end

  h.start('agent-chats: optional tools')
  if require('agent-chats.util.sqlite').available() then
    h.ok('SQLite library found (opencode chats are read directly)')
  else
    h.info(
      'SQLite library not found: opencode chats are read through `opencode db`, which is slower'
    )
  end
  if vim.fn.executable('rg') == 1 then
    h.ok('rg found (conversation search is narrowed with it)')
  else
    h.info('rg not found: conversation search reads every chat, which is slower')
  end
  if vim.fn.executable('git') == 1 then
    h.ok('git found (branches, worktrees, diffs)')
  else
    h.info('git not found: worktree grouping, new worktrees and diffs are unavailable')
  end
end

return M
