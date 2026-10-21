#!/usr/bin/env bash

# ChatGPT subscription authentication for the lmline engine. This file is
# meant to be sourced by the engine entry script after config.bash, http.bash,
# and profiles.bash.
#
# The route is OpenAI's documented "Sign in with ChatGPT" token sharing flow
# for open-source and locally hosted apps:
#   https://developers.openai.com/siwc/token-sharing-open-source
# A ChatGPT plan access token is sent as a Bearer credential to the OpenAI
# Responses API. Subscription authentication and API-key authentication are
# separate billing paths: the engine never exchanges one for the other and
# never falls back from one to the other.

# True when the ChatGPT subscription path is selected.
__lmline_chatgpt_enabled() {
  [[ "${LMLINE_AUTH_MODE:-api-key}" == chatgpt ]]
}

# The subscription token spends the user's ChatGPT plan. It must never
# travel to a third-party endpoint, so only the OpenAI API host and loopback
# proxies are accepted.
__lmline_chatgpt_base_allowed() {
  local host
  host=${1#*://}
  host=${host%%/*}
  host=${host%%:*}
  case "$host" in
    api.openai.com|127.0.0.1|localhost|::1) return 0 ;;
  esac
  return 1
}

# Writes a fresh access token to $1 (mode 0600). Fails closed: a missing
# session, a failed refresh, or a missing Node runtime never falls back to
# an API key.
__lmline_chatgpt_access_token() {
  local out=$1 client=${2-} err_file=$work_dir/chatgpt-token.err
  [[ -n "$client" ]] || client=${__lmline_chatgpt_client:-}
  if ! command -v node >/dev/null 2>&1; then
    printf 'lmline-engine: ChatGPT subscription auth requires Node.js; install Node.js or use API-key auth (LMLINE_AUTH_MODE=api-key)\n' >&2
    return 1
  fi
  if [[ ! -r "$client" ]]; then
    printf 'lmline-engine: the ChatGPT auth client is missing; reinstall lmline\n' >&2
    return 1
  fi
  if ! node "$client" token >"$out" 2>"$err_file"; then
    printf 'lmline-engine: ChatGPT subscription auth failed: %s\n' "$(sed -n '1p' "$err_file")" >&2
    return 1
  fi
  if [[ ! -s "$out" ]]; then
    printf 'lmline-engine: ChatGPT subscription auth returned no access token\n' >&2
    return 1
  fi
  chmod 600 "$out" 2>/dev/null || true
}

# Applies the request contract of the ChatGPT plan route to a Responses
# payload: store:false and stream:true on every request, no sampling
# parameters, and no plain function tools (the route accepts namespaced or
# additional_tools shapes only, so local tools use the text protocol there).
__lmline_chatgpt_apply_payload() {
  local payload=$1
  jq 'del(.temperature, .max_output_tokens, .max_tokens, .top_p, .user, .metadata, .tool_choice)
      | .stream = true
      | .store = false' "$payload" >"$payload.chatgpt" || return 1
  mv "$payload.chatgpt" "$payload"
}
