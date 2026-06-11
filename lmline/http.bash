#!/usr/bin/env bash

# Shared HTTP helpers for lmline. This file is meant to be sourced.
# Owns curl header construction, simple GET requests, and provider error
# classification so the CLI, engine, and frontends share one implementation.

# Builds curl header arguments into the global array __LMLINE_HTTP_HEADERS.
# When an API key is present it is written into header_file (user-only
# permissions) and passed to curl as "-H @file" so the key never appears in
# the curl argv, which other local users can read via ps.
__lmline_http_build_headers() {
  local api_key_file=$1 auth_header=$2 auth_scheme=$3 header_file=$4 api_key=
  __LMLINE_HTTP_HEADERS=(-H 'Content-Type: application/json')
  if [[ -n "$api_key_file" && -r "$api_key_file" ]]; then
    IFS= read -r api_key <"$api_key_file" || true
  fi
  [[ -n "$api_key" ]] || return 0
  if [[ -n "$auth_scheme" ]]; then
    (umask 077; printf '%s: %s %s\n' "$auth_header" "$auth_scheme" "$api_key" >"$header_file")
  else
    (umask 077; printf '%s: %s\n' "$auth_header" "$api_key" >"$header_file")
  fi
  __LMLINE_HTTP_HEADERS+=(-H "@$header_file")
}

# GET with the headers prepared by __lmline_http_build_headers.
__lmline_http_get() {
  local url=$1 max_time=${2:-20}
  curl -fsS --max-time "$max_time" "${__LMLINE_HTTP_HEADERS[@]}" "$url"
}

# Maps raw engine/curl error text to a short actionable user message.
__lmline_engine_error_message() {
  local prefix=$1 error=$2
  case "$error" in
    *timed\ out*|*timeout*|*Operation\ timed\ out*|*"status 124"*)
      printf '%srequest timed out (%ss; set LMLINE_ENGINE_TIMEOUT to increase)\n' "$prefix" "${LMLINE_ENGINE_TIMEOUT:-60}"
      ;;
    lmline-engine:\ no\ valid\ candidate:*)
      printf '%s%s\n' "$prefix" "${error#lmline-engine: }"
      ;;
    *401*|*Unauthorized*|*invalid*api*key*|*authentication*)
      printf '%sauth failed; check: lmline config get\n' "$prefix"
      ;;
    *connection*refused*|*Could\ not\ resolve*|*"status 000"*|*"Failed to connect"*)
      printf '%sconnection failed; try: lmline doctor --check-api\n' "$prefix"
      ;;
    *)
      printf '%sengine failed: %s\n' "$prefix" "$error"
      ;;
  esac
}
