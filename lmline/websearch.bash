#!/usr/bin/env bash

# Native provider web search for the lmline engine. This file is meant to be
# sourced by the engine entry script after chat.bash.
#
# Native web search is a provider-side capability: the model asks the
# provider to retrieve pages, the provider performs the network access, and
# the answer returns with search events and URL citations. It is separate
# from the local function tools, it is opt-in, and it is off by default.
# Retrieved pages are untrusted data; the request prompt says so whenever
# search is enabled.

# True when native web search is enabled.
__lmline_web_search_enabled() {
  case "${LMLINE_WEB_SEARCH:-0}" in
    1|true|TRUE|on|ON|yes|YES) return 0 ;;
  esac
  return 1
}

# A repeated request can trigger a second billed provider search, and the
# ChatGPT subscription route spends the user's plan, so the engine skips
# every automatic repeat (an HTTP retry, a compatibility retry, a format
# retry, a candidate-validation retry) on those routes. The provider error
# is reported instead of repeating the request.
__lmline_request_repeat_allowed() {
  [[ "${LMLINE_AUTH_MODE:-api-key}" == chatgpt ]] && return 1
  __lmline_web_search_enabled && return 1
  return 0
}

# At most one provider request per exchange may ask the provider to run a
# new search, because every such request can bill another search. Later
# tool rounds keep the earlier results in the replay and do not ask again.
__lmline_web_search_request_allowed() {
  __lmline_web_search_enabled || return 1
  [[ "${__lmline_search_requested:-0}" == 1 ]] && return 1
  return 0
}

# Marks the search allowance of this exchange as used. The engine calls this
# when it sends a request that carries the provider-native search tool.
__lmline_web_search_request_done() {
  __lmline_search_requested=1
}

# The provider-native tool declaration. It never reaches the local function
# executor: the provider runs the search.
__lmline_web_search_tool_json() {
  printf '{"type":"web_search"}\n'
}

# Number of provider-side search calls in a response body.
__lmline_web_search_count() {
  local body=$1
  [[ -s "$body" ]] || { printf '0'; return 0; }
  jq -r '
    def items:
      if (.output | type) == "array" then .output
      else ((.choices[0].message.responses_replay // []) | if type == "array" then . else [] end)
      end;
    [items[] | select(.type == "web_search_call")] | length
  ' "$body" 2>/dev/null || printf '0'
}

# Emits the search events and the cited URLs of a response body on the stderr
# side channel. Citations stay out of the candidate text and out of the
# candidate JSON. The provider controls the query, the URL, and the page
# title, so control characters are removed before they are printed.
__lmline_web_search_report() {
  local body=$1 count
  [[ -s "$body" ]] || return 0
  count=$(__lmline_web_search_count "$body")
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
    __lmline_search_calls=$(( ${__lmline_search_calls:-0} + count ))
  fi
  jq -r '
    def clean: (tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; ""));
    def items:
      if (.output | type) == "array" then .output
      else ((.choices[0].message.responses_replay // []) | if type == "array" then . else [] end)
      end;
    items[]
    | select(.type == "web_search_call")
    | .action
    | select(. != null)
    | (.query // .queries // .url // .type // "search")
    | if type == "array" then join(" ") else tostring end
    | clean
  ' "$body" 2>/dev/null | while IFS= read -r detail; do
    [[ -n "$detail" ]] || continue
    printf 'lmline-search: %s\n' "$detail" >&2
  done
  jq -r '
    def clean: (tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; ""));
    def items:
      if (.output | type) == "array" then .output
      else ((.choices[0].message.responses_replay // []) | if type == "array" then . else [] end)
      end;
    items[]
    | select(.type == "message")
    | (.content // [])[]?
    | (.annotations // [])[]?
    | select(.type == "url_citation")
    | ((.url // "") | clean) + "\t" + ((.title // "") | clean)
  ' "$body" 2>/dev/null | while IFS=$'\t' read -r url title; do
    [[ -n "$url" ]] || continue
    printf 'lmline-citation: %s\t%s\n' "$url" "$title" >&2
  done
}
