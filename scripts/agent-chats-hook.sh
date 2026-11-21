#!/bin/sh
# agent-chats.nvim status hook.
#
# An AI coding agent (Claude Code, Qwen Code, Codex) runs this for a handful
# of its hook events. Each run appends one short line to
#
#   <events dir>/<agent>/<session id>.log
#
# which the Neovim plugin reads to show whether that chat is working, has
# finished its turn, or is waiting for you. The events dir is
# $AGENT_CHATS_EVENTS_DIR, else $XDG_STATE_HOME/agent-chats/events, else
# ~/.local/state/agent-chats/events.
#
# What a line holds: the time, the event's name and, when the event has
# them, the notification type, the tool's name, the subagent id, the session
# start source or end reason, whether a tool failed because you interrupted
# it, and the agent's process id. The first line of a log also names the
# transcript file and the working directory. Prompts, replies, commands and
# tool output are never stored.
#
# It prints nothing and always exits 0, so it cannot change or fail what the
# agent is doing. It needs nothing but a POSIX shell, and works whether or
# not Neovim is running.
#
# Usage, as a hook command:   sh agent-chats-hook.sh <agent> [event] [session id]
#
# The agent passes the event as JSON on standard input. `event` and
# `session id` are for agents whose hooks pass them some other way; when
# both are given, standard input is not read at all.

{
  agent=$1
  case $agent in
    '' | *[!A-Za-z0-9_-]*) exit 0 ;;
  esac
  LC_ALL=C
  export LC_ALL
  umask 077

  # Only the start of the payload is needed. The rest (a tool's output can
  # be megabytes) is read and dropped, so the agent never writes into a
  # closed pipe. Told everything on the command line, there is nothing to
  # read, and waiting for input that never ends would hang the agent.
  if [ -n "$2" ] && [ -n "$3" ]; then
    input=
  else
    input=$(
      head -c 16384 | tr '\n\r\t' '   '
      cat >/dev/null
    )
  fi

  # Sets `v` to the string value of the first `"<key>":"..."` in $2, or to
  # nothing. The fields wanted here never contain a quote or a backslash.
  field() {
    case $2 in
      *"\"$1\":\""*) v=${2#*"\"$1\":\""} ;;
      *"\"$1\": \""*) v=${2#*"\"$1\": \""} ;;
      *)
        v=
        return
        ;;
    esac
    v=${v%%\"*}
  }

  # Empties `v` unless it is a plain token of sensible length.
  token() {
    case $v in
      *[!A-Za-z0-9_.:@/+=-]*) v= ;;
    esac
    [ "${#v}" -le 120 ] || v=
  }

  # The session's id comes first in every payload seen so far: look for it
  # ahead of anything nested, where a key of the same name could hide, and
  # only then anywhere.
  flat=${input#*\{}
  flat=${flat%%[\{\[]*}
  field session_id "$flat"
  [ -n "$v" ] || field session_id "$input"
  sid=${v:-$3}
  case $sid in
    '' | *[!A-Za-z0-9_-]*) exit 0 ;;
  esac
  [ "${#sid}" -le 100 ] || exit 0

  field hook_event_name "$input"
  token
  event=${v:-$2}
  case $event in
    '' | *[!A-Za-z0-9_.-]*) exit 0 ;;
  esac
  [ "${#event}" -le 64 ] || exit 0

  # Fields the agent sets itself come before the ones that carry
  # conversation text, so a tool's own input is never mistaken for them.
  base=${input%%\"tool_input\"*}
  base=${base%%\"tool_response\"*}
  base=${base%%\"prompt\"*}
  base=${base%%\"last_assistant_message\"*}

  field agent_id "$base"
  token
  sub=$v
  field tool_name "$base"
  token
  tool=$v
  if [ -z "$tool" ]; then
    field tool_name "$input"
    token
    tool=$v
  fi
  kind=
  source=
  reason=
  interrupt=
  case $event in
    Notification)
      field notification_type "$input"
      token
      kind=$v
      ;;
    PostToolUseFailure)
      # A tool that failed because you interrupted the turn.
      case $input in
        *'"is_interrupt":true'* | *'"is_interrupt": true'*) interrupt=1 ;;
      esac
      ;;
    SessionStart)
      field source "$input"
      token
      source=$v
      ;;
    SessionEnd)
      field reason "$input"
      token
      reason=$v
      ;;
  esac

  dir=${AGENT_CHATS_EVENTS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-chats/events}/$agent
  [ -d "$dir" ] || mkdir -p "$dir" || exit 0
  file=$dir/$sid.log
  first=
  if [ ! -e "$file" ] || [ "$event" = SessionStart ]; then
    first=1
  fi

  # The agent's process: this script's parent, or the parent of the shell
  # the agent ran it through.
  pid=$PPID
  shells='sh dash bash zsh ash ksh mksh fish'
  if [ -r "/proc/$pid/stat" ]; then
    comm=
    read -r comm 2>/dev/null <"/proc/$pid/comm"
    case " $shells " in
      *" $comm "*)
        stat=
        read -r stat 2>/dev/null <"/proc/$pid/stat"
        stat=${stat##*) }
        # shellcheck disable=SC2086
        set -- $stat
        pid=$2
        ;;
    esac
  elif [ -n "$first" ]; then
    # No /proc: `ps` knows, at the price of a process, so it is asked once
    # per session and not for every event.
    # shellcheck disable=SC2046
    set -- $(ps -o ppid=,comm= -p "$pid" 2>/dev/null)
    comm=${2##*/}
    case " $shells " in
      *" ${comm#-} "*) pid=$1 ;;
    esac
  else
    pid=
  fi
  case $pid in
    '' | *[!0-9]*) pid= ;;
  esac

  # Seconds, with milliseconds where `date` can count nanoseconds (GNU,
  # busybox); whole seconds elsewhere.
  now=$(date +%s%N 2>/dev/null)
  case $now in
    *[!0-9]*) now= ;;
  esac
  if [ "${#now}" -eq 19 ]; then
    secs=${now%?????????}
    rest=${now#"$secs"}
    now=$secs.${rest%??????}
  else
    now=$(date +%s 2>/dev/null)
    case $now in
      '' | *[!0-9]*) exit 0 ;;
    esac
  fi

  line="{\"t\":$now,\"e\":\"$event\""
  [ -z "$kind" ] || line="$line,\"type\":\"$kind\""
  [ -z "$tool" ] || line="$line,\"tool\":\"$tool\""
  [ -z "$sub" ] || line="$line,\"agent\":\"$sub\""
  [ -z "$source" ] || line="$line,\"src\":\"$source\""
  [ -z "$reason" ] || line="$line,\"reason\":\"$reason\""
  [ -z "$interrupt" ] || line="$line,\"interrupt\":true"
  [ -z "$pid" ] || line="$line,\"pid\":$pid"
  if [ -n "$first" ]; then
    # Where the conversation is kept, once per log. A path that needs JSON
    # escapes is left out rather than risk a broken line.
    field transcript_path "$input"
    case $v in
      '' | *\\*) ;;
      *) [ "${#v}" -gt 1024 ] || line="$line,\"path\":\"$v\"" ;;
    esac
    field cwd "$input"
    case $v in
      '' | *\\*) ;;
      *) [ "${#v}" -gt 1024 ] || line="$line,\"cwd\":\"$v\"" ;;
    esac
  fi
  printf '%s}\n' "$line" >>"$file"

  # Logs are small, but a session that has been silent for a month is over.
  if [ "$event" = SessionStart ]; then
    find "$dir" -type f -name '*.log' -mtime +30 -exec rm -f {} + 2>/dev/null
  fi
} >/dev/null 2>&1

exit 0
