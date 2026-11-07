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

# Rebuilds the response object directly from a server-sent event stream. A
# completed stream carries the whole response; an interrupted one is rebuilt
# from the output items that were delivered, so search events and citations
# survive.
__lmline_responses_body_from_sse() {
  local sse_file=$1 out=$2
  jq -R -n '
    reduce (
      inputs
      | sub("\r$"; "")
      | select(startswith("data:"))
      | ltrimstr("data:")
      | sub("^ "; "")
      | select(. != "[DONE]")
      | (fromjson? // empty)
    ) as $event
    (
      {done: null, failed: null, incomplete: null, start: null,
       start_seen: false, items: []};
      if $event.type == "response.completed" then .done = $event.response
      elif $event.type == "response.failed" then .failed = $event.response
      elif $event.type == "response.incomplete" then .incomplete = $event.response
      elif $event.type == "response.created" and (.start_seen | not) then
        .start = $event.response | .start_seen = true
      elif $event.type == "response.output_item.done" then
        .items += [$event.item]
      else .
      end
    )
    | if .done != null then .done
      elif .failed != null then (.failed + {status: "failed"})
      elif .incomplete != null then (.incomplete + {status: "incomplete"})
      else ((.start // {}) + {
              output: .items,
              status: "incomplete",
              incomplete_details: {reason: "stream_ended_without_completion"}})
      end
  ' "$sse_file" >"$out"
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
  local raw=$work_dir/responses.raw.sse meta
  meta=$(curl -q -sS -N --max-time "$LMLINE_ENGINE_TIMEOUT" \
    -o "$raw" -w '%{http_code}\t%{content_type}' \
    "${curl_headers[@]}" \
    -X POST \
    --data-binary @"$payload" \
    "$base$(__lmline_api_path responses)" 2>"$err_file") || return 1
  if __lmline_responses_is_event_stream "$raw"; then
    __lmline_responses_body_from_sse "$raw" "$response" || return 1
  else
    cp "$raw" "$response"
  fi
  printf '%s' "$meta"
}
