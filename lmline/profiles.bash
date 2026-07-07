#!/usr/bin/env bash

# Endpoint/model profile management for the lmline CLI. This file is meant to
# be sourced by the lmline entry script, which provides:
#   config_dir, endpoints_file, models_file   - profile storage paths
#   usage                                     - CLI usage printer
#   write_config_value, unset_config_value    - settings.bash writers
#   __lmline_mktemp                           - tracked temp file helper
# It also requires http.bash for __lmline_http_build_headers/__lmline_http_get.

profile_name_ok() {
  [[ -n "$1" && "$1" != *[[:space:]]* && "$1" != *[$'\001'-$'\037'$'\177']* ]]
}

profile_require_name() {
  profile_name_ok "$2" || {
    printf 'lmline: invalid %s name: %s\n' "$1" "$2" >&2
    printf 'lmline: names must not contain whitespace, tabs, or control characters\n' >&2
    exit 2
  }
}

profile_require_field() {
  local label=$1 value=$2
  [[ "$value" != *[$'\001'-$'\037'$'\177']* ]] || {
    printf 'lmline: invalid %s: control characters are not allowed\n' "$label" >&2
    exit 2
  }
}

profile_require_url() {
  local value=$1
  profile_require_field base_url "$value"
  case "$value" in
    http://*|https://*) ;;
    *) printf 'lmline: invalid base_url: expected http:// or https:// URL\n' >&2; exit 2 ;;
  esac
  [[ "$value" != *[[:space:]]* ]] || {
    printf 'lmline: invalid base_url: whitespace is not allowed\n' >&2
    exit 2
  }
}

profile_require_http_token() {
  local label=$1 value=$2
  [[ -z "$value" || "$value" =~ ^[A-Za-z0-9._~-]+$ ]] || {
    printf 'lmline: invalid %s: expected an HTTP token\n' "$label" >&2
    exit 2
  }
}

profile_require_decimal() {
  local label=$1 value=$2
  [[ -z "$value" || "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    printf 'lmline: invalid %s: expected a number\n' "$label" >&2
    exit 2
  }
}

profile_require_positive_int() {
  local label=$1 value=$2
  [[ -z "$value" || "$value" =~ ^[1-9][0-9]*$ ]] || {
    printf 'lmline: invalid %s: expected a positive integer\n' "$label" >&2
    exit 2
  }
}

profile_require_tool_mode() {
  local value=$1
  case "$value" in
    ''|auto|openai|text|none|off) ;;
    *) printf 'lmline: invalid tool_mode: expected auto, openai, text, or none\n' >&2; exit 2 ;;
  esac
}

profile_require_api_format() {
  local value=$1
  case "$value" in
    ''|chat|responses|messages) ;;
    *) printf 'lmline: invalid api_format: expected chat, responses, or messages\n' >&2; exit 2 ;;
  esac
}

profile_require_regex() {
  local label=$1 value=$2 status
  profile_require_field "$label" "$value"
  [[ -z "$value" ]] && return 0
  if printf '' | grep -E -q -- "$value" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  (( status != 2 )) || {
    printf 'lmline: invalid %s: expected an extended regular expression\n' "$label" >&2
    exit 2
  }
}

profile_require_jq_expr() {
  local label=$1 value=$2
  profile_require_field "$label" "$value"
  [[ -z "$value" ]] && return 0
  jq -n "def __lmline_items: $value; null" >/dev/null 2>&1 || {
    printf 'lmline: invalid %s: expected a jq expression\n' "$label" >&2
    exit 2
  }
}

profile_split_tsv() {
  local line=$1 sep=$'\034'
  shift
  line=${line//$'\t'/$sep}
  IFS=$sep read -r "$@" <<<"$line"
}

profile_find_line() {
  local file=$1 key1=$2 key2=${3-} line f1 f2
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    profile_split_tsv "$line" f1 f2 _
    [[ "$f1" == "$key1" ]] || continue
    [[ -z "$key2" || "$f2" == "$key2" ]] && { printf '%s\n' "$line"; return 0; }
  done <"$file"
  return 1
}

# Callers that run from the CLI dispatcher must already hold the config-dir
# lock (with_config_lock); this function does not lock on its own.
profile_upsert_line() {
  local file=$1 key_fields=$2 line=$3 tmp
  mkdir -p "${file%/*}"
  touch "$file"
  __lmline_mktemp tmp "${TMPDIR:-/tmp}/lmline-profile.XXXXXX"
  awk -F '\t' -v OFS='\t' -v key_fields="$key_fields" -v new_line="$line" '
    BEGIN { n=split(new_line, nf, "\t") }
    {
      keep=0
      for (i=1; i<=key_fields; i++) if ($i != nf[i]) keep=1
      if (keep) print
    }
    END { print new_line }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

profile_endpoint_add() {
  local name=${1-} base_url=${2-} auth_header= auth_scheme= api_key_file= temperature= max_tokens= tool_mode=
  local models_url= models_jq= models_prefix= models_include= models_exclude=
  local line old_header old_scheme old_temp old_tokens old_tool old_models_url old_models_jq old_models_prefix old_models_include old_models_exclude
  local header_set=0 scheme_set=0 models_url_set=0 models_jq_set=0 models_prefix_set=0 models_include_set=0 models_exclude_set=0
  [[ -n "$name" && -n "$base_url" ]] || { usage; exit 2; }
  profile_require_name endpoint "$name"
  profile_require_url "$base_url"
  shift 2
  while (($#)); do
    case "$1" in
      --auth-header) auth_header=${2-}; header_set=1; shift 2 ;;
      --auth-scheme) auth_scheme=${2-}; scheme_set=1; shift 2 ;;
      --temperature) temperature=${2-}; shift 2 ;;
      --max-tokens) max_tokens=${2-}; shift 2 ;;
      --tool-mode) tool_mode=${2-}; shift 2 ;;
      --models-url) models_url=${2-}; models_url_set=1; shift 2 ;;
      --models-jq) models_jq=${2-}; models_jq_set=1; shift 2 ;;
      --models-prefix) models_prefix=${2-}; models_prefix_set=1; shift 2 ;;
      --models-include) models_include=${2-}; models_include_set=1; shift 2 ;;
      --models-exclude) models_exclude=${2-}; models_exclude_set=1; shift 2 ;;
      *) printf 'lmline: unknown endpoint option: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  if line=$(profile_find_line "$endpoints_file" "$name"); then
    profile_split_tsv "$line" _ _ old_header old_scheme api_key_file old_temp old_tokens old_tool old_models_url old_models_jq old_models_prefix old_models_include old_models_exclude
    (( header_set == 0 )) && auth_header=$old_header
    (( scheme_set == 0 )) && auth_scheme=$old_scheme
    [[ -z "$temperature" ]] && temperature=$old_temp
    [[ -z "$max_tokens" ]] && max_tokens=$old_tokens
    [[ -z "$tool_mode" ]] && tool_mode=$old_tool
    (( models_url_set == 0 )) && models_url=$old_models_url
    (( models_jq_set == 0 )) && models_jq=$old_models_jq
    (( models_prefix_set == 0 )) && models_prefix=$old_models_prefix
    (( models_include_set == 0 )) && models_include=$old_models_include
    (( models_exclude_set == 0 )) && models_exclude=$old_models_exclude
  else
    (( header_set == 0 )) && auth_header=Authorization
    (( scheme_set == 0 )) && auth_scheme=Bearer
  fi
  profile_require_http_token auth_header "$auth_header"
  profile_require_http_token auth_scheme "$auth_scheme"
  profile_require_decimal temperature "$temperature"
  profile_require_positive_int max_tokens "$max_tokens"
  profile_require_tool_mode "$tool_mode"
  [[ -z "$models_url" ]] || profile_require_url "$models_url"
  profile_require_jq_expr models_jq "$models_jq"
  profile_require_field models_prefix "$models_prefix"
  profile_require_regex models_include "$models_include"
  profile_require_regex models_exclude "$models_exclude"
  profile_upsert_line "$endpoints_file" 1 "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "$base_url" "$auth_header" "$auth_scheme" "$api_key_file" "$temperature" "$max_tokens" "$tool_mode" "$models_url" "$models_jq" "$models_prefix" "$models_include" "$models_exclude")"
}

profile_endpoint_list() {
  [[ -f "$endpoints_file" ]] || return 0
  awk -F '\t' 'NF && $1 !~ /^#/ { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,($5 ? "configured" : ""),$6,$7,$8,$9,$10,$11,$12,$13 }' "$endpoints_file"
}

profile_endpoint_set_secret() {
  local name=${1-} value=${2-} line base auth_header auth_scheme _ old_temp old_tokens old_tool old_models_url old_models_jq old_models_prefix old_models_include old_models_exclude secret_file safe_name
  [[ -n "$name" ]] || { usage; exit 2; }
  profile_require_name endpoint "$name"
  line=$(profile_find_line "$endpoints_file" "$name") || { printf 'lmline: unknown endpoint: %s\n' "$name" >&2; exit 2; }
  profile_split_tsv "$line" _ base auth_header auth_scheme _ old_temp old_tokens old_tool old_models_url old_models_jq old_models_prefix old_models_include old_models_exclude
  if [[ -n "$value" ]]; then
    printf 'lmline: warning: secrets passed as command arguments can leak via shell history and ps; prefer the prompt: lmline endpoint set-secret %s\n' "$name" >&2
  fi
  if [[ -z "$value" ]]; then
    printf 'endpoint %s API key: ' "$name" >&2
    stty -echo 2>/dev/null || true
    IFS= read -r value
    stty echo 2>/dev/null || true
    printf '\n' >&2
  fi
  [[ -n "$value" ]] || { printf 'lmline: empty secret not stored\n' >&2; exit 2; }
  mkdir -p "$config_dir/secrets"
  chmod 700 "$config_dir/secrets" 2>/dev/null || true
  safe_name=${name//\//_}
  secret_file=$config_dir/secrets/endpoint-${safe_name}-api-key.secret
  umask 077
  printf '%s' "$value" >"$secret_file"
  chmod 600 "$secret_file"
  profile_upsert_line "$endpoints_file" 1 "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "$base" "$auth_header" "$auth_scheme" "$secret_file" "$old_temp" "$old_tokens" "$old_tool" "$old_models_url" "$old_models_jq" "$old_models_prefix" "$old_models_include" "$old_models_exclude")"
}

profile_endpoint_remove() {
  local name=${1-} keep_secret=0 line api_key_file tmp
  [[ -n "$name" ]] || { usage; exit 2; }
  shift
  while (($#)); do
    case "$1" in
      --keep-secret) keep_secret=1; shift ;;
      *) printf 'lmline: unknown endpoint option: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  profile_require_name endpoint "$name"
  line=$(profile_find_line "$endpoints_file" "$name") || { printf 'lmline: unknown endpoint: %s\n' "$name" >&2; exit 2; }
  profile_split_tsv "$line" _ _ _ _ api_key_file _
  __lmline_mktemp tmp "${TMPDIR:-/tmp}/lmline-profile.XXXXXX"
  awk -F '\t' -v name="$name" '$1 != name' "$endpoints_file" >"$tmp"
  mv "$tmp" "$endpoints_file"
  chmod 600 "$endpoints_file" 2>/dev/null || true
  if [[ -f "$models_file" ]]; then
    __lmline_mktemp tmp "${TMPDIR:-/tmp}/lmline-profile.XXXXXX"
    awk -F '\t' -v name="$name" '$1 != name' "$models_file" >"$tmp"
    mv "$tmp" "$models_file"
    chmod 600 "$models_file" 2>/dev/null || true
  fi
  if (( keep_secret == 0 )) && [[ -n "$api_key_file" ]]; then
    case "$api_key_file" in
      "$config_dir"/secrets/*) rm -f "$api_key_file" ;;
      *) printf 'lmline: secret file outside %s/secrets was kept: %s\n' "$config_dir" "$api_key_file" >&2 ;;
    esac
  fi
  if [[ "${LMLINE_ACTIVE_ENDPOINT:-}" == "$name" ]]; then
    printf 'lmline: removed endpoint %s was active; run lmline use ENDPOINT [MODEL] to select another\n' "$name" >&2
  fi
}

profile_model_remove() {
  local endpoint=${1-} model=${2-} tmp
  [[ -n "$endpoint" && -n "$model" ]] || { usage; exit 2; }
  profile_require_name endpoint "$endpoint"
  profile_require_name model "$model"
  profile_find_line "$models_file" "$endpoint" "$model" >/dev/null || { printf 'lmline: unknown model for %s: %s\n' "$endpoint" "$model" >&2; exit 2; }
  __lmline_mktemp tmp "${TMPDIR:-/tmp}/lmline-profile.XXXXXX"
  awk -F '\t' -v e="$endpoint" -v m="$model" '!($1 == e && $2 == m)' "$models_file" >"$tmp"
  mv "$tmp" "$models_file"
  chmod 600 "$models_file" 2>/dev/null || true
}

profile_model_add() {
  local endpoint=${1-} model=${2-} temperature= max_tokens= tool_mode= api_format=
  [[ -n "$endpoint" && -n "$model" ]] || { usage; exit 2; }
  profile_require_name endpoint "$endpoint"
  profile_require_name model "$model"
  profile_find_line "$endpoints_file" "$endpoint" >/dev/null || { printf 'lmline: unknown endpoint: %s\n' "$endpoint" >&2; exit 2; }
  shift 2
  while (($#)); do
    case "$1" in
      --temperature) temperature=${2-}; shift 2 ;;
      --max-tokens) max_tokens=${2-}; shift 2 ;;
      --tool-mode) tool_mode=${2-}; shift 2 ;;
      --api-format) api_format=${2-}; shift 2 ;;
      *) printf 'lmline: unknown model option: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  profile_require_decimal temperature "$temperature"
  profile_require_positive_int max_tokens "$max_tokens"
  profile_require_tool_mode "$tool_mode"
  profile_require_api_format "$api_format"
  profile_upsert_line "$models_file" 2 "$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$endpoint" "$model" "$temperature" "$max_tokens" "$tool_mode" "$api_format")"
}

profile_model_list() {
  local endpoint=${1-}
  [[ -f "$models_file" ]] || return 0
  awk -F '\t' -v endpoint="$endpoint" 'NF && $1 !~ /^#/ && (endpoint == "" || $1 == endpoint) { printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6 }' "$models_file"
}

profile_default_model_catalog_jq() {
  printf '(.data[]?), (.result[]?), (.models[]?), (try .result.models[] catch empty), (try .result.data[] catch empty)\n'
}

profile_model_catalog_url() {
  local base=${1%/} override=${2-}
  [[ -n "$override" ]] && printf '%s\n' "$override" || printf '%s/models\n' "$base"
}

profile_model_candidate_format() {
  local signal
  signal=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
  case "$signal" in
    *chat/completions*|*chat\ completions*|*chat_completions*) printf 'chat\n'; return 0 ;;
    */responses*|*responses*) printf 'responses\n'; return 0 ;;
    */messages*|*messages*) printf 'messages\n'; return 0 ;;
    *text\ generation*|*text-generation*|*large\ language*|*llm*) printf 'chat\n'; return 0 ;;
  esac
  case "$signal" in
    *image\ generation*|*image-generation*|*embedding*|*rerank*|*speech*|*audio*|*moderation*) return 1 ;;
  esac
  printf 'chat\n'
}

profile_extract_model_candidates() {
  local models_jq=$1 models_prefix=${2-} models_include=${3-} models_exclude=${4-}
  local parsed id signal
  parsed=$(jq -r "
    def __lmline_items: $models_jq;
    def __lmline_signal:
      if type == \"object\" then
        ([del(.id, .model, .name) | paths(scalars) as \$p | ((\$p | map(tostring) | join(\".\")) + \"=\" + (getpath(\$p) | tostring))] | join(\" \"))
      else
        tostring
      end;
    __lmline_items
    | if type == \"object\" then
        [((.id // .model // .name // \"\") | tostring), __lmline_signal] | @tsv
      elif type == \"string\" then
        [., .] | @tsv
      else
        empty
      end
  ") || return 1
  while IFS=$'\t' read -r id signal; do
    [[ -n "$id" ]] || continue
    [[ -z "$models_prefix" || "$id" == "$models_prefix"* ]] || continue
    if [[ -n "$models_include" ]]; then
      [[ "$id" =~ $models_include || "$signal" =~ $models_include ]] || continue
    fi
    if [[ -n "$models_exclude" ]]; then
      [[ ! "$id" =~ $models_exclude && ! "$signal" =~ $models_exclude ]] || continue
    fi
    printf '%s\t%s\n' "$id" "$signal"
  done <<<"$parsed"
}

profile_extract_model_records() {
  local models_jq=$1 models_prefix=${2-} models_include=${3-} models_exclude=${4-}
  local id signal api_format
  while IFS=$'\t' read -r id signal; do
    [[ -n "$id" ]] || continue
    api_format=$(profile_model_candidate_format "$signal") || continue
    printf '%s\t%s\n' "$id" "$api_format"
  done < <(profile_extract_model_candidates "$models_jq" "$models_prefix" "$models_include" "$models_exclude")
}

profile_extract_model_ids() {
  local models_jq=$1 models_prefix=${2-} models_include=${3-} models_exclude=${4-}
  profile_extract_model_records "$models_jq" "$models_prefix" "$models_include" "$models_exclude" | awk -F '\t' '{ print $1 }'
}

profile_model_refresh() {
  local endpoint=${1-} line base auth_header auth_scheme api_key_file body tmp records_file records id api_format header_tmp models_url models_jq models_prefix models_include models_exclude catalog_url catalog_jq expected merged
  [[ -n "$endpoint" ]] || { usage; exit 2; }
  profile_require_name endpoint "$endpoint"
  line=$(profile_find_line "$endpoints_file" "$endpoint") || { printf 'lmline: unknown endpoint: %s\n' "$endpoint" >&2; exit 2; }
  profile_split_tsv "$line" _ base auth_header auth_scheme api_key_file _ _ _ models_url models_jq models_prefix models_include models_exclude
  profile_require_jq_expr models_jq "$models_jq"
  [[ -z "$api_key_file" || -r "$api_key_file" ]] || { printf 'lmline: endpoint secret file not readable: %s\n' "$api_key_file" >&2; exit 1; }
  catalog_url=$(profile_model_catalog_url "$base" "$models_url")
  catalog_jq=${models_jq:-$(profile_default_model_catalog_jq)}
  __lmline_mktemp header_tmp "${TMPDIR:-/tmp}/lmline-hdr.XXXXXX"
  __lmline_http_build_headers "$api_key_file" "$auth_header" "$auth_scheme" "$header_tmp"
  body=$(__lmline_http_get "$catalog_url" 20) || {
    printf 'lmline: model refresh failed for endpoint: %s\n' "$endpoint" >&2
    exit 1
  }
  records=$(profile_extract_model_records "$catalog_jq" "$models_prefix" "$models_include" "$models_exclude" <<<"$body") || {
    printf 'lmline: model refresh response did not contain model IDs\n' >&2
    exit 1
  }
  [[ -n "$records" ]] || { printf 'lmline: model refresh returned no models\n' >&2; exit 1; }
  mkdir -p "$config_dir"
  touch "$models_file"
  __lmline_mktemp records_file "${TMPDIR:-/tmp}/lmline-model-records.XXXXXX"
  while IFS=$'\t' read -r id api_format; do
    [[ -n "$id" ]] || continue
    profile_require_name model "$id"
    printf '%s\t%s\n' "$id" "$api_format"
  done <<<"$records" >"$records_file"
  __lmline_mktemp tmp "${TMPDIR:-/tmp}/lmline-models.XXXXXX"
  awk -F '\t' -v OFS='\t' -v endpoint="$endpoint" '
    NR == FNR {
      if ($1 == "") next
      order[++n] = $1
      new_format[$1] = $2
      refresh[$1] = 1
      next
    }
    $1 == endpoint && ($2 in refresh) {
      old_temp[$2] = $3
      old_tokens[$2] = $4
      old_tool[$2] = $5
      next
    }
    { print }
    END {
      for (i = 1; i <= n; i++) {
        id = order[i]
        print endpoint, id, old_temp[id], old_tokens[id], old_tool[id], new_format[id]
      }
    }
  ' "$records_file" "$models_file" >"$tmp" || {
    printf 'lmline: model refresh merge failed; keeping existing models\n' >&2
    exit 1
  }
  expected=$(wc -l <"$records_file")
  merged=$(awk -F '\t' -v endpoint="$endpoint" '$1 == endpoint { c++ } END { print c + 0 }' "$tmp")
  (( merged >= expected )) || {
    printf 'lmline: model refresh merge dropped records; keeping existing models\n' >&2
    exit 1
  }
  mv "$tmp" "$models_file"
  chmod 600 "$models_file" 2>/dev/null || true
}

profile_use() {
  local endpoint=${1-} model=${2-} endpoint_line model_line _ base auth_header auth_scheme api_key_file e_temp e_tokens e_tool e_models_url e_models_jq e_models_prefix e_models_include e_models_exclude m_temp m_tokens m_tool m_api_format
  local -a available
  [[ -n "$endpoint" ]] || { usage; exit 2; }
  endpoint_line=$(profile_find_line "$endpoints_file" "$endpoint") || { printf 'lmline: unknown endpoint: %s\n' "$endpoint" >&2; exit 2; }
  if [[ -z "$model" ]]; then
    available=()
    while IFS= read -r model_line; do
      [[ -n "$model_line" ]] && available+=("$model_line")
    done < <(profile_model_list "$endpoint" | awk -F '\t' '{ print $2 }')
    if ((${#available[@]} == 0)); then
      printf 'lmline: no models registered for %s; run: lmline model refresh %s (or lmline model add %s MODEL)\n' "$endpoint" "$endpoint" "$endpoint" >&2
      exit 2
    elif ((${#available[@]} > 1)); then
      printf 'lmline: multiple models registered for %s; pick one:\n' "$endpoint" >&2
      for model_line in "${available[@]}"; do
        printf '  lmline use %s %s\n' "$endpoint" "$model_line" >&2
      done
      exit 2
    fi
    model=${available[0]}
  fi
  model_line=$(profile_find_line "$models_file" "$endpoint" "$model") || { printf 'lmline: unknown model for %s: %s\n' "$endpoint" "$model" >&2; exit 2; }
  profile_split_tsv "$endpoint_line" _ base auth_header auth_scheme api_key_file e_temp e_tokens e_tool e_models_url e_models_jq e_models_prefix e_models_include e_models_exclude
  profile_split_tsv "$model_line" _ _ m_temp m_tokens m_tool m_api_format
  [[ -z "$api_key_file" || -r "$api_key_file" ]] || { printf 'lmline: endpoint secret file not readable: %s\n' "$api_key_file" >&2; exit 1; }
  write_config_value LMLINE_BASE_URL "$base"
  write_config_value LMLINE_MODEL "$model"
  write_config_value LMLINE_AUTH_HEADER "$auth_header"
  write_config_value LMLINE_AUTH_SCHEME "$auth_scheme"
  [[ -n "$api_key_file" ]] && write_config_value LMLINE_API_KEY_FILE "$api_key_file" || unset_config_value LMLINE_API_KEY_FILE
  [[ -n "${m_temp:-$e_temp}" ]] && write_config_value LMLINE_TEMPERATURE "${m_temp:-$e_temp}" || unset_config_value LMLINE_TEMPERATURE
  [[ -n "${m_tokens:-$e_tokens}" ]] && write_config_value LMLINE_MAX_TOKENS "${m_tokens:-$e_tokens}" || unset_config_value LMLINE_MAX_TOKENS
  [[ -n "${m_tool:-$e_tool}" ]] && write_config_value LMLINE_TOOL_MODE "${m_tool:-$e_tool}" || unset_config_value LMLINE_TOOL_MODE
  [[ -n "$m_api_format" ]] && write_config_value LMLINE_API_FORMAT "$m_api_format" || unset_config_value LMLINE_API_FORMAT
  [[ -n "$e_models_url" ]] && write_config_value LMLINE_MODELS_URL "$e_models_url" || unset_config_value LMLINE_MODELS_URL
  [[ -n "$e_models_jq" ]] && write_config_value LMLINE_MODELS_JQ "$e_models_jq" || unset_config_value LMLINE_MODELS_JQ
  [[ -n "$e_models_prefix" ]] && write_config_value LMLINE_MODELS_PREFIX "$e_models_prefix" || unset_config_value LMLINE_MODELS_PREFIX
  [[ -n "$e_models_include" ]] && write_config_value LMLINE_MODELS_INCLUDE "$e_models_include" || unset_config_value LMLINE_MODELS_INCLUDE
  [[ -n "$e_models_exclude" ]] && write_config_value LMLINE_MODELS_EXCLUDE "$e_models_exclude" || unset_config_value LMLINE_MODELS_EXCLUDE
  write_config_value LMLINE_ACTIVE_ENDPOINT "$endpoint"
}

profile_current() {
  local line endpoint model status=unmatched base model_line e
  printf 'base_url=%s\nmodel=%s\n' "${LMLINE_BASE_URL:-}" "${LMLINE_MODEL:-}"
  if [[ -n "${LMLINE_ACTIVE_ENDPOINT:-}" && -n "${LMLINE_MODEL:-}" ]] &&
    profile_find_line "$models_file" "$LMLINE_ACTIVE_ENDPOINT" "$LMLINE_MODEL" >/dev/null 2>&1; then
    printf 'endpoint=%s\nprofile_status=matched\n' "$LMLINE_ACTIVE_ENDPOINT"
    return 0
  fi
  [[ -f "$endpoints_file" && -f "$models_file" ]] || { printf 'profile_status=unmatched\n'; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    profile_split_tsv "$line" endpoint base _
    [[ "$base" == "${LMLINE_BASE_URL:-}" ]] || continue
    while IFS= read -r model_line || [[ -n "$model_line" ]]; do
      profile_split_tsv "$model_line" e model _
      if [[ "$e" == "$endpoint" && "$model" == "${LMLINE_MODEL:-}" ]]; then
        printf 'endpoint=%s\nprofile_status=matched\n' "$endpoint"
        return 0
      fi
    done <"$models_file"
  done <"$endpoints_file"
  printf 'profile_status=%s\n' "$status"
}
