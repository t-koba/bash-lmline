#!/usr/bin/env bash

# ChatGPT subscription authentication for the lmline engine and the lmline
# CLI. This file is meant to be sourced by both entry scripts after
# config.bash and http.bash.
#
# The route is OpenAI's documented "Sign in with ChatGPT" token sharing flow
# for open-source and locally hosted apps:
#   https://developers.openai.com/siwc/token-sharing-open-source
# A ChatGPT plan access token is sent as a Bearer credential to the OpenAI
# Responses API. Subscription authentication and API-key authentication are
# separate billing paths: the engine never exchanges one for the other and
# never falls back from one to the other.
#
# The route owns three things, so that every caller of the route answers the
# same way: the client that holds the session, the host policy that keeps
# the plan token on an allowed host, and the token itself.

# True when the ChatGPT subscription path is selected.
__lmline_chatgpt_enabled() {
  [[ "${LMLINE_AUTH_MODE:-api-key}" == chatgpt ]]
}

# The ChatGPT client executable. Every path of the route resolves the client
# here, so an override means the same thing in the CLI and in the engine.
__lmline_chatgpt_client_path() {
  local client=${LMLINE_CHATGPT_CLIENT:-}
  [[ -n "$client" ]] || client=${script_dir:-.}/chatgpt-client.js
  printf '%s\n' "$client"
}

# The subscription token spends the user's ChatGPT plan. It must never
# travel to a third-party endpoint, and it must never travel in cleartext.
# The decision is made on the scheme and on the host of the URL: a base
# with embedded credentials is refused, because the credentials would go to
# a host that the text does not name, and only a loopback proxy may use
# cleartext, because its traffic stays on the machine. The reason is kept
# in __lmline_chatgpt_base_reason so the user can act on it.
__lmline_chatgpt_base_allowed() {
  local base=$1 scheme host
  __lmline_chatgpt_base_reason=
  [[ "$base" == *://* ]] || {
    __lmline_chatgpt_base_reason="a base URL without an explicit scheme is not allowed"
    return 1
  }
  scheme=${base%%://*}
  host=${base#*://}
  host=${host%%/*}
  [[ "$host" == *@* ]] && {
    __lmline_chatgpt_base_reason="a base URL with embedded credentials is not allowed"
    return 1
  }
  if [[ "$host" == \[*\]* ]]; then
    # A bracketed IPv6 literal, with an optional port.
    host=${host#\[}
    host=${host%%\]*}
  else
    host=${host%%:*}
  fi
  case "$host" in
    api.openai.com)
      case "$scheme" in
        https) return 0 ;;
        http)
          __lmline_chatgpt_base_reason="the OpenAI API needs https, because the plan token is a bearer credential"
          return 1
          ;;
        *)
          __lmline_chatgpt_base_reason="the scheme must be https or http"
          return 1
          ;;
      esac
      ;;
    127.0.0.1|localhost|::1)
      case "$scheme" in
        https|http) return 0 ;;
        *)
          __lmline_chatgpt_base_reason="the scheme must be https or http"
          return 1
          ;;
      esac
      ;;
    *)
      __lmline_chatgpt_base_reason="only the OpenAI API and a loopback proxy are allowed"
      return 1
      ;;
  esac
}

# Fails closed when the URL may not receive the ChatGPT subscription token.
# The policy belongs to the route, so every caller of the route gets the same
# answer and the same message.
__lmline_chatgpt_require_allowed_url() {
  local url=$1
  if __lmline_chatgpt_base_allowed "$url"; then
    return 0
  fi
  printf '%s: the ChatGPT subscription token is not sent to %s: %s\n' \
    "${__lmline_program_name:-lmline}" "$url" \
    "${__lmline_chatgpt_base_reason:-the host is not allowed}" >&2
  return 2
}

# Writes a fresh access token to $1 (mode 0600). Fails closed: a missing
# session, a failed refresh, or a missing Node runtime never falls back to
# an API key. The engine and the CLI use this one function, so the reason a
# sign-in failed is the same everywhere.
__lmline_chatgpt_access_token() {
  local out=$1 program=${__lmline_program_name:-lmline}
  local client err_file err_tmp= status=0 result=0
  client=$(__lmline_chatgpt_client_path)
  if ! command -v node >/dev/null 2>&1; then
    printf '%s: ChatGPT subscription auth requires Node.js; install Node.js or use API-key auth (LMLINE_AUTH_MODE=api-key)\n' "$program" >&2
    return 1
  fi
  if [[ ! -r "$client" ]]; then
    printf '%s: the ChatGPT auth client is missing; reinstall lmline\n' "$program" >&2
    return 1
  fi
  # The client names the reason a sign-in failed in its own stderr. It stays
  # in the work directory of the engine and in a temporary file elsewhere.
  err_file=${work_dir:+$work_dir/chatgpt-token.err}
  if [[ -z "$err_file" ]]; then
    err_tmp=$(mktemp "${TMPDIR:-/tmp}/lmline-chatgpt-token.XXXXXX") || return 1
    err_file=$err_tmp
  fi
  node "$client" token >"$out" 2>"$err_file" || status=$?
  if (( status != 0 )); then
    case "$status" in
      129|130|143)
        # The command was interrupted. The status says so, and the caller
        # passes it on, so an interrupt is not reported as a broken login.
        result=$status
        ;;
      *)
        printf '%s: ChatGPT subscription auth failed: %s\n' "$program" "$(sed -n '1p' "$err_file")" >&2
        result=1
        ;;
    esac
  elif [[ ! -s "$out" ]]; then
    printf '%s: ChatGPT subscription auth returned no access token\n' "$program" >&2
    result=1
  else
    chmod 600 "$out" 2>/dev/null || true
  fi
  [[ -z "$err_tmp" ]] || rm -f "$err_tmp"
  return "$result"
}

# Applies the request contract of the ChatGPT plan route to a Responses
# payload: store:false and stream:true on every request, no sampling
# parameters, and no plain function tools (the route accepts namespaced or
# additional_tools shapes only, and the local tools are off on that route).
__lmline_chatgpt_apply_payload() {
  local payload=$1
  jq 'del(.temperature, .max_output_tokens, .max_tokens, .top_p, .user, .metadata, .tool_choice)
      | .stream = true
      | .store = false' "$payload" >"$payload.chatgpt" || return 1
  mv "$payload.chatgpt" "$payload"
}
