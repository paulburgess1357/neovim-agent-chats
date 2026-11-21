-- Installing and removing the agents' hooks: the files are the user's, so
-- these tests are mostly about what must not change.

local T = require('helpers.harness')
local fx = require('helpers.claude')
local hk = require('helpers.hooks')
local eq, ok, no, has, hasnt = T.eq, T.ok, T.no, T.has, T.hasnt

local function hooks()
  return require('agent-chats.hooks')
end

local function jsontext()
  return require('agent-chats.util.jsontext')
end

local function read(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local s = f:read('*a')
  f:close()
  return s
end

local function settings(home)
  return home.dir .. '/settings.json'
end

--- Install (or uninstall) for Claude and return the plan that was applied.
local function run(action)
  local plan, err = hooks().plan('claude', action)
  ok(plan, tostring(err))
  local done, why = hooks().apply(plan)
  ok(done, tostring(why))
  return plan
end

local EVENTS = {
  'SessionStart',
  'SessionEnd',
  'UserPromptSubmit',
  'PermissionRequest',
  'Notification',
  'ElicitationResult',
  'PostToolUse',
  'PostToolUseFailure',
  'SubagentStop',
  'Stop',
  'StopFailure',
}

describe('json as text', function()
  it('finds where every value sits', function()
    local text = '{ "a": [1, {"b": "x,]}"}], // note\n  "c": null }'
    local root = assert(jsontext().scan(text))
    eq('object', root.kind)
    eq({ 'a', 'c' }, { root.members[1].key, root.members[2].key })
    local a = root.members[1].value
    eq('[1, {"b": "x,]}"}]', text:sub(a.s, a.e))
    eq('{"b": "x,]}"}', text:sub(a.items[2].s, a.items[2].e))
    eq('null', text:sub(root.members[2].value.s, root.members[2].value.e))
  end)

  it('says where a broken file breaks', function()
    local _, err = jsontext().scan('{\n  "a": 1,\n  "b" 2\n}')
    has(err, 'line 3')
    no((jsontext().scan('{"a": 1} trailing')))
    no((jsontext().scan('{"a": /* never closed')))
    no((jsontext().scan('')))
  end)

  it('reads comments without being fooled by strings', function()
    local text = '{\n  // a "comment"\n  "url": "http://x/y", /* b */ "n": 1\n}'
    local v = assert(jsontext().decode(text))
    eq('http://x/y', v.url)
    eq(1, v.n)
    eq(#text, #jsontext().strip_comments(text))
  end)
end)

describe('installing hooks', function()
  it('adds its entries and nothing else', function()
    local home = fx.home()
    local before =
      '{\n  "model": "opus",\n  "permissions": {\n    "allow": ["Bash(ls:*)"]\n  }\n}\n'
    T.write(settings(home), before)
    eq('missing', hooks().status('claude').state)
    local plan = run('install')
    ok(plan.changed)
    local after = read(settings(home))
    -- Everything that was there is still there, in place, byte for byte.
    has(after, '{\n  "model": "opus",\n  "permissions": {\n    "allow": ["Bash(ls:*)"]\n  },\n')
    local doc = vim.json.decode(after)
    eq('opus', doc.model)
    eq({ 'Bash(ls:*)' }, doc.permissions.allow)
    for _, event in ipairs(EVENTS) do
      local group = doc.hooks[event]
      eq(1, #group, event)
      eq('command', group[1].hooks[1].type)
      eq(hooks().command('claude'), group[1].hooks[1].command)
      eq(10, group[1].hooks[1].timeout)
    end
    eq('installed', hooks().status('claude').state)
    -- The script went where the command points.
    eq(read(hooks().script_source()), read(hooks().script_path()))
  end)

  it('is a no-op the second time', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    run('install')
    local once = read(settings(home))
    local plan = assert(hooks().plan('claude', 'install'))
    no(plan.changed)
    no(plan.script)
    hooks().apply(plan)
    eq(once, read(settings(home)))
  end)

  it('puts every layout back exactly as it was', function()
    local layouts = {
      plain = '{\n  "model": "opus",\n  "env": { "A": "1" }\n}\n',
      tabs = '{\n\t"model": "opus",\n\t"list": [\n\t\t1,\n\t\t2\n\t]\n}\n',
      four = '{\n    "model": "opus"\n}\n',
      oneline = '{"model":"opus","n":[1,2]}',
      crlf = '{\r\n  "model": "opus",\r\n  "x": true\r\n}\r\n',
      comments = '{\n  // which model\n  "model": "opus", /* inline */\n  "x": 1 // last\n}\n',
      no_newline = '{\n  "model": "opus"\n}',
      own_hooks = table.concat({
        '{',
        '  "hooks": {',
        '    "Stop": [',
        '      {',
        '        "hooks": [',
        '          { "type": "command", "command": "notify-send done" }',
        '        ]',
        '      }',
        '    ],',
        '    "PreToolUse": [',
        '      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "./check.sh" }] }',
        '    ]',
        '  },',
        '  "model": "opus"',
        '}',
        '',
      }, '\n'),
      empty_lists = '{\n  "hooks": {\n    "Stop": [],\n    "Notification": []\n  }\n}\n',
    }
    for name, before in pairs(layouts) do
      local home = fx.home()
      T.write(settings(home), before)
      run('install')
      local installed = read(settings(home))
      ok(installed ~= before, name)
      eq('installed', hooks().status('claude').state, name)
      local doc = assert(jsontext().decode(installed), name)
      eq('opus', doc.model or 'opus', name)
      run('uninstall')
      eq('missing', hooks().status('claude').state, name)
      if name == 'empty_lists' then
        -- Lists that held nothing are not kept for their own sake.
        eq(vim.empty_dict(), vim.json.decode(read(settings(home))), name)
      else
        eq(before, read(settings(home)), name)
      end
    end
  end)

  it("keeps the user's own hooks, also in the events it shares", function()
    local home = fx.home()
    local mine = '{ "type": "command", "command": "notify-send done" }'
    T.write(
      settings(home),
      '{\n  "hooks": {\n    "Stop": [\n      { "hooks": [' .. mine .. '] }\n    ]\n  }\n}\n'
    )
    run('install')
    local doc = vim.json.decode(read(settings(home)))
    eq(2, #doc.hooks.Stop)
    eq('notify-send done', doc.hooks.Stop[1].hooks[1].command)
    has(doc.hooks.Stop[2].hooks[1].command, 'agent-chats-hook.sh')
    run('uninstall')
    doc = vim.json.decode(read(settings(home)))
    eq(1, #doc.hooks.Stop)
    eq('notify-send done', doc.hooks.Stop[1].hooks[1].command)
    eq(nil, doc.hooks.SessionStart)
  end)

  it('takes its hook out of an entry it shares with others', function()
    local home = fx.home()
    T.write(
      settings(home),
      vim.json.encode({
        hooks = {
          Stop = {
            {
              hooks = {
                { type = 'command', command = 'first' },
                { type = 'command', command = "sh '/old/place/agent-chats-hook.sh' claude" },
                { type = 'command', command = 'last' },
              },
            },
          },
        },
      })
    )
    eq('outdated', hooks().status('claude').state)
    run('uninstall')
    local doc = vim.json.decode(read(settings(home)))
    eq(
      { 'first', 'last' },
      { doc.hooks.Stop[1].hooks[1].command, doc.hooks.Stop[1].hooks[2].command }
    )
  end)

  it('replaces what an older version installed', function()
    local home = fx.home()
    T.write(
      settings(home),
      vim.json.encode({
        model = 'opus',
        hooks = {
          Stop = {
            { hooks = { { type = 'command', command = 'sh /old/agent-chats-hook.sh claude' } } },
          },
          PreToolUse = {
            { hooks = { { type = 'command', command = 'sh /old/agent-chats-hook.sh claude' } } },
          },
        },
      })
    )
    eq('outdated', hooks().status('claude').state)
    run('install')
    local doc = vim.json.decode(read(settings(home)))
    eq('installed', hooks().status('claude').state)
    eq(nil, doc.hooks.PreToolUse, 'an event that is no longer hooked')
    eq(1, #doc.hooks.Stop)
    eq('opus', doc.model)
  end)

  it('accepts entries made by hand that do the same thing', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    run('install')
    local written = hooks().command('claude')
    -- The same thing, spelled the way a person would: double quotes.
    local dir = require('agent-chats.events').dir()
    local by_hand = ('AGENT_CHATS_EVENTS_DIR="%s" sh "%s" claude 2>/dev/null || true'):format(
      dir,
      hooks().script_path()
    )
    local function rewrite(command)
      local text = read(settings(home))
      local escaped = vim.json.encode(written):sub(2, -2):gsub('\\/', '/')
      text = text:gsub(vim.pesc(escaped), (vim.json.encode(command):sub(2, -2):gsub('%%', '%%%%')))
      T.write(settings(home), text)
    end
    rewrite(by_hand)
    has(read(settings(home)), 'sh \\"')
    eq('installed', hooks().status('claude').state)
    no(assert(hooks().plan('claude', 'install')).changed, 'and it is left as written')

    -- One that could fail the agent is not accepted.
    local function try(command)
      rewrite(command)
      written = command
      return hooks().status('claude')
    end
    written = by_hand
    local st =
      try(('AGENT_CHATS_EVENTS_DIR="%s" sh "%s" claude'):format(dir, hooks().script_path()))
    eq('outdated', st.state)
    has(st.detail, '|| true')
    -- Nor one for another agent, nor one whose script is gone.
    st = try(
      ('AGENT_CHATS_EVENTS_DIR="%s" sh "%s" codex 2>/dev/null || true'):format(
        dir,
        hooks().script_path()
      )
    )
    has(st.detail, 'does not name this agent')
    st = try(
      ('AGENT_CHATS_EVENTS_DIR="%s" sh ~/nowhere/agent-chats-hook.sh claude 2>/dev/null || true'):format(
        dir
      )
    )
    has(st.detail, 'a script that is not there')
    -- Nor one that writes where this Neovim does not look: to another
    -- folder, or (told nothing) to the default one while a folder is set.
    st = try(
      ('AGENT_CHATS_EVENTS_DIR=/somewhere/else sh "%s" claude 2>/dev/null || true'):format(
        hooks().script_path()
      )
    )
    eq('outdated', st.state)
    has(st.detail, 'a folder this Neovim does not read')
    st = try(('sh "%s" claude 2>/dev/null || true'):format(hooks().script_path()))
    has(st.detail, 'a folder this Neovim does not read')
    -- Installing puts all of that right.
    written = nil
    run('install')
    eq('installed', hooks().status('claude').state)
    eq(
      hooks().command('claude'),
      vim.json.decode(read(settings(home))).hooks.Stop[1].hooks[1].command
    )
  end)

  it('refuses a file it cannot edit safely, and says why', function()
    local home = fx.home()
    local cases = {
      { '{ "model": "opus", }', 'not valid JSON' },
      { '[1, 2]', 'JSON object' },
      { '{ "hooks": [] }', 'not a table of events' },
      { '{ "hooks": { "Stop": {} } }', 'not a list' },
    }
    for _, case in ipairs(cases) do
      T.write(settings(home), case[1])
      local plan, err = hooks().plan('claude', 'install')
      eq(nil, plan, case[1])
      has(err, case[2])
      has(err, 'left alone')
      eq(case[1], read(settings(home)))
    end
    T.write(settings(home), '{ "model": "opus", }')
    eq('broken', hooks().status('claude').state)
  end)

  it('writes nothing when the file changed after the preview', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    local plan = assert(hooks().plan('claude', 'install'))
    T.write(settings(home), '{ "model": "sonnet" }\n')
    local done, err = hooks().apply(plan)
    no(done)
    has(err, 'changed in the meantime')
    eq('{ "model": "sonnet" }\n', read(settings(home)))
  end)

  it('keeps a backup, the file mode, and a link a link', function()
    local home = fx.home()
    local real = home.root .. '/dotfiles/claude-settings.json'
    T.write(real, '{\n  "model": "opus"\n}\n')
    vim.uv.fs_chmod(real, 384)
    assert(vim.uv.fs_symlink(real, settings(home)))
    run('install')
    eq('link', vim.uv.fs_lstat(settings(home)).type)
    eq(384, bit.band(vim.uv.fs_stat(real).mode, 511))
    has(read(real), 'agent-chats-hook.sh')
    local backups = vim.fn.glob(real .. '.agent-chats-backup-*', false, true)
    eq(1, #backups)
    eq('{\n  "model": "opus"\n}\n', read(backups[1]))
  end)

  it('creates the file when the agent has none yet', function()
    local home = fx.home()
    eq(nil, read(settings(home)))
    local plan = run('install')
    eq(nil, plan.before)
    local doc = vim.json.decode(read(settings(home)))
    eq(#EVENTS, vim.tbl_count(doc.hooks))
    eq({}, vim.fn.glob(settings(home) .. '.agent-chats-backup-*', false, true))
    run('uninstall')
    eq(vim.empty_dict(), vim.json.decode(read(settings(home))))
  end)

  it('will not set up an agent that is not there', function()
    fx.home({ providers = { claude = { home = '/nonexistent/place/.claude' } } })
    local plan, err = hooks().plan('claude', 'install')
    eq(nil, plan)
    has(err, 'does not seem to be set up')
  end)

  it('forgets what the hooks reported when they are removed', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    run('install')
    hk.event('claude', 'some-session', 'Stop')
    eq(1, (require('agent-chats.events').summary('claude')))
    run('uninstall')
    eq(0, (require('agent-chats.events').summary('claude')))
  end)

  it('installs a command that cannot fail the agent', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    run('install')
    local command = vim.json.decode(read(settings(home))).hooks.Stop[1].hooks[1].command
    local payload = '{"session_id":"e2e-1","hook_event_name":"Stop"}'
    local function fire()
      return vim.system({ 'sh', '-c', command }, { stdin = payload, text = true }):wait(10000)
    end
    local res = fire()
    eq(0, res.code)
    eq('', res.stdout .. res.stderr)
    eq('Stop', hk.lines('claude', 'e2e-1')[1].e)

    -- The script is gone (the data folder was wiped): still silent, still 0.
    vim.uv.fs_unlink(hooks().script_path())
    res = fire()
    eq(0, res.code)
    eq('', res.stdout .. res.stderr)
    eq('outdated', hooks().status('claude').state)
  end)

  it('reports through the whole chain: settings, script, log, board status', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    run('install')
    local chat = home:chat({ start = os.time() - 40 }):user('Go')
    chat:tool_use('Bash', { command = 'make' }):write()
    home:registry(vim.uv.os_getpid(), { sessionId = chat.id, status = 'not-a-known-status' })
    local command =
      vim.json.decode(read(settings(home))).hooks.PermissionRequest[1].hooks[1].command
    local payload = ('{"session_id":"%s","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make"}}'):format(
      chat.id
    )
    eq(0, vim.system({ 'sh', '-c', command }, { stdin = payload }):wait(10000).code)
    local store = require('agent-chats.store')
    store.refresh_sync()
    local c = store.get('claude:' .. chat.id)
    eq('attention', c.status)
    eq('hooks', c.source)
    eq('permission to use Bash', c.waiting_for)
  end)

  it('says what to add by hand, with text that is valid as it stands', function()
    fx.home()
    local lines = hooks().manual('claude')
    local text = table.concat(lines, '\n')
    has(text, hooks().script_path())
    has(text, 'settings.json')
    local block = text:match('\n  ({\n.*\n  })')
    local doc = vim.json.decode(block)
    eq(hooks().command('claude'), doc.hooks.Stop[1].hooks[1].command)
  end)

  it('lists the agents in use that have no hooks yet', function()
    local home = fx.home()
    T.write(settings(home), '{}\n')
    home:chat():user('Hi'):write()
    eq({ 'Claude' }, hooks().lacking())
    run('install')
    eq({}, hooks().lacking())
  end)
end)

describe('installing hooks for the other agents', function()
  it('writes a hooks file for Codex, with its own events and time limits', function()
    local cx = require('helpers.codex')
    local home = cx.home()
    local plan = assert(hooks().plan('codex', 'install'))
    eq(home.dir .. '/hooks.json', plan.path)
    ok(hooks().apply(plan))
    local doc = vim.json.decode(read(home.dir .. '/hooks.json'))
    ok(doc.hooks.Interrupt and doc.hooks.PermissionRequest and doc.hooks.Stop)
    eq(nil, doc.hooks.Notification)
    eq(10, doc.hooks.Stop[1].hooks[1].timeout)
    eq(nil, doc.hooks.Interrupt[1].hooks[1].timeout)
    has(doc.hooks.Stop[1].hooks[1].command, ' codex ')
    has(plan.note, '/hooks')
    eq('installed', hooks().status('codex').state)
  end)

  it('edits the settings of Qwen', function()
    local qx = require('helpers.qwen')
    local home = qx.home()
    T.write(home.dir .. '/settings.json', '{\n  "$version": 3,\n  "ui": { "theme": "x" }\n}\n')
    local plan = assert(hooks().plan('qwen', 'install'))
    ok(hooks().apply(plan))
    local doc = vim.json.decode(read(home.dir .. '/settings.json'))
    eq(3, doc['$version'])
    has(doc.hooks.Notification[1].hooks[1].command, ' qwen ')
    eq('installed', hooks().status('qwen').state)
  end)

  it('drops a plugin file in place for opencode, and only removes its own', function()
    local ox = require('helpers.opencode')
    local home = ox.home()
    local path = home.root .. '/config/opencode/plugins/agent-chats.js'
    vim.fn.mkdir(home.root .. '/config/opencode', 'p')
    eq('missing', hooks().status('opencode').state)
    local plan = assert(hooks().plan('opencode', 'install'))
    eq(path, plan.path)
    ok(hooks().apply(plan))
    has(read(path), 'export const AgentChats')
    -- Told where the tests keep their events, since that is not the default.
    has(read(path), 'const FIXED_DIR = "' .. require('agent-chats.events').dir() .. '"')
    eq('installed', hooks().status('opencode').state)

    T.write(path, read(path) .. '\n// edited\n')
    eq('outdated', hooks().status('opencode').state)
    ok(hooks().apply(assert(hooks().plan('opencode', 'uninstall'))))
    eq(nil, read(path))

    T.write(path, 'export const SomebodyElse = async () => ({})\n')
    eq('broken', hooks().status('opencode').state)
    local none, err = hooks().plan('opencode', 'install')
    eq(nil, none)
    has(err, 'not written by this plugin')
    none, err = hooks().plan('opencode', 'uninstall')
    eq(nil, none)
    has(err, 'left alone')
  end)
end)

describe('the opencode plugin', function()
  it('writes down what a session is doing', function()
    if vim.fn.executable('node') ~= 1 then
      return
    end
    local ox = require('helpers.opencode')
    local home = ox.home()
    vim.fn.mkdir(home.root .. '/config/opencode', 'p')
    ok(hooks().apply(assert(hooks().plan('opencode', 'install'))))
    local plugin = home.root .. '/config/opencode/plugins/agent-chats.js'
    -- A driver that loads the plugin the way opencode does and feeds it events.
    local driver = home.root .. '/drive.mjs'
    T.write(
      driver,
      ([==[
import * as mod from %s;
const hooks = [];
for (const make of Object.values(mod)) hooks.push(await make({}));
const send = async (type, properties) => {
  for (const h of hooks) await h.event({ event: { id: "e", type, properties } });
};
await send("session.status", { sessionID: "ses_one", status: { type: "busy" } });
await send("message.updated", { sessionID: "ses_one", info: { secret: "do not keep" } });
await send("permission.asked", { id: "per_1", sessionID: "ses_one", permission: "bash", patterns: ["make secret"] });
await send("permission.replied", { sessionID: "ses_one", requestID: "per_1", reply: "once" });
await send("question.asked", { id: "que_1", sessionID: "ses_one", questions: [{ question: "secret?" }] });
await send("question.replied", { requestID: "que_1", answers: [["secret"]] });
await send("session.error", { sessionID: "ses_one", error: { name: "MessageAbortedError", data: { message: "secret" } } });
await send("session.status", { sessionID: "ses_one", status: { type: "idle" } });
await send("session.idle", { sessionID: "../escape" });
await send("session.idle", {});
]==]):format(vim.json.encode(plugin))
    )
    local res = vim.system({ 'node', driver }, { text = true }):wait(20000)
    eq(0, res.code, res.stderr)
    local lines = hk.lines('opencode', 'ses_one')
    local names = {}
    for i, line in ipairs(lines) do
      names[i] = line.e
      ok(type(line.t) == 'number' and type(line.pid) == 'number')
    end
    eq({
      'session.status',
      'permission.asked',
      'permission.replied',
      'question.asked',
      'question.replied',
      'session.error',
      'session.status',
    }, names)
    eq('busy', lines[1].type)
    eq({ 'per_1', 'bash' }, { lines[2].req, lines[2].tool })
    eq('que_1', lines[5].req, 'an answer finds its session through the question')
    eq('MessageAbortedError', lines[6].type)
    hasnt(read(hk.log('opencode', 'ses_one')), 'secret')
    eq(1, #vim.fn.glob(require('agent-chats.events').dir() .. '/**/*.log', false, true))

    -- And the board reads it: a request that was answered, a turn interrupted.
    local rules = require('agent-chats.providers.opencode').hooks.events
    local ev = require('agent-chats.events')
    eq('aborted', ev.get('opencode', rules, 'ses_one').turn)
    hk.event('opencode', 'ses_two', 'session.status', { type = 'busy' })
    hk.event('opencode', 'ses_two', 'permission.asked', { req = 'p1', tool = 'edit' })
    hk.event('opencode', 'ses_two', 'session.status', { type = 'busy' })
    local r = ev.get('opencode', rules, 'ses_two')
    eq('waiting', r.turn)
    eq('permission to use edit', r.waiting_for)
    hk.event('opencode', 'ses_two', 'permission.replied', { req = 'p1' })
    eq('working', ev.get('opencode', rules, 'ses_two').turn)
    hk.event('opencode', 'ses_two', 'session.idle')
    eq('done', ev.get('opencode', rules, 'ses_two').turn)
  end)
end)
