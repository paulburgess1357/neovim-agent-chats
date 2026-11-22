-- The README and the help file say what the code does: the options with
-- the defaults they really have, the keys that are really bound, and the
-- commands that really exist.

local T = require('helpers.harness')
local eq, ok, has, hasnt = T.eq, T.ok, T.has, T.hasnt

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

local function read(name)
  return table.concat(vim.fn.readfile(root .. '/' .. name), '\n')
end

--- The table a `require('agent-chats').setup({ ... })` call in `block` is given.
local function setup_table(block, where)
  local body = block:match("require%('agent%-chats'%)%.setup%((.*)%)%s*$")
  ok(body, where .. ': the block is one call of setup()')
  local chunk = assert(loadstring('return ' .. body, where))
  return chunk()
end

--- Every place where `documented` and `defaults` differ, as `path: a ~= b`.
local function differences(documented, defaults, path, out)
  out = out or {}
  path = path or ''
  local seen = {}
  for k, v in pairs(defaults) do
    seen[k] = true
    local at = path .. (path == '' and '' or '.') .. tostring(k)
    local d = documented[k]
    if type(v) == 'table' and type(d) == 'table' then
      differences(d, v, at, out)
    elseif not vim.deep_equal(d, v) then
      out[#out + 1] = ('%s: says %s, is %s'):format(at, vim.inspect(d), vim.inspect(v))
    end
  end
  for k, d in pairs(documented) do
    if not seen[k] then
      local at = path .. (path == '' and '' or '.') .. tostring(k)
      out[#out + 1] = ('%s: says %s, and there is no such option'):format(at, vim.inspect(d))
    end
  end
  table.sort(out)
  return out
end

describe('the documentation', function()
  local readme, help = read('README.md'), read('doc/agent-chats.txt')
  local defaults = require('agent-chats.config').defaults

  it('gives every option in the README with the default it has', function()
    local from = assert(readme:find('\n## Options', 1, true))
    local block = assert(readme:match('```lua\n(.-)\n```', from), 'no lua block under Options')
    eq({}, differences(setup_table(block, 'README options'), defaults))
  end)

  it('gives every option in the help file with the default it has', function()
    local from = assert(help:find('*agent-chats-options*', 1, true))
    local block = assert(help:match('>lua\n(.-)\n<', from), 'no lua block under OPTIONS')
    eq({}, differences(setup_table(block, 'help options'), defaults))
  end)

  it('names every key the board binds by default, in both', function()
    -- As each of the two writes a key.
    local written = {
      readme = { ['<CR>'] = 'Enter', ['<Esc>'] = 'Esc', ['<Tab>'] = 'Tab' },
      help = {},
    }
    local keys_section = readme:match('\n### Keys\n(.-)\n### ')
    local help_section = help:match('%*agent%-chats%-keys%*\n(.-)\n=====')
    ok(keys_section and help_section, 'both have a section on keys')
    for action, lhs in pairs(defaults.keys) do
      for _, key in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
        if type(key) == 'string' and not key:lower():find('mouse', 1, true) then
          has(
            keys_section,
            '`' .. (written.readme[key] or key) .. '`',
            ('README: the key of "%s"'):format(action)
          )
          has(help_section, written.help[key] or key, ('help file: the key of "%s"'):format(action))
        end
      end
    end
  end)

  it('names every action that can be given a key, in both', function()
    for action in pairs(defaults.keys) do
      has(help, action, 'help file: ' .. action)
      has(readme, action, 'README: ' .. action)
    end
  end)

  it('speaks of the commands there are, and of no other', function()
    vim.cmd('runtime plugin/agent-chats.lua')
    local subs = require('agent-chats').complete('', 'Chats ')
    ok(#subs >= 10, 'there are subcommands: ' .. #subs)
    local known = {}
    for _, sub in ipairs(subs) do
      known[sub] = true
      if sub ~= 'open' then
        -- (After a range there is no colon: `:'<,'>Chats send`.)
        has(readme, 'Chats ' .. sub, 'README: :Chats ' .. sub)
        has(help, 'Chats ' .. sub, 'help file: :Chats ' .. sub)
      end
    end
    for _, text in ipairs({ readme, help }) do
      for sub in text:gmatch(':Chats (%l+)') do
        ok(known[sub], ('":Chats %s" is written of, and there is no such subcommand'):format(sub))
      end
    end
    -- The mappings on offer exist.
    for plug in readme:gmatch('<Plug>%(agent%-chats[%w%-]*%)') do
      ok(vim.fn.maparg(plug, 'n') ~= '' or vim.fn.maparg(plug, 'x') ~= '', plug)
    end
  end)

  it('uses the words the board uses', function()
    -- What these were called before; "transcript" stays for the file an
    -- agent writes, which is what the sections on status are about.
    for name, text in pairs({ README = readme, ['help file'] = help }) do
      hasnt(text, 'Done, unread', name)
      hasnt(text, 'Filter the board', name)
      hasnt(text, 'Hand the chat', name)
      hasnt(text, 'handoff notes', name)
    end
    local use = readme:match('\n## Use\n(.-)\n## Status hooks')
    hasnt(use, 'transcript', 'README, the part on using the board')
    hasnt(use, 'session', 'README, the part on using the board')
  end)
end)
