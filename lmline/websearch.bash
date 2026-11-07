#!/usr/bin/env bash

# Native provider web search for the lmline engine and the CLI. This file is
# meant to be sourced by both entry scripts; it defines functions only.
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

# Emits the search events and the cited URLs of a response body on the stderr
# side channel. Citations stay out of the candidate text and out of the
# candidate JSON. The provider controls the query, the URL, and the page title,
# so control characters are removed before they are printed.
__lmline_web_search_report() {
  local body=$1 report_pid jq_status=0 loop_status=0 kind value title
  [[ -s "$body" ]] || return 0
  # One slurped pass emits the count, search details, then citations. The
  # engine rejects multi-document bodies before reporting; direct-helper
  # inputs retain document order, and only a single-document count advances
  # the global, matching the previous numeric count gate. Search extraction stays
  # isolated so malformed queries cannot suppress independently found citations.
  if while IFS=$'\t' read -r kind value title; do
    case "$kind" in
      count)
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
          __lmline_search_calls=$(( ${__lmline_search_calls:-0} + value ))
        fi
        ;;
      search)
        [[ -n "$value" ]] || continue
        printf 'lmline-search: %s\n' "$value" >&2
        ;;
      citation)
        [[ -n "$value" ]] || continue
        printf 'lmline-citation: %s\t%s\n' "$value" "$title" >&2
        ;;
    esac
  done < <(jq -s -r '
    def clean: (tostring | gsub("[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"; ""));
    def items:
      if (.output | type) == "array" then .output
      else ((.choices[0].message.responses_replay // []) | if type == "array" then . else [] end)
      end;
    . as $docs
    | [ $docs[] | items[] | select(.type == "web_search_call") ] as $calls
    | (
        "count\t" + (if ($docs | length) == 1 then ($calls | length | tostring) else "0" end),
        (try ($calls[] | .action | select(. != null)
          | (.query // .queries // .url // .type // "search")
          | if type == "array" then join(" ") else tostring end
          | clean | "search\t" + .) catch empty),
        ($docs[] | items[] | select(.type == "message")
          | (.content // [])[]? | (.annotations // [])[]?
          | select(.type == "url_citation")
          | "citation\t" + ((.url // "") | clean)
            + "\t" + ((.title // "") | clean))
      )
  ' "$body" 2>/dev/null); then
    loop_status=0
  else
    loop_status=$?
  fi
  # The read loop runs in this shell; wait for the process-substitution jq so
  # pipefail-enabled callers retain the old extraction error status.
  report_pid=$!
  if wait "$report_pid"; then
    jq_status=0
  else
    jq_status=$?
  fi
  if ((loop_status)); then return "$loop_status"; fi
  if ((jq_status)) && shopt -qo pipefail; then return "$jq_status"; fi
  return 0
}
