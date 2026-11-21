-- What the plugin itself remembers about chats: when you last looked at
-- one, pins, labels, notes, names you gave them, archived chats, queued
-- replies and folded groups. One small JSON file, shared by every Neovim
-- instance, so each change is a locked read-modify-write.

local uv = vim.uv
local config = require('agent-chats.config')
local fs = require('agent-chats.util.fs')
local time = require('agent-chats.util.time')

local M = {}

local data, loaded_path, loaded_mtime
-- How often a change made by another instance was read in.
local foreign = 0
-- When the file was last checked for changes by another instance. Rows and
-- statuslines ask for state constantly; one stat per quarter second is plenty.
local checked_at = 0
local CHECK_EVERY = 250

local function fresh()
  return {
    version = 1,
    -- Chats older than the first run are not "unread": only what finishes
    -- after this moment is.
    baseline = os.time(),
    seen = {},
    pins = {},
    archived = {},
    labels = {},
    notes = {},
    names = {},
    queue = {},
    -- Chat key -> when a queued reply was last handed over; see `dequeue`.
    sending = {},
    -- Chat key -> true: its queued replies are kept, and sent only when
    -- you say so (the chat ended, or is not open here); see queue.lua.
    parked = {},
    collapsed = {},
  }
end

function M.path()
  return config.get().state_file or (vim.fn.stdpath('state') .. '/agent-chats/state.json')
end

local function normalise(t)
  local base = fresh()
  if type(t) ~= 'table' then
    return base, true
  end
  for k, v in pairs(base) do
    if type(t[k]) ~= type(v) then
      t[k] = v
    end
  end
  return t, false
end

local function read()
  local path = M.path()
  local st = fs.stat(path)
  if not st then
    return nil, nil
  end
  local raw = fs.read_json(path)
  if type(raw) ~= 'table' then
    -- Another instance may have been replacing it at that very moment:
    -- look again before believing it is broken.
    for _ = 1, 3 do
      -- A plain sleep: this runs while the lock is held, and callbacks let
      -- in here could come asking for the same lock.
      uv.sleep(10)
      st = fs.stat(path) or st
      raw = fs.read_json(path)
      if type(raw) == 'table' then
        break
      end
    end
  end
  if type(raw) ~= 'table' and st.size > 0 then
    -- Unreadable. It is about to be replaced, so keep what was there: it
    -- holds pins, labels and notes someone may want back.
    uv.fs_copyfile(path, path .. '.corrupt')
  end
  return raw, st.mtime
end

local function write(t)
  local path = M.path()
  if fs.write_atomic(path, vim.json.encode(t)) then
    local st = fs.stat(path)
    loaded_mtime = st and st.mtime or nil
  end
end

--- The current state, re-read when another instance changed the file.
function M.get()
  local path = M.path()
  local now = uv.now()
  if data and loaded_path == path and now - checked_at < CHECK_EVERY then
    return data
  end
  checked_at = now
  local st = fs.stat(path)
  if data and loaded_path == path and (st and st.mtime or nil) == loaded_mtime then
    return data
  end
  local raw, mtime = read()
  local is_new
  if data and loaded_path == path then
    -- Not the first load: another instance wrote the file.
    foreign = foreign + 1
  end
  data, is_new = normalise(raw)
  loaded_path, loaded_mtime = path, mtime
  if is_new and not st then
    -- First run: record the baseline now so it does not move.
    write(data)
  end
  return data
end

--- A number that moves whenever another Neovim changed the shared state
--- (a pin, a label, a read mark): whoever draws from it compares the
--- number to know that its picture is out of date.
---@return integer
function M.foreign_changes()
  M.get()
  return foreign
end

-- How long to wait for another instance to finish its change. A change
-- takes a millisecond or two, so this is only reached when something is
-- wrong; going ahead without the lock then beats freezing the editor.
local LOCK_WAIT_MS = 2000

local function lock()
  local path = M.path() .. '.lock'
  fs.mkdirp(vim.fs.dirname(path))
  local deadline = uv.now() + LOCK_WAIT_MS
  while true do
    local fd = uv.fs_open(path, 'wx', 420)
    if fd then
      uv.fs_close(fd)
      return path
    end
    local st = fs.stat(path)
    if st and os.time() - st.mtime > 5 then
      -- Left behind by an instance that died mid-write.
      uv.fs_unlink(path)
    elseif uv.now() >= deadline then
      return nil
    else
      -- Short and uneven: with several instances waiting, one that slept
      -- longer each time would keep finding the lock taken. (A plain
      -- sleep: nothing else of this Neovim needs to run meanwhile.)
      uv.sleep(math.random(1, 6))
    end
  end
end

--- Change the state: `fn(state)` runs on the latest copy from disk and the
--- result is written back. Returns whatever `fn` returns.
---@generic T
---@param fn fun(state: table): T
---@return T
function M.update(fn)
  local held = lock()
  local raw, mtime = read()
  data = normalise(raw)
  loaded_path, loaded_mtime = M.path(), mtime
  checked_at = uv.now()
  local ok, res = pcall(fn, data)
  if ok then
    write(data)
  end
  if held then
    uv.fs_unlink(held)
  end
  if not ok then
    error(res, 0)
  end
  return res
end

-- Read marks ---------------------------------------------------------------

--- Epoch seconds the user last looked at `key`.
function M.seen(key)
  local s = M.get()
  return s.seen[key] or s.baseline
end

--- To the fraction of a second: a turn that ended a moment before you
--- looked must not count as ended after it.
function M.mark_seen(key, ts)
  M.update(function(s)
    s.seen[key] = ts or time.precise()
  end)
end

function M.mark_unseen(key)
  M.update(function(s)
    s.seen[key] = 0
  end)
end

---@param keys string[]
function M.mark_all_seen(keys)
  local now = time.precise()
  M.update(function(s)
    for _, key in ipairs(keys) do
      s.seen[key] = now
    end
  end)
end

-- Pins, archive ------------------------------------------------------------

function M.pinned(key)
  return M.get().pins[key] == true
end

---@return boolean pinned The new state.
function M.toggle_pin(key)
  return M.update(function(s)
    s.pins[key] = not s.pins[key] or nil
    return s.pins[key] == true
  end)
end

--- When `key` was archived (nil when it is not).
function M.archived_at(key)
  return M.get().archived[key]
end

--- A chat is hidden while it has seen no activity since it was archived.
function M.is_archived(key, updated)
  local at = M.get().archived[key]
  return at ~= nil and (updated or 0) <= at
end

---@return boolean archived The new state.
function M.toggle_archive(key, updated)
  return M.update(function(s)
    local at = s.archived[key]
    if at and (updated or 0) <= at then
      s.archived[key] = nil
      return false
    end
    s.archived[key] = os.time()
    return true
  end)
end

-- Labels, notes, names -----------------------------------------------------

---@return string[]
function M.labels(key)
  return M.get().labels[key] or {}
end

---@param labels string[]
function M.set_labels(key, labels)
  M.update(function(s)
    s.labels[key] = #labels > 0 and labels or nil
  end)
end

function M.note(key)
  return M.get().notes[key]
end

function M.set_note(key, text)
  M.update(function(s)
    s.notes[key] = (text and text ~= '') and text or nil
  end)
end

function M.name(key)
  return M.get().names[key]
end

function M.set_name(key, text)
  M.update(function(s)
    s.names[key] = (text and text ~= '') and text or nil
  end)
end

-- Queued replies -----------------------------------------------------------

---@class agent_chats.Queued
---@field text string
---@field at number

---@return agent_chats.Queued[]
function M.queue(key)
  return M.get().queue[key] or {}
end

function M.enqueue(key, text)
  M.update(function(s)
    local q = s.queue[key] or {}
    q[#q + 1] = { text = text, at = os.time() }
    s.queue[key] = q
  end)
end

-- How long a chat is taken to be busy with the reply it was just handed,
-- when nothing shows that it took it up.
M.SENDING_SECS = 60

--- Take the oldest queued reply. With several instances watching the same
--- chat, only one of them gets it; and nobody gets the next one while that
--- one is on its way (see `claim`).
---@return agent_chats.Queued?
function M.dequeue(key)
  return M.update(function(s)
    local q = s.queue[key]
    if not q or #q == 0 then
      return nil
    end
    local handed = s.sending[key]
    if handed and time.precise() - handed < M.SENDING_SECS then
      return nil
    end
    local item = table.remove(q, 1)
    s.queue[key] = #q > 0 and q or nil
    s.sending[key] = time.precise()
    return item
  end)
end

--- When a reply was last handed to `key` and is not yet known to have
--- arrived (epoch seconds); nil when none is on its way.
---@return number?
function M.claim(key)
  local handed = M.get().sending[key]
  if handed and time.precise() - handed < M.SENDING_SECS then
    return handed
  end
  return nil
end

--- A reply was typed into the chat `key` just now, outside the queue (you
--- sent it yourself). Anything queued behind it waits like after a queued
--- one: until the chat has taken it up.
function M.hand_over(key)
  M.update(function(s)
    s.sending[key] = time.precise()
  end)
end

--- The reply handed to `key` has arrived (the chat is at work on it, or
--- done with it): the next may go.
function M.sent(key)
  if M.get().sending[key] ~= nil then
    M.update(function(s)
      s.sending[key] = nil
    end)
  end
end

--- Put a reply back at the front (delivery failed).
function M.requeue(key, item)
  M.update(function(s)
    local q = s.queue[key] or {}
    table.insert(q, 1, item)
    s.queue[key] = q
    s.sending[key] = nil
  end)
end

--- Drop one queued reply (`index`, 1 the oldest), or all of them (nil).
function M.remove_queued(key, index)
  M.update(function(s)
    local q = s.queue[key]
    if not q then
      return
    end
    if index == nil then
      s.queue[key] = nil
    elseif q[index] then
      table.remove(q, index)
      s.queue[key] = #q > 0 and q or nil
    end
    if not s.queue[key] then
      s.parked[key] = nil
    end
  end)
end

--- Whether the replies queued for `key` wait for you (Q sends or drops
--- them) instead of going out when the chat is free.
---@return boolean
function M.parked(key)
  return M.get().parked[key] == true
end

--- Keep (`on`) or stop keeping the queued replies of `key` back.
function M.park(key, on)
  local want = on ~= false and true or nil
  if M.get().parked[key] ~= want then
    M.update(function(s)
      s.parked[key] = want
    end)
  end
end

-- Folded groups ------------------------------------------------------------

function M.collapsed(group)
  return M.get().collapsed[group] == true
end

function M.set_collapsed(group, value)
  M.update(function(s)
    s.collapsed[group] = value or nil
  end)
end

--- Drop the in-memory copy (tests).
function M.reset()
  data, loaded_path, loaded_mtime, checked_at, foreign = nil, nil, nil, 0, 0
end

return M
