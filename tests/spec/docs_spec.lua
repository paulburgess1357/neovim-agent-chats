-- The help file says what the code does, all of it: the options with the
-- defaults they really have, the keys that are really bound, and the
-- commands that really exist. The README is short: it does not say
-- everything, and what it says is true.

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

--- Every option that `given` names and `defaults` does not have, as a path.
local function unknown(given, defaults, path, out)
  out = out or {}
  for k, v in pairs(given) do
    local at = (path and (path .. '.') or '') .. tostring(k)
    local d = defaults[k]
    if d == nil then
      out[#out + 1] = at
    elseif type(v) == 'table' and type(d) == 'table' and next(d) ~= nil and not vim.islist(d) then
      -- (A table of named options. A list, or a table that is empty by
      -- default, takes whatever it is given.)
      unknown(v, d, at, out)
    end
  end
  table.sort(out)
  return out
end

describe('the documentation', function()
  local readme, help = read('README.md'), read('doc/agent-chats.txt')
  local defaults = require('agent-chats.config').defaults

  it('shows in the README only options that there are', function()
    local shown = 0
    for body in readme:gmatch("require%('agent%-chats'%)%.setup%((%b{})%)") do
      shown = shown + 1
      local given = assert(loadstring('return ' .. body, 'README setup ' .. shown))()
      eq({}, unknown(given, defaults), 'setup() number ' .. shown .. ' in the README')
    end
    ok(shown > 0, 'the README shows a setup() with options')
  end)

  it('gives every option in the help file with the default it has', function()
    local from = assert(help:find('*agent-chats-options*', 1, true))
    local block = assert(help:match('>lua\n(.-)\n<', from), 'no lua block under OPTIONS')
    eq({}, differences(setup_table(block, 'help options'), defaults))
  end)

  it('names every key the board binds by default, in the help file', function()
    local help_section = help:match('%*agent%-chats%-keys%*\n(.-)\n=====')
    ok(help_section, 'it has a section on keys')
    for action, lhs in pairs(defaults.keys) do
      for _, key in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
        if type(key) == 'string' and not key:lower():find('mouse', 1, true) then
          has(help_section, key, ('the key of "%s"'):format(action))
        end
      end
    end
  end)

  it('names in the README the parts the menu has, and what is in them', function()
    -- The README sends a newcomer to the menu, not to a table of keys: what
    -- it says the menu holds is what the menu says of itself.
    local said = assert(readme:match('\n## The menu\n(.-)\n## '), 'a part on the menu')
    local fx = require('helpers.claude')
    local home = fx.home({ board = { spinner = false } })
    local c = home:chat({ cwd = T.folder('here'), start = os.time() - 700 })
    c:user('Do a thing'):title('A chat'):assistant('Done.'):turn_done():write(os.time() - 600)
    require('agent-chats.store').refresh_sync()
    require('agent-chats.store').start = function() end
    local board = require('agent-chats.ui.board')
    board.open()
    board.goto_chat('claude:' .. c.id)
    board.menu()
    local menu = table.concat(require('agent-chats.ui.menu').lines(), '\n')
    require('agent-chats.ui.menu').close()
    board.close()
    for _, part in ipairs({ 'This chat', 'Keep track of it', 'The list', 'The board' }) do
      has(menu, '── ' .. part .. ' ', 'the menu')
      has(said, '**' .. part .. '.**', 'the README')
    end
  end)

  it('names every action that can be given a key, in the help file', function()
    for action in pairs(defaults.keys) do
      has(help, action, 'help file: ' .. action)
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
    -- The README is for someone new: it says "chat" and "conversation",
    -- as the board does.
    hasnt(readme, 'transcript', 'README')
    hasnt(readme, 'session', 'README')
  end)
end)
