-- Process inspection where there is no /proc (macOS, the BSDs). That path
-- cannot be run on the machines the suite runs on, so it is forced here:
-- `ps` and `lsof` take the same arguments on Linux.

local T = require('helpers.harness')
local eq, ok = T.eq, T.ok

local proc = require('agent-chats.util.proc')
local async = require('agent-chats.util.async')

describe('process inspection without /proc', function()
  local had, real_system, calls
  local jobs = {}

  before_each(function()
    had = proc.has_procfs
    proc.has_procfs = false
    proc.reset()
    calls = {}
    real_system = async.system
    async.system = function(cmd, opts)
      calls[#calls + 1] = cmd[1]
      return real_system(cmd, opts)
    end
  end)

  after_each(function()
    async.system = real_system
    proc.has_procfs = had
    proc.reset()
    for _, job in ipairs(jobs) do
      pcall(job.kill, job, 9)
    end
    jobs = {}
  end)

  local function spawn(cmd)
    local job = vim.system(cmd, { stdin = true })
    jobs[#jobs + 1] = job
    T.wait(3000, function()
      proc.reset()
      return proc.argv(job.pid) ~= nil
    end)
    return job
  end

  local function count(name)
    local n = 0
    for _, c in ipairs(calls) do
      n = n + (c == name and 1 or 0)
    end
    return n
  end

  it('answers many questions from one look at the process table', function()
    if vim.fn.executable('ps') ~= 1 then
      return
    end
    local job = spawn({ 'sleep', '30' })
    proc.reset()
    calls = {}
    eq(vim.uv.os_getpid(), proc.parent(job.pid))
    eq({ 'sleep', '30' }, proc.argv(job.pid))
    ok(math.abs(proc.start_time(job.pid) - os.time()) < 10)
    ok(proc.is(job.pid, { sleep = true }))
    ok(not proc.is(job.pid, { codex = true }))
    eq(vim.uv.os_getpid(), proc.ancestors(job.pid)[1])
    local found = false
    for _, p in ipairs(proc.find({ sleep = true })) do
      found = found or p.pid == job.pid
    end
    ok(found)
    eq(nil, proc.parent(999999999))
    eq(1, count('ps'), 'one ps for all of that')
  end)

  it('remembers where a process runs', function()
    if vim.fn.executable('lsof') ~= 1 then
      return
    end
    local job = spawn({ 'sleep', '30' })
    calls = {}
    eq(vim.uv.cwd(), proc.cwd(job.pid))
    eq(vim.uv.cwd(), proc.cwd(job.pid))
    eq(1, count('lsof'))
  end)

  it('finds an agent that is a script run by a shell or a runtime', function()
    if vim.fn.executable('ps') ~= 1 then
      return
    end
    local bin = T.tmpdir() .. '/codex'
    T.write(bin, '#!/bin/sh\nread _\n')
    vim.uv.fs_chmod(bin, 493)
    local job = spawn({ bin, 'resume', 'abc' })
    proc.reset()
    local hit
    for _, p in ipairs(proc.find({ codex = true })) do
      if p.pid == job.pid then
        hit = p
      end
    end
    ok(hit, 'the script is listed under the name of its file')
    eq('codex', hit.name)
    ok(vim.tbl_contains(hit.argv, 'resume'))
  end)

  it('lets Codex match a running process to its chat', function()
    if vim.fn.executable('ps') ~= 1 then
      return
    end
    local cx = require('helpers.codex')
    local home = cx.home()
    local r = home:rollout({ start = os.time() - 60 }):meta():task_started():item_user('hi'):write()
    local bin = T.tmpdir() .. '/codex'
    T.write(bin, '#!/bin/sh\nread _\n')
    vim.uv.fs_chmod(bin, 493)
    local job = spawn({ bin, 'resume', r.id })
    proc.reset()
    local store = require('agent-chats.store')
    store.refresh_sync()
    local c = store.get('codex:' .. r.id)
    eq(true, c.live)
    eq(job.pid, c.pid)
  end)
end)
