-- A small read-oriented SQLite binding over LuaJIT's FFI, for agents that
-- keep their chats in a database instead of files. It uses the system
-- SQLite library, so the plugin needs no build step and no dependency; when
-- the library cannot be loaded `available()` is false and callers fall back
-- to the agent's own command line.

local M = {}

local ffi_ok, ffi = pcall(require, 'ffi')
local lib

local DECLS = {
  'typedef struct sqlite3 sqlite3;',
  'typedef struct sqlite3_stmt sqlite3_stmt;',
  'int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);',
  'int sqlite3_close(sqlite3 *db);',
  'int sqlite3_busy_timeout(sqlite3 *db, int ms);',
  'const char *sqlite3_errmsg(sqlite3 *db);',
  'int sqlite3_exec(sqlite3 *db, const char *sql, void *cb, void *arg, char **errmsg);',
  'int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);',
  'int sqlite3_step(sqlite3_stmt *stmt);',
  'int sqlite3_finalize(sqlite3_stmt *stmt);',
  'int sqlite3_column_count(sqlite3_stmt *stmt);',
  'const char *sqlite3_column_name(sqlite3_stmt *stmt, int n);',
  'int sqlite3_column_type(sqlite3_stmt *stmt, int n);',
  'long long sqlite3_column_int64(sqlite3_stmt *stmt, int n);',
  'double sqlite3_column_double(sqlite3_stmt *stmt, int n);',
  'const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int n);',
  'int sqlite3_column_bytes(sqlite3_stmt *stmt, int n);',
  'int sqlite3_bind_text(sqlite3_stmt *stmt, int n, const char *text, int len, intptr_t destructor);',
  'int sqlite3_bind_int64(sqlite3_stmt *stmt, int n, long long value);',
  'int sqlite3_bind_double(sqlite3_stmt *stmt, int n, double value);',
  'int sqlite3_bind_null(sqlite3_stmt *stmt, int n);',
}

local OPEN_READONLY, OPEN_READWRITE, OPEN_CREATE = 0x1, 0x2, 0x4
local ROW, DONE = 100, 101
local INTEGER, FLOAT, TEXT, BLOB = 1, 2, 3, 4
local TRANSIENT = -1

local function load()
  if lib ~= nil then
    return lib
  end
  lib = false
  if not ffi_ok then
    return lib
  end
  -- Another plugin may have declared (some of) these already; each one is
  -- declared on its own so a duplicate does not stop the rest.
  for _, decl in ipairs(DECLS) do
    pcall(ffi.cdef, decl)
  end
  for _, name in ipairs({
    'sqlite3',
    'libsqlite3.so.0',
    'libsqlite3.0.dylib',
    'libsqlite3.dylib',
    'sqlite3.dll',
  }) do
    local ok, handle = pcall(ffi.load, name)
    if ok then
      -- Loading succeeds lazily; make sure the symbols are really there.
      local has = pcall(function()
        return handle.sqlite3_open_v2
      end)
      if has then
        lib = handle
        break
      end
    end
  end
  return lib
end

--- Whether the system SQLite library could be loaded.
function M.available()
  return load() ~= false
end

---@class agent_chats.Sqlite
---@field private db ffi.cdata*
local DB = {}
DB.__index = DB

--- Open a database. Read-only unless `opts.write` is set (tests).
---@param path string
---@param opts { write: boolean? }?
---@return agent_chats.Sqlite? db, string? err
function M.open(path, opts)
  local l = load()
  if not l then
    return nil, 'SQLite library not found'
  end
  local out = ffi.new('sqlite3*[1]')
  local flags = (opts and opts.write) and bit.bor(OPEN_READWRITE, OPEN_CREATE) or OPEN_READONLY
  local rc = l.sqlite3_open_v2(path, out, flags, nil)
  local db = out[0]
  if rc ~= 0 then
    local msg = db ~= nil and ffi.string(l.sqlite3_errmsg(db)) or ('error ' .. rc)
    if db ~= nil then
      l.sqlite3_close(db)
    end
    return nil, msg
  end
  -- The agent writes to this file while we read it.
  l.sqlite3_busy_timeout(db, 250)
  return setmetatable({ db = db }, DB), nil
end

function DB:close()
  if self.db ~= nil then
    lib.sqlite3_close(self.db)
    self.db = nil
  end
end

function DB:errmsg()
  return ffi.string(lib.sqlite3_errmsg(self.db))
end

--- Run statements that return no rows.
---@return boolean ok, string? err
function DB:exec(sql)
  local rc = lib.sqlite3_exec(self.db, sql, nil, nil, nil)
  if rc ~= 0 then
    return false, self:errmsg()
  end
  return true
end

--- Run one statement and return its rows as `{ column = value }` tables.
---@param sql string
---@param params any[]?
---@return table[]? rows, string? err
function DB:query(sql, params)
  local out = ffi.new('sqlite3_stmt*[1]')
  if lib.sqlite3_prepare_v2(self.db, sql, #sql, out, nil) ~= 0 then
    return nil, self:errmsg()
  end
  local stmt = out[0]
  for i, v in ipairs(params or {}) do
    if type(v) == 'number' then
      if v == math.floor(v) then
        lib.sqlite3_bind_int64(stmt, i, v)
      else
        lib.sqlite3_bind_double(stmt, i, v)
      end
    elseif v == vim.NIL then
      lib.sqlite3_bind_null(stmt, i)
    else
      local s = tostring(v)
      lib.sqlite3_bind_text(stmt, i, s, #s, TRANSIENT)
    end
  end
  local ncol = lib.sqlite3_column_count(stmt)
  local names = {}
  for c = 0, ncol - 1 do
    names[c] = ffi.string(lib.sqlite3_column_name(stmt, c))
  end
  local rows = {}
  local rc
  while true do
    rc = lib.sqlite3_step(stmt)
    if rc ~= ROW then
      break
    end
    local row = {}
    for c = 0, ncol - 1 do
      local t = lib.sqlite3_column_type(stmt, c)
      if t == INTEGER then
        row[names[c]] = tonumber(lib.sqlite3_column_int64(stmt, c))
      elseif t == FLOAT then
        row[names[c]] = lib.sqlite3_column_double(stmt, c)
      elseif t == TEXT or t == BLOB then
        local ptr = lib.sqlite3_column_text(stmt, c)
        row[names[c]] = ptr ~= nil and ffi.string(ptr, lib.sqlite3_column_bytes(stmt, c)) or ''
      end
    end
    rows[#rows + 1] = row
  end
  local err = rc ~= DONE and self:errmsg() or nil
  lib.sqlite3_finalize(stmt)
  if err then
    return nil, err
  end
  return rows, nil
end

return M
