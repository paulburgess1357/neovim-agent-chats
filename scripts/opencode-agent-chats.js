// agent-chats.nvim status plugin for opencode.
//
// opencode loads this file from its plugins folder and hands it every event
// of a session. The few that say what a session is doing are written, one
// short line each, to
//
//   <events dir>/opencode/<session id>.log
//
// which the Neovim plugin reads to show whether that chat is working, has
// finished its turn, or is waiting for you. The events dir is
// $AGENT_CHATS_EVENTS_DIR, else $XDG_STATE_HOME/agent-chats/events, else
// ~/.local/state/agent-chats/events.
//
// What a line holds: the time, the event's name and, when the event has
// them, the session's status, the id of a request and what it asks
// permission for, and opencode's process id. Prompts, replies, commands and
// tool output are never stored. A failure here is swallowed: it can never
// disturb the session.

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Set by the installer when the events dir is not the default one.
const FIXED_DIR = null;

function folder() {
  const state = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state");
  const base =
    FIXED_DIR || process.env.AGENT_CHATS_EVENTS_DIR || join(state, "agent-chats", "events");
  return join(base, "opencode");
}

function token(value) {
  return typeof value === "string" && /^[A-Za-z0-9_.:@/+=-]{1,120}$/.test(value)
    ? value
    : undefined;
}

// The session a request belongs to, for the answers that do not say.
const owners = new Map();

function record(type, props) {
  const line = { t: Date.now() / 1000, e: type };
  let session = props.sessionID;
  switch (type) {
    case "session.idle":
      break;
    case "session.status":
      line.type = token(props.status && props.status.type);
      break;
    case "session.error":
      line.type = token(props.error && props.error.name);
      break;
    case "permission.asked":
    case "question.asked":
      line.req = token(props.id);
      if (type === "permission.asked") line.tool = token(props.permission);
      if (line.req && session) owners.set(line.req, session);
      break;
    case "permission.replied":
    case "question.replied":
    case "question.rejected":
      line.req = token(props.requestID);
      if (!session && line.req) session = owners.get(line.req);
      if (line.req) owners.delete(line.req);
      break;
    default:
      return;
  }
  if (typeof session !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(session)) return;
  line.pid = process.pid;
  const dir = folder();
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
  appendFileSync(join(dir, session + ".log"), JSON.stringify(line) + "\n", { mode: 0o600 });
}

// Logs are small, but a session that has been silent for a month is over.
function prune() {
  const dir = folder();
  const cutoff = Date.now() - 30 * 86400 * 1000;
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(".log")) continue;
    const path = join(dir, name);
    if (statSync(path).mtimeMs < cutoff) unlinkSync(path);
  }
}

export const AgentChats = async () => {
  try {
    prune();
  } catch {
    // Nothing to prune, or not ours to worry about.
  }
  return {
    event: async ({ event }) => {
      try {
        record(event.type, event.properties || {});
      } catch {
        // Never opencode's problem.
      }
    },
  };
};
