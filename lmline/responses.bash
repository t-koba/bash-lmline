#!/usr/bin/env bash

# Responses API request handling for the lmline engine. This file is meant to
# be sourced by the engine entry script after chat.bash.
#
# The ChatGPT plan route requires stream:true on every request, so the engine
# has to read a server-sent event stream even when it does not print the
# answer while it arrives. This module sends the request, rebuilds the
# response object the rest of the pipeline expects, and leaves a plain JSON
# body untouched. Search events and URL citations live in the response
# object, so both survive the rebuild.

# Extracts the JSON payloads of a server-sent event stream: one JSON object
# per line in $2.
__lmline_responses_sse_events() {
  local sse_file=$1 out=$2
  : >"$out"
  jq -R -s '
    [ splits("\n")
      | sub("\r$"; "")
      | select(startswith("data:"))
      | ltrimstr("data:")
      | sub("^ "; "")
      | select(. != "[DONE]")
      | (fromjson? // empty) ]
    | .[]
  ' "$sse_file" >>"$out" 2>/dev/null || return 1
}

# Rebuilds the response object from the collected events. A completed stream
# carries the whole response; an interrupted one is rebuilt from the output
# items that were delivered, so search events and citations survive.
__lmline_responses_body_from_events() {
  local events=$1 out=$2
  jq -s '
    ([.[] | select(.type == "response.completed") | .response] | last) as $done
    | ([.[] | select(.type == "response.failed") | .response] | last) as $failed
    | ([.[] | select(.type == "response.created") | .response] | first) as $start
    | if $done != null then $done
      elif $failed != null then ($failed + {status: "failed"})
      else (($start // {}) + {
              output: [.[] | select(.type == "response.output_item.done") | .item],
              status: "incomplete",
              incomplete_details: {reason: "stream_ended_without_completion"}})
      end
  ' "$events" >"$out"
}

# True when the body is a server-sent event stream.
__lmline_responses_is_event_stream() {
  local body=$1
  [[ -s "$body" ]] || return 1
  grep -q '^data:' "$body" 2>/dev/null
}

# Runs the request and writes the response object to $1. A provider that
# answers with server-sent events is rebuilt into the response object; a
# plain JSON body is used as it is. Prints the HTTP status and content type
# like __lmline_curl_chat.
__lmline_responses_fetch() {
  local response=$1 payload=$2
  local raw=$work_dir/responses.raw.sse events=$work_dir/responses.events.jsonl meta
  meta=$(curl -q -sS -N --max-time "$LMLINE_ENGINE_TIMEOUT" \
    -o "$raw" -w '%{http_code}\t%{content_type}' \
    "${curl_headers[@]}" \
    -X POST \
    --data-binary @"$payload" \
    "$base$(__lmline_api_path responses)" 2>"$err_file") || return 1
  if __lmline_responses_is_event_stream "$raw"; then
    __lmline_responses_sse_events "$raw" "$events" || return 1
    __lmline_responses_body_from_events "$events" "$response" || return 1
  else
    cp "$raw" "$response"
  fi
  printf '%s' "$meta"
}
