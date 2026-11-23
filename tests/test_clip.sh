#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: clipboard provider selection and CLI handling remain correct without exposing secrets.

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-clip-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT

LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model

clip_test_dir="$cfg_tmp/clip"
mkdir -p "$clip_test_dir/bin" "$clip_test_dir/config"
cat >"$clip_test_dir/bin/fakeclip" <<'EOF'
#!/usr/bin/env bash
# Secret-shaped fixtures are assembled from parts at runtime so this
# file never contains a contiguous provider-token literal.
gh_a='gh'
pem_a='BEGIN RSA'
st_sk='sk'
st_rk='rk'
st_pk='pk'
st_live='_live_'
st_test='_test_'
pem_b='PRIVATE KEY'
printf '%s\n' 'API_KEY=secret-value'
printf '%s\n' 'API_KEY = spaced-secret-value'
printf 'aws %s%sIOSFODNN7EXAMPLE\n' 'AK' 'IA'
printf 'slack %s%s123456789012-123456789012-abcdefghijklmnopqrstuvwx\n' 'xo' 'xb-'
printf '%s\n' "-----$pem_a $pem_b-----"
printf '%s\n' 'FAKE-KEY-BODY-FOR-REDACT-TEST-0123456789'
printf '%s\n' "-----END RSA $pem_b-----"
printf 'token %s%sabcdefghijklmnopqrstuvwxyz0123456789ABCD\n' "$gh_a" 'o_'
printf 'token %s%sabcDEF123_tail_with_underscore_xyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_01\n' 'github' '_pat_'
printf 'stripe %s%sStripeBodySkLive0123456789\n' "$st_sk" "$st_live"
printf 'stripe %s%sStripeBodySkTest0123456789\n' "$st_sk" "$st_test"
printf 'stripe %s%sStripeBodyRkLive0123456789\n' "$st_rk" "$st_live"
printf 'stripe %s%sStripeBodyRkTest0123456789\n' "$st_rk" "$st_test"
printf 'stripe %s%sStripePublicBody0123456789\n' "$st_pk" "$st_live"
printf 'token %s%s12345_eyJhbGciOiJIUzI1NiJ9_stateless_jwt_body_0123456789\n' "$gh_a" 's_'
printf 'token %s%sabcdefghijklmnopqrstuvwxyz0123\n' 'glp' 'at-'
printf 'key %s%sSyD12345678901234567890123456789012\n' 'AI' 'za'
printf '%s\n' 'Authorization: Bearer "quoted bearer token value"'
printf '%s\n' "Authorization: Bearer 'single quoted bearer token'"
printf '%s\n' 'Authorization: Bearer "quote\"insideTail1234567890"'
printf '%s\n' 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz'
printf '%s\n' 'authorization: bearer lowercaseBearerTokenValue1234567890'
printf '%s\n' 'api-key: hyphenatedKeyValue1234567890'
printf '%s\n' 'TOKEN=*starredSecretValue*'
printf '%s\n' 'Authorization: Bearer @secretAtValue123'
printf '%s\n' 'Authorization: Basic basicCredentialValue1234567890'
printf '%s\n' 'Authorization: Digest username="user", nonce="digestNonceValue123456"'
printf '%s\n' 'Authorization: Token tokenSchemeValue1234567890'
printf '%s\n' '{"Authorization": "Basic jsonBasicValue1234567890", "note": "keepme2"}'
printf "%s\n" "Authorization: 'Basic quotedBasicValue1234567890'"
printf '%s\n' 'Authorization: "Basic unterminatedBasicValue1234567890'
printf '%s\n' 'Authorization: Bearer firstHeaderToken123 Authorization: Basic secondHeaderCred123'
printf '%s\n' 'curl -H "Authorization: Bearer curlToken123" -H "Authorization: Basic curlCred123" https://x'
printf '%s\n' 'curl -H "Authorization: schemeLessQuoted123" https://x'
printf '%s\n' "curl -H 'Authorization: schemeLessQuoted124' https://x"
printf '%s\n' "curl -H 'Authorization: Basic schemedQuoted125' https://x"
printf '%s\n' 'curl -H "Authorization: @@oddAtDouble999" -H "X: tailDouble" https://x'
printf '%s\n' "curl -H 'Authorization: @@oddAtSingle999' -H 'X: tailSingle' https://x"
printf '%s\n' 'curl -H "Authorization: @" -H "X: keepAtDouble" https://x'
printf '%s\n' "curl -H 'Authorization: @' -H 'X: keepAtSingle' https://x"
printf '%s\n' 'Authorization: Bearer abc123" more_secret456'
printf '%s\n' 'Authorization: Basic p@ss" w0rd123SECRET'
printf '%s\n' '{"api_key": "keyPlusHeaderValue123", "Authorization": "Basic keyPlusHeaderCred123"}'
printf '%s\n' 'TOKEN=tokenPlusHeaderValue123 Authorization: Basic tokenPlusHeaderCred123'
printf '%s\n' 'Authorization: bareSchemeLessValue1234567890'
printf '%s\n' 'Authorization: "quotedSchemeLessValue123"'
printf '%s\n' "Authorization: 'singleSchemeLessValue123'"
printf '%s\n' 'authorization: bareLowerSchemeLess123'
printf '%s\n' 'Authorization: Bearer "tok1" Authorization: bareCred2'
printf '%s\n' '{"api_key": "k1", "Authorization": "schemeLessJsonCred123"}'
printf '%s\n' 'Authorization: @bareAtValue123'
printf '%s\n' 'Authorization: "@quotedAtValue123"'
printf '%s\n' 'Authorization: "unterminatedSchemeLess123'
printf '%s\n' 'Authorization: Bearer @@oddAtValue123'
printf '%s\n' 'Authorization: Bearer @'
printf '%s\n' 'Authorization: @'
printf '%s\n' 'Authorization: Bearer @s3cr3tToken99 extra words'
printf '%s\n' 'Authorization: Basic @acct99 # comment'
printf '%s\n' 'Authorization: Bearer @tok https://example.com'
printf '%s\n' 'Authorization: Bearer @tok Authorization: Basic two999'
printf '%s\n' 'Authorization: "u@host99"'
printf '%s\n' "Authorization: 'u@host99'"
printf '%s\n' '{"Authorization": "u@host99"}'
printf '%s\n' 'Authorization: "@foo bar baz'
printf '%s\n' "Authorization: '@foo bar baz"
printf '%s\n' 'Authorization: "@user@host with spaces tail'
printf '%s\n' "Authorization: '@user@host with spaces tail"
printf '%s\n' 'api-key: keyVal123 Authorization: "u@host456"'
printf '%s\n' 'token=@tokenAtValue123'
printf '%s\n' 'api-key: @keyAtValue123'
printf '%s\n' 'Authorization: Bearer "unterminated_secret_12345'
printf '%s\n' "TOKEN='unterminated_secret_12345"
printf '%s\n' 'Authorization: "Bearer inner_unterminated_12345'
printf '%s\n' 'token: plainTokenValue1234567890'
printf '%s\n' '{"api_key": "json_secret_value", "token": "json_token_value"}'
printf '%s\n' '{"password": "value with spaces", "Authorization": "Bearer json_bearer_value"}'
printf '%s\n' 'Authorization: Bearer quote"BearerSuffix1234567890'
printf '%s\n' '{"note": "keepme", "Authorization": "Bearer quote\"BearerSuffix1234567890"}'
printf "%s\n" "Authorization: 'Bearer quote\\'BearerSuffixSingle1234567890'"
printf "%s\n" "TOKEN='quotedTokenSecret123'"
printf '%s\n' 'MY_TOKEN=abc"defGHI'
printf '%s\n' "DB_PASSWORD=p@ss'w0rd"
printf '%s\n' '123MY_TOKEN=SECRETVAL'
printf '%s\n' '"123MY_TOKEN": "SECRETVAL"'
printf '%s\n' '-MY_TOKEN=MARKER'
printf '%s\n' '{"2fa_secret": "SUPERSECRET123", "123api_token": "ANOTHERSECRET456"}'
printf '%s\n' 'error: failed'
printf '%s\n' 'Authorization: Bearer "backslashBearerOdd901\'
printf '%s\n' 'Authorization: "backslashSchemeLessOdd902\'
printf '%s\n' "Authorization: 'backslashSingleOdd903\\"
printf '%s\n' "MY_TOKEN='backslashKeyOdd904\\"
printf '%s\n' 'Authorization: "u@hostBackslashOdd905\"'
printf '%s\n' 'Authorization: Bearer "backslashBearerEven906\\"'
printf '%s\n' 'Authorization: "backslashSchemeLessEven907\\"'
printf '%s\n' 'curl -d "{\"Authorization\":\"Bearer escapedJsonAuth9001\"}" https://x'
printf '%s\n' 'Authorization\":\"Bearer escapedUnterminated9002'
printf '%s\n' 'MY_TOKEN\":\"escapedKey9003'
printf '%s\n' 'curl -d "{\"api_key\":\"escapedApiKey9004\"}" https://x'
printf '%s\n' 'curl -d "{\\\"Authorization\\\":\\\"Bearer doubleEscapedAuth9101\\\"}" https://x'
printf '%s\n' 'MY_TOKEN\\\":\\\"doubleEscapedKey9102'
EOF
chmod +x "$clip_test_dir/bin/fakeclip"
printf 'fake\t%s\n' "$clip_test_dir/bin/fakeclip" >"$clip_test_dir/config/clipboard_providers.tsv"
cat >"$clip_test_dir/engine" <<'EOF'
#!/usr/bin/env bash
mode=
line_file=
while (($#)); do
  case "$1" in
    --mode) mode=$2; shift 2 ;;
    --line-file) line_file=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$mode" == clip ]] || exit 10
grep -Fq 'API_KEY=***REDACTED***' "$line_file" || exit 11
grep -Fq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 12
grep -Fq 'Authorization: Bearer "***REDACTED***"' "$line_file" || exit 74
grep -Fq "Authorization: Bearer '***REDACTED***'" "$line_file" || exit 75
grep -Fq 'quoted bearer token value' "$line_file" && exit 76
grep -Fq 'single quoted bearer token' "$line_file" && exit 77
grep -Fq 'insideTail1234567890' "$line_file" && exit 78
grep -Fq 'authorization: bearer ***REDACTED***' "$line_file" || exit 39
grep -Fq 'lowercaseBearerTokenValue' "$line_file" && exit 40
grep -Fq 'api-key: ***REDACTED***' "$line_file" || exit 41
grep -Fq 'hyphenatedKeyValue' "$line_file" && exit 42
grep -Fq 'token: ***REDACTED***' "$line_file" || exit 43
grep -Fq 'starredSecretValue' "$line_file" && exit 79
grep -Fq 'secretAtValue123' "$line_file" && exit 80
grep -Fq 'Authorization: Basic ***REDACTED***' "$line_file" || exit 85
grep -Fq 'basicCredentialValue' "$line_file" && exit 86
grep -Fq 'Authorization: Digest ***REDACTED***' "$line_file" || exit 87
grep -Fq 'digestNonceValue' "$line_file" && exit 88
grep -Fq 'Authorization: Token ***REDACTED***' "$line_file" || exit 89
grep -Fq 'tokenSchemeValue' "$line_file" && exit 90
grep -Fq 'jsonBasicValue' "$line_file" && exit 93
grep -Fq 'quotedBasicValue' "$line_file" && exit 94
grep -Fq 'unterminatedBasicValue' "$line_file" && exit 95
grep -Fq 'firstHeaderToken123' "$line_file" && exit 96
grep -Fq 'secondHeaderCred123' "$line_file" && exit 97
grep -Fq 'curlToken123' "$line_file" && exit 98
grep -Fq 'curlCred123' "$line_file" && exit 99
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "Authorization: Basic ***REDACTED***" https://x' "$line_file" || exit 126
grep -Fq 'schemeLessQuoted123' "$line_file" && exit 131
grep -Fq 'schemeLessQuoted124' "$line_file" && exit 132
grep -Fq 'schemedQuoted125' "$line_file" && exit 133
grep -Fxq 'curl -H "Authorization: ***REDACTED***" https://x' "$line_file" || exit 134
grep -Fxq "curl -H 'Authorization: ***REDACTED***' https://x" "$line_file" || exit 135
grep -Fxq "curl -H 'Authorization: Basic ***REDACTED***' https://x" "$line_file" || exit 136
grep -Fq 'oddAtDouble999' "$line_file" && exit 137
grep -Fq 'oddAtSingle999' "$line_file" && exit 138
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: tailDouble" https://x' "$line_file" || exit 139
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: tailSingle' https://x" "$line_file" || exit 140
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keepAtDouble" https://x' "$line_file" || exit 141
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: keepAtSingle' https://x" "$line_file" || exit 142
grep -Fq 'more_secret456' "$line_file" && exit 129
grep -Fq 'w0rd123SECRET' "$line_file" && exit 130
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 127
grep -Fxq 'Authorization: ***REDACTED***' "$line_file" || exit 128
grep -Fq 'keyPlusHeaderValue123' "$line_file" && exit 100
grep -Fq 'keyPlusHeaderCred123' "$line_file" && exit 101
grep -Fq 'tokenPlusHeaderValue123' "$line_file" && exit 102
grep -Fq 'tokenPlusHeaderCred123' "$line_file" && exit 103
grep -Fq 'Authorization: ***REDACTED***' "$line_file" || exit 104
grep -Fq 'Authorization: "***REDACTED***"' "$line_file" || exit 105
grep -Fq "Authorization: '***REDACTED***'" "$line_file" || exit 106
grep -Fq 'bareSchemeLessValue' "$line_file" && exit 107
grep -Fq 'quotedSchemeLessValue' "$line_file" && exit 108
grep -Fq 'singleSchemeLessValue' "$line_file" && exit 109
grep -Fq 'bareLowerSchemeLess' "$line_file" && exit 110
grep -Fq 'bareCred2' "$line_file" && exit 111
grep -Fq 'schemeLessJsonCred' "$line_file" && exit 112
grep -Fq 'bareAtValue' "$line_file" && exit 113
grep -Fq 'quotedAtValue' "$line_file" && exit 114
grep -Fq 'unterminatedSchemeLess' "$line_file" && exit 115
grep -Fq 'oddAtValue' "$line_file" && exit 116
grep -Fq 's3cr3tToken99' "$line_file" && exit 117
grep -Fq 'acct99' "$line_file" && exit 118
grep -Fq 'example.com' "$line_file" && exit 119
grep -Fq 'two999' "$line_file" && exit 120
grep -Fq 'u@host99' "$line_file" && exit 121
grep -Fq 'backslashBearerOdd901' "$line_file" && exit 150
grep -Fq 'backslashSchemeLessOdd902' "$line_file" && exit 151
grep -Fq 'backslashSingleOdd903' "$line_file" && exit 152
grep -Fq 'backslashKeyOdd904' "$line_file" && exit 153
grep -Fq 'hostBackslashOdd905' "$line_file" && exit 154
grep -Fxq 'Authorization: Bearer "***REDACTED***' "$line_file" || exit 155
grep -Fxq 'Authorization: "***REDACTED***' "$line_file" || exit 156
grep -Fxq "Authorization: '***REDACTED***'" "$line_file" || exit 157
grep -Fxq 'MY_TOKEN=***REDACTED***' "$line_file" || exit 158
grep -Fq 'backslashBearerEven906' "$line_file" && exit 159
grep -Fq 'backslashSchemeLessEven907' "$line_file" && exit 160
grep -Fq 'u@host456' "$line_file" && exit 122
grep -Fq 'keyVal123' "$line_file" && exit 123
grep -Fq 'foo bar baz' "$line_file" && exit 124
grep -Fq 'spaces tail' "$line_file" && exit 125
grep -Fq 'tokenAtValue123' "$line_file" && exit 81
grep -Fq 'keyAtValue123' "$line_file" && exit 82
grep -Fq 'unterminated_secret_12345' "$line_file" && exit 83
grep -Fq 'inner_unterminated_12345' "$line_file" && exit 84
grep -Fq 'plainTokenValue' "$line_file" && exit 44
grep -Fq '"api_key": "***REDACTED***"' "$line_file" || exit 45
grep -Fq 'json_secret_value' "$line_file" && exit 46
grep -Fq '"token": "***REDACTED***"' "$line_file" || exit 47
grep -Fq 'json_token_value' "$line_file" && exit 48
grep -Fq '"password": "***REDACTED***"' "$line_file" || exit 49
grep -Fq 'value with spaces' "$line_file" && exit 50
grep -Fq 'quote"BearerSuffix' "$line_file" && exit 53
grep -Fq 'MY_TOKEN=***REDACTED***' "$line_file" || exit 54
grep -Fq "Authorization: 'Bearer ***REDACTED***'" "$line_file" || exit 70
grep -Fq 'BearerSuffixSingle' "$line_file" && exit 71
grep -Fq "TOKEN='***REDACTED***'" "$line_file" || exit 72
grep -Fq 'quotedTokenSecret123' "$line_file" && exit 73
grep -Fq 'defGHI' "$line_file" && exit 55
grep -Fq "DB_PASSWORD=***REDACTED***" "$line_file" || exit 56
grep -Fq "'w0rd" "$line_file" && exit 57
grep -Fxq 'curl -d "{\"Authorization\":\"Bearer ***REDACTED***\"}" https://x' "$line_file" || exit 161
grep -Fq 'escapedJsonAuth9001' "$line_file" && exit 162
grep -Fxq 'Authorization\":\"Bearer ***REDACTED***' "$line_file" || exit 163
grep -Fq 'escapedUnterminated9002' "$line_file" && exit 164
grep -Fxq 'MY_TOKEN\":\"***REDACTED***' "$line_file" || exit 165
grep -Fq 'escapedKey9003' "$line_file" && exit 166
grep -Fxq 'curl -d "{\"api_key\":\"***REDACTED***\"}" https://x' "$line_file" || exit 167
grep -Fq 'escapedApiKey9004' "$line_file" && exit 168
grep -Fxq 'curl -d "{\\\"Authorization\\\":\\\"Bearer ***REDACTED***\\\"}" https://x' "$line_file" || exit 169
grep -Fq 'doubleEscapedAuth9101' "$line_file" && exit 170
grep -Fxq 'MY_TOKEN\\\":\\\"***REDACTED***' "$line_file" || exit 171
grep -Fq 'doubleEscapedKey9102' "$line_file" && exit 172
grep -Fq '"Authorization": "Bearer ***REDACTED***"' "$line_file" || exit 51
json_count=0
while IFS= read -r json_line; do
  printf '%s' "$json_line" | jq -e . >/dev/null 2>&1 || exit 68
  ((json_count += 1))
done < <(grep '^{' "$line_file")
((json_count >= 4)) || exit 67
grep -Fq 'BearerSuffix1234567890' "$line_file" && exit 69
grep -Fq 'json_bearer_value' "$line_file" && exit 52
grep -Fq '123MY_TOKEN=***REDACTED***' "$line_file" || exit 58
grep -Fq 'SECRETVAL' "$line_file" && exit 59
grep -Fq '"123MY_TOKEN": "***REDACTED***"' "$line_file" || exit 60
grep -Fq -- '-MY_TOKEN=***REDACTED***' "$line_file" || exit 61
grep -Fq 'MARKER' "$line_file" && exit 62
grep -Fq '"2fa_secret": "***REDACTED***"' "$line_file" || exit 63
grep -Fq 'SUPERSECRET123' "$line_file" && exit 64
grep -Fq '"123api_token": "***REDACTED***"' "$line_file" || exit 65
grep -Fq 'ANOTHERSECRET456' "$line_file" && exit 66
grep -Fq 'gho_***REDACTED***' "$line_file" || exit 14
grep -Fq 'github_pat_***REDACTED***' "$line_file" || exit 15
grep -Fq 'ghs_***REDACTED***' "$line_file" || exit 17
grep -Fq 'teless_jwt_body' "$line_file" && exit 16
grep -Fq 'tail_with_underscore' "$line_file" && exit 18
grep -Fq 'API_KEY = ***REDACTED***' "$line_file" || exit 19
grep -Fq 'spaced-secret-value' "$line_file" && exit 20
grep -Fq 'AKIA***REDACTED***' "$line_file" || exit 21
grep -Fq 'sk_live_***REDACTED***' "$line_file" || exit 32
grep -Fq 'sk_test_***REDACTED***' "$line_file" || exit 33
grep -Fq 'rk_live_***REDACTED***' "$line_file" || exit 34
grep -Fq 'rk_test_***REDACTED***' "$line_file" || exit 35
grep -Fq 'StripeBodySkLive' "$line_file" && exit 36
grep -Fq 'StripeBodyRkLive' "$line_file" && exit 37
grep -Fq 'pk_live_StripePublicBody0123456789' "$line_file" || exit 38
grep -Fq 'IOSFODNN7EXAMPLE' "$line_file" && exit 22
grep -Fq 'xoxb-***REDACTED***' "$line_file" || exit 23
grep -Fq 'glpat-***REDACTED***' "$line_file" || exit 28
grep -Fq 'abcdefghijklmnopqrstuvwxyz0123' "$line_file" && exit 29
grep -Fq 'AIza***REDACTED***' "$line_file" || exit 30
grep -Fq 'SyD12345678901234567890123456789012' "$line_file" && exit 31
grep -Fq '123456789012' "$line_file" && exit 24
grep -Fq '***REDACTED PRIVATE KEY***' "$line_file" || exit 25
grep -Fq 'FAKE-KEY-BODY-FOR-REDACT-TEST' "$line_file" && exit 26
grep -Fq 'BEGIN RSA PRIV''ATE KEY' "$line_file" && exit 27
grep -q 'Question:' "$line_file" || exit 13
printf 'lmline-meta: model=clip-model tokens=10 prompt=7 completion=3\n' >&2
printf 'lmline-status: m=clip-model; tok=7/3/10\n' >&2
printf 'clip answer\n'
EOF
chmod +x "$clip_test_dir/engine"
clip_status=$(LMLINE_CONFIG_DIR="$clip_test_dir/config" "$repo_dir/lmline/lmline" clip --status)
grep -q '^clipboard_provider=fake$' <<<"$clip_status" || fail "clip status provider"
clip_providers=$(LMLINE_CONFIG_DIR="$clip_test_dir/config" "$repo_dir/lmline/lmline" clip --providers)
grep -q $'^fake\tavailable\t' <<<"$clip_providers" || fail "clip provider list"
clip_complete=$(LMLINE_CONFIG_DIR="$clip_test_dir/config" "$repo_dir/lmline/lmline" complete clipboard-providers)
grep -q '^auto$' <<<"$clip_complete" || fail "clip provider completion auto"
grep -q '^fake$' <<<"$clip_complete" || fail "clip provider completion fake"
clip_use=$(LMLINE_CONFIG_DIR="$clip_test_dir/config" "$repo_dir/lmline/lmline" clip --use fake)
grep -q '^clipboard_provider=fake$' <<<"$clip_use" || fail "clip provider use"
grep -q "LMLINE_CLIPBOARD_PROVIDER=.*fake" "$clip_test_dir/config/settings.bash" || fail "clip provider persisted"
clip_out=$(LMLINE_CONFIG_DIR="$clip_test_dir/config" LMLINE_ENGINE="$clip_test_dir/engine" "$repo_dir/lmline/lmline" clip "原因は？")
grep -q 'clipboard provider=fake' <<<"$clip_out" || fail "clip provider output"
grep -q 'm=clip-model; tok=7/3/10' <<<"$clip_out" || fail "clip metadata"
grep -q 'clip answer' <<<"$clip_out" || fail "clip answer"
clip_provider_out=$(LMLINE_CONFIG_DIR="$clip_test_dir/config" LMLINE_ENGINE="$clip_test_dir/engine" "$repo_dir/lmline/lmline" clip --provider fake "原因は？")
grep -q 'clipboard provider=fake' <<<"$clip_provider_out" || fail "clip one-shot provider"
# Measure only the clipboard section delivered to the engine, never its text.
# Count the exact raw section after the header; tail preserves an unterminated
# final line without adding a byte.
cat >"$clip_test_dir/engine-input-limit" <<'EOF'
#!/usr/bin/env bash
line_file=
while (($#)); do
  case "$1" in
    --line-file) line_file=$2; shift 2 ;;
    *) shift ;;
  esac
done
header_line=$(LC_ALL=C awk '
  /^Pasted terminal or clipboard text:$/ { print NR; found = 1; exit }
  END { if (!found) exit 1 }
' "$line_file")
tail -n +"$((header_line + 1))" "$line_file" | wc -c | tr -d '[:space:]' >"${LMLINE_TEST_INPUT_BYTES:?}"
EOF
chmod +x "$clip_test_dir/engine-input-limit"
LMLINE_CONFIG_DIR="$clip_test_dir/config" LMLINE_CLIP_MAX_INPUT_BYTES=8 \
  LMLINE_ENGINE="$clip_test_dir/engine-input-limit" \
  LMLINE_TEST_INPUT_BYTES="$clip_test_dir/input-bytes" \
  "$repo_dir/lmline/lmline" clip 'analyze' >"$clip_test_dir/input-limit-output" \
  2>"$clip_test_dir/input-limit-error" || fail "small clipboard input cap status"
[[ -s "$clip_test_dir/input-bytes" ]] || fail "small clipboard input cap reaches engine"
input_bytes=$(cat "$clip_test_dir/input-bytes")
[[ "$input_bytes" =~ ^[0-9]+$ ]] || fail "clipboard section byte measurement"
(( input_bytes <= 8 )) || fail "clipboard section strict byte budget"
# An exact-fit one-byte body must remain one byte after the request is written.
cat >"$clip_test_dir/one-byte-provider" <<'EOF'
#!/usr/bin/env bash
printf x
EOF
chmod +x "$clip_test_dir/one-byte-provider"
printf 'fake\t%s\n' "$clip_test_dir/one-byte-provider" >"$clip_test_dir/one-byte-providers.tsv"
LMLINE_CONFIG_DIR="$clip_test_dir/config" \
  LMLINE_CLIPBOARD_PROVIDERS_FILE="$clip_test_dir/one-byte-providers.tsv" \
  LMLINE_CLIP_MAX_INPUT_BYTES=1 \
  LMLINE_ENGINE="$clip_test_dir/engine-input-limit" \
  LMLINE_TEST_INPUT_BYTES="$clip_test_dir/one-byte-input-bytes" \
  "$repo_dir/lmline/lmline" clip --provider fake analyze \
  >"$clip_test_dir/one-byte-output" 2>"$clip_test_dir/one-byte-error" || fail "one-byte clipboard input cap status"
[[ $(cat "$clip_test_dir/one-byte-input-bytes") == 1 ]] || fail "one-byte clipboard exact fit"

# Buffered clip and explain share the answer-body byte budget, not a per-line
# width. Compare everything after metadata so headings/status/notices are not
# counted as answer bytes (and runtime metadata cannot leak into the body).
cat >"$clip_test_dir/engine-limits" <<'EOF'
#!/usr/bin/env bash
printf 'lmline-meta: model=limit-model tokens=10 prompt=7 completion=3\n' >&2
printf 'lmline-status: m=limit-model; tok=7/3/10\n' >&2
printf '%s\n' "$LMLINE_TEST_ANSWER"
EOF
chmod +x "$clip_test_dir/engine-limits"
for action in clip explain; do
  if [[ "$action" == clip ]]; then
    limit_setting=LMLINE_CLIP_MAX_OUTPUT_BYTES
    heading='model response:'
    notice=clip-output-truncated
  else
    limit_setting=LMLINE_EXPLAIN_MAX_OUTPUT_BYTES
    heading='model explanation:'
    notice=explanation-truncated
  fi
  for limit_case in multiline below exact bytes; do
    limit=8
    original_bytes=
    case "$limit_case" in
      multiline) answer=$'abcd\nefgh\nijkl'; expected=$'abcd\nefg'; original_bytes=14 ;;
      below) answer=$'abc\ndef'; expected=$answer ;;
      exact) answer=$'abcd\nefg'; expected=$answer ;;
      # Three UTF-8 e-acute characters, then a newline and ASCII. The
      # three-byte prefix deliberately ends inside a multibyte character.
      bytes) answer=$'\303\251\303\251\303\251\nTAIL'; expected=$'\303\251\303'; limit=3; original_bytes=11 ;;
    esac
    if [[ -n "$original_bytes" ]]; then
      expected+=$'\n\n'"[lm] $notice original_bytes=$original_bytes max_bytes=$limit"
    fi
    limit_out=$(env "$limit_setting=$limit" LMLINE_STREAM=0 \
      LMLINE_CONFIG_DIR="$clip_test_dir/config" LMLINE_PS0='[lm] ' \
      LMLINE_ENGINE="$clip_test_dir/engine-limits" LMLINE_TEST_ANSWER="$answer" \
      "$repo_dir/lmline/lmline" "$action" 'echo hi') || fail "$action $limit_case status"
    [[ "$limit_out" == *"[lm] $heading"* ]] || fail "$action $limit_case heading"
    status_line=$'[lm] m=limit-model; tok=7/3/10\n'
    [[ "$limit_out" == *"$status_line"* ]] || fail "$action $limit_case metadata/status"
    [[ "${limit_out#*"$status_line"}" == "$expected" ]] || fail "$action $limit_case answer byte prefix"
  done
done
# The display boundary protects both actions, including replacement engines.
# Assertions stay boolean: never print the untrusted answer to the test log.
unsafe_answer=$'before\e]52;c;clipboard-payload\aafter\e[31m red\e[0m\r\b\t\177\302\205\nUTF-8: \303\251 \346\227\245 \360\237\230\200\nlast'
expected=$'beforeafter red\nUTF-8: \303\251 \346\227\245 \360\237\230\200\nlast'
for action in clip explain; do
  for streaming in 0 1; do
    safe_out=$(env LMLINE_STREAM="$streaming" LMLINE_CONFIG_DIR="$clip_test_dir/config" LMLINE_PS0='[lm] ' \
      LMLINE_ENGINE="$clip_test_dir/engine-limits" LMLINE_TEST_ANSWER="$unsafe_answer" \
      "$repo_dir/lmline/lmline" "$action" 'echo hi') || fail "$action display status"
    [[ "$safe_out" != *$'\e'* && "$safe_out" != *clipboard-payload* ]] || fail "$action display controls removed"
    if (( streaming )); then
      [[ "$safe_out" == *"$expected"$'\n'"[lm] m=limit-model; tok=7/3/10" ]] || fail "$action stream text and status preserved"
    else
      [[ "${safe_out#*"$status_line"}" == "$expected" ]] || fail "$action buffered text preserved"
    fi
  done
  # Sanitization does not make additional raw answer bytes fit the cap.
  if [[ "$action" == clip ]]; then
    limit_setting=LMLINE_CLIP_MAX_OUTPUT_BYTES; notice=clip-output-truncated
  else
    limit_setting=LMLINE_EXPLAIN_MAX_OUTPUT_BYTES; notice=explanation-truncated
  fi
  answer=$'A\e[31mBTAIL'
  safe_out=$(env "$limit_setting=7" LMLINE_STREAM=0 LMLINE_CONFIG_DIR="$clip_test_dir/config" LMLINE_PS0='[lm] ' \
    LMLINE_ENGINE="$clip_test_dir/engine-limits" LMLINE_TEST_ANSWER="$answer" \
    "$repo_dir/lmline/lmline" "$action" 'echo hi') || fail "$action raw budget status"
  [[ "${safe_out#*"$status_line"}" == $'AB\n\n'"[lm] $notice original_bytes=11 max_bytes=7" ]] || fail "$action raw byte budget preserved"
done
install_clip_dir="$cfg_tmp/install-clip"
mkdir -p "$install_clip_dir/bin" "$install_clip_dir/config" "$install_clip_dir/homebin"
cat >"$install_clip_dir/homebin/pbpaste" <<'EOF'
#!/usr/bin/env bash
printf 'mac clipboard\n'
EOF
cat >"$install_clip_dir/homebin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
chmod +x "$install_clip_dir/homebin/pbpaste" "$install_clip_dir/homebin/uname"
PATH="$install_clip_dir/homebin:$PATH" LMLINE_CONFIG_DIR="$install_clip_dir/config" LMLINE_BIN_DIR="$install_clip_dir/bin" bash "$repo_dir/install.sh" >"$cfg_tmp/install-clip.out"
grep -q "Clipboard provider: configured macos" "$cfg_tmp/install-clip.out" || fail "install auto clipboard output"
grep -q "LMLINE_CLIPBOARD_PROVIDER=.*macos" "$install_clip_dir/config/settings.bash" || fail "install auto clipboard setting"
printf "export LMLINE_CLIPBOARD_PROVIDER='tmux'\n" >"$install_clip_dir/config/settings.bash"
PATH="$install_clip_dir/homebin:$PATH" LMLINE_CONFIG_DIR="$install_clip_dir/config" LMLINE_BIN_DIR="$install_clip_dir/bin" bash "$repo_dir/install.sh" >"$cfg_tmp/install-clip-preserve.out"
grep -q "preserved existing LMLINE_CLIPBOARD_PROVIDER" "$cfg_tmp/install-clip-preserve.out" || fail "install preserves clipboard output"
grep -q "LMLINE_CLIPBOARD_PROVIDER=.*tmux" "$install_clip_dir/config/settings.bash" || fail "install preserves clipboard setting"
install_linux_clip_dir="$cfg_tmp/install-linux-clip"
mkdir -p "$install_linux_clip_dir/bin" "$install_linux_clip_dir/config" "$install_linux_clip_dir/homebin"
cat >"$install_linux_clip_dir/homebin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
cat >"$install_linux_clip_dir/homebin/wl-paste" <<'EOF'
#!/usr/bin/env bash
printf 'linux clipboard\n'
EOF
chmod +x "$install_linux_clip_dir/homebin/uname" "$install_linux_clip_dir/homebin/wl-paste"
PATH="$install_linux_clip_dir/homebin:$PATH" LMLINE_CONFIG_DIR="$install_linux_clip_dir/config" LMLINE_BIN_DIR="$install_linux_clip_dir/bin" bash "$repo_dir/install.sh" >"$cfg_tmp/install-linux-clip.out"
grep -q "Clipboard provider: configured wayland" "$cfg_tmp/install-linux-clip.out" || fail "install linux clipboard output"
grep -q "LMLINE_CLIPBOARD_PROVIDER=.*wayland" "$install_linux_clip_dir/config/settings.bash" || fail "install linux clipboard setting"
custom_count_payload=$(LMLINE_CANDIDATE_COUNT=5 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload generate "# list files")
grep -q 'Requested candidate limit: 5' <<<"$custom_count_payload" || fail "payload custom candidate count"

ok "clip cli"
