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
printf '%s\n' 'curl -H "Authorization: Bearer @atFirstDouble777" -H "X: tailDouble" https://x'
printf '%s\n' "curl -H 'Authorization: Bearer @atFirstSingle778' -H 'X: tailSingle' https://x"
printf '%s\n' 'curl -H "X: keep" -H "Authorization: Bearer @atSecondDouble779" https://x'
printf '%s\n' 'Authorization: Bearer @sec"quoteTail9011" -H "X: keep" https://x'
printf '%s\n' "Authorization: Bearer @sec'quoteTail9012' -H 'X: keep' https://x"
printf '%s\n' 'Authorization: Digest @digestAt9013, nonce="nonceTail9014"'
printf '%s\n' 'curl -H "Authorization: Bearer @sec\"escapedTail9015\"" https://x'
printf '%s\n' 'curl -H "Authorization: Bearer abc\"defGHI tailSECRET9991" -H "X: keep" https://x'
printf '%s\n' 'curl -H "Authorization: abc\"defGHI tailSECRET9992" -H "X: keep" https://x'
printf '%s\n' 'curl -H "Authorization: Bearer abc\" defGHI tailLEAK9041" -H "X: keep" https://x'
printf '%s\n' 'curl -H "Authorization: abc\" defGHI tailLEAK9042" -H "X: keep" https://x'
printf '%s\n' 'curl -H "X: keep" -H "Authorization: Bearer abc\" tailLEAK9043" https://x'
printf '%s\n' 'curl -H "Authorization: Bearer tailEscBearer9031\" -H "X: keepTail9033" https://x'
printf '%s\n' 'curl -H "Authorization: Bearer tailClosedBearer9031\"" -H "X: keepClosed" https://x'
printf '%s\n' 'curl -H "Authorization: tailClosedScheme9032\"" -H "X: keepClosed" https://x'
printf '%s\n' 'curl -H "Authorization: tailEscScheme9032\" -H "X: keepTail9033" https://x'
printf '%s\n' 'curl -H "Authorization: Bearer abc"plainQuote9044" -H "X: keep" https://x'
printf '%s\n' 'curl -H "Authorization: Bearer abc\\"dblSlashQuote9045" -H "X: keep" https://x'
printf '%s\n' 'curl -H "Authorization: abc"tailAUDIT028 -H "X: keep" https://example.test'
printf '%s\n' "curl -H \"Authorization: Bearer abc\"'tailAUDIT027' -H \"X: keep\" https://example.test"
printf '%s\n' "curl -H 'Authorization: abc'\"tailAUDIT029\" -H \"X: keep\" https://example.test"
printf '%s\n' 'curl -H "Authorization: abc""tail innerSPACE1" -H "X: keep" https://example.test'
printf '%s\n' "curl -H \"Authorization: abc\"'tail innerSPACE2' -H \"X: keep\" https://example.test"
printf '%s\n' "curl -H 'Authorization: abc'\"tail innerSPACE4\" -H \"X: keep\" https://example.test"
printf '%s\n' "curl -H 'Authorization: abc''tail innerSPACE5' -H \"X: keep\" https://example.test"
printf '%s\n' 'curl -H "Authorization: abc""tail multiDQ901""tail multiDQ903" -H "X: keep" https://example.test'
printf '%s\n' "curl -H \"Authorization: Bearer abc\"'tail multiSQ902''tail multiSQ904' -H \"X: keep\" https://example.test"
printf '%s\n' 'curl -H "Authorization: abc""multiDQ905""multiDQ906""multiDQ907" -H "X: keep" https://example.test'
printf '%s\n' 'curl -H "Authorization: abc""pa\\"insideEsc9031""pb" -H "X: keep" https://dqesc9031.example.test'
printf '%s\n' 'curl -H "Authorization: abc""pa\\"inside space""pb tailDQSpaced9034" -H "X: keep" https://dqesc9031.example.test'
printf '%s\n' "curl -H 'Authorization: abc'\"pa\\\"insideEsc9033\"\"pb\" -H \"X: keep\" https://sqesc9033.example.test"
printf '%s\n' "curl -H 'Authorization: abc'\"pa\\\"inside space\"\"pb tailSQSpaced9035\" -H \"X: keep\" https://sqesc9033.example.test"
printf '%s\n' 'Authorization: Bearer @sec".unterminatedDot9021'
printf '%s\n' "Authorization: Bearer @sec'unterminatedApostrophe9022 more"
printf '%s\n' "Authorization: Bearer @o'brien Secret9029 tail"
printf '%s\n' 'Authorization: Bearer @sec"untermTail -H "X: keep" https://x'
printf '%s\n' 'Authorization: Digest @digestAtSecret9023, response="respSecret9023"'
printf '%s\n' 'Authorization: Digest @ZxSecretMARKER7788, nonce="nonce7788", response="ZxSecretMARKER7788"'
printf '%s\n' 'Authorization: Digest @ZxSecret7789, response="respFirst7789", nonce="nonceSecond7789"'
printf '%s\n' 'Authorization" : Digest @sec7788, nonce="NONCE7788", response="RESP7788"'
printf '%s\n' '"Authorization" : Digest @sec7789, nonce="NONCE7789", response="RESP7789"'
printf '%s\n' 'authorization  : Digest @sec7790, nonce="NONCE7790", response="RESP7790"'
printf '%s\n' 'Authorization: Bearer #secretHash9020'
printf '%s\n' "Authorization: Bearer @o'brienApostrophe9016"
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
printf '%s\n' 'curl -d "{\"Authorization\":\"Bearer ab\\cdSECRET888\"}" https://x'
printf '%s\n' 'curl -d "{\"MY_TOKEN\":\"ab\\cdSECRET888\"}" https://x'
printf '%s\n' 'curl -d "{\"Authorization\":\"Bearer mytok\\\" tailSECRET999\"}" https://x'
printf '%s\n' 'Authorization\":\"Bearer secretEnding8888\\'
printf '%s\n' 'MY_TOKEN\":\"secretEnding7777\\'
printf '%s\n' 'Authorization\":\"Bearer backslashOddEscapedAuth9011\'
printf '%s\n' 'MY_TOKEN\":\"backslashOddEscapedKey9012\\\'
printf '%s\n' 'curl -d "{\"Authorization\":\"Bearer o'\''brienEscapedAuth9201\"}" https://x'
printf '%s\n' 'Authorization\":\"Bearer o'\''brienEscapedUnterm9202'
printf '%s\n' 'curl -d "{\"MY_TOKEN\":\"o'\''brienEscapedKey9203\"}" https://x'
printf '%s\n' 'curl -d "{\"Authorization\":\"Bearer bracketCloseAuth9301\"]}" https://x'
printf '%s\n' 'curl -d "{\"MY_TOKEN\":\"bracketCloseKey9302\"]}" https://x'
printf '%s\n' 'Authorization\: "Bearer partialAuthClose9401"}'
printf '%s\n' 'MY_TOKEN\: "partialKeyClose9402"}'
printf '%s\n' 'Authorization\": "Bearer partialUnterm9403'
printf '%s\n' "Authorization\\': 'Bearer singleQuotePartial9404'}"
printf "%s\n" "Authorization: \\'Bearer simpleSecret777'"
printf "%s\n" "Authorization: \\'o'brienZZSECRETABC123END'"
printf "%s\n" "Authorization: \\'Bearer o'brienAuth777'}"
printf "%s\n" "MY_TOKEN\\': 'o'brienKey777'"
printf "%s\n" "Authorization: \\\"Bearer dqSecret777\""
printf "%s\n" "Authorization: \\\"o'brien777\""
printf "%s\n" "MY_TOKEN\\: \"plainKey777\""
printf '%s\n' 'git clone https://oauth2:cloneTokUrl901@github.example/org/repo.git'
printf '%s\n' 'psql postgresql://reporting:dbPwUrl902@db.example:5432/analytics'
printf '%s\n' 'curl "https://u:quotedPwUrl903@host.example/x" -H "X: keepUrl"'
printf '%s\n' 'curl https://example.test:8443?q=alice@example.test'
printf '%s\n' 'curl https://example.test:8443#alice@example.test'
printf '%s\n' 'git clone //user:pass@example.test/path'
printf '%s\n' 'url=//user:passAssignLine@example.test/path'
printf '%s\n' 'url=//BAREline123456@example.test/path'
printf '%s\n' 'curl "//user:passDoubleQuote@example.test/path"'
printf '%s\n' 'curl "//BAREdoublequote123@example.test/path"'
printf '%s\n' 'echo foo,//user:passComma@example.test/path'
printf '%s\n' 'foo=bar,//user:passComma2@example.test/path'
printf '%s\n' 'git clone //BAREabcdefghijkl@example.test/path'
printf '%s\n' 'echo url=//user:passAssign@example.test/path'
printf '%s\n' 'echo url=//BAREassign123456@example.test/path'
printf '%s\n' 'echo [//user:passBracket@example.test/path]'
printf '%s\n' 'echo {user=//user:passBrace@example.test/path}'
printf '%s\n' 'echo `//user:passTick@example.test/path`'
printf '%s\n' 'echo "url=//user:passQuotedAssign@example.test/path"'
printf '%s\n' "echo 'url=//user:passSingleAssign@example.test/path'"
printf '%s\n' 'db.url=//user:passDotted@example.test/x'
printf '%s\n' 'spring.datasource.url=//user:passSpring@example.test/x'
printf '%s\n' 'curl --url=//user:passFlag@example.test/x'
printf '%s\n' 'java -Ddb.url=//user:passD@example.test/x'
printf '%s\n' 'db.url=//BAREdot123456@example.test/x'
printf '%s\n' "curl 'https://example.test/docs#//user:Secret987654@example.test'"
printf '%s\n' "curl 'https://example.test/?a=1&//user:Secret987654@example.test'"
printf '%s\n' 'curl https://example.test/?q=//abcdefghijkl@example.test'
printf '%s\n' "curl 'https://example.test/path?token=abc&x=1'"
printf '%s\n' "curl 'https://example.test/?x=1&token=abc'"
printf '%s\n' "curl 'https://example.test/?x=1;token=fixtureSemi9001&y=2'"
printf '%s\n' "curl 'https://example.test/?x=1,token=fixtureComma9002&y=2'"
printf '%s\n' "curl 'https://example.test/a;token=fixturePath9003?x=1'"
printf '%s\n' 'curl "https://x/?token=abcQuestionMark9004&y=2"'
printf '%s\n' 'echo x;token=abcQuestionShell9005'
printf '%s\n' 'echo x;token=fixtureShell9004'
printf '%s\n' "curl 'https://example.test/a/token=abc'"
printf '%s\n' 'INFO|token=SECRETpipe987654 service=web'
printf '%s\n' 'db:password=SECRETcolon987654'
printf '%s\n' '[INFO]token=SECRETbracket987654'
printf '%s\n' "curl 'https://example.test/?token=user@example.com&at=1'"
printf '%s\n' "curl 'https://example.test/?token=abc/def&slash=1'"
printf '%s\n' 'curl "https://example.test/?q=sk_live_StripeBodyTail123&x=1"'
printf '%s\n' 'sk_test_StripeCommaBody456,next=1'
printf '%s\n' 'curl "https://example.test/?q=ghp_GitHubBodyTail456&x=1"'
printf '%s\n' 'curl "https://example.test/?q=AKIAAWSBODYTAIL456&x=1"'
printf '%s\n' 'curl "https://example.test/?q=xoxb-12-34-SlackTail&x=1"'
printf '%s\n' 'curl "https://example.test/?q=glpat-GitLabBodyTail456&x=1"'
printf '%s\n' "curl 'https://user:pass;token=abc@example.test/path'"
printf '%s\n' 'TOKEN=httpsSecret987654 https://x'
printf '%s\n' 'curl https://example.test/a//abc:def@example.test'
printf '%s\n' 'curl https://example.test/?q=//BAREabcdefghijkl@example.test'
printf '%s\n' 'git clone https://PATabcdefghijkl@example.test/nope.git'
printf '%s\n' 'git clone https://shortus@example.test/nope.git'
printf '%s\n' 'git clone https://s3cret@example.test/nope.git'
printf '%s\n' "curl 'https://example.test/?a=1;//u:pSemiQuery987654@example.test'"
printf '%s\n' "curl 'https://example.test/a,//u:pCommaPath987654@example.test'"
printf '%s\n' 'curl "https://x/?q=\"a;//u:pInQuote987654@example.test\""'
printf '%s\n' 'curl "https://x/?q=\"a;//BAREesc987654@example.test\""'
printf '%s\n' 'echo first;//u:pShellSeparator987654@example.test'
printf '%s\n' "echo '\"';//u:fixtureSeq101@example.test; echo '\"'"
printf '%s\n' "echo 'x';//u:fixtureSeq101Control@example.test; echo 'x'"
printf '%s\n' 'curl "https://x/?a=1;b=2;//u:pSeq113Semi@one.example.test";//u:realSeq113Semi@two.example.test'
printf '%s\n' 'curl "https://x/?a=1,b=2,//u:pSeq113Comma@one.example.test",//u:realSeq113Comma@two.example.test'
printf '%s\n' "curl 'https://x/?a=;//u:pSeq113One@h;b=;//u:pSeq113Two@h';//u:realSeq113Two@h"
printf '%s\n' 'curl "https://mixedsep1.example.test/?q=;//u:pMixedSepData1@one.example.test";//u:pMixedSepReal1@two.example.test'
printf '%s\n' 'curl "https://mixedsep2.example.test/?q=;//BAREMixedData2@one.example.test";//BAREMixedReal2@two.example.test'
printf '%s\n' 'curl "https://mixedsep3.example.test/?q=,//u:pMixedCommaData3@one.example.test",//u:pMixedCommaReal3@two.example.test'
printf '%s\n' "curl 'https://mixedsep4.example.test/?q=;//u:pMixedSquoteData4@one.example.test';//u:pMixedSquoteReal4@two.example.test"
printf '%s\n' 'echo "q";echo first;//u:pQuoteSemi987654@example.test'
printf '%s\n' 'echo "a\"b";echo first;//u:pQuoteEscSep987654@example.test'
printf '%s\n' "echo 'q';echo first;//u:pSquoteSemi987654@example.test"
printf '%s\n' 'echo "q";echo foo,//user:passQuoteComma987654@example.test/path'
printf '%s\n' 'echo first;//u:pTrailingQuote987654@example.test "tail"'
printf '%s\n' 'echo "q";;//BAREabcdefghijkl@example.test'
printf '%s\n' 'x=1;url=//user:passSemiAssign@example.test/path'
printf '%s\n' 'echo plain@example.com https://host.example/path:with@at'
printf "%s\n" "MY_TOKEN\\: \"o'brienKey777\""
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
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: tailDouble" https://x' "$line_file" || exit 143
grep -Fxq "curl -H 'Authorization: Bearer ***REDACTED***' -H 'X: tailSingle' https://x" "$line_file" || exit 144
grep -Fxq 'curl -H "X: keep" -H "Authorization: Bearer ***REDACTED***" https://x' "$line_file" || exit 145
grep -Fq 'atFirstDouble777' "$line_file" && exit 146
grep -Fq 'atFirstSingle778' "$line_file" && exit 147
grep -Fq 'atSecondDouble779' "$line_file" && exit 148
grep -Fxq 'Authorization: Bearer ***REDACTED*** -H "X: keep" https://x' "$line_file" || exit 170
grep -Fxq "Authorization: Bearer ***REDACTED*** -H 'X: keep' https://x" "$line_file" || exit 171
grep -Fxq 'Authorization: Digest ***REDACTED***, nonce="***REDACTED***"' "$line_file" || exit 172
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" https://x' "$line_file" || exit 173
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 174
grep -Fq 'quoteTail9011' "$line_file" && exit 175
grep -Fq 'quoteTail9012' "$line_file" && exit 176
grep -Fq 'nonceTail9014' "$line_file" && exit 177
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 202
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 203
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 204
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 205
grep -Fxq 'Authorization: Digest ***REDACTED***, response="***REDACTED***"' "$line_file" || exit 206
grep -Fq 'unterminatedDot9021' "$line_file" && exit 207
grep -Fq 'unterminatedApostrophe9022' "$line_file" && exit 208
grep -Fq 'Secret9029' "$line_file" && exit 209
grep -Fq 'untermTail' "$line_file" && exit 210
grep -Fq 'respSecret9023' "$line_file" && exit 211
grep -Fxq 'Authorization: Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"' "$line_file" || exit 214
grep -Fxq 'Authorization: Digest ***REDACTED***, response="***REDACTED***", nonce="***REDACTED***"' "$line_file" || exit 215
grep -Fq 'ZxSecretMARKER7788' "$line_file" && exit 216
grep -Fq 'nonceSecond7789' "$line_file" && exit 217
grep -Fxq 'Authorization" : Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"' "$line_file" || exit 218
grep -Fq 'sec7788' "$line_file" && exit 219
grep -Fq 'NONCE7788' "$line_file" && exit 220
grep -Fq 'RESP7788' "$line_file" && exit 221
grep -Fxq '"Authorization" : Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"' "$line_file" || exit 222
grep -Fq 'sec7789' "$line_file" && exit 223
grep -Fq 'NONCE7789' "$line_file" && exit 224
grep -Fq 'RESP7789' "$line_file" && exit 225
grep -Fxq 'authorization  : Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"' "$line_file" || exit 226
grep -Fq 'sec7790' "$line_file" && exit 227
grep -Fq 'NONCE7790' "$line_file" && exit 228
grep -Fq 'RESP7790' "$line_file" && exit 229
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 212
grep -Fq 'secretHash9020' "$line_file" && exit 213
grep -Fq 'escapedTail9015' "$line_file" && exit 178
grep -Fq 'tailSECRET9991' "$line_file" && exit 230
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x' "$line_file" || exit 231
grep -Fq 'tailSECRET9992' "$line_file" && exit 232
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://x' "$line_file" || exit 233
grep -Fq 'tailLEAK9041' "$line_file" && exit 234
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x' "$line_file" || exit 235
grep -Fq 'tailLEAK9042' "$line_file" && exit 236
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://x' "$line_file" || exit 237
grep -Fq 'tailLEAK9043' "$line_file" && exit 238
grep -Fxq 'curl -H "X: keep" -H "Authorization: Bearer ***REDACTED***" https://x' "$line_file" || exit 239
grep -Fq 'tailEscBearer9031' "$line_file" && exit 240
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"X: keepTail9033" https://x' "$line_file" || exit 241
grep -Fq 'tailEscScheme9032' "$line_file" && exit 242
grep -Fxq 'curl -H "Authorization: ***REDACTED***"X: keepTail9033" https://x' "$line_file" || exit 243
# Genuinely closed escaped quotes are real word boundaries: keep the next header.
grep -Fq 'tailClosedBearer9031' "$line_file" && exit 254
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keepClosed" https://x' "$line_file" || exit 255
grep -Fq 'tailClosedScheme9032' "$line_file" && exit 254
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keepClosed" https://x' "$line_file" || exit 255
# The tailEscBearer9031/tailEscScheme9032 fixtures above are malformed shell text.
# Their exact assertions record the fail-closed fallback, not a word boundary.
grep -Fq 'plainQuote9044' "$line_file" && exit 244
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x' "$line_file" || exit 245
grep -Fq 'dblSlashQuote9045' "$line_file" && exit 246
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***' "$line_file" || exit 247
grep -Fq 'tailAUDIT028' "$line_file" && exit 248
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://example.test' "$line_file" || exit 249
grep -Fq 'tailAUDIT027' "$line_file" && exit 250
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://example.test' "$line_file" || exit 251
grep -Fq 'tailAUDIT029' "$line_file" && exit 252
grep -Fq 'innerSPACE' "$line_file" && exit 254
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://example.test' "$line_file" || exit 255
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://example.test" "$line_file" || exit 255
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://example.test" "$line_file" || exit 253
grep -Fq 'multiDQ90' "$line_file" && exit 256
grep -Fq 'multiSQ90' "$line_file" && exit 257
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://example.test' "$line_file" || exit 258
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://example.test' "$line_file" || exit 259
grep -Fq 'insideEsc9031' "$line_file" && exit 270
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://dqesc9031.example.test' "$line_file" || exit 271
grep -Fq 'insideEsc9033' "$line_file" && exit 272
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://sqesc9033.example.test" "$line_file" || exit 273
grep -Fq 'tailDQSpaced9034' "$line_file" && exit 307
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://dqesc9031.example.test' "$line_file" || exit 308
grep -Fq 'tailSQSpaced9035' "$line_file" && exit 309
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://sqesc9033.example.test" "$line_file" || exit 310
grep -Fq 'brienApostrophe9016' "$line_file" && exit 179
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
grep -Fxq 'Authorization: Bearer ***REDACTED*** https://example.com' "$line_file" || exit 119
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
grep -Fxq 'curl -d "{\\\"Authorization\\\":\\\"Bearer ***REDACTED***\"}" https://x' "$line_file" || exit 169
grep -Fq 'doubleEscapedAuth9101' "$line_file" && exit 170
grep -Fxq 'MY_TOKEN\\\":\\\"***REDACTED***' "$line_file" || exit 171
grep -Fq 'doubleEscapedKey9102' "$line_file" && exit 172
grep -Fxq 'curl -d "{\"Authorization\":\"Bearer ***REDACTED***\"}" https://x' "$line_file" || exit 173
grep -Fq 'SECRET888' "$line_file" && exit 174
grep -Fxq 'curl -d "{\"MY_TOKEN\":\"***REDACTED***\"}" https://x' "$line_file" || exit 175
grep -Fxq 'curl -d "{\"Authorization\":\"Bearer ***REDACTED***\"}" https://x' "$line_file" || exit 176
grep -Fq 'tailSECRET999' "$line_file" && exit 177
grep -Fxq 'Authorization\":\"Bearer ***REDACTED***' "$line_file" || exit 178
grep -Fq 'secretEnding8888' "$line_file" && exit 179
grep -Fxq 'MY_TOKEN\":\"***REDACTED***' "$line_file" || exit 180
grep -Fq 'secretEnding7777' "$line_file" && exit 181
grep -Fxq 'Authorization\":\"Bearer ***REDACTED***' "$line_file" || exit 182
grep -Fq 'backslashOddEscapedAuth9011' "$line_file" && exit 183
grep -Fxq 'MY_TOKEN\":\"***REDACTED***' "$line_file" || exit 184
grep -Fq 'backslashOddEscapedKey9012' "$line_file" && exit 185
grep -Fq 'brienEscapedAuth9201' "$line_file" && exit 186
grep -Fq 'brienEscapedUnterm9202' "$line_file" && exit 187
grep -Fq 'brienEscapedKey9203' "$line_file" && exit 188
grep -Fq 'bracketCloseAuth9301' "$line_file" && exit 189
grep -Fq 'bracketCloseKey9302' "$line_file" && exit 190
grep -Fxq 'Authorization\: "Bearer ***REDACTED***"}' "$line_file" || exit 191
grep -Fxq 'MY_TOKEN\: "***REDACTED***"}' "$line_file" || exit 192
grep -Fxq 'Authorization\": "Bearer ***REDACTED***' "$line_file" || exit 193
grep -Fxq "Authorization\\': 'Bearer ***REDACTED***'}" "$line_file" || exit 194
grep -Fxq "Authorization: \\'Bearer ***REDACTED***'" "$line_file" || exit 195
grep -Fxq "Authorization: \\'***REDACTED***'" "$line_file" || exit 196
grep -Fxq "Authorization: \\'Bearer ***REDACTED***'}" "$line_file" || exit 197
grep -Fxq "MY_TOKEN\\': '***REDACTED***'" "$line_file" || exit 198
grep -Fxq "Authorization: \\\"Bearer ***REDACTED***\"" "$line_file" || exit 199
grep -Fxq "Authorization: \\\"***REDACTED***\"" "$line_file" || exit 200
grep -Fxq "MY_TOKEN\\: \"***REDACTED***\"" "$line_file" || exit 201
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
grep -Fxq 'git clone https://oauth2:***REDACTED***@github.example/org/repo.git' "$line_file" || exit 200
grep -Fq 'cloneTokUrl901' "$line_file" && exit 201
grep -Fxq 'psql postgresql://reporting:***REDACTED***@db.example:5432/analytics' "$line_file" || exit 202
grep -Fq 'dbPwUrl902' "$line_file" && exit 203
grep -Fxq 'curl "https://u:***REDACTED***@host.example/x" -H "X: keepUrl"' "$line_file" || exit 204
grep -Fq 'quotedPwUrl903' "$line_file" && exit 205
grep -Fq 'plain@example.com' "$line_file" || exit 206
grep -Fxq 'curl https://example.test:8443?q=alice@example.test' "$line_file" || exit 207
grep -Fxq 'curl https://example.test:8443#alice@example.test' "$line_file" || exit 208
grep -Fxq 'git clone //user:***REDACTED***@example.test/path' "$line_file" || exit 209
grep -Fq 'git clone //user:pass@example.test/path' "$line_file" && exit 210
grep -Fxq 'echo [//user:***REDACTED***@example.test/path]' "$line_file" || exit 255
grep -Fq 'passBracket@example.test' "$line_file" && exit 254
grep -Fxq 'echo {user=//user:***REDACTED***@example.test/path}' "$line_file" || exit 255
grep -Fq 'passBrace@example.test' "$line_file" && exit 254
grep -Fxq 'echo `//user:***REDACTED***@example.test/path`' "$line_file" || exit 255
grep -Fq 'passTick@example.test' "$line_file" && exit 254
grep -Fxq 'echo "url=//user:***REDACTED***@example.test/path"' "$line_file" || exit 255
grep -Fq 'passQuotedAssign@example.test' "$line_file" && exit 254
grep -Fxq "echo 'url=//user:***REDACTED***@example.test/path'" "$line_file" || exit 255
grep -Fxq 'db.url=//user:***REDACTED***@example.test/x' "$line_file" || exit 255
grep -Fq 'passDotted@example.test' "$line_file" && exit 254
grep -Fxq 'spring.datasource.url=//user:***REDACTED***@example.test/x' "$line_file" || exit 255
grep -Fq 'passSpring@example.test' "$line_file" && exit 254
grep -Fxq 'curl --url=//user:***REDACTED***@example.test/x' "$line_file" || exit 255
grep -Fq 'passFlag@example.test' "$line_file" && exit 254
grep -Fxq 'java -Ddb.url=//user:***REDACTED***@example.test/x' "$line_file" || exit 255
grep -Fq 'passD@example.test' "$line_file" && exit 254
grep -Fxq 'db.url=//***REDACTED***@example.test/x' "$line_file" || exit 255
grep -Fq 'BAREdot123456@example.test' "$line_file" && exit 254
grep -Fxq "curl 'https://example.test/docs#//user:Secret987654@example.test'" "$line_file" || exit 255
grep -Fxq "curl 'https://example.test/?a=1&//user:Secret987654@example.test'" "$line_file" || exit 255
grep -Fq 'passSingleAssign@example.test' "$line_file" && exit 254
grep -Fxq 'curl https://example.test/?q=//abcdefghijkl@example.test' "$line_file" || exit 214
grep -Fxq "curl 'https://example.test/path?token=***REDACTED***&x=1'" "$line_file" || exit 255
grep -Fxq "curl 'https://example.test/?x=1&token=***REDACTED***'" "$line_file" || exit 255
grep -Fxq "curl 'https://example.test/?x=1;token=***REDACTED***&y=2'" "$line_file" || exit 285
grep -Fq 'fixtureSemi9001' "$line_file" && exit 286
grep -Fxq "curl 'https://example.test/?x=1,token=***REDACTED***&y=2'" "$line_file" || exit 287
grep -Fq 'fixtureComma9002' "$line_file" && exit 288
grep -Fxq "curl 'https://example.test/a;token=***REDACTED***?x=1'" "$line_file" || exit 289
grep -Fq 'fixturePath9003' "$line_file" && exit 290
grep -Fxq 'curl "https://x/?token=***REDACTED***&y=2"' "$line_file" || exit 303
grep -Fq 'abcQuestionMark9004' "$line_file" && exit 304
grep -Fxq 'echo x;token=***REDACTED***' "$line_file" || exit 305
grep -Fq 'abcQuestionShell9005' "$line_file" && exit 306
grep -Fxq 'echo x;token=***REDACTED***' "$line_file" || exit 291
grep -Fq 'fixtureShell9004' "$line_file" && exit 292
grep -Fxq "curl 'https://example.test/a/token=***REDACTED***'" "$line_file" || exit 255
grep -Fxq 'INFO|token=***REDACTED*** service=web' "$line_file" || exit 255
grep -Fxq 'db:password=***REDACTED***' "$line_file" || exit 255
grep -Fxq '[INFO]token=***REDACTED***' "$line_file" || exit 255
grep -Fxq "curl 'https://example.test/?token=***REDACTED***&at=1'" "$line_file" || exit 255
grep -Fxq "curl 'https://example.test/?token=***REDACTED***&slash=1'" "$line_file" || exit 255
grep -Fq '@example.com&at=1' "$line_file" && exit 254
grep -Fq '/def&slash=1' "$line_file" && exit 254
grep -Fxq 'curl "https://example.test/?q=sk_live_***REDACTED***&x=1"' "$line_file" || exit 255
grep -Fq 'StripeBodyTail123' "$line_file" && exit 254
grep -Fxq 'sk_test_***REDACTED***,next=1' "$line_file" || exit 255
grep -Fq 'StripeCommaBody456' "$line_file" && exit 254
grep -Fxq 'curl "https://example.test/?q=ghp_***REDACTED***&x=1"' "$line_file" || exit 255
grep -Fq 'GitHubBodyTail456' "$line_file" && exit 254
grep -Fxq 'curl "https://example.test/?q=AKIA***REDACTED***&x=1"' "$line_file" || exit 255
grep -Fq 'AWSBODYTAIL456' "$line_file" && exit 254
grep -Fxq 'curl "https://example.test/?q=xoxb-***REDACTED***&x=1"' "$line_file" || exit 255
grep -Fq 'SlackTail' "$line_file" && exit 254
grep -Fxq 'curl "https://example.test/?q=glpat-***REDACTED***&x=1"' "$line_file" || exit 255
grep -Fq 'GitLabBodyTail456' "$line_file" && exit 254
grep -Fxq "curl 'https://user:***REDACTED***@example.test/path'" "$line_file" || exit 255
grep -Fq 'pass;token=abc@example.test' "$line_file" && exit 254
grep -Fxq 'TOKEN=***REDACTED*** https://x' "$line_file" || exit 255
grep -Fq 'httpsSecret987654' "$line_file" && exit 254
grep -Fq 'abcdefghijkl@example.test' "$line_file" || exit 215
grep -Fxq 'curl https://example.test/a//abc:def@example.test' "$line_file" || exit 216
grep -Fxq 'git clone //***REDACTED***@example.test/path' "$line_file" || exit 217
grep -Fq 'BAREabcdefghijkl@example.test/path' "$line_file" && exit 218
grep -Fxq 'echo url=//user:***REDACTED***@example.test/path' "$line_file" || exit 220
grep -Fq 'passAssign@example.test' "$line_file" && exit 221
grep -Fxq 'echo url=//***REDACTED***@example.test/path' "$line_file" || exit 222
grep -Fq 'BAREassign123456@example.test' "$line_file" && exit 223
grep -Fxq 'url=//user:***REDACTED***@example.test/path' "$line_file" || exit 224
grep -Fq 'passAssignLine@example.test' "$line_file" && exit 225
grep -Fxq 'url=//***REDACTED***@example.test/path' "$line_file" || exit 226
grep -Fq 'BAREline123456@example.test' "$line_file" && exit 227
grep -Fxq 'echo foo,//user:***REDACTED***@example.test/path' "$line_file" || exit 228
grep -Fq 'passComma@example.test' "$line_file" && exit 229
grep -Fxq 'curl "//user:***REDACTED***@example.test/path"' "$line_file" || exit 232
grep -Fq 'passDoubleQuote@example.test' "$line_file" && exit 233
grep -Fxq 'curl "//***REDACTED***@example.test/path"' "$line_file" || exit 234
grep -Fq 'BAREdoublequote123@example.test' "$line_file" && exit 235
grep -Fxq 'foo=bar,//user:***REDACTED***@example.test/path' "$line_file" || exit 230
grep -Fq 'passComma2@example.test' "$line_file" && exit 231
grep -Fxq 'curl https://example.test/?q=//BAREabcdefghijkl@example.test' "$line_file" || exit 219
grep -Fxq 'git clone https://***REDACTED***@example.test/nope.git' "$line_file" || exit 211
grep -Fq 'PATabcdefghijkl' "$line_file" && exit 212
grep -Fxq 'git clone https://shortus@example.test/nope.git' "$line_file" || exit 213
grep -Fxq 'git clone https://s3cret@example.test/nope.git' "$line_file" || exit 213
grep -Fxq "curl 'https://example.test/?a=1;//u:pSemiQuery987654@example.test'" "$line_file" || exit 255
grep -Fxq "curl 'https://example.test/a,//u:pCommaPath987654@example.test'" "$line_file" || exit 255
grep -Fxq 'curl "https://x/?q=\"a;//u:pInQuote987654@example.test\""' "$line_file" || exit 273
grep -Fxq 'curl "https://x/?q=\"a;//BAREesc987654@example.test\""' "$line_file" || exit 276
grep -Fxq 'echo first;//u:***REDACTED***@example.test' "$line_file" || exit 255
grep -Fxq "echo '\"';//u:***REDACTED***@example.test; echo '\"'" "$line_file" || exit 293
grep -Fq 'fixtureSeq101@example.test' "$line_file" && exit 294
grep -Fxq "echo 'x';//u:***REDACTED***@example.test; echo 'x'" "$line_file" || exit 295
grep -Fq 'fixtureSeq101Control@example.test' "$line_file" && exit 296
grep -Fxq 'curl "https://x/?a=1;b=2;//u:pSeq113Semi@one.example.test";//u:***REDACTED***@two.example.test' "$line_file" || exit 297
grep -Fq 'realSeq113Semi@two.example.test' "$line_file" && exit 298
grep -Fxq 'curl "https://x/?a=1,b=2,//u:pSeq113Comma@one.example.test",//u:***REDACTED***@two.example.test' "$line_file" || exit 299
grep -Fq 'realSeq113Comma@two.example.test' "$line_file" && exit 300
grep -Fxq "curl 'https://x/?a=;//u:pSeq113One@h;b=;//u:pSeq113Two@h';//u:***REDACTED***@h" "$line_file" || exit 301
grep -Fq 'realSeq113Two@h' "$line_file" && exit 302
grep -Fxq 'curl "https://mixedsep1.example.test/?q=;//u:pMixedSepData1@one.example.test";//u:***REDACTED***@two.example.test' "$line_file" || exit 277
grep -Fq 'pMixedSepReal1' "$line_file" && exit 278
grep -Fxq 'curl "https://mixedsep2.example.test/?q=;//BAREMixedData2@one.example.test";//***REDACTED***@two.example.test' "$line_file" || exit 279
grep -Fq 'BAREMixedReal2' "$line_file" && exit 280
grep -Fxq 'curl "https://mixedsep3.example.test/?q=,//u:pMixedCommaData3@one.example.test",//u:***REDACTED***@two.example.test' "$line_file" || exit 281
grep -Fq 'pMixedCommaReal3' "$line_file" && exit 282
grep -Fxq "curl 'https://mixedsep4.example.test/?q=;//u:pMixedSquoteData4@one.example.test';//u:***REDACTED***@two.example.test" "$line_file" || exit 283
grep -Fq 'pMixedSquoteReal4' "$line_file" && exit 284
grep -Fq 'pShellSeparator987654@example.test' "$line_file" && exit 254
grep -Fq 'QuoteSemi987654@example.test' "$line_file" && exit 260
grep -Fq 'pQuoteEscSep987654@example.test' "$line_file" && exit 274
grep -Fxq 'echo "a\"b";echo first;//u:***REDACTED***@example.test' "$line_file" || exit 275
grep -Fq 'SquoteSemi987654@example.test' "$line_file" && exit 261
grep -Fq 'passQuoteComma987654@example.test' "$line_file" && exit 262
grep -Fq 'pTrailingQuote987654@example.test' "$line_file" && exit 263
grep -Fq ';;//BAREabcdefghijkl@example.test' "$line_file" && exit 264
grep -Fxq 'echo "q";echo first;//u:***REDACTED***@example.test' "$line_file" || exit 265
grep -Fxq "echo 'q';echo first;//u:***REDACTED***@example.test" "$line_file" || exit 266
grep -Fxq 'echo "q";echo foo,//user:***REDACTED***@example.test/path' "$line_file" || exit 267
grep -Fxq 'echo first;//u:***REDACTED***@example.test "tail"' "$line_file" || exit 268
grep -Fxq 'echo "q";;//***REDACTED***@example.test' "$line_file" || exit 269
grep -Fq 'passSemiAssign@example.test' "$line_file" && exit 254
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

strict_dir="$cfg_tmp/strict"
mkdir -p "$strict_dir/bin" "$strict_dir/config"
LMLINE_CONFIG_DIR="$strict_dir/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
LMLINE_CONFIG_DIR="$strict_dir/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model
cat >"$strict_dir/bin/fakeclip-strict" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'git clone https://s3cret@example.test/nope.git'
EOF
printf 'strictclip\t%s\n' "$strict_dir/bin/fakeclip-strict" >"$strict_dir/config/clipboard_providers.tsv"
cat >"$strict_dir/engine" <<'EOF'
#!/usr/bin/env bash
line_file=
while (($#)); do
  case "$1" in
    --line-file) line_file=$2; shift 2 ;;
    *) shift ;;
  esac
done
grep -Fxq 'git clone https://***REDACTED***@example.test/nope.git' "$line_file" || exit 11
grep -Fq 's3cret@example.test' "$line_file" && exit 12
printf 'lmline-meta: model=clip-model tokens=10 prompt=7 completion=3\n' >&2
printf 'lmline-status: m=clip-model; tok=7/3/10\n' >&2
printf 'strict answer\n'
EOF
chmod +x "$strict_dir/bin/fakeclip-strict" "$strict_dir/engine"
strict_out=$(LMLINE_CLIP_USERINFO_MIN=1 LMLINE_CONFIG_DIR="$strict_dir/config" LMLINE_ENGINE="$strict_dir/engine" \
  "$repo_dir/lmline/lmline" clip --provider strictclip explain) || fail "strict userinfo minimum status"
grep -q 'strict answer' <<<"$strict_out" || fail "strict userinfo minimum answer"

userinfo_token_255=$(printf '%255s' '' | tr ' ' a)
threshold_255=$(LMLINE_CLIP_USERINFO_MIN=255 bash -c 'source "$1"; printf "https://%s@example.test/x\n" "$2" | __lmline_redact_clip_text' _ "$repo_dir/lmline/actions.bash" "$userinfo_token_255") || fail "userinfo threshold 255 redaction"
grep -Fxq 'https://***REDACTED***@example.test/x' <<<"$threshold_255" || fail "userinfo threshold 255 output"
for invalid_userinfo_min in 256 32768 100000 invalid; do
  fallback_userinfo=$(LMLINE_CLIP_USERINFO_MIN="$invalid_userinfo_min" bash -c 'source "$1"; printf "https://abcdefghijkl@example.test/x\n" | __lmline_redact_clip_text' _ "$repo_dir/lmline/actions.bash") || fail "invalid userinfo threshold $invalid_userinfo_min broke redaction"
  grep -Fxq 'https://***REDACTED***@example.test/x' <<<"$fallback_userinfo" || fail "invalid userinfo threshold $invalid_userinfo did not fall back"
done

ok "clip cli"
