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
printf '%s\n' 'Authorization: my_scheme: SECRETZZ9; echo TAILZZ9'
printf '%s\n' 'Authorization: 2Scheme: SECRETZZ10; echo TAILZZ10'
printf '%s\n' 'Authorization: x~y: SECRETZZ11; echo TAILZZ11'
printf '%s\n' 'Authorization: my_scheme=\"SYNTHE12\"; echo TAILZZ12'
printf '%s\n' 'Authorization: 2Scheme=\"SYNTHE13\"; echo TAILZZ13'
printf '%s\n' 'Authorization: my_scheme \"SYNTHSP2\"; echo TAILZZSP2'
printf '%s\n' 'Authorization: 2Scheme \"SYNTHSP3\"; echo TAILZZSP3'
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
printf '%s\n' 'Authorization: secretValue127 "payload127"; echo "KEEP4"'
printf '%s\n' 'Authorization: secretValue130; echo "KEEP5"'
printf '%s\n' 'Authorization: secretPipe90201 | grep keepPipe90201'
printf '%s\n' 'Authorization: secretPipeTail90202|grep keepPipeTail90202'
printf '%s\n' 'Authorization: Bearer secretBearerPipe90203 | grep keepBearerPipe90203'
printf '%s\n' 'Authorization: Bearer secretBearerPipeTail90204|grep keepBearerPipeTail90204'
printf '%s\n' 'Authorization: secretAmp90205 && echo keepAmp90205'
printf '%s\n' 'Authorization: secretAmpTail90206&&echo keepAmpTail90206'
printf '%s\n' 'Authorization: Bearer secretBearerAmp90207 && echo keepBearerAmp90207'
printf '%s\n' 'Authorization: Bearer secretBearerAmpTail90208&&echo keepBearerAmpTail90208'
printf '%s\n' 'Authorization: secretOr90209 || echo keepOr90209'
printf '%s\n' 'Authorization: Bearer secretBearerOr90210 || echo keepBearerOr90210'
printf '%s\n' 'Authorization: secretRedirect123456 > out.txt'
printf '%s\n' 'Authorization: secretRedirectTail123456>out.txt'
printf '%s\n' 'Authorization: secretRedirectDouble123456 >> out.txt'
printf '%s\n' 'Authorization: Bearer secretBearerRedirect123456 > out.txt'
printf '%s\n' 'Authorization: Bearer secretBearerRedirectTail123456>out.txt'
printf '%s\n' 'Authorization: secretInput123456 < in.txt'
printf '%s\n' 'Authorization: Bearer secretHere123456 <<EOF'
printf '%s\n' 'Authorization: splitRedirect123456 > out.txt; Authorization: splitBare123456'
# Fd-prefixed redirections must stay outside the masked credential. The
# synthetic tokens are secret-shaped without matching the privacy scanner.
printf '%s\n' 'Authorization: SYNTHFDSECRET 2>err'
printf '%s\n' 'Authorization: SYNTHPLAINSECRET >out'
printf '%s\n' 'Authorization: SYNTHFDSTDERR 2>&1'
printf '%s\n' 'Authorization: SYNTHFDSTDIN 0<in'
printf '%s\n' 'Authorization: SYNTHFDFD10 10>out'
printf '%s\n' 'Authorization: SYNTHFDAPPEND 3>>err'
printf '%s\n' 'Authorization: SYNTHFDSPACE 2> err'
printf '%s\n' 'Authorization: Bearer SYNTHFDBEARER 2>err'
printf '%s\n' 'Authorization: Bearer SYNTHFDSCHEMED10 10>out'
printf '%s\n' 'Authorization: SYNTHFDSPLIT 2>err; Authorization: SYNTHFDBARE'
printf '%s\n' 'Authorization: SYNTHFDNUM123 2>err'
printf '%s\n' 'Authorization: SYNTHFDTAIL456>out'
printf '%s\n' 'Authorization: SYNTHFDFD123 123>out'
printf '%s\n' 'Authorization: Bearer SYNTHFDSCHEMED123 123>out'
printf '%s\n' 'Authorization: SYNTHFDGAP 2 >err'
printf '%s\n' 'Authorization: Bearer SYNTHFDSCHEMEGAP 2 >err'
# Padded base64 values end at the shell operator; the tail must stay visible.
printf '%s\n' 'Authorization: Basic dXNlcjpwYXNz== > out'
printf '%s\n' 'Authorization: Bearer SYNTHAUTHPAD1==; echo KEEPAUTHPAD1'
printf '%s\n' 'Authorization: Bearer SYNTHAUTHPAD2== 2>err; echo KEEPAUTHPAD2'
printf '%s\n' 'Authorization: Bearer SYNTHMIXAUTH1;token=SYNTHMIXAUTH2; echo KEEPMIXAUTH'
printf '%s\n' 'Authorization: Bearer SYNTHMIXAUTH3,token=SYNTHMIXAUTH4; echo KEEPMIXAUTH2'
printf '%s\n' 'Authorization: Bearer SYNTHMIXAUTH5;token=SYNTHMIXAUTH6;token2=SYNTHMIXAUTH7; echo KEEPMIXAUTH3'
# A case-variant internal marker is opaque text, not a recognized chain boundary.
printf '%s\n' 'Authorization: Bearer SYNTHCASEMARK1;token=SYNTHCASEMARK2;@lmline_chain_key@;:token2=SYNTHCASEMARK3; echo KEEPCASEMARK'
# A pasted internal URL marker must not survive into the prompt.
printf '%s\n' 'url=https://u:@@LMLINE_URL_REDACTED@@@host/path; echo KEEPPASTEDURLMARK'
printf '%s\n' 'url=https://u:@@LmLiNe_Url_ReDaCtEd@@@host/path; echo KEEPPASTEDURLMARKCASE'
# Pasted internal markers must not reach the model prompt, in any casing.
printf '%s\n' 'echo KEEPPASTEDREDMARK @@LmLINE_Redacted@@ KEEPPASTEDREDTAIL'
printf '%s\n' 'echo KEEPPASTEDCHAINMARK @LmLINE_ChAiN_kEy@ KEEPPASTEDCHAINTAIL'
printf '%s\n' 'echo KEEPPASTEDSEPMARK @LmLINE_SeP@ KEEPPASTEDSEPTAIL'
# A known Authorization scheme may be followed by '=' and a quoted value.
printf '%s\n' 'Authorization: Bearer="SYNTHEQSDQ1"; echo KEEPEQSDQ1'
printf '%s\n' "Authorization: Bearer='SYNTHESQSQ1'; echo KEEPEQSQ1"
printf '%s\n' 'authorization: bearer="SYNTHEQSCASE1" && echo KEEPEQSCASE'
printf '%s\n' 'Authorization: Basic="SYNTHEQSESC1\"TAIL"; echo KEEPEQSESC'
printf '%s\n' 'Authorization: Bearer="SYNTHEQUNTERM1'
printf '%s\n' "Authorization: Bearer='SYNTHEQUNTERM2"
printf '%s\n' 'Authorization: Bearer="SYNTHEQTBACK1\'
printf '%s\n' "Authorization: Bearer='SYNTHEQTBACK2\\"
printf '%s\n' 'Authorization: Bearer="SYNTHEQCHAIN1";token=SYNTHEQCHAIN2; echo KEEPEQCHAIN'
# Contiguous quoted segments after a known scheme are one credential value.
printf '%s\n' 'Authorization: Bearer=\"SYNTHAUDSEG1\"\"SYNTHAUDSEG2\"; echo KEEPAUDSEG1'
printf '%s\n' "Authorization: Bearer=\\'SYNTHAUDSEG3\\'\\'SYNTHAUDSEG4\\'; echo KEEPAUDSEG2"
printf '%s\n' 'Authorization: Bearer="SYNTHAUDSEG5""SYNTHAUDSEG6"; echo KEEPAUDSEG3'
printf '%s\n' "Authorization: Bearer='SYNTHAUDSEG7''SYNTHAUDSEG8'; echo KEEPAUDSEG4"
printf '%s\n' 'Authorization: Bearer="SYNTHAUDSEG9";token=SYNTHAUDSEG10; echo KEEPAUDSEG5'
printf '%s\n' 'Authorization: Bearer="SEEDFIRST""SYNTH SPACE1"; echo KEEPSEGSPACE1'
printf '%s\n' "Authorization: Bearer='SEEDFIRST''SYNTH SPACE2'; echo KEEPSEGSPACE2"
printf '%s\n' 'Authorization: Bearer=\\"SEEDFIRST\\"\\"SYNTH SPACE3\\"; echo KEEPSEGSPACE3'
printf '%s\n' 'Authorization: Bearer="SEEDFIRST""SYNTH SPACE4"; echo "KEEPSEGSPACE4"'
printf '%s\n' 'Authorization: Bearer=FIRST"SYNTH UPQ1"; echo KEEPUPQ1'
printf '%s\n' "Authorization: Bearer=FIRST'SYNTH UPQ2'; echo KEEPUPQ2"
printf '%s\n' 'Authorization: Bearer=FIRST"SYNTH UPQ3"; echo "KEEPUPQ3"'
printf '%s\n' 'Authorization: Bearer=FIRST"SYNTH UPQ4";token=SYNTHUPQKEY; echo KEEPUPQ4'
printf '%s\n' 'Authorization: Bearer=FIRST"SYNTHUPQ5"; Authorization: Bearer=SECOND"SYNTHUPQ6"; echo KEEPUPQ5'
printf '%s\n' 'Authorization: Bearer=FIRST"SYNTHUPQ7" | grep KEEPUPQ7'
printf '%s\n' 'Authorization: Bearer=FIRST"SYNTHUPQ8""SYNTHUPQ9"; echo KEEPUPQ8'
printf "%s\n" "Authorization: Bearer=FIRST'SYNTHUPQ10'; Authorization: Basic=SECOND'SYNTHUPQ11'; echo KEEPUPQ10"
printf "%s\n" "Authorization: Bearer=AAA'SYNTHUPQESC1'; Authorization: Basic=BBB\\\"SYNTHUPQESC1\\\"; echo KEEPUPQESC1"
printf "%s\n" "Authorization: Bearer=AAA'SYNTHUPQESC2'; Authorization: Basic=BBB\\\\\"SYNTHUPQESC2\\\\\"; echo KEEPUPQESC2"
printf "%s\n" "Authorization: Bearer=AAA'SYNTHUPQESC3'; Authorization: Basic=BBB'SYNTHUPQESC3'; echo KEEPUPQESC3"
# Repeated headers with any scheme token must each be masked, including a
# single custom header; URL realm keys and Digest parameters are controls.
printf '%s\n' 'Authorization: Bearer=FIRST\"SYNTHCUSTM1\"; Authorization: Custom=SECOND\"SYNTHCUSTM2\"; echo KEEPCUSTOM1'
printf '%s\n' 'Authorization: Custom=ONLY\"SYNTHCUSTM3\"; echo KEEPCUSTOM2'
printf '%s\n' 'Authorization: X-OAuth2=FIRST\"SYNTHXAUTH1\"; Authorization: X-OAuth2=SECOND\"SYNTHXAUTH2\"; echo KEEPCUSTOM3'
# Opposite-family quotes inside escaped credentials must not split the value.
printf '%s\n' 'Authorization: Bearer=abc\"tok'\''LEAKAPOSTROPHE987"end; echo KEEPTAIL'
printf '%s\n' 'Authorization: Custom=abc\"tok'\''LEAKAPOSTROPHE988\"end; echo KEEPTAIL'
printf '%s\n' "Authorization: Bearer=abc\\'tok\"LEAKDQUOTE989\\'end; echo KEEPTAIL"
# Quoted custom-scheme -H tails must survive byte-for-byte in both quote families.
printf '%s\n' "curl -H 'Authorization: Custom=WORD\\\"SYNTHCUSTOMQH1\\\"' -H 'X: keep' https://example.test; echo KEEPQHCUSTOM1"
printf '%s\n' 'curl -H "Authorization: Custom=WORD\"SYNTHCUSTOMQH2\"" https://example.test; echo KEEPQHCUSTOM2'
printf '%s\n' 'url=https://x/?realm=\"example.com\"; echo KEEPTAIL5'
printf '%s\n' 'Authorization: Digest realm=\"example.com\", nonce=\"abc123\"; echo KEEPTAIL4'
# The separator between a known scheme and its quoted value may be ':' or repeated.
printf '%s\n' 'Authorization: Bearer:"SYNTHCOLSDQ1"; echo KEEPCOLSDQ1'
printf '%s\n' "Authorization: Basic=='SYNTHCOLSQ2'; echo KEEPCOLSQ2"
printf '%s\n' 'Authorization: Digest:="SYNTHCOLREP3"; echo KEEPCOLREP3'
printf '%s\n' 'Authorization: Bearer:"SYNTHCOLUNTERM4'
# A known scheme separator may precede a literal backslash-escaped quote.
printf '%s\n' 'Authorization: Bearer=\"SYNTHESESDQ1\"; echo KEEPESESDQ1'
printf "%s\n" "Authorization: Bearer=\\'SYNTHESESQ1\\'; echo KEEPESESQ1"
printf '%s\n' 'Authorization: Bearer==\"SYNTHESESDQ2\" | echo KEEPESESDQ2'
printf "%s\n" "Authorization: Bearer:\'SYNTHESESQ2\' >> out; echo KEEPESESQ2"
printf '%s\n' 'authorization: bearer=\"SYNTHESESDQCASE\" && echo KEEPESESDQCASE'
printf '%s\n' 'Authorization: Bearer=\"SYNTHESESDQ3\"'
# Unterminated escaped quotes after a known scheme still mask the credential.
printf '%s\n' 'Authorization: Bearer=\"SYNTHUNTERMDPQ1'
printf "%s\n" "Authorization: Bearer=\\'SYNTHUNTERMSQ1"
# An escaped opening quote at EOL may be followed by an even or odd number of backslashes.
printf '%s\n' 'Authorization: Bearer=\"SYNTHTRAILDDQ0'
printf '%s\n' 'Authorization: Bearer=\"SYNTHTRAILDDQ1\'
printf '%s\n' 'Authorization: Bearer=\"SYNTHTRAILDDQ2\\'
printf '%s\n' 'Authorization: Bearer=\"SYNTHTRAILDDQ3\\\'
printf "%s\n" "Authorization: Bearer=\\'SYNTHTRAILSQ0"
printf "%s\n" "Authorization: Bearer=\\'SYNTHTRAILSQ1\\"
printf "%s\n" "Authorization: Bearer=\\'SYNTHTRAILSQ2\\\\"
printf "%s\n" "Authorization: Bearer=\\'SYNTHTRAILSQ3\\\\\\"
# URL query key values may be plain or backslash-escaped quotes.
printf '%s\n' 'url=https://x/?token="SYNTHQURL1"&y=1; echo KEEPQURL1'
printf "%s\n" "url=https://x/?secret='SYNTHQURL2'&y=2; echo KEEPQURL2"
printf '%s\n' 'url=https://x/?token=\"SYNTHQURL3\"&y=3; echo KEEPQURL3'
printf "%s\n" "url=https://x/?api_key=\'SYNTHQURL4\'&y=4; echo KEEPQURL4"
printf '%s\n' 'curl "https://x/?token=\"SYNTHQURL5\"&y=5"; echo KEEPQURL5'
printf '%s\n' 'url=https://x/?token=\"SYNTHQURL6\"'
# Credential keys may be wrapped in literal escaped quotes in URLs.
printf '%s\n' 'url=https://x/?\"token\"="SYNTHESCKQ1"&y=1; echo KEEPESCKQ1'
printf '%s\n' 'url=https://x/?\'"'"'secret\'"'"'='"'"'SYNTHESCKQ2'"'"'&y=2; echo KEEPESCKQ2'
printf '%s\n' 'url=https://x/?\"api_key\"='"'"'SYNTHESCKQ3'"'"'&y=3; echo KEEPESCKQ3'
printf '%s\n' 'curl "https://x/?\"token\"="SYNTHESCKQ4"&y=4"; echo KEEPESCKQ4'
printf '%s\n' 'url=https://x/?\"token\"=SYNTHESCKQ5&y=5; echo KEEPESCKQ5'
# Adjacent escaped value segments must not leak after the key quotes are canonicalized.
printf '%s\n' 'url=https://x/?\"token\"=\"a\"\"SYNTHESCADJ1\"&y=1; echo KEEPESCADJ1'
printf '%s\n' 'url=https://x/?\"token\"=\"\"\"SYNTHESCADJ2\"&y=2; echo KEEPESCADJ2'
printf '%s\n' 'url=https://x/?\"token\"=\"prefix\"\"SYNTHESCADJ3\"&y=3; echo KEEPESCADJ3'
printf "%s\n" "url=https://x/?\\'token\\'=\\'a\\'\\'SYNTHESCADJ4\\'&y=4; echo KEEPESCADJ4"
# Plain URL keys: adjacent escaped quoted segments are one value.
printf '%s\n' 'url=https://x/?token=\\"a\\"\\"SYNTHADJPLAIN1\\"&y=1; echo KEEPADJPLAIN1'
printf "%s\n" "url=https://x/?token=\\\\'a\\\\'\\\\'SYNTHADJPLAIN2\\\\'&y=2; echo KEEPADJPLAIN2"
printf '%s\n' 'url=https://x/?token=\\"a&b\\"&y=3; echo KEEPADJPLAIN3'
printf '%s\n' 'url=https://x/?token=\\"a\\"&other_token=\\"b\\"&y=4; echo KEEPADJPLAIN4'
# Doubled credential-key separators must still mask the quoted value.
printf '%s\n' 'url=https://x/?token:="SYNTHDOUBLE1"'
printf '%s\n' 'url=https://x/?token:="SYNTHDOUBLE2"&y=1; echo KEEPTAIL'
printf "%s\n" "url=https://x/?token=='SYNTHDOUBLE3'"
printf '%s\n' 'url=https://x/?api_key::"SYNTHDOUBLE4"&y=2; echo KEEPDOUBLE4'
# Spaced doubled credential-key separators must still mask the value.
printf '%s\n' 'url=https://x/?token : = SYNTHSPACED1'
printf '%s\n' 'url=https://x/?token : = "SYNTHSPACED2"&y=1; echo KEEPTAIL'
printf "%s\n" "url=https://x/?api_key :: 'SYNTHSPACED3'"
printf '%s\n' 'url=https://x/?realm : = "example.com"; echo KEEPREALM'
# URL-embedded Authorization keys must mask values after any separator form.
printf '%s\n' 'url=https://x/?Authorization:="SYNTHAUTHURL1"'
printf '%s\n' 'url=https://x/?Authorization="SYNTHAUTHURL2"&y=1; echo KEEPTAIL'
printf '%s\n' 'url=https://x/?Authorization=SYNTHAUTHURL3'
printf '%s\n' 'url=https://x/?Authorization : = SYNTHAUTHURL4'
printf '%s\n' 'url=https://x/?Authorization=realm="example.com"; echo KEEPURLAUTH'
# A credential value with unequal escape depth still leaves the next credential field intact.
printf '%s\n' 'url=https://x/?token=\"SYNTHKEEPUNEQ1\"&password=\\\"SYNTHKEEPUNEQ2\"&y=2; echo KEEPUNEQ'
printf '%s\n' 'url=https://x/?token=\"FRST\"&password=\\"\\"SECNEXT\\"&y=1; echo KEEPESEMPTYDQ'
printf '%s\n' "url=https://x/?token=\\\\'FRST\\\\'&secret=\\\\'\\\\'SECNEXTE\\\\'&y=2; echo KEEPESEMPTYSQ"
printf '%s\n' 'url=https://x/?token=\\"FRST\\"&password=\\\\"\\\\"SECNEXT WITH SPACE\\\\"&y=1; echo KEEPURLDQSPACE'
printf '%s\n' "url=https://x/?token=\\\\'FRST\\\\'&secret=\\\\'\\\\'SECNEXT SQ SPACE\\\\'&y=2; echo KEEPURLSQSPACE"
# Escaped credential keys leave the following credential field intact in both quote families.
printf '%s\n' 'url=https://x/?\"token\"=\"SYNTHKEEPESCQ1\"&password=SYNTHKEEPESCQ2; echo KEEPESCQ'
printf '%s\n' 'url=https://x/?\"token\"=\"SYNTHKEEPSEMI\";password=SYNTHKEEPSEMIV; echo KEEPSEMI'
printf '%s\n' 'url=https://x/?\"token\"=\"SYNTHKEEPCOMMA\",password=SYNTHKEEPCOMMAV; echo KEEPCOMMA'
printf "%s\n" "url=https://x/?\\'token\\'=\\'SYNTHKEEPESCSQ1\\'&password=SYNTHKEEPESCSQ2; echo KEEPESCSQ"
# Fresh synthetic secrets in adjacent escaped segments must be consumed fail closed.
printf '%s\n' 'url=https://x/?\"token\"=\"a\"\"SYNTHADJGUARD1\"&y=1; echo KEEPADJGUARD1'
printf "%s\n" "url=https://x/?\\'token\\'=\\'a\\'\\'SYNTHADJGUARD2\\'&y=2; echo KEEPADJGUARD2"
printf '%s\n' 'Authorization: secretValue131 "payload131"'
printf '%s\n' 'curl -H "Authorization: secretValue128" "payload128" https://x'
printf '%s\n' 'Authorization: tokenWithHash#9002 "payload9002"; echo "K9002"'
printf '%s\n' 'Authorization: tokenWithBack\slash9003 "payload9003"; echo "K9003"'
printf '%s\n' 'Authorization: DPoP "realDpopSecret123456" https://x'
printf '%s\n' 'Authorization: WSSE "realWsseSecret123456" https://x'
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
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb tailBearer9038" -H "X: keep" https://example.test'
printf '%s\n' 'curl -H "Authorization: abc""pa\\\"inside space""pb tailEOL9039"'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"; echo "KEEP07"'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT08", "KEEP08"'
# An operator immediately after an orphaned quoted tail is a word boundary:
# the tail must be discarded while the operator and its command survive.
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT09"| :'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT10">out'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT11">>out'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT12"<in'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT13" >out'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT14"; :'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT15"2>err'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT16"2>&1'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT17"1>>out'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT18"10>out'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT19"& :'
printf '%s\n' 'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT20"&& :'
printf '%s\n' "curl -H 'Authorization: Bearer abc'\"'pa\\\"inside space'\"'pb TAILAUDIT02'"
# An escaped quoted value ends at the unescaped quote that closes the header:
# the closing quote, URL and trailing command must survive redaction.
printf '%s\n' 'curl -H "Authorization: Bearer=AAA'"'"'FIRSTSECRET'"'"'; Authorization: Basic=BBB\"SECONDSECRET\"" https://x; echo KEEPTAIL'
printf '%s\n' 'curl -H '"'"'Authorization: Basic=BBB\"ONLYSECRET\"'"'"' -H '"'"'X: keep'"'"' https://x; echo KEEPTAIL'
printf '%s\n' 'curl -H "Authorization: Bearer=AAA\"SINGLESECRET\"" https://x; echo KEEPTAIL'
# An adjacent tail after the closing header quote must survive.
printf '%s\n' 'curl -H "Authorization: Bearer=abc\\\"tokSECRETADJQ\\\""2>err; echo KEEPTAILADJQ'
printf '%s\n' "curl -H 'Authorization: Bearer=abc\\\\'tokSECRETADJS\\\\''2>err; echo KEEPTAILADJS"
# A shell quote immediately after an escaped pair must also keep its tail.
printf '%s\n' "curl -H 'Authorization: Bearer=abc\\\"tokSECRETADJPQ\\\"'2>err; echo KEEPTAILADJPQ"
printf '%s\n' "curl -H \"Authorization: Bearer=abc\\'tokSECRETADJSQ\\'\"2>err; echo KEEPTAILADJSQ"
printf '%s\n' 'curl -H "Authorization: Bearer:abc\'"'"'\"'"'"'SECRETZZ\'"'"'"X; echo KEEPTAIL'
printf '%s\n' 'curl -H '"'"'Authorization: Bearer:abc\"\'"'"'"SECRETMM\"'"'"'X; echo MIRRORTAIL'
printf '%s\n' 'curl -H"Authorization: Bearer:abc\'"'"'\"'"'"'SECRETZZ\'"'"'"X; echo KEEPTAIL'
printf '%s\n' 'curl -H'"'"'Authorization: Bearer:abc\"\'"'"'"SECRETMM\"'"'"'X; echo KEEPTAIL'
printf '%s\n' 'Authorization: Bearer:abc\'"'"'\"'"'"'LEAKMIN987\'"'"'\" -H "X: keep" https://x; echo KEEPTAIL'
printf '%s\n' 'Authorization: Bearer:abc\"\'"'"'"LEAKMIRROR988\"\'"'"' -H '"'"'X: keep'"'"' https://x; echo KEEPTAIL'
# An escaped opening quote before a bare secret must keep the real closing quote and tail.
printf '%s\n' 'curl -H "Authorization: Bearer=abc\">SYNTHCLOSURE901"2>err; echo KEEPTAILCLOSURE1'
printf '%s\n' 'curl -H"Authorization: Bearer:abc\">SYNTHCLOSURE902"2>err; echo KEEPTAILCLOSURE2'
printf '%s\n' 'curl -H "Authorization: Custom=abc\">SYNTHCLOSURE903" https://x; echo KEEPTAILCLOSURE3'
# A scheme separator followed by spaces still masks the Authorization value.
printf '%s\n' 'Authorization: Bearer: SYNTHSEP901; echo KEEPSEPTAIL1'
printf '%s\n' 'Authorization: Bearer= SYNTHSEP902; echo KEEPSEPTAIL2'
printf '%s\n' 'Authorization: Basic: SYNTHSEP903; echo KEEPSEPTAIL3'
printf '%s\n' 'curl -H "Authorization: Bearer: SYNTHSEP904" https://x; echo KEEPSEPTAIL4'
# A glued scheme value followed by another word keeps that word and the tail.
printf '%s\n' 'Authorization: Bearer=SYNTHGLUED901 https://x; echo KEEPGLUEDTAIL1'
printf '%s\n' 'Authorization: Basic:abcSYNTHGLUED902 foo; echo KEEPGLUEDTAIL2'
# Quoted headers must keep the following quoted argument while masking the value.
# A quoted header with a spaced separator must mask even at EOL or before a shell operator.
printf '%s\n' 'curl -H "Authorization: Bearer: SYNTHQSEP911"; echo KEEPQSEPTAIL11'
printf '%s\n' "curl -H 'Authorization: Basic= SYNTHQSEP912'; echo KEEPQSEPTAIL12"
printf '%s\n' 'curl -H"Authorization: Bearer: SYNTHQSEP913"; echo KEEPQSEPTAIL13'
printf '%s\n' "curl -H'Authorization: Token= SYNTHQSEP914'; echo KEEPQSEPTAIL14"
printf '%s\n' 'curl -H "Authorization: Basic: SYNTHQSEP915"'
printf '%s\n' 'curl -H "Authorization: Bearer:*SYNTHSTAR911"; echo KEEPSTAR911'
printf "%s\\n" "curl -H 'Authorization: Basic:@SYNTHAT912'; echo KEEPAT912"
printf '%s\n' 'curl -H "Authorization: Bearer:**SYNTHSTAR913"; echo KEEPSTAR913'
printf '%s\n' 'curl -H "Authorization: Bearer: @@SYNTHAT914"; echo KEEPAT914'
printf '%s\n' 'curl -H "Authorization: Bearer=*SYNTHSTAR921"; echo KEEP921'
printf "%s\\n" "curl -H 'Authorization: Basic:*SYNTHSTAR922'; echo KEEP922"
printf "%s\\n" "curl -H 'Authorization: Basic:@SYNTHAT923'; echo KEEP923"
printf '%s\n' 'Authorization: abc: SYNTHGENSC901; echo KEEPGENSC901'
printf '%s\n' 'curl -H "Authorization: abc: SYNTHGENSC902"; echo KEEPGENSC902'
printf '%s\n' 'Authorization: abc=\"SYNTHGESC001\"; echo KEEPGESTAIL1'
printf "%s\n" "Authorization: abc=\\'SYNTHGESC002\\'; echo KEEPGESTAIL2"
printf "%s\n" "curl -H 'Authorization: abc=\\'SYNTHGESC003\\''; echo KEEPGESTAIL3"
printf '%s\n' 'curl -H "Authorization: abc=\"SYNTHGESC004\""; echo KEEPGESTAIL4'
printf '%s\n' 'curl -H "Authorization: Bearer: SYNTHARG901" -H "X: keep" https://x; echo KEEPARGTAIL1'
printf '%s\n' 'curl -H "Authorization: Bearer: SYNTHEOL1001"'
printf '%s\n' 'curl -H "Authorization: Bearer: abc***REDACTED***xyz"; echo KEEPZZ'
printf "%s\\n" "curl -H 'Authorization: Bearer: abc***REDACTED***xyz'; echo KEEPZZ"
printf '%s\n' 'curl -H "Authorization: Bearer: ***REDACTED***" -H "Authorization: Bearer: REALSECRET89"; echo KEEPZZ9'
printf "%s\\n" "curl -H 'Authorization: Bearer: ***REDACTED***' -H 'Authorization: Bearer: REALSECRET89'; echo KEEPZZ9"
# A credential may end with a marker spelling; only a canonical already-redacted
# value is exempt from redaction. The shell tail must survive in every case.
printf '%s\n' 'curl -H "Authorization: Bearer: REALSECRET941***REDACTED***"; echo KEEPENDRED1'
printf "%s\\n" "curl -H 'Authorization: Bearer: REALSECRET942***REDACTED***'; echo KEEPENDRED2"
printf '%s\n' 'curl -H "Authorization: Bearer: REALSECRET943@@LMLINE_REDACTED@@"; echo KEEPENDRED3'
printf "%s\\n" "curl -H 'Authorization: Bearer: REALSECRET944@@LMLINE_REDACTED@@'; echo KEEPENDRED4"
printf '%s\n' 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x; echo KEEP88'
printf '%s\n' 'curl -H "Authorization: Bearer "1234567890; echo KEEPNUM1'
printf "%s\\n" "curl -H 'Authorization: Bearer '1234567890; echo KEEPNUM2"
printf '%s\n' 'curl -H "Authorization: Bearer "SECRETABC123; echo KEEPNUM3'
printf "%s\\n" "curl -H 'Authorization: Bearer: SYNTHEOL1002'"
printf '%s\n' 'curl -H "Authorization: Basic: SYNTHEOL1003"'
printf '%s\n' 'curl -H '"'"'Authorization: Basic=SYNTHARG902'"'"' -H '"'"'X: keep'"'"' https://x; echo KEEPARGTAIL2'
printf '%s\n' 'curl -H "Authorization: Basic: SYNTHARG903" "payload903" https://x; echo KEEPARGTAIL3'
printf '%s\n' 'curl -H '"'"'Authorization: Bearer=SYNTHARG904'"'"' '"'"'payload904'"'"' https://x; echo KEEPARGTAIL4'
printf '%s\n' 'Authorization: Bearer=\"SYNTHBAREQUOTED4\"; echo KEEPTAILBARE'
# An interior bare quote is part of the escaped value, not its closing quote.
printf '%s\n' 'Authorization: Bearer=AAA\"don'"'"'tSECRET\"; echo KEEP6'
printf '%s\n' 'curl -H "Authorization: Bearer secret123456" "payload123" https://x'
printf '%s\n' 'curl -H "Authorization: Bearer secret123456" "user@host" "other" https://x'
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
printf '%s\n' 'token=SYNTHSEMIKEY; echo KEEPSEMIFIX'
printf '%s\n' 'TOKEN=SYNTHSEMIKEY2; echo KEEPSEMI2FIX'
printf '%s\n' 'api_key=SYNTHSEMIKEY3; echo KEEPAPIFIX'
printf '%s\n' '"token=SYNTHSEMIKEY"; echo KEEPQUOTEDFIX'
printf '%s\n' "'token=SYNTHSEMIKEY'; echo KEEPQUOTED2FIX"
printf '%s\n' 'token=SYNTHSECRETFIRST; password=SYNTHSECRETSECOND; echo KEEP_TWO'
printf '%s\n' 'token=SYNTHMULTI1; password=SYNTHMULTI2; key=SYNTHMULTI3; echo KEEP_MULTI'
printf '%s\n' 'token=abc;defFIX'
printf '%s\n' 'token=SYNTHSEMIKEY;token2=SYNTHSEMIKEY2; echo KEEPDOUBLEFIX'
printf '%s\n' 'echo token=SYNTHCHAIN;token2=SYNTHCHAIN2; echo KEEPCHAIN'
printf '%s\n' 'echo token=abc;defFIX'
printf '%s\n' 'echo token=abc;def=SYNTHCHAINLEAK; echo KEEPCHAINLEAK'
printf '%s\n' 'token=SYNTHCHAIN3A;token2=SYNTHCHAIN3B;token3=SYNTHCHAIN3C; echo KEEPCHAIN3'
printf '%s\n' 'token=SYNTHCOMMA1,token2=SYNTHCOMMA2, echo KEEPCOMMA'
printf '%s\n' 'token=SYNTHMIX1,token2=SYNTHMIX2;token3=SYNTHMIX3; echo KEEPMIXCHAIN'
printf '%s\n' 'token=SYNTHMIX4;token2=SYNTHMIX5,token3=SYNTHMIX6, echo KEEPMIXCHAIN2'
printf '%s\n' 'token = SYNTHSPACE1;token2 = SYNTHSPACE2; echo KEEPSPACEKEY'
printf '%s\n' '"token":SYNTHDQKEY1;"password":SYNTHDQKEY2; echo KEEPDQKEY'
printf '%s\n' "'test_key':SYNTHSQKEY1,'api_key':SYNTHSQKEY2, echo KEEPSQKEY"
printf '%s\n' '"token":SYNTHDQOPAQUE;defTAILQUOTED; echo KEEPQUOTEDOPAQUE'
printf '%s\n' 'token=SYNTHAMPKEY1&token2=SYNTHAMPKEY2& echo KEEPAMPKEY'
printf '%s\n' 'token=SYNTHPIPEKEY1|token2=SYNTHPIPEKEY2; echo KEEPPIPEKEY'
printf '%s\n' 'token=SYNTHAMPOPAQUE&defTAILAMP& echo KEEPAMPOPAQUE'
printf '%s\n' 'token=SYNTHPIPEOPAQUE|defTAILPIPE; echo KEEPPIPEOPAQUE'
printf '%s\n' 'token=SYNTHCOMMAOPAQUE,defTAILCOMMA, echo KEEPCOMMAOPAQUE'
printf '%s\n' 'token=SYNTHOPAQUE;defTAILCHAIN; echo KEEPOPAQUE'
printf '%s\n' 'token=ghp_SYNTHSEMI; echo KEEPKEYSemiFIX'
printf '%s\n' 'token=SYNTHPIPE | grep KEEPPIPEFIX'
printf '%s\n' '{"2fa_secret": "SUPERSECRET123", "123api_token": "ANOTHERSECRET456"}'
printf '%s\n' 'error: failed'
printf '%s\n' 'Authorization: Bearer "backslashBearerOdd901\'
printf '%s\n' 'Authorization: "backslashSchemeLessOdd902\'
printf '%s\n' "Authorization: 'backslashSingleOdd903\\"
printf '%s\n' "MY_TOKEN='backslashKeyOdd904\\"
printf '%s\n' 'Authorization: continuationSecret444444\'
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
printf '%s\n' 'curl "https://x/?token=abcLitQ9006?defLitQ9006&y=2"'
printf '%s\n' 'echo x;token=abcShellLitQ9007?defShellLitQ9007'
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
printf '%s\n' 'a=("https://x/?q=;//u:pArrayData@one.example.test");//u:realArray@two.example.test'
printf '%s\n' 'foo("https://x/?q=;//u:pParenData@one.example.test");//u:realParen@two.example.test'
printf '%s\n' 'echo {"url":"https://x/?q=;//u:pAnchorData@one.example.test"};//u:realAnchor@two.example.test'
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
printf '%s\n' 'curl \"https://example.test/?q=a;//user:SYNTHESCAPE1@host/KEEPE1\" -H \"X: keepHeader\"'
printf '%s\n' 'curl \"https://example.test/?q=a,//user:SYNTHESCAPE2@host/KEEPE2\" -H \"X: keepHeader\"'
printf '%s\n' '{\"url\":\"https://x/?q=;//user:SYNTHESCAPE3@host/KEEPE3\",\"keep\":\"keepValue\"}'
printf '%s\n' 'curl \"https://example.test/?q=a;//user:SYNTHESCAPE4@host/KEEPE4;b=;//user:SYNTHESCAPE4B@host/KEEPE4B\" -H \"X: keepHeader\"'
printf '%s\n' 'curl \"https://user:SYNTHREAL@host/x?q=KEEPREAL\"'
printf '%s\n' 'echo \"q\";//user:SYNTHSEP@host/KEEPSEP'
printf '%s\n' 'echo a;\"https://x/?q=a;//user:SYNTHBND1@host/KEEPBND1\"'
printf '%s\n' 'echo a|\"https://x/?q=a;//user:SYNTHBND2@host/KEEPBND2\"'
printf '%s\n' 'echo a&\"https://x/?q=a;//user:SYNTHBND3@host/KEEPBND3\"'
printf '%s\n' 'echo a#\"https://x/?q=a;//user:SYNTHBND4@host/KEEPBND4\"'
printf '%s\n' 'foo(\"https://x/?q=a;//user:SYNTHBND5@host/KEEPBND5\")'
printf '%s\n' 'echo a;\"https://x/?q=a;//user:SYNTHBNDDATA@one\";//user:SYNTHREALBND@evil'
printf '%s\n' 'echo \"note;//user:SYNTHURLGATE1@host; echo \"'
printf '%s\n' 'printf %s \"key;//user:SYNTHURLGATE2@host; date\"'
printf '%s\n' 'echo \"a,b;//user:SYNTHURLGATE3@h\"'
printf '%s\n' 'curl \"https://ok/x\" \"note;//user:SYNTHARG@host\"'
printf '%s\n' 'echo \"https://ok/x; echo note;//user:SYNTHLEAK@host; echo \"'
printf '%s\n' 'curl \"https://ok/x?q=a\" \"a,b;//user:SYNTHARG3@h\"'
printf '%s\n' 'echo \"x:// ;//user:SYNTHDEGEN@host\"'
printf '%s\n' 'echo \"x://;//user:SYNTHZERO@host\"'
printf '%s\n' 'echo \"x://,//user:SYNTHZEROC@host\"'
printf '%s\n' "echo 'x://;//user:SYNTHSQZERO@host'"
printf '%s\n' 'echo \"https://ok/x\";//user:SYNTHBQ@host\"'
printf '%s\n' 'curl \"https://ok/x\";//user:SYNTHBQC@host\"'
printf '%s\n' 'echo \"https://ok/x\"a;//user:SYNTHBQA@host\"'
printf '%s\n' 'echo \"https://ok/x\"note;//user:SYNTHBQN@host\"'
printf '%s\n' 'curl \"https://x/?q=a!;//user:TOKENBANG@host/KEEP\"'
printf '%s\n' 'echo \"https://x/?q=a*;//user:TOKENSTAR@host/KEEP\"'
printf '%s\n' 'echo \"see https://x/?q=a;//user:TOKENPREFIX@host/KEEP\"'
printf '%s\n' 'curl \"--url https://x/?q=a;//user:TOKENARG@host/KEEP\"'
printf '%s\n' 'echo \"prefix https://x/?q=a,//user:TOKENCOMMA@host/KEEP\"'
printf '%s\n' 'curl "https://ok/x";//user:SYNTHPLAINLEAK@host"'
printf '%s\n' "echo 'https://ok/x';//user:SYNTHSQLOCK@host'"
printf '%s\n' 'curl "https://ok/x",//user:SYNTHPLAINCOMMA@host"'
printf '%s\n' 'curl \"https://x/?q=a;//user:SYNTHMIXCLOSE@host/KEEP\"'
printf '%s\n' 'curl \"https://x/?q=a;//user:SYNTHMIXOPEN@host/KEEP\"'
printf '%s\n' 'curl "https://x/?q=a;//user:SYNTHMIXCLOSE2@host/KEEP\"'
printf '%s\n' 'curl "https://x/?q=a,//user:SYNTHMIXCLOSE3@host/KEEP\"'
# Paired boundary battery: quoted URL data stays byte-for-byte; the same
# separator after a closed quote fully redacts its paired token.
printf '%s\n' 'curl "https://x/?q=a;//user:SYNBATDQDSEM@host/KEEPDQDSEM"'
printf '%s\n' 'curl "https://ok/x";//user:SYNBATDQDSLP@host"'
printf '%s\n' 'curl "https://x/?q=a,//user:SYNBATDQDCOM@host/KEEPDQDCOM"'
printf '%s\n' 'curl "https://ok/x",//user:SYNBATDQDCLP@host"'
printf '%s\n' "echo 'https://x/?q=a;//user:SYNBATSQDSEM@host/KEEPSQDSEM'"
printf '%s\n' "echo 'https://ok/x';//user:SYNBATSQLP@host'"
printf '%s\n' "echo 'https://x/?q=a,//user:SYNBATSQDCOM@host/KEEPSQDCOM'"
printf '%s\n' "echo 'https://ok/x',//user:SYNBATSQCLP@host'"
printf '%s\n' 'curl \"https://x/?q=a;//user:SYNBATEQDSEM@host/KEEPEQDSEM\"'
printf '%s\n' 'echo \"q\";//user:SYNBATEQDSLP@host\"'
printf '%s\n' 'curl \"https://x/?q=a,//user:SYNBATEQDCOM@host/KEEPEQDCOM\"'
printf '%s\n' 'echo \"q\",//user:SYNBATEQCLP@host\"'
printf '%s\n' 'curl "https://x/?q=a;//user:leadSYNBATMIXD@host/KEEPMIXD\"'
printf '%s\n' 'curl \"https://ok/x\";//user:leadSYNBATMIXL@host\"'
# Separator leak probes: a bare command word or an empty token must not shield
# the following authority, while key=value URL data stays byte-for-byte.
printf '%s\n' 'echo \"https://x;cat;//SYNFIXBARE01@host\"'
printf '%s\n' 'curl \"https://ok/x;cat;//user:SYNFIXCOLON02@host\" -H \"X: keepHeader\"'
printf '%s\n' 'echo \"https://x;echo;//SYNFIXBARE03@host\"'
printf '%s\n' 'echo \"https://x,ls;//user:SYNFIXCOLON04@host\"'
printf '%s\n' 'echo \"x://;//SYNFIXEMPTY05@host\"'
printf '%s\n' 'echo \"x://,//SYNFIXEMPTY06@host\"'
printf '%s\n' 'curl \"https://x/?q=a=1;b=2;//u:pSYNFIXDATA07@one.example.test\";//u:realSYNFIXREAL07@two.example.test'
printf '%s\n' 'curl \"https://x/?q=a=1,b=2;//u:pSYNFIXDATA08@one.example.test\",//u:realSYNFIXREAL08@two.example.test'
printf '%s\n' "curl 'https://x/?q=a=1;b=2;//u:pSYNFIXDATA09@one.example.test';//u:realSYNFIXREAL09@two.example.test"
# A separator assignment word shields only after a query marker; before it,
# the same shape is a shell command and its credential must be redacted.
printf '%s\n' 'echo \"https://x;a=b;//u:LEAKASSIGN01@host\"'
printf '%s\n' 'echo \"https://x,k=1;//user:LEAKASSIGN02@host\"'
printf '%s\n' 'curl \"https://x;cat=1;//user:LEAKASSIGN03@host\" -H \"X: keep\"'
printf '%s\n' 'curl \"https://x/?q=a=1;b=2;//u:pDATAKEEP11@one.example.test\";//u:realDATAKEEP11@two.example.test'
printf '%s\n' 'curl \"https://x/?q=a=1,b=2;//u:pDATAKEEP12@one.example.test\",//u:realDATAKEEP12@two.example.test'
printf '%s\n' "curl 'https://x/?q=a=1;b=2;//u:pDATAKEEP13@one.example.test';//u:realDATAKEEP13@two.example.test"
# Long assignment words in a query stay shell separators; the later authority must be masked.
printf '%s\n' 'curl \"https://api.example.test/v1?verbose=1;cat=1;//user:LEAKQUERY01@host\" -H \"X: keep\"'
printf '%s\n' 'echo \"https://x/?q=hello;cat=1;//user:LEAKQUERY02@host\"'
printf '%s\n' 'echo \"https://x/?q=hello,cmd=1;//user:LEAKQUERY04@host\"'
# Path matrix segments are not exempt: separators before ? remain shell separators.
printf '%s\n' 'echo \"https://x/path;v=1;b=2;//user:PATHREDACT03@host\"'
# Escaped single-character and empty assignments are shell separators;
# credentials after them must be masked even though the key is short.
printf '%s\n' 'echo \"https://x/?q=hello;a=1;//user:LEAKONE641@host\"'
printf '%s\n' 'echo \"https://x/?q=hello,b=1;//user:LEAKCOMMA642@host\"'
printf '%s\n' 'echo \"https://x/?q=hello;=1;//user:LEAKEMPTY643@host\"'
printf '%s\n' 'echo \"https://x/?q=hello;1=1;//user:LEAKDIGIT644@host\"'
printf "%s\n" "echo \\'https://x/?q=hello;a=1;//user:SQESC649@host\\'"
printf '%s\n' "curl 'https://x/?q=hello;cat=1;//u:pSQPLAIN651@one.example.test';//u:realSQPLAIN652@two.example.test"
printf '%s\n' 'echo \"https://x/?q=a=1;b=2;//u:pDQESC654@one.test"'
# Bare separator authorities in escaped quotes are shell separators; their
# credentials must be masked even without query data.
printf '%s\n' 'echo \"https://x/path;//user:BARE77@host\"'
printf '%s\n' 'echo \"https://x/path,//user:BARE77@host\"'
printf "%s\n" "echo \\'https://x/path;//user:BARE77@host\\'"
printf "%s\n" "echo \\'https://x/path,//user:BARE77@host\\'"
# POSIX single quotes close at the first following quote; backslash is
# literal inside them, so the separator after 'a\\' is outside quotes.
printf '%s\n' "echo 'a\\'b;//user:NORM77@host'"
printf '%s\n' 'echo \"https://x;ls;//user:SYNFIXCOLON10@host; echo KEEPTAIL10\"'
printf '%s\n' 'echo "note;//user:SYNTHPLAIN142@host"'
printf '%s\n' 'curl "https://example.test/?q=a;//user:SYNTHPLAIN@host/KEEPPLAIN" -H "X: keepHeader"'
printf '%s\n' 'curl -H "Authorization: Bearer SYNTHAUTHPLAIN" https://x'
printf '%s\n' 'x=1;url=//user:passSemiAssign@example.test/path'
printf '%s\n' 'echo plain@example.com https://host.example/path:with@at'
printf "%s\n" "MY_TOKEN\\: \"o'brienKey777\""
printf '%s\n' 'curl -u user:SYNTHFLAG901 https://x; echo KEEPFLAG901'
printf '%s\n' 'curl --user user:SYNTHFLAG902 https://x; echo KEEPFLAG902'
printf '%s\n' 'curl -u=SYNTHFLAG903 https://x; echo KEEPFLAG903'
printf '%s\n' 'curl --password SYNTHFLAG904 https://x; echo KEEPFLAG904'
printf '%s\n' 'curl -u "user:SYNTHFLAG905" https://x; echo KEEPFLAG905'
printf '%s\n' "curl -u 'user:SYNTHFLAG906' https://x; echo KEEPFLAG906"
printf '%s\n' 'id --user=1000; echo KEEPFLAG907'
printf '%s\n' 'bash -p; echo KEEPFLAG908'
printf '%s\n' 'curl -u user:SYNTHFLAG921;echo KEEPFLAG921'
printf '%s\n' 'curl -u=user:SYNTHFLAG922 https://x; echo KEEPFLAG922'
printf '%s\n' 'curl --u=user:SYNTHFLAG923 https://x; echo KEEPFLAG923'
printf '%s\n' 'curl --user=SYNTHFLAG924 https://x; echo KEEPFLAG924'
printf '%s\n' 'curl --password "SYNTHFLAG925" https://x; echo KEEPFLAG925'
printf "%s\\n" "curl --password 'SYNTHFLAG926' https://x; echo KEEPFLAG926"
printf '%s\n' 'curl -u "user:pass wordSYNTHFLAG927" https://x; echo KEEPFLAG927'
printf '%s\n' 'curl -u=SYNTHFLAG928&&echo KEEPFLAG928'
printf '%s\n' 'curl --password SYNTHFLAG929|grep KEEPFLAG929'
printf '%s\n' 'curl --user=1SYNTHFLAG933 https://x; echo KEEPFLAG933'
printf '%s\n' 'curl -u=\"user:SYNTHQE1\" https://x; echo KEEPE1'
printf '%s\n' 'curl --user=\"SYNTHQE2\" https://x; echo KEEPE2'
printf '%s\n' 'curl --user=SECOPS1>out;echo KEEPOPS1'
printf '%s\n' 'curl -u=user:SECOPS2>>out;echo KEEPOPS2'
printf '%s\n' 'curl --password SECOPS3<in;echo KEEPOPS3'
printf '%s\n' 'curl -u="user:SYNTHQ01" https://x; echo KEEPQ01'
printf "%s\n" "curl --user='user:SYNTHQ02' https://x; echo KEEPQ02"
printf '%s\n' 'curl -u="SYNTHQ03" https://x; echo KEEPQ03'
printf '%s\n' 'curl --user="SYNTHQ04" https://x; echo KEEPQ04'
printf '%s\n' 'curl -H "Authorization: Bearer SYNTHGLUE101";echo KEEPGLUE101'
printf "%s\\n" "curl -H 'Authorization: Bearer SYNTHGLUE102'&&echo KEEPGLUE102"
printf '%s\n' 'curl -H "Authorization: Bearer SYNTHGLUE103"&echo KEEPGLUE103'
printf '%s\n' 'curl -H "Authorization: Bearer SYNTHGLUE104"2>err;echo KEEPGLUE104'
printf '%s\n' 'curl -H "Authorization: Bearer SYNTHGLUE105"; echo KEEPGLUE105'
printf '%s\n' 'mysql -uadmin -pSYNTHP941; echo KEEPP941'
printf '%s\n' 'mysqldump -pSYNTHP942&&echo KEEPP942'
printf '%s\n' 'bash -p; echo KEEPP943'
printf '%s\n' 'ls -p /tmp; echo KEEPP944'
printf '%s\n' 'mysql -p"SYNTHP945" https://x; echo KEEPP945'
printf "%s\\n" "mysql -p'SYNTHP946' https://x; echo KEEPP946"
printf '%s\n' 'mysql -p"SYNTHQDB1">out; echo KEEPQDB1'
printf '%s\n' "mysql -p'SYNTHQDB2'<in; echo KEEPQDB2"
printf '%s\n' 'mysql -p"SYNTHQDB3">>out; echo KEEPQDB3'
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
grep -Fxq 'Authorization: ***REDACTED*** | grep keepPipe90201' "$line_file" || exit 357
grep -Fxq 'Authorization: ***REDACTED***|grep keepPipeTail90202' "$line_file" || exit 358
grep -Fxq 'Authorization: Bearer ***REDACTED*** | grep keepBearerPipe90203' "$line_file" || exit 359
grep -Fxq 'Authorization: Bearer ***REDACTED***|grep keepBearerPipeTail90204' "$line_file" || exit 360
grep -Fxq 'Authorization: ***REDACTED*** && echo keepAmp90205' "$line_file" || exit 361
grep -Fxq 'Authorization: ***REDACTED***&&echo keepAmpTail90206' "$line_file" || exit 362
grep -Fxq 'Authorization: Bearer ***REDACTED*** && echo keepBearerAmp90207' "$line_file" || exit 363
grep -Fxq 'Authorization: Bearer ***REDACTED***&&echo keepBearerAmpTail90208' "$line_file" || exit 364
grep -Fxq 'Authorization: ***REDACTED*** || echo keepOr90209' "$line_file" || exit 365
grep -Fxq 'Authorization: Bearer ***REDACTED*** || echo keepBearerOr90210' "$line_file" || exit 366
grep -Fxq 'Authorization: ***REDACTED*** > out.txt' "$line_file" || exit 367
grep -Fq 'secretRedirect123456' "$line_file" && exit 368
grep -Fxq 'Authorization: ***REDACTED***>out.txt' "$line_file" || exit 369
grep -Fq 'secretRedirectTail123456' "$line_file" && exit 370
grep -Fxq 'Authorization: ***REDACTED*** >> out.txt' "$line_file" || exit 371
grep -Fq 'secretRedirectDouble123456' "$line_file" && exit 372
grep -Fxq 'Authorization: Bearer ***REDACTED*** > out.txt' "$line_file" || exit 373
grep -Fq 'secretBearerRedirect123456' "$line_file" && exit 374
grep -Fxq 'Authorization: Bearer ***REDACTED***>out.txt' "$line_file" || exit 375
grep -Fq 'secretBearerRedirectTail123456' "$line_file" && exit 376
grep -Fxq 'Authorization: ***REDACTED*** < in.txt' "$line_file" || exit 377
grep -Fq 'secretInput123456' "$line_file" && exit 378
grep -Fxq 'Authorization: Bearer ***REDACTED*** <<EOF' "$line_file" || exit 379
grep -Fq 'secretHere123456' "$line_file" && exit 380
# A placeholder on the first value must not disable terminal cleanup of the second.
grep -Fxq 'Authorization: ***REDACTED*** > out.txt; Authorization: ***REDACTED***' "$line_file" || exit 384
grep -Fq 'splitRedirect123456' "$line_file" && exit 385
grep -Fq 'splitBare123456' "$line_file" && exit 386
# Fd digits belong to the redirect boundary, never to the credential.
grep -Fxq 'Authorization: ***REDACTED*** 2>err' "$line_file" || exit 390
grep -Fq 'SYNTHFDSECRET' "$line_file" && exit 391
grep -Fxq 'Authorization: ***REDACTED*** >out' "$line_file" || exit 392
grep -Fq 'SYNTHPLAINSECRET' "$line_file" && exit 393
grep -Fxq 'Authorization: ***REDACTED*** 2>&1' "$line_file" || exit 394
grep -Fq 'SYNTHFDSTDERR' "$line_file" && exit 395
grep -Fxq 'Authorization: ***REDACTED*** 0<in' "$line_file" || exit 396
grep -Fq 'SYNTHFDSTDIN' "$line_file" && exit 397
grep -Fxq 'Authorization: ***REDACTED*** 10>out' "$line_file" || exit 398
grep -Fq 'SYNTHFDFD10' "$line_file" && exit 399
grep -Fxq 'Authorization: ***REDACTED*** 3>>err' "$line_file" || exit 400
grep -Fq 'SYNTHFDAPPEND' "$line_file" && exit 401
grep -Fxq 'Authorization: ***REDACTED*** 2> err' "$line_file" || exit 402
grep -Fq 'SYNTHFDSPACE' "$line_file" && exit 403
grep -Fxq 'Authorization: Bearer ***REDACTED*** 2>err' "$line_file" || exit 404
grep -Fq 'SYNTHFDBEARER' "$line_file" && exit 405
grep -Fxq 'Authorization: Bearer ***REDACTED*** 10>out' "$line_file" || exit 406
grep -Fq 'SYNTHFDSCHEMED10' "$line_file" && exit 407
# The marker on the first value must not stop the later bare value from masking.
grep -Fxq 'Authorization: ***REDACTED*** 2>err; Authorization: ***REDACTED***' "$line_file" || exit 408
grep -Fq 'SYNTHFDSPLIT' "$line_file" && exit 409
grep -Fq 'SYNTHFDBARE' "$line_file" && exit 410
# Digits inside a credential stay masked; only fd digits before an operator are kept.
grep -Fxq 'Authorization: ***REDACTED*** 2>err' "$line_file" || exit 411
grep -Fq 'SYNTHFDNUM123' "$line_file" && exit 412
grep -Fxq 'Authorization: ***REDACTED***>out' "$line_file" || exit 413
grep -Fq 'SYNTHFDTAIL456' "$line_file" && exit 414
# Three-digit and spaced fd forms keep the full redirect boundary.
grep -Fxq 'Authorization: ***REDACTED*** 123>out' "$line_file" || exit 415
grep -Fq 'SYNTHFDFD123' "$line_file" && exit 416
grep -Fxq 'Authorization: Bearer ***REDACTED*** 123>out' "$line_file" || exit 417
grep -Fq 'SYNTHFDSCHEMED123' "$line_file" && exit 418
grep -Fxq 'Authorization: ***REDACTED*** 2 >err' "$line_file" || exit 419
grep -Fq 'SYNTHFDGAP' "$line_file" && exit 420
grep -Fxq 'Authorization: Bearer ***REDACTED*** 2 >err' "$line_file" || exit 421
grep -Fq 'SYNTHFDSCHEMEGAP' "$line_file" && exit 422
# A padded value must not swallow the operator or the following words.
grep -Fxq 'Authorization: Basic ***REDACTED*** > out' "$line_file" || exit 700
grep -Fq 'dXNlcjpwYXNz==' "$line_file" && exit 701
grep -Fxq 'Authorization: Bearer ***REDACTED***; echo KEEPAUTHPAD1' "$line_file" || exit 702
grep -Fq 'SYNTHAUTHPAD1' "$line_file" && exit 703
grep -Fxq 'Authorization: Bearer ***REDACTED*** 2>err; echo KEEPAUTHPAD2' "$line_file" || exit 704
grep -Fq 'SYNTHAUTHPAD2' "$line_file" && exit 705
# A keyed chain after an Authorization marker keeps both boundaries.
grep -Fxq 'Authorization: Bearer ***REDACTED***;token=***REDACTED***; echo KEEPMIXAUTH' "$line_file" || exit 706
grep -Fq 'SYNTHMIXAUTH2' "$line_file" && exit 707
grep -Fxq 'Authorization: Bearer ***REDACTED***,token=***REDACTED***; echo KEEPMIXAUTH2' "$line_file" || exit 708
grep -Fq 'SYNTHMIXAUTH4' "$line_file" && exit 709
grep -Fxq 'Authorization: Bearer ***REDACTED***;token=***REDACTED***;token2=***REDACTED***; echo KEEPMIXAUTH3' "$line_file" || exit 710
grep -Fq 'SYNTHMIXAUTH7' "$line_file" && exit 711
grep -Fxq 'Authorization: Bearer ***REDACTED***;token=***REDACTED*** echo KEEPCASEMARK' "$line_file" || exit 712
grep -Fqi '@lmline_chain_key@' "$line_file" && exit 713
grep -Fq 'SYNTHCASEMARK' "$line_file" && exit 714
grep -Fxq 'url=https://u:***REDACTED***@host/path; echo KEEPPASTEDURLMARK' "$line_file" || exit 715
grep -Fq '@@LMLINE_URL_REDACTED@@' "$line_file" && exit 716
grep -Fxq 'url=https://u:***REDACTED***@host/path; echo KEEPPASTEDURLMARKCASE' "$line_file" || exit 717
grep -Fqi '@@LMLINE_URL_REDACTED@@' "$line_file" && exit 718
grep -Fxq 'echo KEEPPASTEDREDMARK ***REDACTED*** KEEPPASTEDREDTAIL' "$line_file" || exit 719
grep -Fqi '@@LmLINE_Redacted@@' "$line_file" && exit 720
grep -Fxq 'echo KEEPPASTEDCHAINMARK ***REDACTED*** KEEPPASTEDCHAINTAIL' "$line_file" || exit 721
grep -Fqi '@LmLINE_ChAiN_kEy@' "$line_file" && exit 722
grep -Fxq 'echo KEEPPASTEDSEPMARK ***REDACTED*** KEEPPASTEDSEPTAIL' "$line_file" || exit 723
grep -Fqi '@LmLINE_SeP@' "$line_file" && exit 724
grep -Fxq 'Authorization: Bearer="***REDACTED***"; echo KEEPEQSDQ1' "$line_file" || exit 725
grep -Fq 'SYNTHEQSDQ1' "$line_file" && exit 726
grep -Fxq "Authorization: Bearer='***REDACTED***'; echo KEEPEQSQ1" "$line_file" || exit 727
grep -Fq 'SYNTHESQSQ1' "$line_file" && exit 728
grep -Fxq 'authorization: bearer="***REDACTED***" && echo KEEPEQSCASE' "$line_file" || exit 729
grep -Fq 'SYNTHEQSCASE1' "$line_file" && exit 730
grep -Fxq 'Authorization: Basic="***REDACTED***"; echo KEEPEQSESC' "$line_file" || exit 731
grep -Fq 'SYNTHEQSESC1' "$line_file" && exit 732
grep -Fxq 'Authorization: Bearer="***REDACTED***' "$line_file" || exit 733
grep -Fq 'SYNTHEQUNTERM1' "$line_file" && exit 734
grep -Fxq "Authorization: Bearer='***REDACTED***" "$line_file" || exit 735
grep -Fq 'SYNTHEQUNTERM2' "$line_file" && exit 736
grep -Fq 'SYNTHEQTBACK1' "$line_file" && exit 740
grep -Fq 'SYNTHEQTBACK2' "$line_file" && exit 742
grep -Fxq 'Authorization: Bearer:"***REDACTED***"; echo KEEPCOLSDQ1' "$line_file" || exit 743
grep -Fq 'SYNTHCOLSDQ1' "$line_file" && exit 744
grep -Fxq "Authorization: Basic=='***REDACTED***'; echo KEEPCOLSQ2" "$line_file" || exit 745
grep -Fq 'SYNTHCOLSQ2' "$line_file" && exit 746
grep -Fxq 'Authorization: Digest:="***REDACTED***"; echo KEEPCOLREP3' "$line_file" || exit 747
grep -Fq 'SYNTHCOLREP3' "$line_file" && exit 748
grep -Fxq 'Authorization: Bearer:"***REDACTED***' "$line_file" || exit 749
grep -Fq 'SYNTHCOLUNTERM4' "$line_file" && exit 750
grep -Fxq 'Authorization: Bearer=\"***REDACTED***\"; echo KEEPESESDQ1' "$line_file" || exit 751
grep -Fq 'SYNTHESESDQ1' "$line_file" && exit 752
grep -Fxq "Authorization: Bearer=\\'***REDACTED***\\'; echo KEEPESESQ1" "$line_file" || exit 753
grep -Fq 'SYNTHESESQ1' "$line_file" && exit 754
grep -Fxq 'Authorization: Bearer==\"***REDACTED***\" | echo KEEPESESDQ2' "$line_file" || exit 755
grep -Fq 'SYNTHESESDQ2' "$line_file" && exit 756
grep -Fxq "Authorization: Bearer:\'***REDACTED***\' >> out; echo KEEPESESQ2" "$line_file" || exit 757
grep -Fq 'SYNTHESESQ2' "$line_file" && exit 758
grep -Fxq 'authorization: bearer=\"***REDACTED***\" && echo KEEPESESDQCASE' "$line_file" || exit 759
grep -Fq 'SYNTHESESDQCASE' "$line_file" && exit 760
grep -Fxq 'Authorization: Bearer=\"***REDACTED***\"' "$line_file" || exit 761
grep -Fq 'SYNTHESESDQ3' "$line_file" && exit 762
grep -Fq 'SYNTHUNTERMDPQ1' "$line_file" && exit 775
grep -Fxq -- 'Authorization: Bearer=\"***REDACTED***' "$line_file" || exit 776
grep -Fq 'SYNTHUNTERMSQ1' "$line_file" && exit 777
grep -Fxq "Authorization: Bearer=\\'***REDACTED***" "$line_file" || exit 778
# Every trailing-backslash parity masks the credential and consumes the dangling slash;
# all four parities share the exact output asserted above.
grep -Fq 'SYNTHTRAILDDQ0' "$line_file" && exit 786
grep -Fq 'SYNTHTRAILDDQ1' "$line_file" && exit 788
grep -Fq 'SYNTHTRAILDDQ2' "$line_file" && exit 790
grep -Fq 'SYNTHTRAILDDQ3' "$line_file" && exit 792
grep -Fq 'SYNTHTRAILSQ0' "$line_file" && exit 794
grep -Fq 'SYNTHTRAILSQ1' "$line_file" && exit 796
grep -Fq 'SYNTHTRAILSQ2' "$line_file" && exit 798
grep -Fq 'SYNTHTRAILSQ3' "$line_file" && exit 800
grep -Fq 'SYNTHQURL1' "$line_file" && exit 763
grep -Fxq -- 'url=https://x/?token="***REDACTED***"&y=1; echo KEEPQURL1' "$line_file" || exit 764
grep -Fq 'SYNTHQURL2' "$line_file" && exit 765
grep -Fxq -- "url=https://x/?secret='***REDACTED***'&y=2; echo KEEPQURL2" "$line_file" || exit 766
grep -Fq 'SYNTHQURL3' "$line_file" && exit 767
grep -Fxq -- 'url=https://x/?token="***REDACTED***"&y=3; echo KEEPQURL3' "$line_file" || exit 768
grep -Fq 'SYNTHQURL4' "$line_file" && exit 769
grep -Fxq -- "url=https://x/?api_key='***REDACTED***'&y=4; echo KEEPQURL4" "$line_file" || exit 770
grep -Fq 'SYNTHQURL5' "$line_file" && exit 771
grep -Fxq -- 'curl "https://x/?token="***REDACTED***"&y=5"; echo KEEPQURL5' "$line_file" || exit 772
grep -Fq 'SYNTHQURL6' "$line_file" && exit 773
grep -Fq 'SYNTHESCKQ1' "$line_file" && exit 779
grep -Fxq -- 'url=https://x/?"token"="***REDACTED***"&y=1; echo KEEPESCKQ1' "$line_file" || exit 780
grep -Fq 'SYNTHESCKQ2' "$line_file" && exit 780
grep -Fxq -- 'url=https://x/?'"'"'secret'"'"'='"'"'***REDACTED***'"'"'&y=2; echo KEEPESCKQ2' "$line_file" || exit 781
grep -Fq 'SYNTHESCKQ3' "$line_file" && exit 781
grep -Fxq -- 'url=https://x/?"api_key"='"'"'***REDACTED***'"'"'&y=3; echo KEEPESCKQ3' "$line_file" || exit 782
grep -Fq 'SYNTHESCKQ4' "$line_file" && exit 782
grep -Fxq -- 'curl "https://x/?"token"="***REDACTED***"&y=4"; echo KEEPESCKQ4' "$line_file" || exit 783
grep -Fq 'SYNTHESCKQ5' "$line_file" && exit 783
grep -Fxq -- 'url=https://x/?"token"=***REDACTED***&y=5; echo KEEPESCKQ5' "$line_file" || exit 784
grep -Fxq -- 'url=https://x/?token="***REDACTED***"' "$line_file" || exit 774
# Adjacent escaped segments are consumed fail-closed: no value or tail survives.
grep -Fq 'SYNTHESCADJ1' "$line_file" && exit 801
grep -Fxq -- 'url=https://x/?"token"=***REDACTED***"***REDACTED***' "$line_file" || exit 802
grep -Fq 'KEEPESCADJ1' "$line_file" && exit 803
grep -Fq 'SYNTHESCADJ2' "$line_file" && exit 804
grep -Fq 'KEEPESCADJ2' "$line_file" && exit 806
grep -Fq 'SYNTHESCADJ3' "$line_file" && exit 807
grep -Fq 'KEEPESCADJ3' "$line_file" && exit 809
grep -Fq 'SYNTHESCADJ4' "$line_file" && exit 810
grep -Fxq -- "url=https://x/?'token'=***REDACTED***'***REDACTED***" "$line_file" || exit 811
grep -Fq 'KEEPESCADJ4' "$line_file" && exit 812
# Chained credential keys keep their field boundaries; adjacent segments stay masked.
grep -Fq 'SYNTHKEEPUNEQ1' "$line_file" && exit 890
grep -Fq 'SYNTHKEEPUNEQ2' "$line_file" && exit 891
grep -Fq 'SECNEXT' "$line_file" && exit 913
grep -Fxq 'url=https://x/?token="***REDACTED***"&password=***REDACTED***&y=1; echo KEEPESEMPTYDQ' "$line_file" || exit 914
grep -Fq 'SECNEXTE' "$line_file" && exit 915
grep -Fxq "url=https://x/?token='***REDACTED***'&secret=***REDACTED***&y=2; echo KEEPESEMPTYSQ" "$line_file" || exit 916
grep -Fq 'SECNEXT WITH SPACE' "$line_file" && exit 926
grep -Fq 'SECNEXT SQ SPACE' "$line_file" && exit 927
grep -Fxq 'url=https://x/?token="***REDACTED***"&password=***REDACTED***&y=1; echo KEEPURLDQSPACE' "$line_file" || exit 928
grep -Fxq "url=https://x/?token='***REDACTED***'&secret=***REDACTED***&y=2; echo KEEPURLSQSPACE" "$line_file" || exit 929
grep -Fxq -- 'url=https://x/?token="***REDACTED***"&password="***REDACTED***"&y=2; echo KEEPUNEQ' "$line_file" || exit 892
grep -Fq 'SYNTHKEEPESCQ1' "$line_file" && exit 893
grep -Fq 'SYNTHKEEPESCQ2' "$line_file" && exit 894
grep -Fxq -- "url=https://x/?\"token\"=\"***REDACTED***\"&password=***REDACTED***; echo KEEPESCQ" "$line_file" || exit 895
grep -Fxq -- "url=https://x/?\"token\"=\"***REDACTED***\";password=***REDACTED***; echo KEEPSEMI" "$line_file" || exit 905
grep -Fxq -- "url=https://x/?\"token\"=\"***REDACTED***\",password=***REDACTED***; echo KEEPCOMMA" "$line_file" || exit 906
grep -Fq 'SYNTHKEEPESCSQ1' "$line_file" && exit 896
grep -Fq 'SYNTHKEEPESCSQ2' "$line_file" && exit 897
grep -Fxq -- "url=https://x/?'token'='***REDACTED***'&password=***REDACTED***; echo KEEPESCSQ" "$line_file" || exit 898
grep -Fq 'SYNTHADJGUARD1' "$line_file" && exit 899
grep -Fq 'KEEPADJGUARD1' "$line_file" && exit 900
grep -Fq 'SYNTHADJGUARD2' "$line_file" && exit 902
grep -Fq 'KEEPADJGUARD2' "$line_file" && exit 903
# A plain key must consume adjacent escaped segments; a second keyed field stays separate.
grep -Fq 'SYNTHADJPLAIN1' "$line_file" && exit 850
grep -Fxq -- 'url=https://x/?token="***REDACTED***"&y=1; echo KEEPADJPLAIN1' "$line_file" || exit 851
grep -Fq 'SYNTHADJPLAIN2' "$line_file" && exit 852
grep -Fxq -- "url=https://x/?token='***REDACTED***'&y=2; echo KEEPADJPLAIN2" "$line_file" || exit 853
grep -Fq 'SYNTHADJPLAIN3' "$line_file" && exit 854
grep -Fxq -- 'url=https://x/?token="***REDACTED***"&y=3; echo KEEPADJPLAIN3' "$line_file" || exit 855
grep -Fq 'SYNTHADJPLAIN4' "$line_file" && exit 856
grep -Fxq -- 'url=https://x/?token="***REDACTED***"&other_token="***REDACTED***"&y=4; echo KEEPADJPLAIN4' "$line_file" || exit 857
grep -Fq 'SYNTHDOUBLE1' "$line_file" && exit 860
grep -Fxq -- 'url=https://x/?token:"***REDACTED***"' "$line_file" || exit 861
grep -Fq 'SYNTHDOUBLE2' "$line_file" && exit 862
grep -Fxq -- 'url=https://x/?token:"***REDACTED***"&y=1; echo KEEPTAIL' "$line_file" || exit 863
grep -Fq 'SYNTHDOUBLE3' "$line_file" && exit 864
grep -Fxq -- "url=https://x/?token='***REDACTED***'" "$line_file" || exit 865
grep -Fq 'SYNTHDOUBLE4' "$line_file" && exit 866
grep -Fxq -- 'url=https://x/?api_key:"***REDACTED***"&y=2; echo KEEPDOUBLE4' "$line_file" || exit 867
grep -Fq 'SYNTHSPACED1' "$line_file" && exit 870
grep -Fxq -- 'url=https://x/?token : ***REDACTED***' "$line_file" || exit 871
grep -Fq 'SYNTHSPACED2' "$line_file" && exit 872
grep -Fxq -- 'url=https://x/?token : "***REDACTED***"&y=1; echo KEEPTAIL' "$line_file" || exit 873
grep -Fq 'SYNTHSPACED3' "$line_file" && exit 874
grep -Fxq -- "url=https://x/?api_key : '***REDACTED***'" "$line_file" || exit 875
grep -Fxq -- 'url=https://x/?realm : = "example.com"; echo KEEPREALM' "$line_file" || exit 876
grep -Fq 'SYNTHAUTHURL1' "$line_file" && exit 880
grep -Fxq -- 'url=https://x/?Authorization:"***REDACTED***"' "$line_file" || exit 881
grep -Fq 'SYNTHAUTHURL2' "$line_file" && exit 882
grep -Fxq -- 'url=https://x/?Authorization:"***REDACTED***"&y=1; echo KEEPTAIL' "$line_file" || exit 883
grep -Fq 'SYNTHAUTHURL3' "$line_file" && exit 884
grep -Fxq -- 'url=https://x/?Authorization:***REDACTED***' "$line_file" || exit 885
grep -Fq 'SYNTHAUTHURL4' "$line_file" && exit 886
grep -Fxq -- 'url=https://x/?Authorization: ***REDACTED***' "$line_file" || exit 887
grep -Fxq -- 'url=https://x/?Authorization:realm="example.com"; echo KEEPURLAUTH' "$line_file" || exit 888
grep -Fxq 'Authorization: Bearer="***REDACTED***";token=***REDACTED***; echo KEEPEQCHAIN' "$line_file" || exit 737
grep -Fq 'SYNTHEQCHAIN' "$line_file" && exit 738
grep -Fxq 'Authorization: Bearer=\"***REDACTED***\"; echo KEEPAUDSEG1' "$line_file" || exit 907
grep -Fq 'SYNTHAUDSEG' "$line_file" && exit 908
grep -Fxq "Authorization: Bearer=\\'***REDACTED***\\'; echo KEEPAUDSEG2" "$line_file" || exit 909
grep -Fxq 'Authorization: Bearer="***REDACTED***"; echo KEEPAUDSEG3' "$line_file" || exit 910
grep -Fxq "Authorization: Bearer='***REDACTED***'; echo KEEPAUDSEG4" "$line_file" || exit 911
grep -Fxq 'Authorization: Bearer="***REDACTED***";token=***REDACTED***; echo KEEPAUDSEG5' "$line_file" || exit 912
grep -Fq 'SYNTH SPACE' "$line_file" && exit 917
grep -Fxq 'Authorization: Bearer="***REDACTED***"; echo KEEPSEGSPACE1' "$line_file" || exit 918
grep -Fxq "Authorization: Bearer='***REDACTED***'; echo KEEPSEGSPACE2" "$line_file" || exit 919
grep -Fxq 'Authorization: Bearer="***REDACTED***"; echo "KEEPSEGSPACE4"' "$line_file" || exit 920
grep -Fq 'SYNTH UPQ' "$line_file" && exit 921
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPUPQ1' "$line_file" || exit 922
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPUPQ2' "$line_file" || exit 923
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo "KEEPUPQ3"' "$line_file" || exit 924
grep -Fxq 'Authorization: Bearer=***REDACTED***;token=***REDACTED***; echo KEEPUPQ4' "$line_file" || exit 925
grep -Fq 'SYNTHUPQ5' "$line_file" && exit 930
grep -Fq 'SYNTHUPQ6' "$line_file" && exit 931
grep -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Bearer=***REDACTED***; echo KEEPUPQ5' "$line_file" || exit 932
grep -Fq 'SYNTHUPQ7' "$line_file" && exit 933
grep -Fxq 'Authorization: Bearer=***REDACTED*** | grep KEEPUPQ7' "$line_file" || exit 934
grep -Fq 'SYNTHUPQ8' "$line_file" && exit 935
grep -Fq 'SYNTHUPQ9' "$line_file" && exit 936
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPUPQ8' "$line_file" || exit 937
grep -Fq 'SYNTHUPQ10' "$line_file" && exit 938
grep -Fq 'SYNTHUPQ11' "$line_file" && exit 939
grep -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQ10' "$line_file" || exit 940
grep -Fq 'SYNTHUPQESC1' "$line_file" && exit 941
grep -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC1' "$line_file" || exit 942
grep -Fq 'SYNTHUPQESC2' "$line_file" && exit 943
grep -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC2' "$line_file" || exit 944
grep -Fq 'SYNTHUPQESC3' "$line_file" && exit 945
grep -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC3' "$line_file" || exit 946
grep -Fq 'SYNTHCUSTM' "$line_file" && exit 947
grep -Fq 'SYNTHXAUTH' "$line_file" && exit 948
grep -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Custom=***REDACTED***; echo KEEPCUSTOM1' "$line_file" || exit 949
grep -Fxq 'Authorization: Custom=***REDACTED***; echo KEEPCUSTOM2' "$line_file" || exit 950
grep -Fxq 'Authorization: X-OAuth2=***REDACTED***; Authorization: X-OAuth2=***REDACTED***; echo KEEPCUSTOM3' "$line_file" || exit 951
grep -Fq 'SYNTHCUSTOMQH1' "$line_file" && exit 954
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: keep' https://example.test; echo KEEPQHCUSTOM1" "$line_file" || exit 955
grep -Fq 'SYNTHCUSTOMQH2' "$line_file" && exit 956
grep -Fxq 'curl -H "Authorization: ***REDACTED***" https://example.test; echo KEEPQHCUSTOM2' "$line_file" || exit 957
grep -Fq 'LEAKAPOSTROPHE987' "$line_file" && exit 958
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPTAIL' "$line_file" || exit 959
grep -Fq 'LEAKAPOSTROPHE988' "$line_file" && exit 960
grep -Fxq 'Authorization: Custom=***REDACTED***; echo KEEPTAIL' "$line_file" || exit 961
grep -Fq 'LEAKDQUOTE989' "$line_file" && exit 962
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPTAIL' "$line_file" || exit 963
grep -Fxq 'url=https://x/?realm=\"example.com\"; echo KEEPTAIL5' "$line_file" || exit 952
grep -Fxq 'Authorization: Digest ***REDACTED***' "$line_file" || exit 953
# The existing URL/query and provider-key fixtures are controls for the narrow rule change.
grep -Fxq "curl 'https://example.test/?x=1;token=***REDACTED***&y=2'" "$line_file" || exit 381
grep -Fxq 'curl "https://example.test/?q=ghp_***REDACTED***&x=1"' "$line_file" || exit 382
grep -Fq 'sk_live_***REDACTED***' "$line_file" || exit 383
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
grep -Fxq 'Authorization: ***REDACTED*** ***REDACTED***; echo "KEEP4"' "$line_file" || exit 340
grep -Fq 'secretValue127' "$line_file" && exit 341
grep -Fxq 'Authorization: ***REDACTED***; echo "KEEP5"' "$line_file" || exit 342
grep -Fq 'secretValue130' "$line_file" && exit 343
grep -Fxq 'Authorization: ***REDACTED*** ***REDACTED***' "$line_file" || exit 344
grep -Fq 'secretValue131' "$line_file" && exit 345
grep -Fxq 'curl -H "Authorization: ***REDACTED***" "payload128" https://x' "$line_file" || exit 346
grep -Fq 'secretValue128' "$line_file" && exit 347
grep -Fxq 'Authorization: ***REDACTED*** ***REDACTED***; echo "K9002"' "$line_file" || exit 348
grep -Fq 'tokenWithHash#9002' "$line_file" && exit 349
grep -Fxq 'Authorization: ***REDACTED*** ***REDACTED***; echo "K9003"' "$line_file" || exit 350
grep -Fq 'tokenWithBack\slash9003' "$line_file" && exit 351
grep -Fxq 'Authorization: ***REDACTED*** ***REDACTED*** https://x' "$line_file" || exit 352
grep -Fq 'realDpopSecret123456' "$line_file" && exit 353
grep -Fq 'realWsseSecret123456' "$line_file" && exit 354
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
grep -Fq 'tailBearer9038' "$line_file" && exit 321
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://example.test' "$line_file" || exit 322
grep -Fq 'tailEOL9039' "$line_file" && exit 323
grep -Fxq 'curl -H "Authorization: ***REDACTED***' "$line_file" || exit 324
grep -Fq 'secret123456' "$line_file" && exit 325
grep -Fq 'TAILAUDIT07' "$line_file" && exit 328
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo "KEEP07"' "$line_file" || exit 329
grep -Fq 'TAILAUDIT08' "$line_file" && exit 330
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***", "KEEP08"' "$line_file" || exit 331
grep -Fq 'TAILAUDIT09' "$line_file" && exit 430
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"| :' "$line_file" || exit 431
grep -Fq 'TAILAUDIT10' "$line_file" && exit 432
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***">out' "$line_file" || exit 433
grep -Fq 'TAILAUDIT11' "$line_file" && exit 434
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***">>out' "$line_file" || exit 435
grep -Fq 'TAILAUDIT12' "$line_file" && exit 436
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"<in' "$line_file" || exit 437
grep -Fq 'TAILAUDIT13' "$line_file" && exit 438
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" >out' "$line_file" || exit 439
grep -Fq 'TAILAUDIT14' "$line_file" && exit 440
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; :' "$line_file" || exit 441
grep -Fq 'TAILAUDIT15' "$line_file" && exit 442
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"2>err' "$line_file" || exit 443
grep -Fq 'TAILAUDIT16' "$line_file" && exit 444
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"2>&1' "$line_file" || exit 445
grep -Fq 'TAILAUDIT17' "$line_file" && exit 446
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"1>>out' "$line_file" || exit 447
grep -Fq 'TAILAUDIT18' "$line_file" && exit 448
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"10>out' "$line_file" || exit 449
grep -Fq 'TAILAUDIT19' "$line_file" && exit 450
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"& :' "$line_file" || exit 451
grep -Fq 'TAILAUDIT20' "$line_file" && exit 452
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"&& :' "$line_file" || exit 453
grep -Fq 'TAILAUDIT02' "$line_file" && exit 332
grep -Fxq "curl -H 'Authorization: Bearer ***REDACTED***'" "$line_file" || exit 333
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" "payload123" https://x' "$line_file" || exit 326
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" "user@host" "other" https://x' "$line_file" || exit 327
grep -Fq 'brienApostrophe9016' "$line_file" && exit 179
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: keepAtSingle' https://x" "$line_file" || exit 142
grep -Fq 'FIRSTSECRET' "$line_file" && exit 970
grep -Fq 'SECONDSECRET' "$line_file" && exit 971
grep -Fq 'ONLYSECRET' "$line_file" && exit 972
grep -Fq 'SINGLESECRET' "$line_file" && exit 973
grep -Fxq 'curl -H "Authorization: Bearer=***REDACTED***; Authorization: ***REDACTED***" https://x; echo KEEPTAIL' "$line_file" || exit 974
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: keep' https://x; echo KEEPTAIL" "$line_file" || exit 975
grep -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPTAIL' "$line_file" || exit 976
grep -Fxq 'Authorization: Bearer=\"***REDACTED***\"; echo KEEPTAILBARE' "$line_file" || exit 977
grep -Fq "'tSECRET" "$line_file" && exit 978
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEP6' "$line_file" || exit 979
grep -Fq 'SECRETADJ' "$line_file" && exit 980
grep -Fxq 'curl -H "Authorization: ***REDACTED***"2>err; echo KEEPTAILADJQ' "$line_file" || exit 981
grep -Fxq "curl -H 'Authorization: ***REDACTED***'2>err; echo KEEPTAILADJS" "$line_file" || exit 982
grep -Fq 'SECRETADJPQ' "$line_file" && exit 983
grep -Fxq "curl -H 'Authorization: ***REDACTED***'2>err; echo KEEPTAILADJPQ" "$line_file" || exit 984
grep -Fq 'SECRETADJSQ' "$line_file" && exit 985
grep -Fxq 'curl -H "Authorization: ***REDACTED***"2>err; echo KEEPTAILADJSQ' "$line_file" || exit 986
grep -Fxq 'curl -H "Authorization: Bearer:***REDACTED***"X; echo KEEPTAIL' "$line_file" || exit 990
grep -Fxq 'curl -H '"'"'Authorization: Bearer:***REDACTED***'"'"'X; echo MIRRORTAIL' "$line_file" || exit 991
grep -Fq SECRETZZ "$line_file" && exit 992
grep -Fq SECRETMM "$line_file" && exit 993
grep -Fxq 'curl -H"Authorization: Bearer:***REDACTED***"X; echo KEEPTAIL' "$line_file" || exit 998
grep -Fxq 'curl -H'"'"'Authorization: Bearer:***REDACTED***'"'"'X; echo KEEPTAIL' "$line_file" || exit 999
grep -Fq SECRETZZ "$line_file" && exit 1000
grep -Fq SECRETMM "$line_file" && exit 1001
grep -Fxq 'Authorization: Bearer:***REDACTED*** -H "X: keep" https://x; echo KEEPTAIL' "$line_file" || exit 994
grep -Fxq 'Authorization: Bearer:***REDACTED*** -H '"'"'X: keep'"'"' https://x; echo KEEPTAIL' "$line_file" || exit 995
grep -Fq LEAKMIN987 "$line_file" && exit 996
grep -Fq LEAKMIRROR988 "$line_file" && exit 997
grep -Fxq 'curl -H "Authorization: ***REDACTED***"2>err; echo KEEPTAILCLOSURE1' "$line_file" || exit 1002
grep -Fxq 'curl -H"Authorization: ***REDACTED***"2>err; echo KEEPTAILCLOSURE2' "$line_file" || exit 1003
grep -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPTAILCLOSURE3' "$line_file" || exit 1004
grep -Fq SYNTHCLOSURE901 "$line_file" && exit 1005
grep -Fq SYNTHCLOSURE902 "$line_file" && exit 1006
grep -Fq SYNTHCLOSURE903 "$line_file" && exit 1007
grep -Fxq 'Authorization: ***REDACTED***; echo KEEPSEPTAIL1' "$line_file" || exit 1010
grep -Fxq 'Authorization: ***REDACTED***; echo KEEPSEPTAIL2' "$line_file" || exit 1011
grep -Fxq 'Authorization: ***REDACTED***; echo KEEPSEPTAIL3' "$line_file" || exit 1012
grep -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPSEPTAIL4' "$line_file" || exit 1013
grep -Fq SYNTHSEP901 "$line_file" && exit 1014
grep -Fq SYNTHSEP902 "$line_file" && exit 1015
grep -Fq SYNTHSEP903 "$line_file" && exit 1016
grep -Fq SYNTHSEP904 "$line_file" && exit 1017
grep -Fq SYNTHQSEP911 "$line_file" && exit 1030
grep -Fq SYNTHQSEP912 "$line_file" && exit 1031
grep -Fq SYNTHQSEP913 "$line_file" && exit 1032
grep -Fq SYNTHQSEP914 "$line_file" && exit 1033
grep -Fq SYNTHQSEP915 "$line_file" && exit 1034
grep -Fq KEEPQSEPTAIL11 "$line_file" || exit 1040
grep -Fq KEEPQSEPTAIL12 "$line_file" || exit 1041
grep -Fq KEEPQSEPTAIL13 "$line_file" || exit 1042
grep -Fq KEEPQSEPTAIL14 "$line_file" || exit 1043
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPQSEPTAIL11' "$line_file" || exit 1051
grep -Fxq 'curl -H '\''Authorization: ***REDACTED***'\''; echo KEEPQSEPTAIL12' "$line_file" || exit 1052
grep -Fxq 'curl -H"Authorization: ***REDACTED***"; echo KEEPQSEPTAIL13' "$line_file" || exit 1053
grep -Fxq 'curl -H'\''Authorization: ***REDACTED***'\''; echo KEEPQSEPTAIL14' "$line_file" || exit 1054
grep -Fxq 'Authorization: ***REDACTED*** https://x; echo KEEPGLUEDTAIL1' "$line_file" || exit 1018
grep -Fxq 'Authorization: ***REDACTED*** foo; echo KEEPGLUEDTAIL2' "$line_file" || exit 1019
grep -Fq SYNTHGLUED901 "$line_file" && exit 1020
grep -Fq SYNTHGLUED902 "$line_file" && exit 1021
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://x; echo KEEPARGTAIL1' "$line_file" || exit 1022
grep -Fxq 'curl -H "Authorization: Bearer:***REDACTED***"' "$line_file" || exit 1023
grep -Fq SYNTHEOL1001 "$line_file" && exit 1024
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPZZ' "$line_file" || exit 9170
grep -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPZZ" "$line_file" || exit 9171
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "Authorization: ***REDACTED***"; echo KEEPZZ9' "$line_file" || exit 9172
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'Authorization: ***REDACTED***'; echo KEEPZZ9" "$line_file" || exit 9173
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x; echo KEEP88' "$line_file" || exit 9174
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPENDRED1' "$line_file" || exit 9180
grep -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPENDRED2" "$line_file" || exit 9181
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPENDRED3' "$line_file" || exit 9182
grep -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPENDRED4" "$line_file" || exit 9183
grep -Fq REALSECRET941 "$line_file" && exit 9184
grep -Fq REALSECRET942 "$line_file" && exit 9185
grep -Fq REALSECRET943 "$line_file" && exit 9186
grep -Fq REALSECRET944 "$line_file" && exit 9187
grep -Fxq "curl -H 'Authorization: Bearer:***REDACTED***'" "$line_file" || exit 1025
grep -Fq SYNTHEOL1002 "$line_file" && exit 1026
grep -Fxq 'curl -H "Authorization: Basic:***REDACTED***"' "$line_file" || exit 1027
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPSTAR911' "$line_file" || exit 1060
grep -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPAT912" "$line_file" || exit 1061
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPSTAR913' "$line_file" || exit 1062
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPAT914' "$line_file" || exit 1063
grep -Fq SYNTHSTAR911 "$line_file" && exit 1064
grep -Fq SYNTHAT912 "$line_file" && exit 1065
grep -Fq SYNTHSTAR913 "$line_file" && exit 1066
grep -Fq SYNTHAT914 "$line_file" && exit 1067
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEP921' "$line_file" || exit 1068
grep -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEP922" "$line_file" || exit 1069
grep -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEP923" "$line_file" || exit 1070
grep -Fq SYNTHSTAR921 "$line_file" && exit 1071
grep -Fq SYNTHSTAR922 "$line_file" && exit 1072
grep -Fq SYNTHAT923 "$line_file" && exit 1073
grep -Fxq 'Authorization: ***REDACTED***; echo KEEPGENSC901' "$line_file" || exit 1074
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPGENSC902' "$line_file" || exit 1075
grep -Fq SYNTHGENSC901 "$line_file" && exit 1076
grep -Fq SYNTHGENSC902 "$line_file" && exit 1077
grep -Fq SYNTHEOL1003 "$line_file" && exit 1028
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPNUM1' "$line_file" || exit 1029
grep -Fq 1234567890 "$line_file" && exit 1030
grep -Fxq "curl -H 'Authorization: Bearer ***REDACTED***'; echo KEEPNUM2" "$line_file" || exit 1031
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPNUM3' "$line_file" || exit 1032
grep -Fq SECRETABC123 "$line_file" && exit 1033
grep -Fq SYNTHARG901 "$line_file" && exit 1026
grep -Fxq 'curl -H '"'"'Authorization: ***REDACTED***'"'"' -H '"'"'X: keep'"'"' https://x; echo KEEPARGTAIL2' "$line_file" || exit 1023
grep -Fq SYNTHARG902 "$line_file" && exit 1027
grep -Fxq 'curl -H "Authorization: ***REDACTED***" "payload903" https://x; echo KEEPARGTAIL3' "$line_file" || exit 1024
grep -Fq SYNTHARG903 "$line_file" && exit 1028
grep -Fxq 'curl -H '"'"'Authorization: ***REDACTED***'"'"' '"'"'payload904'"'"' https://x; echo KEEPARGTAIL4' "$line_file" || exit 1025
grep -Fq SYNTHARG904 "$line_file" && exit 1029
grep -Fxq 'Authorization: ***REDACTED***; echo TAILZZ9' "$line_file" || exit 9301
grep -Fq SECRETZZ9 "$line_file" && exit 9302
grep -Fxq 'Authorization: ***REDACTED***; echo TAILZZ10' "$line_file" || exit 9303
grep -Fq SECRETZZ10 "$line_file" && exit 9304
grep -Fxq 'Authorization: ***REDACTED***; echo TAILZZ11' "$line_file" || exit 9305
grep -Fq SECRETZZ11 "$line_file" && exit 9306
grep -Fxq 'Authorization: my_scheme=\"***REDACTED***\"; echo TAILZZ12' "$line_file" || exit 9307
grep -Fq SYNTHE12 "$line_file" && exit 9308
grep -Fxq 'Authorization: 2Scheme=\"***REDACTED***\"; echo TAILZZ13' "$line_file" || exit 9309
grep -Fq SYNTHE13 "$line_file" && exit 9310
grep -Fxq 'Authorization: my_scheme \"***REDACTED***\"; echo TAILZZSP2' "$line_file" || exit 9311
grep -Fq SYNTHSP2 "$line_file" && exit 9312
grep -Fxq 'Authorization: 2Scheme \"***REDACTED***\"; echo TAILZZSP3' "$line_file" || exit 9313
grep -Fq SYNTHSP3 "$line_file" && exit 9314
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
grep -Fxq 'Authorization: ***REDACTED***\' "$line_file" || exit 355
grep -Fq 'continuationSecret444444' "$line_file" && exit 356
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
done < <(grep '^{"' "$line_file")
((json_count >= 4)) || exit 67
grep -Fq 'BearerSuffix1234567890' "$line_file" && exit 69
grep -Fq 'json_bearer_value' "$line_file" && exit 52
grep -Fq '123MY_TOKEN=***REDACTED***' "$line_file" || exit 58
grep -Fq 'SECRETVAL' "$line_file" && exit 59
grep -Fq '"123MY_TOKEN": "***REDACTED***"' "$line_file" || exit 60
grep -Fq -- '-MY_TOKEN=***REDACTED***' "$line_file" || exit 61
grep -Fxq 'token=***REDACTED***; echo KEEPSEMIFIX' "$line_file" || exit 460
grep -Fxq 'TOKEN=***REDACTED***; echo KEEPSEMI2FIX' "$line_file" || exit 461
grep -Fxq 'api_key=***REDACTED***; echo KEEPAPIFIX' "$line_file" || exit 462
grep -Fxq '"token=***REDACTED***"; echo KEEPQUOTEDFIX' "$line_file" || exit 463
grep -Fxq "'token=***REDACTED***'; echo KEEPQUOTED2FIX" "$line_file" || exit 464
grep -Fxq 'token=***REDACTED***' "$line_file" || exit 465
grep -Fq 'defFIX' "$line_file" && exit 475
grep -Fxq 'token=***REDACTED***; password=***REDACTED***; echo KEEP_TWO' "$line_file" || exit 466
grep -Fxq 'token=***REDACTED***; password=***REDACTED***; key=***REDACTED***; echo KEEP_MULTI' "$line_file" || exit 467
grep -Fxq 'token=***REDACTED***;token2=***REDACTED***; echo KEEPDOUBLEFIX' "$line_file" || exit 468
grep -Fq 'SYNTHSEMIKEY' "$line_file" && exit 469
grep -Fxq 'echo token=***REDACTED***;token2=***REDACTED***; echo KEEPCHAIN' "$line_file" || exit 546
grep -Fq 'SYNTHCHAIN' "$line_file" && exit 547
grep -Fxq 'echo token=***REDACTED***' "$line_file" || exit 548
grep -Fxq 'token=***REDACTED***;token2=***REDACTED***;token3=***REDACTED***; echo KEEPCHAIN3' "$line_file" || exit 663
grep -Fq 'SYNTHCHAIN3' "$line_file" && exit 664
grep -Fxq 'token=***REDACTED***,token2=***REDACTED***;token3=***REDACTED***; echo KEEPMIXCHAIN' "$line_file" || exit 669
grep -Fq 'SYNTHMIX1' "$line_file" && exit 670
grep -Fxq 'token=***REDACTED***;token2=***REDACTED***,token3=***REDACTED***, echo KEEPMIXCHAIN2' "$line_file" || exit 671
grep -Fq 'SYNTHMIX4' "$line_file" && exit 672
grep -Fxq 'token = ***REDACTED***;token2 = ***REDACTED***; echo KEEPSPACEKEY' "$line_file" || exit 673
grep -Fq 'SYNTHSPACE1' "$line_file" && exit 674
grep -Fxq 'token=***REDACTED*** echo KEEPCOMMAOPAQUE' "$line_file" || exit 675
grep -Fq 'defTAILCOMMA' "$line_file" && exit 676
grep -Fxq 'token=***REDACTED***&token2=***REDACTED***& echo KEEPAMPKEY' "$line_file" || exit 683
grep -Fq 'SYNTHAMPKEY' "$line_file" && exit 684
grep -Fxq 'token=***REDACTED***|token2=***REDACTED***; echo KEEPPIPEKEY' "$line_file" || exit 685
grep -Fq 'SYNTHPIPEKEY' "$line_file" && exit 686
grep -Fxq 'token=***REDACTED*** echo KEEPAMPOPAQUE' "$line_file" || exit 687
grep -Fq 'defTAILAMP' "$line_file" && exit 688
grep -Fxq 'token=***REDACTED*** echo KEEPPIPEOPAQUE' "$line_file" || exit 689
grep -Fq 'defTAILPIPE' "$line_file" && exit 690
grep -Fxq '"token":***REDACTED***;"password":***REDACTED***; echo KEEPDQKEY' "$line_file" || exit 677
grep -Fq 'SYNTHDQKEY' "$line_file" && exit 678
grep -Fxq "'test_key':***REDACTED***,'api_key':***REDACTED***, echo KEEPSQKEY" "$line_file" || exit 679
grep -Fq 'SYNTHSQKEY' "$line_file" && exit 680
grep -Fxq '"token":***REDACTED*** echo KEEPQUOTEDOPAQUE' "$line_file" || exit 681
grep -Fq 'defTAILQUOTED' "$line_file" && exit 682
grep -Fxq 'token=***REDACTED***,token2=***REDACTED***, echo KEEPCOMMA' "$line_file" || exit 665
grep -Fq 'SYNTHCOMMA' "$line_file" && exit 666
grep -Fxq 'token=***REDACTED*** echo KEEPOPAQUE' "$line_file" || exit 667
grep -Fq 'defTAILCHAIN' "$line_file" && exit 668
grep -Fq 'defFIX' "$line_file" && exit 549
grep -Fxq 'echo token=***REDACTED*** echo KEEPCHAINLEAK' "$line_file" || exit 550
grep -Fq 'SYNTHCHAINLEAK' "$line_file" && exit 551
grep -Fxq 'x=1;url=//user:***REDACTED***@example.test/path' "$line_file" || exit 552
grep -Fq 'SYNTHSECRETFIRST' "$line_file" && exit 470
grep -Fq 'SYNTHSECRETSECOND' "$line_file" && exit 471
grep -Fq 'SYNTHMULTI' "$line_file" && exit 472
grep -Fxq 'token=***REDACTED***; echo KEEPKEYSemiFIX' "$line_file" || exit 473
grep -Fxq 'token=***REDACTED*** | grep KEEPPIPEFIX' "$line_file" || exit 474
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
grep -Fq 'defLitQ9006' "$line_file" && exit 317
grep -Fxq 'curl "https://x/?token=***REDACTED***&y=2"' "$line_file" || exit 318
grep -Fq 'defShellLitQ9007' "$line_file" && exit 319
grep -Fxq 'echo x;token=***REDACTED***' "$line_file" || exit 320
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
grep -Fxq 'a=("https://x/?q=;//u:pArrayData@one.example.test");//u:***REDACTED***@two.example.test' "$line_file" || exit 311
grep -Fq 'realArray@two.example.test' "$line_file" && exit 312
grep -Fxq 'foo("https://x/?q=;//u:pParenData@one.example.test");//u:***REDACTED***@two.example.test' "$line_file" || exit 313
grep -Fq 'realParen@two.example.test' "$line_file" && exit 314
grep -Fxq 'echo {"url":"https://x/?q=;//u:pAnchorData@one.example.test"};//u:***REDACTED***@two.example.test' "$line_file" || exit 315
grep -Fq 'realAnchor@two.example.test' "$line_file" && exit 316
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
grep -Fxq 'curl \"https://example.test/?q=a;//user:***REDACTED***@host/KEEPE1\" -H \"X: keepHeader\"' "$line_file" || exit 501
grep -Fxq 'curl \"https://example.test/?q=a,//user:***REDACTED***@host/KEEPE2\" -H \"X: keepHeader\"' "$line_file" || exit 502
grep -Fxq '{\"url\":\"https://x/?q=;//user:***REDACTED***@host/KEEPE3\",\"keep\":\"keepValue\"}' "$line_file" || exit 503
grep -Fxq 'curl \"https://example.test/?q=a;//user:***REDACTED***@host/KEEPE4;b=;//user:***REDACTED***@host/KEEPE4B\" -H \"X: keepHeader\"' "$line_file" || exit 504
grep -Fxq 'curl \"https://user:***REDACTED***@host/x?q=KEEPREAL\"' "$line_file" || exit 505
grep -Fq 'SYNTHREAL' "$line_file" && exit 506
grep -Fxq 'echo \"q\";//user:***REDACTED***@host/KEEPSEP' "$line_file" || exit 507
grep -Fq 'SYNTHSEP' "$line_file" && exit 508
grep -Fxq 'curl "https://example.test/?q=a;//user:SYNTHPLAIN@host/KEEPPLAIN" -H "X: keepHeader"' "$line_file" || exit 509
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" https://x' "$line_file" || exit 510
grep -Fxq 'echo a;\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND1\"' "$line_file" || exit 511
grep -Fxq 'echo a|\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND2\"' "$line_file" || exit 512
grep -Fxq 'echo a&\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND3\"' "$line_file" || exit 513
grep -Fxq 'echo a#\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND4\"' "$line_file" || exit 514
grep -Fxq 'foo(\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND5\")' "$line_file" || exit 515
grep -Fxq 'echo a;\"https://x/?q=a;//user:***REDACTED***@one\";//user:***REDACTED***@evil' "$line_file" || exit 516
grep -Fxq 'echo \"note;//user:***REDACTED***@host; echo \"' "$line_file" || exit 520
grep -Fxq 'printf %s \"key;//user:***REDACTED***@host; date\"' "$line_file" || exit 521
grep -Fxq 'echo \"a,b;//user:***REDACTED***@h\"' "$line_file" || exit 522
grep -Fxq 'curl \"https://ok/x\" \"note;//user:***REDACTED***@host\"' "$line_file" || exit 523
grep -Fxq 'echo \"https://ok/x; echo note;//user:***REDACTED***@host; echo \"' "$line_file" || exit 524
grep -Fxq 'curl \"https://ok/x?q=a\" \"a,b;//user:***REDACTED***@h\"' "$line_file" || exit 525
grep -Fxq 'echo \"x:// ;//user:***REDACTED***@host\"' "$line_file" || exit 526
grep -Fxq 'echo \"x://;//user:***REDACTED***@host\"' "$line_file" || exit 527
grep -Fxq 'echo \"x://,//user:***REDACTED***@host\"' "$line_file" || exit 528
grep -Fxq "echo 'x://;//user:***REDACTED***@host'" "$line_file" || exit 529
grep -Fxq 'echo \"https://ok/x\";//user:***REDACTED***@host\"' "$line_file" || exit 530
grep -Fxq 'curl \"https://ok/x\";//user:***REDACTED***@host\"' "$line_file" || exit 531
grep -Fxq 'echo \"see https://x/?q=a;//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 532
grep -Fxq 'curl \"--url https://x/?q=a;//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 533
grep -Fxq 'echo \"prefix https://x/?q=a,//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 534
grep -Fq 'SYNTHZERO' "$line_file" && exit 535
grep -Fq 'SYNTHZEROC' "$line_file" && exit 536
grep -Fq 'SYNTHSQZERO' "$line_file" && exit 537
grep -Fq 'SYNTHBQ' "$line_file" && exit 538
grep -Fq 'SYNTHBQC' "$line_file" && exit 539
grep -Fxq 'echo \"https://ok/x\"a;//user:***REDACTED***@host\"' "$line_file" || exit 540
grep -Fxq 'echo \"https://ok/x\"note;//user:***REDACTED***@host\"' "$line_file" || exit 541
grep -Fxq 'curl \"https://x/?q=a!;//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 542
grep -Fxq 'echo \"https://x/?q=a*;//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 543
grep -Fq 'SYNTHBQA' "$line_file" && exit 544
grep -Fq 'SYNTHBQN' "$line_file" && exit 545
grep -Fxq 'curl "https://ok/x";//user:***REDACTED***@host"' "$line_file" || exit 553
grep -Fq 'SYNTHPLAINLEAK' "$line_file" && exit 554
grep -Fxq "echo 'https://ok/x';//user:***REDACTED***@host'" "$line_file" || exit 555
grep -Fq 'SYNTHSQLOCK' "$line_file" && exit 556
grep -Fxq 'curl "https://ok/x",//user:***REDACTED***@host"' "$line_file" || exit 557
grep -Fq 'SYNTHPLAINCOMMA' "$line_file" && exit 558
grep -Fxq 'curl \"https://x/?q=a;//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 559
grep -Fq 'SYNTHMIXCLOSE' "$line_file" && exit 560
grep -Fxq 'curl \"https://x/?q=a;//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 561
grep -Fq 'SYNTHMIXOPEN' "$line_file" && exit 562
grep -Fxq 'curl "https://x/?q=a;//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 565
grep -Fq 'SYNTHMIXCLOSE2' "$line_file" && exit 566
grep -Fxq 'curl "https://x/?q=a,//user:***REDACTED***@host/KEEP\"' "$line_file" || exit 567
grep -Fq 'SYNTHMIXCLOSE3' "$line_file" && exit 568
# Paired boundary battery: exact preservation or exact redaction, no leak.
grep -Fxq 'curl "https://x/?q=a;//user:SYNBATDQDSEM@host/KEEPDQDSEM"' "$line_file" || exit 570
grep -Fq 'SYNBATDQDSEM' "$line_file" || exit 571
grep -Fxq 'curl "https://ok/x";//user:***REDACTED***@host"' "$line_file" || exit 572
grep -Fq 'SYNBATDQDSLP' "$line_file" && exit 573
grep -Fxq 'curl "https://x/?q=a,//user:SYNBATDQDCOM@host/KEEPDQDCOM"' "$line_file" || exit 574
grep -Fq 'SYNBATDQDCOM' "$line_file" || exit 575
grep -Fxq 'curl "https://ok/x",//user:***REDACTED***@host"' "$line_file" || exit 576
grep -Fq 'SYNBATDQDCLP' "$line_file" && exit 577
grep -Fxq "echo 'https://x/?q=a;//user:SYNBATSQDSEM@host/KEEPSQDSEM'" "$line_file" || exit 578
grep -Fq 'SYNBATSQDSEM' "$line_file" || exit 579
grep -Fxq "echo 'https://ok/x';//user:***REDACTED***@host'" "$line_file" || exit 580
grep -Fq 'SYNBATSQLP' "$line_file" && exit 581
grep -Fxq "echo 'https://x/?q=a,//user:SYNBATSQDCOM@host/KEEPSQDCOM'" "$line_file" || exit 582
grep -Fq 'SYNBATSQDCOM' "$line_file" || exit 583
grep -Fxq "echo 'https://ok/x',//user:***REDACTED***@host'" "$line_file" || exit 584
grep -Fq 'SYNBATSQCLP' "$line_file" && exit 585
grep -Fxq 'curl \"https://x/?q=a;//user:***REDACTED***@host/KEEPEQDSEM\"' "$line_file" || exit 586
grep -Fq 'SYNBATEQDSEM' "$line_file" && exit 587
grep -Fxq 'echo \"q\";//user:***REDACTED***@host\"' "$line_file" || exit 588
grep -Fq 'SYNBATEQDSLP' "$line_file" && exit 589
grep -Fxq 'curl \"https://x/?q=a,//user:***REDACTED***@host/KEEPEQDCOM\"' "$line_file" || exit 590
grep -Fq 'SYNBATEQDCOM' "$line_file" && exit 591
grep -Fxq 'echo \"q\",//user:***REDACTED***@host\"' "$line_file" || exit 592
grep -Fq 'SYNBATEQCLP' "$line_file" && exit 593
grep -Fxq 'curl "https://x/?q=a;//user:***REDACTED***@host/KEEPMIXD\"' "$line_file" || exit 594
grep -Fq 'SYNBATMIXD' "$line_file" && exit 595
grep -Fxq 'curl \"https://ok/x\";//user:***REDACTED***@host\"' "$line_file" || exit 596
grep -Fq 'SYNBATMIXL' "$line_file" && exit 597
# Exact outputs for the separator leak probes and their data controls.
grep -Fxq 'echo \"https://x;cat;//***REDACTED***@host\"' "$line_file" || exit 598
grep -Fq 'SYNFIXBARE01' "$line_file" && exit 599
grep -Fxq 'curl \"https://ok/x;cat;//user:***REDACTED***@host\" -H \"X: keepHeader\"' "$line_file" || exit 600
grep -Fq 'SYNFIXCOLON02' "$line_file" && exit 601
grep -Fxq 'echo \"https://x;echo;//***REDACTED***@host\"' "$line_file" || exit 602
grep -Fq 'SYNFIXBARE03' "$line_file" && exit 603
grep -Fxq 'echo \"https://x,ls;//user:***REDACTED***@host\"' "$line_file" || exit 604
grep -Fq 'SYNFIXCOLON04' "$line_file" && exit 605
grep -Fxq 'echo \"x://;//***REDACTED***@host\"' "$line_file" || exit 606
grep -Fq 'SYNFIXEMPTY05' "$line_file" && exit 607
grep -Fxq 'echo \"x://,//***REDACTED***@host\"' "$line_file" || exit 608
grep -Fq 'SYNFIXEMPTY06' "$line_file" && exit 609
grep -Fxq 'curl \"https://x/?q=a=1;b=2;//u:***REDACTED***@one.example.test\";//u:***REDACTED***@two.example.test' "$line_file" || exit 610
grep -Fq 'SYNFIXREAL07' "$line_file" && exit 611
grep -Fxq 'curl \"https://x/?q=a=1,b=2;//u:***REDACTED***@one.example.test\",//u:***REDACTED***@two.example.test' "$line_file" || exit 612
grep -Fq 'SYNFIXREAL08' "$line_file" && exit 613
grep -Fxq "curl 'https://x/?q=a=1;b=2;//u:pSYNFIXDATA09@one.example.test';//u:***REDACTED***@two.example.test" "$line_file" || exit 614
grep -Fq 'SYNFIXREAL09' "$line_file" && exit 615
grep -Fxq 'echo \"https://x;ls;//user:***REDACTED***@host; echo KEEPTAIL10\"' "$line_file" || exit 616
grep -Fq 'SYNFIXCOLON10' "$line_file" && exit 617
# Query-data controls stay byte-for-byte; assignment words before any ? leak nothing.
grep -Fxq 'curl \"https://x/?q=a=1;b=2;//u:***REDACTED***@one.example.test\";//u:***REDACTED***@two.example.test' "$line_file" || exit 618
grep -Fq 'pDATAKEEP11' "$line_file" && exit 619
grep -Fq 'realDATAKEEP11' "$line_file" && exit 620
grep -Fxq 'curl \"https://x/?q=a=1,b=2;//u:***REDACTED***@one.example.test\",//u:***REDACTED***@two.example.test' "$line_file" || exit 621
grep -Fq 'pDATAKEEP12' "$line_file" && exit 622
grep -Fq 'realDATAKEEP12' "$line_file" && exit 623
grep -Fxq "curl 'https://x/?q=a=1;b=2;//u:pDATAKEEP13@one.example.test';//u:***REDACTED***@two.example.test" "$line_file" || exit 624
grep -Fq 'pDATAKEEP13' "$line_file" || exit 625
grep -Fq 'realDATAKEEP13' "$line_file" && exit 626
grep -Fxq 'echo \"https://x;a=b;//u:***REDACTED***@host\"' "$line_file" || exit 627
grep -Fq 'LEAKASSIGN01' "$line_file" && exit 628
grep -Fxq 'echo \"https://x,k=1;//user:***REDACTED***@host\"' "$line_file" || exit 629
grep -Fq 'LEAKASSIGN02' "$line_file" && exit 630
grep -Fxq 'curl \"https://x;cat=1;//user:***REDACTED***@host\" -H \"X: keep\"' "$line_file" || exit 631
grep -Fq 'LEAKASSIGN03' "$line_file" && exit 632
grep -Fxq 'curl \"https://api.example.test/v1?verbose=1;cat=1;//user:***REDACTED***@host\" -H \"X: keep\"' "$line_file" || exit 633
grep -Fq 'LEAKQUERY01' "$line_file" && exit 634
grep -Fxq 'echo \"https://x/?q=hello;cat=1;//user:***REDACTED***@host\"' "$line_file" || exit 635
grep -Fq 'LEAKQUERY02' "$line_file" && exit 636
grep -Fxq 'echo \"https://x/?q=hello,cmd=1;//user:***REDACTED***@host\"' "$line_file" || exit 637
grep -Fq 'LEAKQUERY04' "$line_file" && exit 638
grep -Fxq 'echo \"https://x/path;v=1;b=2;//user:***REDACTED***@host\"' "$line_file" || exit 639
grep -Fq 'PATHREDACT03' "$line_file" && exit 640
# Escaped short assignments leak nothing: exact redaction plus token absence.
grep -Fxq 'echo \"https://x/?q=hello;a=1;//user:***REDACTED***@host\"' "$line_file" || exit 641
grep -Fq 'LEAKONE641' "$line_file" && exit 642
grep -Fxq 'echo \"https://x/?q=hello,b=1;//user:***REDACTED***@host\"' "$line_file" || exit 643
grep -Fq 'LEAKCOMMA642' "$line_file" && exit 644
grep -Fxq 'echo \"https://x/?q=hello;=1;//user:***REDACTED***@host\"' "$line_file" || exit 645
grep -Fq 'LEAKEMPTY643' "$line_file" && exit 646
grep -Fxq 'echo \"https://x/?q=hello;1=1;//user:***REDACTED***@host\"' "$line_file" || exit 647
grep -Fq 'LEAKDIGIT644' "$line_file" && exit 648
grep -Fxq "echo \\'https://x/?q=hello;a=1;//user:***REDACTED***@host\\'" "$line_file" || exit 649
grep -Fq 'SQESC649' "$line_file" && exit 650
grep -Fxq "curl 'https://x/?q=hello;cat=1;//u:pSQPLAIN651@one.example.test';//u:***REDACTED***@two.example.test" "$line_file" || exit 651
grep -Fq 'pSQPLAIN651' "$line_file" || exit 652
grep -Fq 'realSQPLAIN652' "$line_file" && exit 653
grep -Fxq 'echo \"https://x/?q=a=1;b=2;//u:***REDACTED***@one.test"' "$line_file" || exit 654
grep -Fq 'DQESC654' "$line_file" && exit 655
# Bare escaped authorities redact exactly; the credential never appears.
grep -Fxq 'echo \"https://x/path;//user:***REDACTED***@host\"' "$line_file" || exit 656
grep -Fxq 'echo \"https://x/path,//user:***REDACTED***@host\"' "$line_file" || exit 657
grep -Fxq "echo \\'https://x/path;//user:***REDACTED***@host\\'" "$line_file" || exit 658
grep -Fxq "echo \\'https://x/path,//user:***REDACTED***@host\\'" "$line_file" || exit 659
grep -Fq 'BARE77' "$line_file" && exit 660
# POSIX single-quote close redacts the outside authority exactly.
grep -Fxq "echo 'a\\'b;//user:***REDACTED***@host'" "$line_file" || exit 661
grep -Fq 'NORM77' "$line_file" && exit 662
grep -Fxq 'echo "note;//user:SYNTHPLAIN142@host"' "$line_file" || exit 563
grep -Fq 'SYNTHPLAIN142' "$line_file" || exit 564
grep -Fq 'SYNTHREALBND' "$line_file" && exit 517
grep -Fq 'passSemiAssign@example.test' "$line_file" && exit 254
grep -q 'Question:' "$line_file" || exit 13
printf 'lmline-meta: model=clip-model tokens=10 prompt=7 completion=3\n' >&2
printf 'lmline-status: m=clip-model; tok=7/3/10\n' >&2
printf 'clip answer\n'
# Generic Authorization schemes must mask backslash-escaped quote values.
grep -Fxq 'Authorization: abc=\"***REDACTED***\"; echo KEEPGESTAIL1' "$line_file" || exit 9180
grep -Fq SYNTHGESC001 "$line_file" && exit 9181
grep -Fxq "Authorization: abc=\'***REDACTED***\'; echo KEEPGESTAIL2" "$line_file" || exit 9182
grep -Fq SYNTHGESC002 "$line_file" && exit 9183
grep -Fxq "curl -H 'Authorization: abc=\'***REDACTED***\''; echo KEEPGESTAIL3" "$line_file" || exit 9184
grep -Fq SYNTHGESC003 "$line_file" && exit 9185
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPGESTAIL4' "$line_file" || exit 9186
grep -Fq SYNTHGESC004 "$line_file" && exit 9187
grep -Fxq 'curl -u user:***REDACTED*** https://x; echo KEEPFLAG901' "$line_file" || exit 9101
grep -Fq 'SYNTHFLAG901' "$line_file" && exit 9102
grep -Fxq 'curl --user user:***REDACTED*** https://x; echo KEEPFLAG902' "$line_file" || exit 9103
grep -Fq 'SYNTHFLAG902' "$line_file" && exit 9104
grep -Fxq 'curl -u=***REDACTED*** https://x; echo KEEPFLAG903' "$line_file" || exit 9105
grep -Fq 'SYNTHFLAG903' "$line_file" && exit 9106
grep -Fxq 'curl --password ***REDACTED*** https://x; echo KEEPFLAG904' "$line_file" || exit 9107
grep -Fq 'SYNTHFLAG904' "$line_file" && exit 9108
grep -Fxq 'curl -u "user:***REDACTED***" https://x; echo KEEPFLAG905' "$line_file" || exit 9109
grep -Fq 'SYNTHFLAG905' "$line_file" && exit 9110
grep -Fxq "curl -u 'user:***REDACTED***' https://x; echo KEEPFLAG906" "$line_file" || exit 9111
grep -Fq 'SYNTHFLAG906' "$line_file" && exit 9112
grep -Fxq 'id --user=1000; echo KEEPFLAG907' "$line_file" || exit 9113
grep -Fxq 'bash -p; echo KEEPFLAG908' "$line_file" || exit 9114
grep -Fxq 'curl -u user:***REDACTED***;echo KEEPFLAG921' "$line_file" || exit 9115
grep -Fq 'SYNTHFLAG921' "$line_file" && exit 9116
grep -Fxq 'curl -u=user:***REDACTED*** https://x; echo KEEPFLAG922' "$line_file" || exit 9117
grep -Fq 'SYNTHFLAG922' "$line_file" && exit 9118
grep -Fxq 'curl --u=user:***REDACTED*** https://x; echo KEEPFLAG923' "$line_file" || exit 9119
grep -Fq 'SYNTHFLAG923' "$line_file" && exit 9120
grep -Fxq 'curl --user=***REDACTED*** https://x; echo KEEPFLAG924' "$line_file" || exit 9121
grep -Fq 'SYNTHFLAG924' "$line_file" && exit 9122
grep -Fxq 'curl --password "***REDACTED***" https://x; echo KEEPFLAG925' "$line_file" || exit 9123
grep -Fq 'SYNTHFLAG925' "$line_file" && exit 9124
grep -Fxq "curl --password '***REDACTED***' https://x; echo KEEPFLAG926" "$line_file" || exit 9125
grep -Fq 'SYNTHFLAG926' "$line_file" && exit 9126
grep -Fxq 'curl -u "user:***REDACTED***" https://x; echo KEEPFLAG927' "$line_file" || exit 9127
grep -Fq 'SYNTHFLAG927' "$line_file" && exit 9128
grep -Fxq 'curl -u=***REDACTED***&&echo KEEPFLAG928' "$line_file" || exit 9129
grep -Fq 'SYNTHFLAG928' "$line_file" && exit 9130
grep -Fxq 'curl --password ***REDACTED***|grep KEEPFLAG929' "$line_file" || exit 9131
grep -Fq 'SYNTHFLAG929' "$line_file" && exit 9132
grep -Fxq 'curl --user=***REDACTED*** https://x; echo KEEPFLAG933' "$line_file" || exit 9133
grep -Fq 'SYNTHFLAG933' "$line_file" && exit 9134
grep -Fxq 'curl -u=\"user:***REDACTED***\" https://x; echo KEEPE1' "$line_file" || exit 9166
grep -Fq 'SYNTHQE1' "$line_file" && exit 9167
grep -Fxq 'curl --user=\"***REDACTED***\" https://x; echo KEEPE2' "$line_file" || exit 9168
grep -Fq 'SYNTHQE2' "$line_file" && exit 9169
grep -Fxq 'curl --user=***REDACTED***;echo KEEPOPS1' "$line_file" || exit 9154
grep -Fq 'SECOPS1' "$line_file" && exit 9155
grep -Fxq 'curl -u=user:***REDACTED***;echo KEEPOPS2' "$line_file" || exit 9156
grep -Fq 'SECOPS2' "$line_file" && exit 9157
grep -Fxq 'curl --password ***REDACTED***;echo KEEPOPS3' "$line_file" || exit 9158
grep -Fq 'SECOPS3' "$line_file" && exit 9159
grep -Fxq 'mysql -uadmin -p***REDACTED***; echo KEEPP941' "$line_file" || exit 9135
grep -Fq 'SYNTHP941' "$line_file" && exit 9136
grep -Fxq 'curl -u="user:***REDACTED***" https://x; echo KEEPQ01' "$line_file" || exit 9146
grep -Fq 'SYNTHQ01' "$line_file" && exit 9147
grep -Fxq "curl --user='user:***REDACTED***' https://x; echo KEEPQ02" "$line_file" || exit 9148
grep -Fq 'SYNTHQ02' "$line_file" && exit 9149
grep -Fxq 'curl -u="***REDACTED***" https://x; echo KEEPQ03' "$line_file" || exit 9150
grep -Fq 'SYNTHQ03' "$line_file" && exit 9151
grep -Fxq 'curl --user="***REDACTED***" https://x; echo KEEPQ04' "$line_file" || exit 9152
grep -Fq 'SYNTHQ04' "$line_file" && exit 9153
grep -Fxq 'mysqldump -p***REDACTED***&&echo KEEPP942' "$line_file" || exit 9137
grep -Fq 'SYNTHP942' "$line_file" && exit 9138
grep -Fxq 'bash -p; echo KEEPP943' "$line_file" || exit 9139
grep -Fxq 'ls -p /tmp; echo KEEPP944' "$line_file" || exit 9140
grep -Fxq 'mysql -p"***REDACTED***" https://x; echo KEEPP945' "$line_file" || exit 9141
grep -Fq 'SYNTHP945' "$line_file" && exit 9142
grep -Fxq "mysql -p'***REDACTED***' https://x; echo KEEPP946" "$line_file" || exit 9143
grep -Fq 'SYNTHP946' "$line_file" && exit 9144
grep -Fxq 'mysql -p"***REDACTED***">out; echo KEEPQDB1' "$line_file" || exit 9160
grep -Fq 'SYNTHQDB1' "$line_file" && exit 9161
grep -Fxq "mysql -p'***REDACTED***'<in; echo KEEPQDB2" "$line_file" || exit 9162
grep -Fq 'SYNTHQDB2' "$line_file" && exit 9163
grep -Fxq 'mysql -p"***REDACTED***">>out; echo KEEPQDB3' "$line_file" || exit 9164
grep -Fq 'SYNTHQDB3' "$line_file" && exit 9165
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***";echo KEEPGLUE101' "$line_file" || exit 9145
grep -Fq 'SYNTHGLUE101' "$line_file" && exit 9146
grep -Fxq "curl -H 'Authorization: Bearer ***REDACTED***'&&echo KEEPGLUE102" "$line_file" || exit 9147
grep -Fq 'SYNTHGLUE102' "$line_file" && exit 9148
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"&echo KEEPGLUE103' "$line_file" || exit 9149
grep -Fq 'SYNTHGLUE103' "$line_file" && exit 9150
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"2>err;echo KEEPGLUE104' "$line_file" || exit 9151
grep -Fq 'SYNTHGLUE104' "$line_file" && exit 9152
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPGLUE105' "$line_file" || exit 9153
grep -Fq 'SYNTHGLUE105' "$line_file" && exit 9154
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
# Mutation: restricting escaped-quote rules to recognized schemes leaks these values.
[[ $(grep -Fc '${auth_scheme_any}' "$repo_dir/lmline/actions.bash") == 11 ]] || fail "expected eleven generic scheme escaped-quote rules"
sed 's/${auth_scheme_any}/${auth_scheme_name}/g' "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-recognized-esc-quotes.bash" || fail "escaped-quote scheme mutation copy"
grep -Fq '${auth_scheme_any}' "$cfg_tmp/actions-recognized-esc-quotes.bash" && fail "escaped-quote scheme mutation did not apply"
generic_esc_fixtures=(
  'Authorization: abc=\"SYNTHGESC001\"; echo KEEPGESTAIL1'
  "Authorization: abc=\\'SYNTHGESC002\\'; echo KEEPGESTAIL2"
  "curl -H 'Authorization: abc=\\'SYNTHGESC003\\''; echo KEEPGESTAIL3"
  'curl -H "Authorization: abc=\"SYNTHGESC004\""; echo KEEPGESTAIL4'
)
generic_esc_secrets=(SYNTHGESC001 SYNTHGESC002 SYNTHGESC003)
for mutation_index in 0 1 2; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-recognized-esc-quotes.bash" "${generic_esc_fixtures[$mutation_index]}") || fail "mutated escaped-quote scheme $mutation_index"
  grep -Fq "${generic_esc_secrets[$mutation_index]}" <<<"$mutated" || fail "recognized-scheme mutation $mutation_index did not leak"
done

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
  grep -Fxq 'https://***REDACTED***@example.test/x' <<<"$fallback_userinfo" || fail "invalid userinfo threshold $invalid_userinfo_min did not fall back"
done

# The direct forms must also stay valid shell text after redaction: the
# unfixed rule left the synthetic tail behind and bash -n returned rc=2.
quoted_tail_fixtures=(
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"| :'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07">out'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07">>out'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"<in'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"2>err'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"2>&1'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"1>>out'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"10>out'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"& :'
  'curl -H "Authorization: Bearer abc""pa\\\"inside space""pb TAILAUDIT07"&& :'
)
for quoted_tail_fixture in "${quoted_tail_fixtures[@]}"; do
  quoted_tail_redacted=$(bash -c 'source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ "$repo_dir/lmline/actions.bash" "$quoted_tail_fixture") || fail "quoted tail redaction: $quoted_tail_fixture"
  printf '%s\n' "$quoted_tail_redacted" | bash -n || fail "quoted tail redaction is not valid shell text: $quoted_tail_redacted"
done

# Mutation check: deleting the chained-key rules must break the exact preservation
# assertions above; the unfixed redactor consumes the following credential field.
grep -v 'key_prefix_keep_url' "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-keep.bash" || fail "redaction mutation copy"
mutation_fixtures=(
  'url=https://x/?\"token\"=\"SYNTHKEEPESCQ1\"&password=SYNTHKEEPESCQ2; echo KEEPESCQ'
  "url=https://x/?\\'token\\'=\\'SYNTHKEEPESCSQ1\\'&password=SYNTHKEEPESCSQ2; echo KEEPESCSQ"
)
mutation_expected=(
  'url=https://x/?"token"="***REDACTED***"&password=***REDACTED***; echo KEEPESCQ'
  "url=https://x/?'token'='***REDACTED***'&password=***REDACTED***; echo KEEPESCSQ"
)
for mutation_index in 0 1; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-keep.bash" "${mutation_fixtures[$mutation_index]}") || fail "mutated redaction $mutation_index"
  grep -Fxq "${mutation_expected[$mutation_index]}" <<<"$mutated" && fail "mutated rule $mutation_index still passes the exact assertion"
  grep -Fq '&password=' <<<"$mutated" && fail "mutated rule $mutation_index kept the field boundary"
done

# Mutation check: deleting the per-header UPQ rule must leak the first header.
grep -vF '(^|[^A-Za-z0-9_])' "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-upq.bash" || fail "redaction mutation copy"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-no-upq.bash" 'Authorization: Bearer=FIRST"SYNTHUPQ5"; Authorization: Bearer=SECOND"SYNTHUPQ6"; echo KEEPUPQ5') || fail "mutated UPQ redaction"
grep -Fq 'SYNTHUPQ5' <<<"$mutated" || fail "mutated UPQ rule did not leak the first header"

# Mutation check: deleting the escaped-open-quote value rule must leak both
# escaped fixtures while leaving the plain-quoted control intact.
grep -vF '(([^[:space:];,&|' "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-escaped-upq.bash" || fail "redaction mutation copy"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-no-escaped-upq.bash" "Authorization: Bearer=AAA'SYNTHUPQESC1'; Authorization: Basic=BBB\\\"SYNTHUPQESC1\\\"; echo KEEPUPQESC1") || fail "mutated escaped UPQ redaction 1"
grep -Fq 'SYNTHUPQESC1' <<<"$mutated" || fail "mutated escaped rule 1 did not leak the value"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-no-escaped-upq.bash" "Authorization: Bearer=AAA'SYNTHUPQESC2'; Authorization: Basic=BBB\\\\\"SYNTHUPQESC2\\\\\"; echo KEEPUPQESC2") || fail "mutated escaped UPQ redaction 2"
grep -Fq 'SYNTHUPQESC2' <<<"$mutated" || fail "mutated escaped rule 2 did not leak the value"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-no-escaped-upq.bash" "Authorization: Bearer=AAA'SYNTHUPQESC3'; Authorization: Basic=BBB'SYNTHUPQESC3'; echo KEEPUPQESC3") || fail "mutated control redaction"
grep -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC3' <<<"$mutated" || fail "mutated control fixture changed"

# Mutation check: removing all generalized scheme rules must leak the custom
# headers while leaving the URL realm and Digest controls unchanged.
generalized_rule='${auth_prefix}(${auth_scheme_token}+)([:=]+)'
[[ $(grep -cF "$generalized_rule" "$repo_dir/lmline/actions.bash") == 4 ]] || fail "expected four generalized scheme rules"
grep -vF "$generalized_rule" "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-any-scheme.bash" || fail "redaction mutation copy"
scheme_mutation_fixtures=(
  'Authorization: Bearer=FIRST\"SYNTHCUSTM1\"; Authorization: Custom=SECOND\"SYNTHCUSTM2\"; echo KEEPCUSTOM1'
  'Authorization: Custom=ONLY\"SYNTHCUSTM3\"; echo KEEPCUSTOM2'
  'Authorization: X-OAuth2=FIRST\"SYNTHXAUTH1\"; Authorization: X-OAuth2=SECOND\"SYNTHXAUTH2\"; echo KEEPCUSTOM3'
  'url=https://x/?realm=\"example.com\"; echo KEEPTAIL5'
  'Authorization: Digest realm=\"example.com\", nonce=\"abc123\"; echo KEEPTAIL4'
)
scheme_mutation_leaks=(SYNTHCUSTM SYNTHCUSTM3 SYNTHXAUTH)
scheme_mutation_controls=(
  'url=https://x/?realm=\"example.com\"; echo KEEPTAIL5'
  'Authorization: Digest ***REDACTED***'
)
for mutation_index in 0 1 2; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-any-scheme.bash" "${scheme_mutation_fixtures[$mutation_index]}") || fail "mutated scheme redaction $mutation_index"
  grep -Fq "${scheme_mutation_leaks[$mutation_index]}" <<<"$mutated" || fail "mutated scheme rule $mutation_index did not leak the custom credential"
done
for mutation_index in 3 4; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-any-scheme.bash" "${scheme_mutation_fixtures[$mutation_index]}") || fail "mutated scheme control redaction $mutation_index"
  grep -Fxq "${scheme_mutation_controls[$mutation_index - 3]}" <<<"$mutated" || fail "mutated scheme rule changed control $mutation_index"
done

# The same deletion restores all quoted -H tails, while the bare-line
# escaped-header control still masks.
[[ $(grep -cF '(([^[:space:];,&|' "$repo_dir/lmline/actions.bash") == 2 ]] || fail "expected two escaped-open-quote value rules"
quoted_tail_mutation_fixtures=(
  "curl -H \"Authorization: Bearer=AAA'FIRSTSECRET'; Authorization: Basic=BBB\\\"SECONDSECRET\\\"\" https://x; echo KEEPTAIL"
  "curl -H 'Authorization: Basic=BBB\\\"ONLYSECRET\\\"' -H 'X: keep' https://x; echo KEEPTAIL"
  "curl -H \"Authorization: Bearer=AAA\\\"SINGLESECRET\\\"\" https://x; echo KEEPTAIL"
  'Authorization: Bearer=\"SYNTHBAREQUOTED4\"; echo KEEPTAILBARE'
)
quoted_tail_mutation_expected=(
  'curl -H "Authorization: Bearer=***REDACTED***; Authorization: ***REDACTED***" https://x; echo KEEPTAIL'
  "curl -H 'Authorization: ***REDACTED***' -H 'X: keep' https://x; echo KEEPTAIL"
  'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPTAIL'
  'Authorization: Bearer=\"***REDACTED***\"; echo KEEPTAILBARE'
)
quoted_tail_mutation_secrets=(FIRSTSECRET SECONDSECRET ONLYSECRET SINGLESECRET SYNTHBAREQUOTED4)
for mutation_index in 0 1 2 3; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-escaped-upq.bash" "${quoted_tail_mutation_fixtures[$mutation_index]}") || fail "mutated quoted tail redaction $mutation_index"
  grep -Fxq "${quoted_tail_mutation_expected[$mutation_index]}" <<<"$mutated" || fail "mutated rule $mutation_index changed the quoted tail"
  grep -Fq "${quoted_tail_mutation_secrets[$mutation_index]}" <<<"$mutated" && fail "mutated rule $mutation_index leaked a secret"
done

bare_mixed_rule=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(Authorization:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)['\"]([^[:space:];,&|\\\\]|\\\\.)*/\1\2/Ig" \
RULE
)

interior_quote_alt_dq="|'[^[:space:];,&|\\\"']|\\\"[^[:space:];,&|\\\"']"
interior_quote_alt_sq="|\\\"[^[:space:];,&|\\\"']|'[^[:space:];,&|\\\"']"
# The bare-quote alternatives are absent from the escaped-separator Authorization
# rules; the exact closure fixtures above fail if either alternative is reintroduced.
[[ $(grep -cF "$interior_quote_alt_dq" "$repo_dir/lmline/actions.bash") == 0 ]] || fail "double-quote interior alternative reintroduced"
[[ $(grep -cF "$interior_quote_alt_sq" "$repo_dir/lmline/actions.bash") == 0 ]] || fail "single-quote interior alternative reintroduced"

# Removing the staged same-family restriction must drop an adjacent tail.
staged_tail_rule="(\\\\\\\\+[\\\"']([^[:space:];,&|\\\"'])*)*"
[[ $(grep -cF "$staged_tail_rule" "$repo_dir/lmline/actions.bash") == 2 ]] || fail "expected two staged tail rules"
A="$staged_tail_rule" awk 'BEGIN{a=ENVIRON["A"]} { while ((i=index($0,a))) $0=substr($0,1,i-1) substr($0,i+length(a)); print }' \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-staged-tail.bash" || fail "staged tail mutation copy"

# Mutation check: removing the two mixed-quote residue rules must leak both
# credentials, while the shipped redactor masks them.
mixed_dq_rule=$(cat <<'RULE'
    -e "s/(\"Authorization:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)'([^\"\\\\]|\\\\.)*((\")|\\\\?\$)/\1\4/Ig" \
RULE
)
mixed_sq_rule=$(cat <<'RULE'
    -e "s/('Authorization:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)\"([^'\\\\]|\\\\.)*((')|\\\\?\$)/\1\3/Ig" \
RULE
)
[[ $(grep -cF "$mixed_dq_rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one mixed double-quote residue rule"
[[ $(grep -cF "$mixed_sq_rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one mixed single-quote residue rule"
grep -vF -e "$mixed_dq_rule" -e "$mixed_sq_rule" "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-mixed-quote.bash" || fail "redaction mutation copy"
mixed_quote_fixtures=(
  "curl -H \"Authorization: Bearer:abc\\'\\\"'SECRETZZ\\'\"X; echo KEEPTAIL"
  "curl -H 'Authorization: Bearer:abc\\\"\\'\"SECRETMM\\\"'X; echo MIRRORTAIL"
  "curl -H\"Authorization: Bearer:abc\\'\\\"'SECRETZZ\\'\"X; echo KEEPTAIL"
  "curl -H'Authorization: Bearer:abc\\\"\\'\"SECRETMM\\\"'X; echo KEEPTAIL"
)
mixed_quote_secrets=(SECRETZZ SECRETMM SECRETZZ SECRETMM)
for mutation_index in 0 1 2 3; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-mixed-quote.bash" "${mixed_quote_fixtures[$mutation_index]}") || fail "mutated mixed-quote redaction $mutation_index"
  grep -Fq "${mixed_quote_secrets[$mutation_index]}" <<<"$mutated" || fail "mutated mixed-quote rule $mutation_index did not leak the credential"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${mixed_quote_fixtures[$mutation_index]}") || fail "shipped mixed-quote redaction $mutation_index"
  grep -Fq "${mixed_quote_secrets[$mutation_index]}" <<<"$shipped" && fail "shipped mixed-quote rule $mutation_index leaked the credential"
done

# Mutation check: removing the bare-prefix mixed-quote residue rule must
# leak both new credentials, while the shipped redactor masks them.
[[ $(grep -cF "$bare_mixed_rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one bare mixed-quote residue rule"
grep -vF "$bare_mixed_rule" "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-bare-mixed.bash" || fail "redaction mutation copy"
bare_mixed_fixtures=(
  "Authorization: Bearer:abc\\'\\\"'LEAKMIN987\\'\\\" -H \"X: keep\" https://x; echo KEEPTAIL"
  "Authorization: Bearer:abc\\\"\\'\"LEAKMIRROR988\\\"\\' -H 'X: keep' https://x; echo KEEPTAIL"
)
bare_mixed_secrets=(LEAKMIN987 LEAKMIRROR988)
for mutation_index in 0 1; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-bare-mixed.bash" "${bare_mixed_fixtures[$mutation_index]}") || fail "mutated bare mixed-quote redaction $mutation_index"
  grep -Fq "${bare_mixed_secrets[$mutation_index]}" <<<"$mutated" || fail "mutated bare mixed-quote rule $mutation_index did not leak the credential"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${bare_mixed_fixtures[$mutation_index]}") || fail "shipped bare mixed-quote redaction $mutation_index"
  grep -Fq "${bare_mixed_secrets[$mutation_index]}" <<<"$shipped" && fail "shipped bare mixed-quote rule $mutation_index leaked the credential"
done

# Mutation check: the terminal quoted-Authorization tail rules must stop at shell separators.
tail_rule1=$(cat <<'RULE'
    -e "s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
RULE
)
tail_rule2=$(cat <<'RULE'
    -e "s/('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
RULE
)
for rule in "$tail_rule1" "$tail_rule2"; do
  [[ $(grep -cF "$rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one malformed-header tail rule"
done
grep -vF -e "$tail_rule1" -e "$tail_rule2" "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-wide-tail.bash" || fail "malformed-header tail mutation copy"
tail_fixture='curl -H "Authorization: Bearer: SYNTHQSEP931"; echo KEEPQSEPTAIL31'
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-wide-tail.bash" "$tail_fixture") || fail "mutated tail redaction"
grep -Fq SYNTHQSEP931 <<<"$mutated" || fail "mutated tail rule did not leak the credential"
shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$repo_dir/lmline/actions.bash" "$tail_fixture") || fail "shipped tail redaction"
grep -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPQSEPTAIL31' <<<"$shipped" || fail "shipped tail rule lost the separator"

# Shipped guard: a credential that merely contains a marker spelling stays
# live and is masked, while an already-redacted header keeps its following text.
marker_fixtures=(
  'curl -H "Authorization: Bearer:*SYNTHGUARD941"; echo KEEPGUARD941'
  "curl -H 'Authorization: Basic:@SYNTHGUARD942'; echo KEEPGUARD942"
  'curl -H "Authorization: Bearer: MYREDACTEDTOKEN"; echo KEEPWORD941'
  "curl -H 'Authorization: Bearer: TOKEN_WITH_REDACTED_PART'; echo KEEPWORD942"
  'curl -H "Authorization: Bearer: REDACTED"; echo KEEPWORD943'
)
marker_expected=(
  'curl -H "Authorization: ***REDACTED***"; echo KEEPGUARD941'
  "curl -H 'Authorization: ***REDACTED***'; echo KEEPGUARD942"
  'curl -H "Authorization: ***REDACTED***"; echo KEEPWORD941'
  "curl -H 'Authorization: ***REDACTED***'; echo KEEPWORD942"
  'curl -H "Authorization: ***REDACTED***"; echo KEEPWORD943'
)
for mutation_index in 0 1 2 3 4; do
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${marker_fixtures[$mutation_index]}") || fail "shipped marker guard $mutation_index"
  grep -Fxq "${marker_expected[$mutation_index]}" <<<"$shipped" || fail "shipped marker guard $mutation_index did not mask the credential"
done

# A live credential that ends with either marker spelling must be masked, and
# masking it twice must be stable. These are the same fixtures used end to end
# in the fake-engine clipboard above.
suffix_fixtures=(
  'curl -H "Authorization: Bearer: REALSECRET941***REDACTED***"; echo KEEPENDRED1'
  "curl -H 'Authorization: Bearer: REALSECRET942***REDACTED***'; echo KEEPENDRED2"
  'curl -H "Authorization: Bearer: REALSECRET943@@LMLINE_REDACTED@@"; echo KEEPENDRED3'
  "curl -H 'Authorization: Bearer: REALSECRET944@@LMLINE_REDACTED@@'; echo KEEPENDRED4"
)
suffix_expected=(
  'curl -H "Authorization: ***REDACTED***"; echo KEEPENDRED1'
  "curl -H 'Authorization: ***REDACTED***'; echo KEEPENDRED2"
  'curl -H "Authorization: ***REDACTED***"; echo KEEPENDRED3'
  "curl -H 'Authorization: ***REDACTED***'; echo KEEPENDRED4"
)
for mutation_index in 0 1 2 3; do
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${suffix_fixtures[$mutation_index]}") || fail "shipped suffix redaction $mutation_index"
  grep -Fxq "${suffix_expected[$mutation_index]}" <<<"$shipped" || fail "shipped suffix redaction $mutation_index did not mask the credential"
  again=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "$shipped") || fail "idempotent suffix redaction $mutation_index"
  [[ $again == "$shipped" ]] || fail "idempotent suffix redaction $mutation_index changed the output"
done

# Mutation check: removing only the per-header shield leaks a live header that
# follows a redacted one, because the terminal rules are no longer line-guarded.
shield_rule1=$(cat <<'RULE'
    -e 's/(\"[^\"]*Authorization:[[:space:]]*'"${auth_redacted_value}"')\"/\1 \"/Ig' \
RULE
)
shield_rule2=$(cat <<'RULE'
    -e "s/('[^']*Authorization:[[:space:]]*${auth_redacted_value})'/\1 '/Ig" \
RULE
)
shield_rule3=$(cat <<'RULE'
    -e 's/("[^"]*Authorization:[^"]*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)) "/\1"/Ig' \
RULE
)
shield_rule4=$(cat <<'RULE'
    -e "s/('[^']*Authorization:[^']*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)) '/\1'/Ig" \
RULE
)
for rule in "$shield_rule1" "$shield_rule2"; do
  [[ $(grep -cF "$rule" "$repo_dir/lmline/actions.bash") == 2 ]] || fail "expected two marker shield rules"
done

# Mutation check: restoring a suffix-based shield (the vulnerable behavior)
# must leak the live credential, while the shipped canonical-shape rules mask it.
vulnerable_rule1=$(cat <<'RULE'
    -e 's/(\"[^\"]*Authorization:[^\"]*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@))\"/\1 \"/Ig' \
RULE
)
vulnerable_rule2=$(cat <<'RULE'
    -e "s/('[^']*Authorization:[^']*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@))'/\1 '/Ig" \
RULE
)
while IFS= read -r rule_line; do
  case $rule_line in
    "$shield_rule1") printf '%s\n' "$vulnerable_rule1" ;;
    "$shield_rule2") printf '%s\n' "$vulnerable_rule2" ;;
    *) printf '%s\n' "$rule_line" ;;
  esac
done <"$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-suffix-shield.bash" || fail "suffix shield mutation copy"
for vulnerable in "$vulnerable_rule1" "$vulnerable_rule2"; do
  [[ $(grep -cF "$vulnerable" "$cfg_tmp/actions-suffix-shield.bash") == 2 ]] || fail "suffix shield mutation did not apply"
done
for mutation_index in 0 1 2 3; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-suffix-shield.bash" "${suffix_fixtures[$mutation_index]}") || fail "suffix shield mutation redaction $mutation_index"
  grep -Fq "REALSECRET$((941 + mutation_index))" <<<"$mutated" || fail "suffix shield mutation $mutation_index did not leak the credential"
done
grep -vF -e "$shield_rule1" -e "$shield_rule2" -e "$shield_rule3" -e "$shield_rule4" \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-shield.bash" || fail "marker shield mutation copy"
second_header_fixtures=(
  'curl -H "Authorization: Bearer: ***REDACTED***" -H "Authorization: Bearer: REALSECRET89"; echo KEEPZZ9'
  "curl -H 'Authorization: Bearer: ***REDACTED***' -H 'Authorization: Bearer: REALSECRET89'; echo KEEPZZ9"
)
for mutation_index in 0 1; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-shield.bash" "${second_header_fixtures[$mutation_index]}") || fail "unshielded marker redaction $mutation_index"
  grep -Fq REALSECRET89 <<<"$mutated" || fail "marker shield mutation $mutation_index did not leak the second header"
done

# Mutation check: restoring the loose line-wide guard together with removing the
# shield resurrects both fail-open inputs; the shipped guard masks both.
loose_rule1=$(cat <<'RULE'
    -e "/Authorization:.*(@@LMLINE_REDACTED@@|\\*\\*\\*REDACTED\\*\\*\\*)/!s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
RULE
)
loose_rule2=$(cat <<'RULE'
    -e "/Authorization:.*(@@LMLINE_REDACTED@@|\\*\\*\\*REDACTED\\*\\*\\*)/!s/('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
RULE
)
terminal_rule_line1=$(grep -nF "$tail_rule1" "$cfg_tmp/actions-no-shield.bash" | cut -d: -f1)
printf '%s\n' "$loose_rule1" >"$cfg_tmp/loose-rule1"
awk -v n="$terminal_rule_line1" -v repl="$cfg_tmp/loose-rule1" 'NR==n {while ((getline line < repl) > 0) print line; next} {print}' \
  "$cfg_tmp/actions-no-shield.bash" >"$cfg_tmp/actions-loose-guard.bash" || fail "loose guard mutation copy 1"
terminal_rule_line2=$(grep -nF "$tail_rule2" "$cfg_tmp/actions-loose-guard.bash" | cut -d: -f1)
printf '%s\n' "$loose_rule2" >"$cfg_tmp/loose-rule2"
awk -v n="$terminal_rule_line2" -v repl="$cfg_tmp/loose-rule2" 'NR==n {while ((getline line < repl) > 0) print line; next} {print}' \
  "$cfg_tmp/actions-loose-guard.bash" >"$cfg_tmp/actions-loose-guarded.bash" || fail "loose guard mutation copy 2"
loose_fixtures=(
  'curl -H "Authorization: Bearer: abc***REDACTED***xyz"; echo KEEPZZ'
  "curl -H 'Authorization: Bearer: abc***REDACTED***xyz'; echo KEEPZZ"
  'curl -H "Authorization: Bearer: ***REDACTED***" -H "Authorization: Bearer: REALSECRET89"; echo KEEPZZ9'
  "curl -H 'Authorization: Bearer: ***REDACTED***' -H 'Authorization: Bearer: REALSECRET89'; echo KEEPZZ9"
)
loose_secrets=(abc***REDACTED***xyz abc***REDACTED***xyz REALSECRET89 REALSECRET89)
loose_expected=(
  'curl -H "Authorization: ***REDACTED***"; echo KEEPZZ'
  "curl -H 'Authorization: ***REDACTED***'; echo KEEPZZ"
  'curl -H "Authorization: ***REDACTED***" -H "Authorization: ***REDACTED***"; echo KEEPZZ9'
  "curl -H 'Authorization: ***REDACTED***' -H 'Authorization: ***REDACTED***'; echo KEEPZZ9"
)
for mutation_index in 0 1 2 3; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-loose-guarded.bash" "${loose_fixtures[$mutation_index]}") || fail "loose guard redaction $mutation_index"
  grep -Fq "${loose_secrets[$mutation_index]}" <<<"$mutated" || fail "loose guard mutation $mutation_index did not leak the credential"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${loose_fixtures[$mutation_index]}") || fail "shipped loose guard redaction $mutation_index"
  grep -Fxq "${loose_expected[$mutation_index]}" <<<"$shipped" || fail "shipped guard $mutation_index did not mask the credential"
done

# Mutation check: deleting the scheme-separator whitespace rule must leak
# each credential, while the shipped redactor masks it and keeps the tail.
scheme_space_rule=$(cat <<'RULE'
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)[[:space:]]+/\1\2\3/Ig" \
RULE
)
scheme_space_generic_rule=$(cat <<'RULE'
    -e "s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+/\1\2\3/Ig" \
RULE
)
[[ $(grep -cF "$scheme_space_rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one scheme-separator whitespace rule"
[[ $(grep -cF "$scheme_space_generic_rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one generic scheme-separator whitespace rule"
grep -vF -e "$scheme_space_rule" -e "$scheme_space_generic_rule" "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-scheme-space.bash" || fail "scheme-separator whitespace mutation copy"
scheme_space_fixtures=(
  'Authorization: Bearer: SYNTHSEP901; echo KEEPSEPTAIL1'
  'Authorization: Bearer= SYNTHSEP902; echo KEEPSEPTAIL2'
  'Authorization: Basic: SYNTHSEP903; echo KEEPSEPTAIL3'
  'curl -H "Authorization: Bearer: SYNTHQSEP921"; echo KEEPQSEPTAIL21'
  "curl -H 'Authorization: Basic= SYNTHQSEP922'; echo KEEPQSEPTAIL22"
)
scheme_space_secrets=(SYNTHSEP901 SYNTHSEP902 SYNTHSEP903 SYNTHQSEP921 SYNTHQSEP922)
scheme_space_tails=(KEEPSEPTAIL1 KEEPSEPTAIL2 KEEPSEPTAIL3 KEEPQSEPTAIL21 KEEPQSEPTAIL22)
for mutation_index in 0 1 2 3 4; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-scheme-space.bash" "${scheme_space_fixtures[$mutation_index]}") || fail "mutated scheme-separator redaction $mutation_index"
  grep -Fq "${scheme_space_secrets[$mutation_index]}" <<<"$mutated" || fail "mutated scheme-separator rule $mutation_index did not leak the credential"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${scheme_space_fixtures[$mutation_index]}") || fail "shipped scheme-separator redaction $mutation_index"
  grep -Fq "${scheme_space_secrets[$mutation_index]}" <<<"$shipped" && fail "shipped scheme-separator rule $mutation_index leaked the credential"
  grep -Fq "${scheme_space_tails[$mutation_index]}" <<<"$shipped" || fail "shipped scheme-separator rule $mutation_index lost the tail"
done

# Mutation check: deleting the glued-scheme value rule leaks both credentials
# while the shipped redactor keeps the following word and command tail.
glued_rule=$(cat <<'RULE'
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"'[:space:];,&|]+)([[:space:]]+)/\1***REDACTED***\5/Ig" \
RULE
)
[[ $(grep -cF "$glued_rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one glued-scheme value rule"
grep -vF "$glued_rule" "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-glued-scheme.bash" || fail "glued-scheme mutation copy"
glued_fixtures=(
  'Authorization: Bearer=SYNTHGLUED901 https://x; echo KEEPGLUEDTAIL1'
  'Authorization: Basic:abcSYNTHGLUED902 foo; echo KEEPGLUEDTAIL2'
)
glued_secrets=(SYNTHGLUED901 SYNTHGLUED902)
glued_tails=('https://x; echo KEEPGLUEDTAIL1' 'foo; echo KEEPGLUEDTAIL2')
for mutation_index in 0 1; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-glued-scheme.bash" "${glued_fixtures[$mutation_index]}") || fail "mutated glued-scheme redaction $mutation_index"
  grep -Fq "${glued_secrets[$mutation_index]}" <<<"$mutated" || fail "mutated glued-scheme rule $mutation_index did not leak the credential"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${glued_fixtures[$mutation_index]}") || fail "shipped glued-scheme redaction $mutation_index"
  grep -Fq "${glued_secrets[$mutation_index]}" <<<"$shipped" && fail "shipped glued-scheme rule $mutation_index leaked the credential"
  grep -Fq "${glued_tails[$mutation_index]}" <<<"$shipped" || fail "shipped glued-scheme rule $mutation_index lost the tail"
done

# Mutation check: removing the quote-terminated value rules must delete a
# following quoted argument, while the shipped redactor preserves it.
qrule_double=$(cat <<'RULE'
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"='[:space:];,&|]+)(\")([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
RULE
)
qrule_single=$(cat <<'RULE'
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"='[:space:];,&|]+)(')([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
RULE
)
qrule_convert=$(cat <<'RULE'
    -e "s/==LMLINE_AUTH_VALUE==/@@LMLINE_REDACTED@@/Ig" \
RULE
)
for rule in "$qrule_double" "$qrule_single" "$qrule_convert"; do
  [[ $(grep -cF "$rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one quoted-argument protection rule"
done
grep -vF -e "$qrule_double" -e "$qrule_single" -e "$qrule_convert" \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-quoted-arg.bash" || fail "quoted-argument mutation removal"
arg_fixtures=('curl -H "Authorization: Basic=SYNTHARG905" -H "X: keep" https://x; echo KEEPARGTAIL5' 'curl -H '"'"'Authorization: Basic=SYNTHARG906'"'"' -H '"'"'X: keep'"'"' https://x; echo KEEPARGTAIL6' 'curl -H "Authorization: Bearer=SYNTHARG907" "payload907" https://x; echo KEEPARGTAIL7' 'curl -H '"'"'Authorization: Bearer=SYNTHARG908'"'"' '"'"'payload908'"'"' https://x; echo KEEPARGTAIL8')
arg_victims=('X: keep' 'X: keep' payload907 payload908)
for mutation_index in 0 1 2 3; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-quoted-arg.bash" "${arg_fixtures[$mutation_index]}") || fail "mutated quoted-argument redaction $mutation_index"
  grep -Fq "${arg_victims[$mutation_index]}" <<<"$mutated" && fail "mutated quoted-argument rule $mutation_index kept the argument"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${arg_fixtures[$mutation_index]}") || fail "shipped quoted-argument redaction $mutation_index"
  grep -Fq "${arg_victims[$mutation_index]}" <<<"$shipped" || fail "shipped quoted-argument rule $mutation_index lost the argument"
done

# Mutation check: deleting the CLI auth flag rules leaks each credential.
flag_rule1=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([^[:space:]\"':;,|&]+):([^[:space:]\"';,&|]+)/\1\2\3:@@LMLINE_REDACTED@@/Ig" \
RULE
)
flag_rule2=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-u=|--u=)([^[:space:]\"':;,|&]+)([[:space:];,&|]|$)/\1\2@@LMLINE_REDACTED@@\4/Ig" \
RULE
)
flag_rule2b=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(--user=)([0-9]*[^0-9[:space:]\"':;,|&][^[:space:]\"':;,|&]*)([[:space:];,&|]|$)/\1\2@@LMLINE_REDACTED@@\4/Ig" \
RULE
)
flag_rule3=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-u[[:space:]]+|--u[[:space:]]+|--user[[:space:]]+)([^[:space:]\"':;,|&]+):([^[:space:]\"';,&|]+)/\1\2\3:@@LMLINE_REDACTED@@/Ig" \
RULE
)
flag_rule4=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-u[[:space:]]+|--u[[:space:]]+|--user[[:space:]]+)([\"'])([^[:space:]\"':]+):([^\"']+)([\"'])/\1\2\3\4:@@LMLINE_REDACTED@@\6/Ig" \
RULE
)
flag_rule5=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(--password[[:space:]]+)([^[:space:]\"';,&|]+)/\1\2@@LMLINE_REDACTED@@/Ig" \
RULE
)
flag_rule5dq=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(--password[[:space:]]+)(\")([^\"']+)([\"])/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
RULE
)
flag_rule5sq=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(--password[[:space:]]+)(')([^']+)(')/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
RULE
)
flag_rule_quoted1=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([\"'])([^[:space:]\"':]+):([^\"']+)([\"'])/\1\2\3\4:@@LMLINE_REDACTED@@\6/Ig" \
RULE
)
flag_rule_quoted2=$(cat <<'RULE'
    -e "/@@LMLINE_REDACTED@@/!s/(^|[[:space:]])(-u=|--u=|--user=)([\"'])([^\"']+)([\"'])/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
RULE
)
flag_rule_escaped1=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)(\\\\*)\"([^[:space:]\"':]+):([^\"\\\\']*)(\\\\*)\"/\1\2\3\"\4:@@LMLINE_REDACTED@@\6\"/Ig" \
RULE
)
flag_rule_escaped2=$(cat <<'RULE'
    -e "/@@LMLINE_REDACTED@@/!s/(^|[[:space:]])(-u=|--u=|--user=)(\\\\*)\"([^\"\\\\']*)(\\\\*)\"/\1\2\3\"@@LMLINE_REDACTED@@\5\"/Ig" \
RULE
)
flag_rules=("$flag_rule1" "$flag_rule2" "$flag_rule2b" "$flag_rule3" "$flag_rule4" "$flag_rule5" "$flag_rule5dq" "$flag_rule5sq" "$flag_rule_quoted1" "$flag_rule_quoted2" "$flag_rule_escaped1" "$flag_rule_escaped2")
for rule in "${flag_rules[@]}"; do
  [[ $(grep -cF "$rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one CLI auth flag rule"
done
grep -vF -e "$flag_rule1" -e "$flag_rule2" -e "$flag_rule2b" -e "$flag_rule3" -e "$flag_rule4" -e "$flag_rule5" -e "$flag_rule5dq" -e "$flag_rule5sq" \
  -e "$flag_rule_escaped1" -e "$flag_rule_escaped2" \
  -e "$flag_rule_quoted1" -e "$flag_rule_quoted2" \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-cli-flags.bash" || fail "CLI auth flag mutation removal"
flag_fixtures=('curl -u user:SYNTHFLAG911 https://x; echo KEEPFLAG911' 'curl --user user:SYNTHFLAG912 https://x; echo KEEPFLAG912' 'curl -u=SYNTHFLAG913 https://x; echo KEEPFLAG913' 'curl --password SYNTHFLAG914 https://x; echo KEEPFLAG914' 'curl -u "user:SYNTHFLAG915" https://x; echo KEEPFLAG915' "curl -u 'user:SYNTHFLAG916' https://x; echo KEEPFLAG916" 'curl -u user:SYNTHFLAG921;echo KEEPFLAG921' 'curl -u=user:SYNTHFLAG922 https://x; echo KEEPFLAG922' 'curl --u=user:SYNTHFLAG923 https://x; echo KEEPFLAG923' 'curl --user=SYNTHFLAG924 https://x; echo KEEPFLAG924' 'curl --password "SYNTHFLAG925" https://x; echo KEEPFLAG925' "curl --password 'SYNTHFLAG926' https://x; echo KEEPFLAG926" 'curl -u "user:pass wordSYNTHFLAG927" https://x; echo KEEPFLAG927' 'curl -u=SYNTHFLAG928&&echo KEEPFLAG928' 'curl --password SYNTHFLAG929|grep KEEPFLAG929' 'curl --user=1SYNTHFLAG933 https://x; echo KEEPFLAG933' 'curl -u="user:SYNTHQ01" https://x; echo KEEPQ01' "curl --user='user:SYNTHQ02' https://x; echo KEEPQ02" 'curl -u="SYNTHQ03" https://x; echo KEEPQ03' 'curl --user="SYNTHQ04" https://x; echo KEEPQ04' 'curl -u=\"user:SYNTHQE1\" https://x; echo KEEPE1' 'curl --user=\"SYNTHQE2\" https://x; echo KEEPE2')
flag_secrets=(SYNTHFLAG911 SYNTHFLAG912 SYNTHFLAG913 SYNTHFLAG914 SYNTHFLAG915 SYNTHFLAG916 SYNTHFLAG921 SYNTHFLAG922 SYNTHFLAG923 SYNTHFLAG924 SYNTHFLAG925 SYNTHFLAG926 SYNTHFLAG927 SYNTHFLAG928 SYNTHFLAG929 SYNTHFLAG933 SYNTHQ01 SYNTHQ02 SYNTHQ03 SYNTHQ04 SYNTHQE1 SYNTHQE2)
for mutation_index in "${!flag_fixtures[@]}"; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-cli-flags.bash" "${flag_fixtures[$mutation_index]}") || fail "mutated CLI auth flag redaction $mutation_index"
  grep -Fq "${flag_secrets[$mutation_index]}" <<<"$mutated" || fail "mutated CLI auth flag rule $mutation_index did not leak"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${flag_fixtures[$mutation_index]}") || fail "shipped CLI auth flag redaction $mutation_index"
  grep -Fq "${flag_secrets[$mutation_index]}" <<<"$shipped" && fail "shipped CLI auth flag rule $mutation_index leaked"
done
# A boundary-less equals flag rule clobbers a preserved username.
flag_rule2_old=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-u=|--u=)([^[:space:]\"':;,|&]+)/\1\2@@LMLINE_REDACTED@@/Ig" \
RULE
)
flag_rule2_line=$(grep -nF "$flag_rule2" "$repo_dir/lmline/actions.bash" | cut -d: -f1)
printf '%s\n' "$flag_rule2_old" >"$cfg_tmp/flag-rule2-old"
awk -v n="$flag_rule2_line" -v repl="$cfg_tmp/flag-rule2-old" 'NR==n {while ((getline line < repl) > 0) print line; next} {print}' \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-flag-no-boundary.bash" || fail "flag boundary mutation removal"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-flag-no-boundary.bash" 'curl -u=user:SYNTHFLAG922 https://x; echo KEEPFLAG922') || fail "flag boundary mutation redaction"
grep -Fq 'user:***REDACTED***' <<<"$mutated" && fail "flag boundary mutation kept the username"
# The quoted bare-value rule must not clobber a preserved username after the
# colon form has already masked the credential.
flag_rule_quoted2_old=${flag_rule_quoted2/\/@@LMLINE_REDACTED@@\/!/}
flag_rule_quoted2_line=$(grep -nF "$flag_rule_quoted2" "$repo_dir/lmline/actions.bash" | cut -d: -f1)
printf '%s\n' "$flag_rule_quoted2_old" >"$cfg_tmp/flag-quoted-unguarded"
awk -v n="$flag_rule_quoted2_line" -v repl="$cfg_tmp/flag-quoted-unguarded" 'NR==n {while ((getline line < repl) > 0) print line; next} {print}' \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-flag-unguarded.bash" || fail "flag quote guard mutation removal"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-flag-unguarded.bash" 'curl -u="user:SYNTHQ01" https://x; echo KEEPQ01') || fail "flag quote guard mutation redaction"
grep -Fq 'user:***REDACTED***' <<<"$mutated" && fail "flag quote guard mutation kept the username"

# Separator-inclusive credential values swallow the following shell operator.
flag_rule1_line=$(grep -nF "$flag_rule1" "$repo_dir/lmline/actions.bash" | cut -d: -f1)
cat <<'RULE' >"$cfg_tmp/flag-rule1-old"
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([^[:space:]\"':]+):([^[:space:]\"']+)/\1\2\3:@@LMLINE_REDACTED@@/Ig" \
RULE
awk -v n="$flag_rule1_line" -v repl="$cfg_tmp/flag-rule1-old" 'NR==n {while ((getline line < repl) > 0) print line; next} {print}' \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-flag-glued.bash" || fail "flag separator mutation removal"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-flag-glued.bash" 'curl -u=user:SYNTHFLAG928&&echo KEEPFLAG928') || fail "flag separator mutation redaction"
grep -Fq '&&echo KEEPFLAG928' <<<"$mutated" && fail "flag separator mutation kept the shell tail"

p_rule=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-p)([^[:space:]\"';,&|]+)([[:space:];,&|]|$)/\1\2@@LMLINE_REDACTED@@\4/Ig" \
RULE
)
p_quoted_rule=$(cat <<'RULE'
    -e "s/(^|[[:space:]])(-p)([\"'])([^\"']+)([\"'])/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
RULE
)
# Requiring a shell terminator after a quoted -p value leaves glued redirects verbatim.
p_quoted_rule_line=$(grep -nF "$p_quoted_rule" "$repo_dir/lmline/actions.bash" | cut -d: -f1)
cat <<'RULE' >"$cfg_tmp/p-quoted-terminator"
    -e "s/(^|[[:space:]])(-p)([\"'])([^\"']+)([\"'])([[:space:];,&|]|$)/\1\2\3@@LMLINE_REDACTED@@\5\6/Ig" \
RULE
awk -v n="$p_quoted_rule_line" -v repl="$cfg_tmp/p-quoted-terminator" 'NR==n {while ((getline line < repl) > 0) print line; next} {print}' \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-p-terminator.bash" || fail "quoted -p terminator mutation removal"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-p-terminator.bash" 'mysql -p"SYNTHQDB1">out; echo KEEPQDB1') || fail "quoted -p terminator mutation redaction"
grep -Fq 'SYNTHQDB1' <<<"$mutated" || fail "quoted -p terminator mutation did not leak"
for rule in "$p_rule" "$p_quoted_rule"; do
  [[ $(grep -cF "$rule" "$repo_dir/lmline/actions.bash") == 1 ]] || fail "expected one attached password flag rule"
done
grep -vF -e "$p_rule" -e "$p_quoted_rule" \
  "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-attached-password.bash" || fail "attached password mutation removal"
p_fixtures=('mysql -uadmin -pSYNTHP941; echo KEEPP941' 'mysql -p"SYNTHP945" https://x; echo KEEPP945')
p_secrets=(SYNTHP941 SYNTHP945)
for mutation_index in 0 1; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-no-attached-password.bash" "${p_fixtures[$mutation_index]}") || fail "mutated attached password redaction $mutation_index"
  grep -Fq "${p_secrets[$mutation_index]}" <<<"$mutated" || fail "mutated attached password rule $mutation_index did not leak"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${p_fixtures[$mutation_index]}") || fail "shipped attached password redaction $mutation_index"
  grep -Fq "${p_secrets[$mutation_index]}" <<<"$shipped" && fail "shipped attached password rule $mutation_index leaked"
done

# Without the quoted-header shield, a later terminal Authorization rule eats
# the closing quote and the glued command.
awk '!(index($0,"##LMLINE_REDACTED##") && index($0,"Authorization:"))' "$repo_dir/lmline/actions.bash" >"$cfg_tmp/actions-no-auth-shield.bash" || fail "auth shield mutation removal"
mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$2" | __lmline_redact_clip_text' _ \
  "$cfg_tmp/actions-no-auth-shield.bash" 'curl -H "Authorization: Bearer SYNTHGLUE101";echo KEEPGLUE101') || fail "auth shield mutation redaction"
grep -Fq ';echo KEEPGLUE101' <<<"$mutated" && fail "auth shield mutation dropped the glued tail"

# Narrowing the shared auth-scheme token class back to URI-scheme syntax must
# reopen every custom-scheme case; the shipped class masks all of them.
[[ $(grep -Fc '${auth_scheme_token}+' "$repo_dir/lmline/actions.bash") == 28 ]] || fail "expected twenty-eight shared auth-scheme token uses"
sed 's/${auth_scheme_token}+/[A-Za-z][A-Za-z0-9+.-]*/g' "$repo_dir/lmline/actions.bash" \
  >"$cfg_tmp/actions-uri-scheme-class.bash" || fail "auth-scheme class mutation copy"
grep -Fq '${auth_scheme_token}' "$cfg_tmp/actions-uri-scheme-class.bash" && fail "auth-scheme class mutation did not apply"
token_fixtures=(
  'Authorization: my_scheme: SECRETZZ9; echo TAILZZ9'
  'Authorization: 2Scheme: SECRETZZ10; echo TAILZZ10'
  'Authorization: x~y: SECRETZZ11; echo TAILZZ11'
  'Authorization: my_scheme=\"SYNTHE12\"; echo TAILZZ12'
  'Authorization: 2Scheme \"SYNTHSP3\"; echo TAILZZSP3'
)
token_secrets=(SECRETZZ9 SECRETZZ10 SECRETZZ11 SYNTHE12 SYNTHSP3)
token_expected=(
  'Authorization: ***REDACTED***; echo TAILZZ9'
  'Authorization: ***REDACTED***; echo TAILZZ10'
  'Authorization: ***REDACTED***; echo TAILZZ11'
  'Authorization: my_scheme=\"***REDACTED***\"; echo TAILZZ12'
  'Authorization: 2Scheme \"***REDACTED***\"; echo TAILZZSP3'
)
for mutation_index in "${!token_fixtures[@]}"; do
  mutated=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\\n" "$2" | __lmline_redact_clip_text' _ \
    "$cfg_tmp/actions-uri-scheme-class.bash" "${token_fixtures[$mutation_index]}") || fail "narrowed auth-scheme class redaction $mutation_index"
  grep -Fq "${token_secrets[$mutation_index]}" <<<"$mutated" || fail "narrowed auth-scheme class $mutation_index did not leak"
  shipped=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\\n" "$2" | __lmline_redact_clip_text' _ \
    "$repo_dir/lmline/actions.bash" "${token_fixtures[$mutation_index]}") || fail "shipped auth-scheme class redaction $mutation_index"
  grep -Fxq "${token_expected[$mutation_index]}" <<<"$shipped" || fail "shipped auth-scheme class $mutation_index did not mask"
done

ok "clip cli"
