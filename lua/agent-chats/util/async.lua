-- Cooperative time slicing.
--
-- Scanning and parsing transcripts is synchronous code, and a first scan can
-- touch hundreds of files. `run` puts such a function in a coroutine; inside
-- it, `tick` hands control back to the event loop whenever the current slice
-- is used up, so the editor never stalls for longer than a few milliseconds.
--
-- Called outside `run` (tests, one-off calls) the same code simply runs to
-- completion: `tick` does nothing and `system` waits for the process.

local uv = vim.uv

local M = {}

-- Longest stretch of work before control returns to the event loop.
M.slice_ms = 8

---@type table<thread, { start: number, step: fun(...) }>
local running = setmetatable({}, { __mode = 'k' })

local function now()
  return uv.hrtime() / 1e6
end

local function current()
  local co, is_main = coroutine.running()
  if not co or is_main then
    return nil
  end
  return running[co]
end

--- Run `fn` in a time-sliced coroutine.
---@param fn fun(): ...
---@param done fun(ok: boolean, ...)? Called with `true, results...` or `false, traceback`.
---@return thread
function M.run(fn, done)
  local co = coroutine.create(fn)
  local state = { start = now() }
  local function step(...)
    state.start = now()
    local res = { coroutine.resume(co, ...) }
    if not res[1] then
      running[co] = nil
      local trace = debug.traceback(co, tostring(res[2]))
      if done then
        done(false, trace)
      else
        vim.schedule(function()
          vim.notify('agent-chats: ' .. trace, vim.log.levels.ERROR)
        end)
      end
    elseif coroutine.status(co) == 'dead' then
      running[co] = nil
      if done then
        done(true, unpack(res, 2, table.maxn(res)))
      end
    end
  end
  state.step = step
  running[co] = state
  step()
  return co
end

--- Yield to the event loop if this coroutine has used up its slice.
function M.tick()
  local state = current()
  if not state or now() - state.start < M.slice_ms then
    return
  end
  vim.schedule(state.step)
  coroutine.yield()
end

--- Whether the caller runs inside `run`.
function M.is_async()
  return current() ~= nil
end

--- Run a process and return its result (`vim.system` completion table).
--- Suspends the coroutine inside `run`; blocks outside it.
---@param cmd string[]
---@param opts table?
---@return vim.SystemCompleted
function M.system(cmd, opts)
  opts = vim.tbl_extend('keep', opts or {}, { text = true })
  local state = current()
  if not state then
    local ok, obj = pcall(vim.system, cmd, opts)
    if not ok then
      return { code = 127, signal = 0, stdout = '', stderr = tostring(obj) }
    end
    return obj:wait()
  end
  local ok, err = pcall(vim.system, cmd, opts, function(res)
    vim.schedule(function()
      state.step(res)
    end)
  end)
  if not ok then
    return { code = 127, signal = 0, stdout = '', stderr = tostring(err) }
  end
  return coroutine.yield()
end

--- Wait `ms` milliseconds without blocking the editor.
---@param ms integer
function M.sleep(ms)
  local state = current()
  if not state then
    vim.wait(ms)
    return
  end
  vim.defer_fn(state.step, ms)
  coroutine.yield()
end

return M
