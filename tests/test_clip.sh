#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: clipboard provider selection and CLI handling remain correct without exposing secrets.

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-clip-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT

LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model

# BSD sed rejects an empty ERE alternative that GNU sed accepts. Keep the
# redaction pipeline free of `(...?|)` branches so macOS runs the same rules.
if grep -nF '?|)' "$repo_dir/lmline/actions.bash"; then
  fail 'empty sed ERE alternative in actions.bash'
fi

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
printf '%s\n' 'Authorization: Bearer @secretAtValue123; echo KEEPATSECRET123'
printf '%s\n' 'Authorization: my_scheme: SECRETZZ9; echo TAILZZ9'
printf '%s\n' 'Authorization: 2Scheme: SECRETZZ10; echo TAILZZ10'
printf '%s\n' 'Authorization: x~y: SECRETZZ11; echo TAILZZ11'
printf '%s\n' 'Authorization: my_scheme=\"SYNTHE12\"; echo TAILZZ12'
printf '%s\n' 'Authorization: 2Scheme=\"SYNTHE13\"; echo TAILZZ13'
printf '%s\n' 'Authorization: my_scheme \"SYNTHSP2\"; echo TAILZZSP2'
printf '%s\n' 'Authorization: 2Scheme \"SYNTHSP3\"; echo TAILZZSP3'
printf '%s\n' 'Authorization: my_scheme: "SYNTHQUOTED1"; echo KEEPQUOTED1'
printf "%s\n" "Authorization: my_scheme: 'SYNTHQUOTED2'; echo KEEPQUOTED2"
printf '%s\n' 'Authorization: 2Scheme= "SYNTHQUOTED3"; echo KEEPQUOTED3'
printf "%s\n" "Authorization: 2Scheme= 'SYNTHQUOTED4'; echo KEEPQUOTED4"
printf '%s\n' 'Authorization: my_scheme:"SYNTHGLUEDQ1"; echo KEEPGLUEDQ1'
printf "%s\n" "Authorization: 2Scheme:'SYNTHGLUEDS1'; echo KEEPGLUEDS1"
printf '%s\n' 'Authorization: my_scheme:"SYNTHGLUEDQ2" "PAYLOADGLUEDQ2"; echo KEEPGLUEDQ2'
printf '%s\n' 'Authorization: my_scheme:"SYNTHREPEATQ1"; Authorization: 2scheme:"SYNTHREPEATQ2"; echo KEEPREPEATQ'
printf '%s\n' 'Authorization: my_scheme:"SYNTHREPEATPIPE1"|Authorization: 2scheme:"SYNTHREPEATPIPE2"; echo KEEPREPEATPIPE'
printf '%s\n' 'Authorization: my_scheme:"SYNTHREPEATREDIR1" >out; Authorization: 2scheme:"SYNTHREPEATREDIR2" <in; echo KEEPREPEATREDIR'
printf "%s\\n" "Authorization: my_scheme:'SYNTHREPEATSQ1'; Authorization: 2scheme:'SYNTHREPEATSQ2'; echo KEEPREPEATSQ"
printf "%s\\n" "Authorization: my_scheme:'SYNTHREPEATSQPIPE1'|Authorization: 2scheme:'SYNTHREPEATSQPIPE2'; echo KEEPREPEATSQPIPE"
printf "%s\\n" "Authorization: my_scheme:'SYNTHREPEATSQREDIR1' >out; Authorization: 2scheme:'SYNTHREPEATSQREDIR2' <in; echo KEEPREPEATSQREDIR"
printf '%s\n' 'Authorization: my_scheme:"SYNTHSEPAMP1"&Authorization: 2scheme:"SYNTHSEPAMP2"; echo KEEPSEPAMP'
printf '%s\n' 'Authorization: my_scheme:"SYNTHSEPSEMI1";Authorization: 2scheme:"SYNTHSEPSEMI2"; echo KEEPSEPSEMI'
printf '%s\n' 'Authorization: my_scheme:"SYNTHSEPCOMMA1",Authorization: 2scheme:"SYNTHSEPCOMMA2"; echo KEEPSEPCOMMA'
printf "%s\\n" "Authorization: my_scheme:'SYNTHSEPAMPSQ1'&Authorization: 2scheme:'SYNTHSEPAMPSQ2'; echo KEEPSEPAMPSQ"
printf '%s\n' 'echo "note Authorization: SYNTHNATQ1 tail"; echo KEEPNATQ1'
printf "%s\\n" "echo 'note Authorization: SYNTHNATS1 tail'; echo KEEPNATS1"
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
printf '%s\n' 'Authorization: SYNTHFDNUM123 2>err; echo KEEPFDNUM123'
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
printf '%s\n' 'Authorization: Bearer=abc\"tok'\''LEAKAPOSTROPHE987"end; echo KEEPTAILAPOS987'
printf '%s\n' 'Authorization: Custom=abc\"tok'\''LEAKAPOSTROPHE988\"end; echo KEEPTAILCUSTOM988'
printf '%s\n' "Authorization: Bearer=abc\\'tok\"LEAKDQUOTE989\\'end; echo KEEPTAILDQUOTE989"
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
printf '%s\n' 'url=https://x/?a=1&Authorization=SYNTHURLAMP1; echo KEEPURLAMP1'
printf '%s\n' 'url=https://x/?a=1;Authorization=SYNTHURLSEMI1'
printf '%s\n' 'url=https://x/?a=1,Authorization=SYNTHURLCOMMA1'
printf '%s\n' 'url=https://x/?a=1&Authorization=Bearer%20SYNTHURLBEARER1'
printf '%s\n' 'curl -H "Authorization: Bearer SYNTHURLHDR2"; curl "https://x/?a=1&Authorization=SYNTHURLSAME2"'
printf '%s\n' 'curl "https://x/?a=1&Authorization=SYNTHURLDQ2"'
printf '%s\n' "curl 'https://x/?a=1&Authorization=SYNTHURLSQ2'"
printf '%s\n' 'curl "https://x/?a=1&Authorization=Bearer SYNTHURLSP2"; echo KEEPURLSP2'
printf '%s\n' 'url=https://x/?a=1&Authorization=SYNTHCOLEND1:; echo KEEPURLCOLEND1'
printf '%s\n' 'url=https://x/?a=1&Authorization=SYNTHEQEND1=; echo KEEPURLEQEND1'
printf '%s\n' "curl 'https://x/?a=1&Authorization=SYNTHCOLQUOTE1:'; echo KEEPURLCOLQUOTE1"
# Base64 padding at the value end must not hide a URL query Authorization secret.
printf '%s\n' 'url=https://x/?a=1&Authorization=U1lOVEhCQVNFNjQx==; echo KEEPPADEQ1'
printf '%s\n' 'url=https://x/?a=1;Authorization=U1lOVEhCQVNFNjQy===; echo KEEPPADEQ2'
printf '%s\n' 'url=https://x/?a=1,Authorization=U1lOVEhCQVNFNjQz==; echo KEEPPADEQ3'
printf '%s\n' "curl 'https://x/?a=1&Authorization=U1lOVEhCQVNFNjQ0=='; echo KEEPPADEQ4"
printf '%s\n' 'curl "https://x/?a=1;Authorization=U1lOVEhCQVNFNjQ1=="; echo KEEPPADEQ5'
printf '%s\n' 'curl "https://x/?a=1&Authorization=U1lOVEhCQVNFNjQ2===; echo KEEPPADEQ6"'
printf '%s\n' "curl 'https://x/?a=1&Authorization=U1lOVEhCQVNFNjQ3===; echo KEEPPADEQ7'"
printf '%s\n' 'curl "https://x/?a=1&Authorization=U1lOVEhCQVNFNjQ4=="; echo KEEPPADEQ8'
printf '%s\n' "curl 'https://x/?a=1&Authorization=U1lOVEhCQVNFNjQ5==='; echo KEEPPADEQ9"
printf '%s\n' 'curl "https://x/?a=1&Authorization=U1lOVEhCQVNFNjQ6="; echo KEEPSINGLEEQ1'
printf '%s\n' "curl 'https://x/?a=1;Authorization=U1lOVEhCQVNFNjQ7='; echo KEEPSINGLEEQ2"
printf '%s\n' 'curl "https://x/?a=1,Authorization=U1lOVEhCQVNFNjQ8="; echo KEEPSINGLEEQ3'
printf '%s\n' 'curl "https://x/?Authorization=U1lOVEhCQVFCMQ=="; echo TAILFQ1'
printf '%s\n' "curl 'https://x/?Authorization=U1lOVEhCQVFCMg=='; echo TAILFQ2"
printf '%s\n' 'url=https://x/?Authorization=U1lOVEhCQVFCMw===; echo TAILFQ3'
printf '%s\n' 'url=https://x/?Authorization=U1lOVEhCQVFCNDo:; echo TAILFQ4'
printf '%s\n' 'curl "https://x/?Authorization=YWI="; echo TAILB64ONE'
printf '%s\n' "curl 'https://x/?Authorization=YWJjZGVmZ2hpamtsbW5vcHE='; echo TAILB64LONG"
printf '%s\n' 'curl "https://x/?Authorization=SYNTHSINGLEEQ4="; echo TAILSINGLE4'
printf '%s\n' "curl 'https://x/?Authorization=SYNTHSINGLEEQ5='; echo TAILSINGLE5"
printf '%s\n' 'curl \"https://x/?Authorization=SYNTHESCAPED1=\"; echo TAILESC'
printf '%s\n' 'curl "https://x/?Authorization=SYNTHGT1=">out; echo TAILGT'
printf '%s\n' 'curl "https://x/?Authorization=SYNTHPAR1="); echo TAILPAR'
printf '%s\n' 'curl "https://x/?Authorization=SYNTHMULTIGT1==">out; echo TAILMULTIGT'
printf '%s\n' 'curl "https://x/?Authorization=U1lOVEhCQVFCMA=="]; echo KEEPBASE1'
printf '%s\n' 'curl "https://x/?Authorization=U1lOVEhCQVFCMA=="?x=1; echo KEEPBASE2'
printf '%s\n' 'curl "https://x/?Authorization=SYNTHSUFFIX1="]; echo TAILSUFFIX1'
printf '%s\n' 'url=https://x/?Authorization=realm="example.com"; echo KEEPURLAUTH'
printf '%s\n' 'Note LMLINE_REALM_EQ_SENTINEL is only a temporary marker.'
printf '%s\n' 'Note @@LMLINE_REALM_SHIELD_FOO@@ stays intact.'
printf '%s\n' 'curl "https://x/?Authorization=@@LMLINE_REALM_SHIELD_FOO@@" ; echo KEEPPASTEDSHIELD'
printf '%s\n' 'curl "https://x/?Authorization=@@LMLINE_REALM_SHIELD_FOO@@\"example.com\"; echo KEEPPASTEDSHIELDGLUED'
printf '%s\n' '?Authorization:REALM="example.com"; echo KEEPREALMCASE'
printf '%s\n' 'url=https://x/?Authorization:=realm="example.com"; echo KEEPCOLONEQREALM'
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
printf '%s\n' 'curl -H "Authorization: Bearer @sec\"escapedTail9015\"" https://x; echo KEEPESC9015'
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
# A generic RFC-token scheme ends at the closing shell quote: the next word
# or header is a separate word and must survive redaction (seq240).
printf '%s\n' 'curl -H "Authorization: Foo: SYNTHA1" "PAYLOADA1"; echo TAILA1'
printf '%s\n' "curl -H 'Authorization: Foo: SYNTHS1' 'PAYLOADS1'; echo TAILS1"
printf '%s\n' 'curl -H "Authorization: X-OAuth2: SYNTHX1" --data "DATAX1"; echo TAILX1'
printf '%s\n' 'curl -H "Authorization: Foo: SYNTHC1" -H "X: KEEPC1" https://x; echo TAILC1'
printf '%s\n' "curl -H 'Authorization: X-OAuth2: SYNTHX2' -H 'X: KEEPX2' https://x; echo TAILX2"
printf '%s\n' 'curl -H "Authorization: my_scheme: SYNTHM1" https://x; echo TAILM1'
printf '%s\n' 'curl -H "Authorization: 2Scheme: SYNTH2" 2>err; echo TAIL2'
# A glued adjacent quoted piece is part of the same word and stays masked.
printf '%s\n' 'curl -H "Authorization: Foo: SYNTHG1""GLUEDG1"; echo TAILG1'
# Known schemes are the control for the same shell shapes.
printf '%s\n' 'curl -H "Authorization: Bearer: SYNTHB1" "PAYLOADB1"; echo TAILB1'
printf '%s\n' 'curl -H "Authorization: Bearer: SYNTHBC1" -H "X: KEEPC1" https://x; echo TAILBC1'
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
printf '%s\n' 'Authorization: Bearer #secretHash9020; echo KEEPHASH9020'
printf '%s\n' "Authorization: Bearer @o'brienApostrophe9016"
printf '%s\n' 'echo KEEPMORE456; Authorization: Bearer abc123" more_secret456'
printf '%s\n' 'echo KEEPWORD123; Authorization: Basic p@ss" w0rd123SECRET'
printf '%s\n' '{"api_key": "keyPlusHeaderValue123", "Authorization": "Basic keyPlusHeaderCred123", "keep": "KEEPKEYPLUS"}'
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
# Percent-encoded URL separators still carry credential keys.
printf '%s\n' 'curl "https://x.test/a?token%3DencEqSecret9001&keep=KEEPENC1"'
printf '%s\n' 'curl "https://x.test/a?api-key%3dencEqSecret9002&keep=KEEPENC2"'
printf '%s\n' 'curl "https://x.test/a#token%3AencColonSecret9003&keep=KEEPENC3"'
printf '%s\n' 'curl "https://x.test/a?token%20%3D%20encSpaceSecret9004&keep=KEEPENC4"'
printf '%s\n' 'curl "https://x.test/a?redirect=https%3A//safe.test&keep=KEEPENC5"'
printf '%s\n' 'curl "https://x.test/a?Authorization%3DBearer%20AUTHENCSECRET0103&keep=KEEP0103"'
printf '%s\n' "curl 'https://x.test/a?\"Authorization\"%3DBearer%20AUTHENCSECRET0103&keep=KEEP0103'"
printf '%s\n' "curl 'https://x.test/a?\"token\"%3DquotedKeySecret0201&keep=KEEP0201'"
printf '%s\n' "curl \"https://x.test/a?'token'%3DquotedKeySecret0202&keep=KEEP0202\""
printf '%s\n' 'url=https://x/?\"token\"%3DEscapedQuotedSecret0301&y=KEEPQ1; echo KEEPQ1'
printf '%s\n' "url=https://x/?\\'token\\'%3DEscapedQuotedSecret0302&y=KEEPQ2"
printf '%s\n' 'url=https://x/?\"Authorization\"%3DBearer%20EscapedAuthSecret0303&y=KEEPQ3'
printf '%s\n' "url=https://x/?\\'Authorization\\'%3DBearer%20EscapedAuthSecret0304&y=KEEPQ4"
# Encoded separators must mask adjacent segments, quoted values and %20 padding without eating the tail.
printf '%s\n' 'url=https://x/?\"Authorization\"%3DSYNTHADJENCA1\"SYNTHADJENCB1\"&y=1; echo KEEPADJENC1'
printf '%s\n' 'url=https://x/?\"token\"%3DSYNTHADJENCA2\"SYNTHADJENCB2\"&y=1; echo KEEPADJENC2'
printf '%s\n' 'url=https://x/?\"Authorization\"%3D\"SYNTHQUOTEENCA1\"&y=1; echo KEEPQUOTEENC1'
printf '%s\n' 'url=https://x/?\"token\"%3D\"SYNTHQUOTEENCA2\"&y=1; echo KEEPQUOTEENC2'
printf '%s\n' 'url=https://x/?\"Authorization\"%20%3D%20Bearer%20SYNTHPADENCA1&y=KEEPPADENC1'
printf "%s\n" "url=https://x/?\\'Authorization\\'%20%3D%20Bearer%20SYNTHPADENCA2&y=KEEPPADENC2"
# Literal-space scheme values must be masked whole, not just the scheme word.
printf '%s\n' 'url=https://x/?a=1&Authorization%3DBearer SYNTHSCHEMESPACE9001&keep=KEEPSCHEMESPACE1'
printf '%s\n' "url=https://x/?a=1&\\'Authorization\\'%3DBasic SYNTHSCHEMESPACE9002&keep=KEEPSCHEMESPACE2"
# Encoded credentials must keep shell quotes and command tails intact.
printf '%s\n' 'curl "https://x/?Authorization%3DSYNTHQUOTEKEEP9001" -H "X: keep"; echo KEEPQUOTETAIL9001'
printf '%s\n' 'curl "https://x/?Authorization%3DSYNTHQUOTEKEEP9002"'
printf '%s\n' "curl 'https://x/?Authorization%3DSYNTHQUOTEKEEP9003' -H 'X: keep'; echo KEEPQUOTETAIL9003"
printf '%s\n' "curl \"https://x/?Authorization%3DSYNTHQUOTEKEEP9004\" --data=' keep'; echo KEEPQUOTETAIL9004"
printf '%s\n' 'url=https://x/?a=1&\"Authorization\"%3DBearer SYNTHESCDQ9003&keep=KEEPTAIL540'
printf '%s\n' 'url=https://x/?a=1&token%3Dmy secret SYNTHKEY9008&keep=KEEPTAIL603'
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
printf '%s\n' 'mkdir -pkeep; echo KEEPPCMDB1'
printf '%s\n' 'MKDIR -pKEEPUPPER; echo KEEPPCMDB2'
printf '%s\n' 'ls -la -pKEEPPCMDB3; echo KEEPPCMDB3'
printf '%s\n' 'echo PREPCMDB4; mysql -uadmin -pSYNTHPCMDB4; echo KEEPPCMDB4'
printf '%s\n' 'mkdir -pkeep; mysql -pSYNTHPCMDB5; mkdir -pkeep2'
printf '%s\n' '/usr/bin/mysql -pSYNTHPCMDB6; echo KEEPPCMDB6'
printf '%s\n' 'sudo /usr/local/bin/mysql -pSYNTHPCMDB7; echo KEEPPCMDB7'
printf '%s\n' 'echo $(mysql -pSYNTHPCMDB8); echo KEEPPCMDB8'
printf '%s\n' 'x=$(mariadb -pSYNTHPCMDB9); echo KEEPPCMDB9'
printf '%s\n' '(mysql -pSYNTHPCMDB10); echo KEEPPCMDB10'
printf '%s\n' 'MYSQL -pSYNTHPCMDB11; echo KEEPPCMDB11'
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
# One helper owns every fixture assertion. It reports a stable case label,
# never the expected text or clipboard contents, and always fails with status 1.
assert_fixture() {
  local label=$1 expectation=$2
  shift 2
  case $expectation in
    present)
      if grep "$@" "$line_file" >/dev/null 2>&1; then return 0; fi
      ;;
    absent)
      if ! grep "$@" "$line_file" >/dev/null 2>&1; then return 0; fi
      ;;
    *)
      printf 'clip fixture assertion failed: %s (invalid expectation)\n' "$label" >&2
      exit 1
      ;;
  esac
  printf 'clip fixture assertion failed: %s\n' "$label" >&2
  exit 1
}

assert_fixture 'case 1' present -Fq 'API_KEY=***REDACTED***'
assert_fixture 'case 2' present -Fq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 3' present -Fxq 'Authorization: ***REDACTED*** | grep keepPipe90201'
assert_fixture 'case 4' present -Fxq 'Authorization: ***REDACTED***|grep keepPipeTail90202'
assert_fixture 'case 5' present -Fxq 'Authorization: Bearer ***REDACTED*** | grep keepBearerPipe90203'
assert_fixture 'case 6' present -Fxq 'Authorization: Bearer ***REDACTED***|grep keepBearerPipeTail90204'
assert_fixture 'case 7' present -Fxq 'Authorization: ***REDACTED*** && echo keepAmp90205'
assert_fixture 'case 8' present -Fxq 'Authorization: ***REDACTED***&&echo keepAmpTail90206'
assert_fixture 'case 9' present -Fxq 'Authorization: Bearer ***REDACTED*** && echo keepBearerAmp90207'
assert_fixture 'case 10' present -Fxq 'Authorization: Bearer ***REDACTED***&&echo keepBearerAmpTail90208'
assert_fixture 'case 11' present -Fxq 'Authorization: ***REDACTED*** || echo keepOr90209'
assert_fixture 'case 12' present -Fxq 'Authorization: Bearer ***REDACTED*** || echo keepBearerOr90210'
assert_fixture 'case 13' present -Fxq 'Authorization: ***REDACTED*** > out.txt'
assert_fixture 'case 14' absent -Fq 'secretRedirect123456'
assert_fixture 'case 15' present -Fxq 'Authorization: ***REDACTED***>out.txt'
assert_fixture 'case 16' absent -Fq 'secretRedirectTail123456'
assert_fixture 'case 17' present -Fxq 'Authorization: ***REDACTED*** >> out.txt'
assert_fixture 'case 18' absent -Fq 'secretRedirectDouble123456'
assert_fixture 'case 19' present -Fxq 'Authorization: Bearer ***REDACTED*** > out.txt'
assert_fixture 'case 20' absent -Fq 'secretBearerRedirect123456'
assert_fixture 'case 21' present -Fxq 'Authorization: Bearer ***REDACTED***>out.txt'
assert_fixture 'case 22' absent -Fq 'secretBearerRedirectTail123456'
assert_fixture 'case 23' present -Fxq 'Authorization: ***REDACTED*** < in.txt'
assert_fixture 'case 24' absent -Fq 'secretInput123456'
assert_fixture 'case 25' present -Fxq 'Authorization: Bearer ***REDACTED*** <<EOF'
assert_fixture 'case 26' absent -Fq 'secretHere123456'
# A placeholder on the first value must not disable terminal cleanup of the second.
assert_fixture 'case 27' present -Fxq 'Authorization: ***REDACTED*** > out.txt; Authorization: ***REDACTED***'
assert_fixture 'case 28' absent -Fq 'splitRedirect123456'
assert_fixture 'case 29' absent -Fq 'splitBare123456'
# Fd digits belong to the redirect boundary, never to the credential.
assert_fixture 'case 30' present -Fxq 'Authorization: ***REDACTED*** 2>err'
assert_fixture 'case 31' absent -Fq 'SYNTHFDSECRET'
assert_fixture 'case 32' present -Fxq 'Authorization: ***REDACTED*** >out'
assert_fixture 'case 33' absent -Fq 'SYNTHPLAINSECRET'
assert_fixture 'case 34' present -Fxq 'Authorization: ***REDACTED*** 2>&1'
assert_fixture 'case 35' absent -Fq 'SYNTHFDSTDERR'
assert_fixture 'case 36' present -Fxq 'Authorization: ***REDACTED*** 0<in'
assert_fixture 'case 37' absent -Fq 'SYNTHFDSTDIN'
assert_fixture 'case 38' present -Fxq 'Authorization: ***REDACTED*** 10>out'
assert_fixture 'case 39' absent -Fq 'SYNTHFDFD10'
assert_fixture 'case 40' present -Fxq 'Authorization: ***REDACTED*** 3>>err'
assert_fixture 'case 41' absent -Fq 'SYNTHFDAPPEND'
assert_fixture 'case 42' present -Fxq 'Authorization: ***REDACTED*** 2> err'
assert_fixture 'case 43' absent -Fq 'SYNTHFDSPACE'
assert_fixture 'case 44' present -Fxq 'Authorization: Bearer ***REDACTED*** 2>err'
assert_fixture 'case 45' absent -Fq 'SYNTHFDBEARER'
assert_fixture 'case 46' present -Fxq 'Authorization: Bearer ***REDACTED*** 10>out'
assert_fixture 'case 47' absent -Fq 'SYNTHFDSCHEMED10'
# The marker on the first value must not stop the later bare value from masking.
assert_fixture 'case 48' present -Fxq 'Authorization: ***REDACTED*** 2>err; Authorization: ***REDACTED***'
assert_fixture 'case 49' absent -Fq 'SYNTHFDSPLIT'
assert_fixture 'case 50' absent -Fq 'SYNTHFDBARE'
# Digits inside a credential stay masked; only fd digits before an operator are kept.
assert_fixture 'case 51' present -Fxq 'Authorization: ***REDACTED*** 2>err; echo KEEPFDNUM123'
assert_fixture 'case 52' absent -Fq 'SYNTHFDNUM123'
assert_fixture 'case 53' present -Fxq 'Authorization: ***REDACTED***>out'
assert_fixture 'case 54' absent -Fq 'SYNTHFDTAIL456'
# Three-digit and spaced fd forms keep the full redirect boundary.
assert_fixture 'case 55' present -Fxq 'Authorization: ***REDACTED*** 123>out'
assert_fixture 'case 56' absent -Fq 'SYNTHFDFD123'
assert_fixture 'case 57' present -Fxq 'Authorization: Bearer ***REDACTED*** 123>out'
assert_fixture 'case 58' absent -Fq 'SYNTHFDSCHEMED123'
assert_fixture 'case 59' present -Fxq 'Authorization: ***REDACTED*** 2 >err'
assert_fixture 'case 60' absent -Fq 'SYNTHFDGAP'
assert_fixture 'case 61' present -Fxq 'Authorization: Bearer ***REDACTED*** 2 >err'
assert_fixture 'case 62' absent -Fq 'SYNTHFDSCHEMEGAP'
# A padded value must not swallow the operator or the following words.
assert_fixture 'case 63' present -Fxq 'Authorization: Basic ***REDACTED*** > out'
assert_fixture 'case 64' absent -Fq 'dXNlcjpwYXNz=='
assert_fixture 'case 65' present -Fxq 'Authorization: Bearer ***REDACTED***; echo KEEPAUTHPAD1'
assert_fixture 'case 66' absent -Fq 'SYNTHAUTHPAD1'
assert_fixture 'case 67' present -Fxq 'Authorization: Bearer ***REDACTED*** 2>err; echo KEEPAUTHPAD2'
assert_fixture 'case 68' absent -Fq 'SYNTHAUTHPAD2'
# A keyed chain after an Authorization marker keeps both boundaries.
assert_fixture 'case 69' present -Fxq 'Authorization: Bearer ***REDACTED***;token=***REDACTED***; echo KEEPMIXAUTH'
assert_fixture 'case 70' absent -Fq 'SYNTHMIXAUTH2'
assert_fixture 'case 71' present -Fxq 'Authorization: Bearer ***REDACTED***,token=***REDACTED***; echo KEEPMIXAUTH2'
assert_fixture 'case 72' absent -Fq 'SYNTHMIXAUTH4'
assert_fixture 'case 73' present -Fxq 'Authorization: Bearer ***REDACTED***;token=***REDACTED***;token2=***REDACTED***; echo KEEPMIXAUTH3'
assert_fixture 'case 74' absent -Fq 'SYNTHMIXAUTH7'
assert_fixture 'case 75' present -Fxq 'Authorization: Bearer ***REDACTED***;token=***REDACTED*** echo KEEPCASEMARK'
assert_fixture 'case 76' absent -Fqi '@lmline_chain_key@'
assert_fixture 'case 77' absent -Fq 'SYNTHCASEMARK'
assert_fixture 'case 78' present -Fxq 'url=https://u:***REDACTED***@host/path; echo KEEPPASTEDURLMARK'
assert_fixture 'case 79' absent -Fq '@@LMLINE_URL_REDACTED@@'
assert_fixture 'case 80' present -Fxq 'url=https://u:***REDACTED***@host/path; echo KEEPPASTEDURLMARKCASE'
assert_fixture 'case 81' absent -Fqi '@@LMLINE_URL_REDACTED@@'
assert_fixture 'case 82' present -Fxq 'echo KEEPPASTEDREDMARK ***REDACTED*** KEEPPASTEDREDTAIL'
assert_fixture 'case 83' absent -Fqi '@@LmLINE_Redacted@@'
assert_fixture 'case 84' present -Fxq 'echo KEEPPASTEDCHAINMARK ***REDACTED*** KEEPPASTEDCHAINTAIL'
assert_fixture 'case 85' absent -Fqi '@LmLINE_ChAiN_kEy@'
assert_fixture 'case 86' present -Fxq 'echo KEEPPASTEDSEPMARK ***REDACTED*** KEEPPASTEDSEPTAIL'
assert_fixture 'case 87' absent -Fqi '@LmLINE_SeP@'
assert_fixture 'case 88' present -Fxq 'Authorization: Bearer="***REDACTED***"; echo KEEPEQSDQ1'
assert_fixture 'case 89' absent -Fq 'SYNTHEQSDQ1'
assert_fixture 'case 90' present -Fxq "Authorization: Bearer='***REDACTED***'; echo KEEPEQSQ1"
assert_fixture 'case 91' absent -Fq 'SYNTHESQSQ1'
assert_fixture 'case 92' present -Fxq 'authorization: bearer="***REDACTED***" && echo KEEPEQSCASE'
assert_fixture 'case 93' absent -Fq 'SYNTHEQSCASE1'
assert_fixture 'case 94' present -Fxq 'Authorization: Basic="***REDACTED***"; echo KEEPEQSESC'
assert_fixture 'case 95' absent -Fq 'SYNTHEQSESC1'
assert_fixture 'case 96' present -Fxq 'Authorization: Bearer="***REDACTED***'
assert_fixture 'case 97' absent -Fq 'SYNTHEQUNTERM1'
assert_fixture 'case 98' present -Fxq "Authorization: Bearer='***REDACTED***"
assert_fixture 'case 99' absent -Fq 'SYNTHEQUNTERM2'
assert_fixture 'case 100' absent -Fq 'SYNTHEQTBACK1'
assert_fixture 'case 101' absent -Fq 'SYNTHEQTBACK2'
assert_fixture 'case 102' present -Fxq 'Authorization: Bearer:"***REDACTED***"; echo KEEPCOLSDQ1'
assert_fixture 'case 103' absent -Fq 'SYNTHCOLSDQ1'
assert_fixture 'case 104' present -Fxq "Authorization: Basic=='***REDACTED***'; echo KEEPCOLSQ2"
assert_fixture 'case 105' absent -Fq 'SYNTHCOLSQ2'
assert_fixture 'case 106' present -Fxq 'Authorization: Digest:="***REDACTED***"; echo KEEPCOLREP3'
assert_fixture 'case 107' absent -Fq 'SYNTHCOLREP3'
assert_fixture 'case 108' present -Fxq 'Authorization: Bearer:"***REDACTED***'
assert_fixture 'case 109' absent -Fq 'SYNTHCOLUNTERM4'
assert_fixture 'case 110' present -Fxq 'Authorization: Bearer=\"***REDACTED***\"; echo KEEPESESDQ1'
assert_fixture 'case 111' absent -Fq 'SYNTHESESDQ1'
assert_fixture 'case 112' present -Fxq "Authorization: Bearer=\\'***REDACTED***\\'; echo KEEPESESQ1"
assert_fixture 'case 113' absent -Fq 'SYNTHESESQ1'
assert_fixture 'case 114' present -Fxq 'Authorization: Bearer==\"***REDACTED***\" | echo KEEPESESDQ2'
assert_fixture 'case 115' absent -Fq 'SYNTHESESDQ2'
assert_fixture 'case 116' present -Fxq "Authorization: Bearer:\'***REDACTED***\' >> out; echo KEEPESESQ2"
assert_fixture 'case 117' absent -Fq 'SYNTHESESQ2'
assert_fixture 'case 118' present -Fxq 'authorization: bearer=\"***REDACTED***\" && echo KEEPESESDQCASE'
assert_fixture 'case 119' absent -Fq 'SYNTHESESDQCASE'
assert_fixture 'case 120' present -Fxq 'Authorization: Bearer=\"***REDACTED***\"'
assert_fixture 'case 121' absent -Fq 'SYNTHESESDQ3'
assert_fixture 'case 122' absent -Fq 'SYNTHUNTERMDPQ1'
assert_fixture 'case 123' present -Fxq -- 'Authorization: Bearer=\"***REDACTED***'
assert_fixture 'case 124' absent -Fq 'SYNTHUNTERMSQ1'
assert_fixture 'case 125' present -Fxq "Authorization: Bearer=\\'***REDACTED***"
# Every trailing-backslash parity masks the credential and consumes the dangling slash;
# all four parities share the exact output asserted above.
assert_fixture 'case 126' absent -Fq 'SYNTHTRAILDDQ0'
assert_fixture 'case 127' absent -Fq 'SYNTHTRAILDDQ1'
assert_fixture 'case 128' absent -Fq 'SYNTHTRAILDDQ2'
assert_fixture 'case 129' absent -Fq 'SYNTHTRAILDDQ3'
assert_fixture 'case 130' absent -Fq 'SYNTHTRAILSQ0'
assert_fixture 'case 131' absent -Fq 'SYNTHTRAILSQ1'
assert_fixture 'case 132' absent -Fq 'SYNTHTRAILSQ2'
assert_fixture 'case 133' absent -Fq 'SYNTHTRAILSQ3'
assert_fixture 'case 134' absent -Fq 'SYNTHQURL1'
assert_fixture 'case 135' present -Fxq -- 'url=https://x/?token="***REDACTED***"&y=1; echo KEEPQURL1'
assert_fixture 'case 136' absent -Fq 'SYNTHQURL2'
assert_fixture 'case 137' present -Fxq -- "url=https://x/?secret='***REDACTED***'&y=2; echo KEEPQURL2"
assert_fixture 'case 138' absent -Fq 'SYNTHQURL3'
assert_fixture 'case 139' present -Fxq -- 'url=https://x/?token="***REDACTED***"&y=3; echo KEEPQURL3'
assert_fixture 'case 140' absent -Fq 'SYNTHQURL4'
assert_fixture 'case 141' present -Fxq -- "url=https://x/?api_key='***REDACTED***'&y=4; echo KEEPQURL4"
assert_fixture 'case 142' absent -Fq 'SYNTHQURL5'
assert_fixture 'case 143' present -Fxq -- 'curl "https://x/?token="***REDACTED***"&y=5"; echo KEEPQURL5'
assert_fixture 'case 144' absent -Fq 'SYNTHQURL6'
assert_fixture 'case 145' absent -Fq 'SYNTHESCKQ1'
assert_fixture 'case 146' present -Fxq -- 'url=https://x/?"token"="***REDACTED***"&y=1; echo KEEPESCKQ1'
assert_fixture 'case 147' absent -Fq 'SYNTHESCKQ2'
assert_fixture 'case 148' present -Fxq -- 'url=https://x/?'"'"'secret'"'"'='"'"'***REDACTED***'"'"'&y=2; echo KEEPESCKQ2'
assert_fixture 'case 149' absent -Fq 'SYNTHESCKQ3'
assert_fixture 'case 150' present -Fxq -- 'url=https://x/?"api_key"='"'"'***REDACTED***'"'"'&y=3; echo KEEPESCKQ3'
assert_fixture 'case 151' absent -Fq 'SYNTHESCKQ4'
assert_fixture 'case 152' present -Fxq -- 'curl "https://x/?"token"="***REDACTED***"&y=4"; echo KEEPESCKQ4'
assert_fixture 'case 153' absent -Fq 'SYNTHESCKQ5'
assert_fixture 'case 154' present -Fxq -- 'url=https://x/?"token"=***REDACTED***&y=5; echo KEEPESCKQ5'
assert_fixture 'case 155' present -Fxq -- 'url=https://x/?token="***REDACTED***"'
# Adjacent escaped segments are consumed fail-closed: no value or tail survives.
assert_fixture 'case 156' absent -Fq 'SYNTHESCADJ1'
assert_fixture 'case 157' present -Fxq -- 'url=https://x/?"token"=***REDACTED***"***REDACTED***'
assert_fixture 'case 158' absent -Fq 'KEEPESCADJ1'
assert_fixture 'case 159' absent -Fq 'SYNTHESCADJ2'
assert_fixture 'case 160' absent -Fq 'KEEPESCADJ2'
assert_fixture 'case 161' absent -Fq 'SYNTHESCADJ3'
assert_fixture 'case 162' absent -Fq 'KEEPESCADJ3'
assert_fixture 'case 163' absent -Fq 'SYNTHESCADJ4'
assert_fixture 'case 164' present -Fxq -- "url=https://x/?'token'=***REDACTED***'***REDACTED***"
assert_fixture 'case 165' absent -Fq 'KEEPESCADJ4'
# Chained credential keys keep their field boundaries; adjacent segments stay masked.
assert_fixture 'case 166' absent -Fq 'SYNTHKEEPUNEQ1'
assert_fixture 'case 167' absent -Fq 'SYNTHKEEPUNEQ2'
assert_fixture 'case 168' absent -Fq 'SECNEXT'
assert_fixture 'case 169' present -Fxq 'url=https://x/?token="***REDACTED***"&password=***REDACTED***&y=1; echo KEEPESEMPTYDQ'
assert_fixture 'case 170' absent -Fq 'SECNEXTE'
assert_fixture 'case 171' present -Fxq "url=https://x/?token='***REDACTED***'&secret=***REDACTED***&y=2; echo KEEPESEMPTYSQ"
assert_fixture 'case 172' absent -Fq 'SECNEXT WITH SPACE'
assert_fixture 'case 173' absent -Fq 'SECNEXT SQ SPACE'
assert_fixture 'case 174' present -Fxq 'url=https://x/?token="***REDACTED***"&password=***REDACTED***&y=1; echo KEEPURLDQSPACE'
assert_fixture 'case 175' present -Fxq "url=https://x/?token='***REDACTED***'&secret=***REDACTED***&y=2; echo KEEPURLSQSPACE"
assert_fixture 'case 176' present -Fxq -- 'url=https://x/?token="***REDACTED***"&password="***REDACTED***"&y=2; echo KEEPUNEQ'
assert_fixture 'case 177' absent -Fq 'SYNTHKEEPESCQ1'
assert_fixture 'case 178' absent -Fq 'SYNTHKEEPESCQ2'
assert_fixture 'case 179' present -Fxq -- "url=https://x/?\"token\"=\"***REDACTED***\"&password=***REDACTED***; echo KEEPESCQ"
assert_fixture 'case 180' present -Fxq -- "url=https://x/?\"token\"=\"***REDACTED***\";password=***REDACTED***; echo KEEPSEMI"
assert_fixture 'case 181' present -Fxq -- "url=https://x/?\"token\"=\"***REDACTED***\",password=***REDACTED***; echo KEEPCOMMA"
assert_fixture 'case 182' absent -Fq 'SYNTHKEEPESCSQ1'
assert_fixture 'case 183' absent -Fq 'SYNTHKEEPESCSQ2'
assert_fixture 'case 184' present -Fxq -- "url=https://x/?'token'='***REDACTED***'&password=***REDACTED***; echo KEEPESCSQ"
assert_fixture 'case 185' absent -Fq 'SYNTHADJGUARD1'
assert_fixture 'case 186' absent -Fq 'KEEPADJGUARD1'
assert_fixture 'case 187' absent -Fq 'SYNTHADJGUARD2'
assert_fixture 'case 188' absent -Fq 'KEEPADJGUARD2'
# A plain key must consume adjacent escaped segments; a second keyed field stays separate.
assert_fixture 'case 189' absent -Fq 'SYNTHADJPLAIN1'
assert_fixture 'case 190' present -Fxq -- 'url=https://x/?token="***REDACTED***"&y=1; echo KEEPADJPLAIN1'
assert_fixture 'case 191' absent -Fq 'SYNTHADJPLAIN2'
assert_fixture 'case 192' present -Fxq -- "url=https://x/?token='***REDACTED***'&y=2; echo KEEPADJPLAIN2"
assert_fixture 'case 193' absent -Fq 'SYNTHADJPLAIN3'
assert_fixture 'case 194' present -Fxq -- 'url=https://x/?token="***REDACTED***"&y=3; echo KEEPADJPLAIN3'
assert_fixture 'case 195' absent -Fq 'SYNTHADJPLAIN4'
assert_fixture 'case 196' present -Fxq -- 'url=https://x/?token="***REDACTED***"&other_token="***REDACTED***"&y=4; echo KEEPADJPLAIN4'
assert_fixture 'case 197' absent -Fq 'SYNTHDOUBLE1'
assert_fixture 'case 198' present -Fxq -- 'url=https://x/?token:"***REDACTED***"'
assert_fixture 'case 199' absent -Fq 'SYNTHDOUBLE2'
assert_fixture 'case 200' present -Fxq -- 'url=https://x/?token:"***REDACTED***"&y=1; echo KEEPTAIL'
assert_fixture 'case 201' absent -Fq 'SYNTHDOUBLE3'
assert_fixture 'case 202' present -Fxq -- "url=https://x/?token='***REDACTED***'"
assert_fixture 'case 203' absent -Fq 'SYNTHDOUBLE4'
assert_fixture 'case 204' present -Fxq -- 'url=https://x/?api_key:"***REDACTED***"&y=2; echo KEEPDOUBLE4'
assert_fixture 'case 205' absent -Fq 'SYNTHSPACED1'
assert_fixture 'case 206' present -Fxq -- 'url=https://x/?token : ***REDACTED***'
assert_fixture 'case 207' absent -Fq 'SYNTHSPACED2'
assert_fixture 'case 208' present -Fxq -- 'url=https://x/?token : "***REDACTED***"&y=1; echo KEEPTAIL'
assert_fixture 'case 209' absent -Fq 'SYNTHSPACED3'
assert_fixture 'case 210' present -Fxq -- "url=https://x/?api_key : '***REDACTED***'"
assert_fixture 'case 211' present -Fxq -- 'url=https://x/?realm : = "example.com"; echo KEEPREALM'
assert_fixture 'case 212' absent -Fq 'SYNTHAUTHURL1'
assert_fixture 'case 213' present -Fxq -- 'url=https://x/?Authorization:"***REDACTED***"'
assert_fixture 'case 214' absent -Fq 'SYNTHAUTHURL2'
assert_fixture 'case 215' present -Fxq -- 'url=https://x/?Authorization:"***REDACTED***"&y=1; echo KEEPTAIL'
assert_fixture 'case 216' absent -Fq 'SYNTHAUTHURL3'
assert_fixture 'case 217' present -Fxq -- 'url=https://x/?Authorization:***REDACTED***'
assert_fixture 'case 218' absent -Fq 'SYNTHAUTHURL4'
assert_fixture 'case 219' present -Fxq -- 'url=https://x/?Authorization: ***REDACTED***'
assert_fixture 'case 220' present -Fxq -- 'url=https://x/?Authorization:realm="example.com"; echo KEEPURLAUTH'
assert_fixture 'case 221' present -Fxq 'Note LMLINE_REALM_EQ_SENTINEL is only a temporary marker.'
assert_fixture 'case 222' present -Fxq 'Note @@LMLINE_REALM_SHIELD_FOO@@ stays intact.'
assert_fixture 'case 223' present -Fxq -- 'curl "https://x/?Authorization:@@LMLINE_REALM_SHIELD_FOO@@" ; echo KEEPPASTEDSHIELD'
assert_fixture 'case 224' present -Fxq -- 'curl "https://x/?Authorization:@@LMLINE_REALM_SHIELD_FOO@@\"example.com\"; echo KEEPPASTEDSHIELDGLUED'
assert_fixture 'case 225' present -Fxq '?Authorization:REALM="example.com"; echo KEEPREALMCASE'
assert_fixture 'case 226' present -Fxq -- 'url=https://x/?Authorization:realm="example.com"; echo KEEPCOLONEQREALM'
assert_fixture 'case 227' present -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPURLAMP1'
assert_fixture 'case 228' absent -Fq SYNTHURLAMP1
assert_fixture 'case 229' present -Fxq -- 'url=https://x/?a=1;Authorization:***REDACTED***'
assert_fixture 'case 230' absent -Fq SYNTHURLSEMI1
assert_fixture 'case 231' present -Fxq -- 'url=https://x/?a=1,Authorization:***REDACTED***'
assert_fixture 'case 232' absent -Fq SYNTHURLCOMMA1
assert_fixture 'case 233' present -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***'
assert_fixture 'case 234' absent -Fq SYNTHURLBEARER1
assert_fixture 'case 235' present -Fxq 'Authorization: Bearer="***REDACTED***";token=***REDACTED***; echo KEEPEQCHAIN'
assert_fixture 'case 236' present -Fxq -- 'curl -H "Authorization: Bearer ***REDACTED***"; curl "https://x/?a=1&Authorization:***REDACTED***"'
assert_fixture 'case 237' absent -Fq SYNTHURLSAME2
assert_fixture 'case 238' present -Fxq -- 'curl "https://x/?a=1&Authorization:***REDACTED***"'
assert_fixture 'case 239' absent -Fq SYNTHURLDQ2
assert_fixture 'case 240' present -Fxq -- "curl 'https://x/?a=1&Authorization:***REDACTED***'"
assert_fixture 'case 241' absent -Fq SYNTHURLSQ2
assert_fixture 'case 242' present -Fxq -- 'curl "https://x/?a=1&Authorization:***REDACTED***"; echo KEEPURLSP2'
assert_fixture 'case 243' absent -Fq SYNTHURLSP2
assert_fixture 'case 244' absent -Fq 'SYNTHEQCHAIN'
assert_fixture 'case 245' present -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPURLCOLEND1'
assert_fixture 'case 246' absent -Fq SYNTHCOLEND1
assert_fixture 'case 247' present -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPURLEQEND1'
assert_fixture 'case 248' absent -Fq SYNTHEQEND1
assert_fixture 'case 249' present -Fxq -- "curl 'https://x/?a=1&Authorization:***REDACTED***'; echo KEEPURLCOLQUOTE1"
assert_fixture 'case 250' absent -Fq SYNTHCOLQUOTE1
assert_fixture 'case 251' absent -Fq U1lOVEhCQVNFNjQx==
assert_fixture 'case 252' present -Fxq 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPPADEQ1'
assert_fixture 'case 253' absent -Fq U1lOVEhCQVNFNjQy===
assert_fixture 'case 254' present -Fxq 'url=https://x/?a=1;Authorization:***REDACTED***; echo KEEPPADEQ2'
assert_fixture 'case 255' absent -Fq U1lOVEhCQVNFNjQz==
assert_fixture 'case 256' present -Fxq 'url=https://x/?a=1,Authorization:***REDACTED***; echo KEEPPADEQ3'
assert_fixture 'case 257' absent -Fq U1lOVEhCQVNFNjQ0==
assert_fixture 'case 258' present -Fxq "curl 'https://x/?a=1&Authorization:***REDACTED***'; echo KEEPPADEQ4"
assert_fixture 'case 259' absent -Fq U1lOVEhCQVNFNjQ1==
assert_fixture 'case 260' present -Fxq 'curl "https://x/?a=1;Authorization:***REDACTED***"; echo KEEPPADEQ5'
assert_fixture 'case 261' absent -Fq U1lOVEhCQVNFNjQ2===
assert_fixture 'case 262' present -Fxq 'curl "https://x/?a=1&Authorization:***REDACTED***; echo KEEPPADEQ6"'
assert_fixture 'case 263' absent -Fq U1lOVEhCQVNFNjQ3===
assert_fixture 'case 264' present -Fxq "curl 'https://x/?a=1&Authorization:***REDACTED***; echo KEEPPADEQ7'"
assert_fixture 'case 265' absent -Fq U1lOVEhCQVNFNjQ4==
assert_fixture 'case 266' present -Fxq 'curl "https://x/?a=1&Authorization:***REDACTED***"; echo KEEPPADEQ8'
assert_fixture 'case 267' absent -Fq U1lOVEhCQVNFNjQ5===
assert_fixture 'case 268' present -Fxq "curl 'https://x/?a=1&Authorization:***REDACTED***'; echo KEEPPADEQ9"
assert_fixture 'case 269' absent -Fq U1lOVEhCQVNFNjQ6=
assert_fixture 'case 270' present -Fxq 'curl "https://x/?a=1&Authorization:***REDACTED***"; echo KEEPSINGLEEQ1'
assert_fixture 'case 271' absent -Fq U1lOVEhCQVNFNjQ7=
assert_fixture 'case 272' present -Fxq "curl 'https://x/?a=1;Authorization:***REDACTED***'; echo KEEPSINGLEEQ2"
assert_fixture 'case 273' absent -Fq U1lOVEhCQVNFNjQ8=
assert_fixture 'case 274' present -Fxq 'curl "https://x/?a=1,Authorization:***REDACTED***"; echo KEEPSINGLEEQ3'
assert_fixture 'case 275' absent -Fq U1lOVEhCQVFCMQ==
assert_fixture 'case 276' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"; echo TAILFQ1'
assert_fixture 'case 277' absent -Fq U1lOVEhCQVFCMg==
assert_fixture 'case 278' present -Fxq "curl 'https://x/?Authorization:***REDACTED***'; echo TAILFQ2"
assert_fixture 'case 279' absent -Fq U1lOVEhCQVFCMw===
assert_fixture 'case 280' present -Fxq 'url=https://x/?Authorization:***REDACTED***; echo TAILFQ3'
assert_fixture 'case 281' absent -Fq U1lOVEhCQVFCNDo:
assert_fixture 'case 282' present -Fxq 'url=https://x/?Authorization:***REDACTED***; echo TAILFQ4'
assert_fixture 'case 283' absent -Fq YWI=
assert_fixture 'case 284' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"; echo TAILB64ONE'
assert_fixture 'case 285' absent -Fq YWJjZGVmZ2hpamtsbW5vcHE=
assert_fixture 'case 286' present -Fxq "curl 'https://x/?Authorization:***REDACTED***'; echo TAILB64LONG"
assert_fixture 'case 287' absent -Fq SYNTHSINGLEEQ4=
assert_fixture 'case 288' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"; echo TAILSINGLE4'
assert_fixture 'case 289' absent -Fq SYNTHSINGLEEQ5=
assert_fixture 'case 290' present -Fxq "curl 'https://x/?Authorization:***REDACTED***'; echo TAILSINGLE5"
assert_fixture 'case 291' absent -Fq SYNTHESCAPED1=
assert_fixture 'case 292' present -Fxq 'curl \"https://x/?Authorization:***REDACTED***\"; echo TAILESC'
assert_fixture 'case 293' absent -Fq SYNTHGT1=
assert_fixture 'case 294' present -Fxq 'curl "https://x/?Authorization:***REDACTED***">out; echo TAILGT'
assert_fixture 'case 295' absent -Fq SYNTHPAR1=
assert_fixture 'case 296' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"); echo TAILPAR'
assert_fixture 'case 297' absent -Fq SYNTHMULTIGT1==
assert_fixture 'case 298' present -Fxq 'curl "https://x/?Authorization:***REDACTED***">out; echo TAILMULTIGT'
assert_fixture 'case 299' absent -Fq U1lOVEhCQVFCMA==
assert_fixture 'case 300' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"]; echo KEEPBASE1'
assert_fixture 'case 301' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"?x=1; echo KEEPBASE2'
assert_fixture 'case 302' absent -Fq SYNTHSUFFIX1=
assert_fixture 'case 303' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"]; echo TAILSUFFIX1'
assert_fixture 'case 304' present -Fxq 'Authorization: Bearer=\"***REDACTED***\"; echo KEEPAUDSEG1'
assert_fixture 'case 305' absent -Fq 'SYNTHAUDSEG'
assert_fixture 'case 306' present -Fxq "Authorization: Bearer=\\'***REDACTED***\\'; echo KEEPAUDSEG2"
assert_fixture 'case 307' present -Fxq 'Authorization: Bearer="***REDACTED***"; echo KEEPAUDSEG3'
assert_fixture 'case 308' present -Fxq "Authorization: Bearer='***REDACTED***'; echo KEEPAUDSEG4"
assert_fixture 'case 309' present -Fxq 'Authorization: Bearer="***REDACTED***";token=***REDACTED***; echo KEEPAUDSEG5'
assert_fixture 'case 310' absent -Fq 'SYNTH SPACE'
assert_fixture 'case 311' present -Fxq 'Authorization: Bearer="***REDACTED***"; echo KEEPSEGSPACE1'
assert_fixture 'case 312' present -Fxq "Authorization: Bearer='***REDACTED***'; echo KEEPSEGSPACE2"
assert_fixture 'case 313' present -Fxq 'Authorization: Bearer="***REDACTED***"; echo "KEEPSEGSPACE4"'
assert_fixture 'case 314' absent -Fq 'SYNTH UPQ'
assert_fixture 'case 315' present -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPUPQ1'
assert_fixture 'case 316' present -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPUPQ2'
assert_fixture 'case 317' present -Fxq 'Authorization: Bearer=***REDACTED***; echo "KEEPUPQ3"'
assert_fixture 'case 318' present -Fxq 'Authorization: Bearer=***REDACTED***;token=***REDACTED***; echo KEEPUPQ4'
assert_fixture 'case 319' absent -Fq 'SYNTHUPQ5'
assert_fixture 'case 320' absent -Fq 'SYNTHUPQ6'
assert_fixture 'case 321' present -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Bearer=***REDACTED***; echo KEEPUPQ5'
assert_fixture 'case 322' absent -Fq 'SYNTHUPQ7'
assert_fixture 'case 323' present -Fxq 'Authorization: Bearer=***REDACTED*** | grep KEEPUPQ7'
assert_fixture 'case 324' absent -Fq 'SYNTHUPQ8'
assert_fixture 'case 325' absent -Fq 'SYNTHUPQ9'
assert_fixture 'case 326' present -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPUPQ8'
assert_fixture 'case 327' absent -Fq 'SYNTHUPQ10'
assert_fixture 'case 328' absent -Fq 'SYNTHUPQ11'
assert_fixture 'case 329' present -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQ10'
assert_fixture 'case 330' absent -Fq 'SYNTHUPQESC1'
assert_fixture 'case 331' present -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC1'
assert_fixture 'case 332' absent -Fq 'SYNTHUPQESC2'
assert_fixture 'case 333' present -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC2'
assert_fixture 'case 334' absent -Fq 'SYNTHUPQESC3'
assert_fixture 'case 335' present -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC3'
assert_fixture 'case 336' absent -Fq 'SYNTHCUSTM'
assert_fixture 'case 337' absent -Fq 'SYNTHXAUTH'
assert_fixture 'case 338' present -Fxq 'Authorization: Bearer=***REDACTED***; Authorization: Custom=***REDACTED***; echo KEEPCUSTOM1'
assert_fixture 'case 339' present -Fxq 'Authorization: Custom=***REDACTED***; echo KEEPCUSTOM2'
assert_fixture 'case 340' present -Fxq 'Authorization: X-OAuth2=***REDACTED***; Authorization: X-OAuth2=***REDACTED***; echo KEEPCUSTOM3'
assert_fixture 'case 341' absent -Fq 'SYNTHCUSTOMQH1'
assert_fixture 'case 342' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: keep' https://example.test; echo KEEPQHCUSTOM1"
assert_fixture 'case 343' absent -Fq 'SYNTHCUSTOMQH2'
assert_fixture 'case 344' present -Fxq 'curl -H "Authorization: ***REDACTED***" https://example.test; echo KEEPQHCUSTOM2'
assert_fixture 'case 345' absent -Fq 'LEAKAPOSTROPHE987'
assert_fixture 'case 346' present -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPTAILAPOS987'
assert_fixture 'case 347' absent -Fq 'LEAKAPOSTROPHE988'
assert_fixture 'case 348' present -Fxq 'Authorization: Custom=***REDACTED***; echo KEEPTAILCUSTOM988'
assert_fixture 'case 349' absent -Fq 'LEAKDQUOTE989'
assert_fixture 'case 350' present -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPTAILDQUOTE989'
assert_fixture 'case 351' present -Fxq 'url=https://x/?realm=\"example.com\"; echo KEEPTAIL5'
assert_fixture 'case 352' present -Fxq 'Authorization: Digest ***REDACTED***'
# The existing URL/query and provider-key fixtures are controls for the narrow rule change.
assert_fixture 'case 353' present -Fxq "curl 'https://example.test/?x=1;token=***REDACTED***&y=2'"
assert_fixture 'case 354' present -Fxq 'curl "https://example.test/?q=ghp_***REDACTED***&x=1"'
assert_fixture 'case 355' present -Fq 'sk_live_***REDACTED***'
assert_fixture 'case 356' present -Fq 'Authorization: Bearer "***REDACTED***"'
assert_fixture 'case 357' present -Fq "Authorization: Bearer '***REDACTED***'"
assert_fixture 'case 358' absent -Fq 'quoted bearer token value'
assert_fixture 'case 359' absent -Fq 'single quoted bearer token'
assert_fixture 'case 360' absent -Fq 'insideTail1234567890'
assert_fixture 'case 361' present -Fq 'authorization: bearer ***REDACTED***'
assert_fixture 'case 362' absent -Fq 'lowercaseBearerTokenValue'
assert_fixture 'case 363' present -Fq 'api-key: ***REDACTED***'
assert_fixture 'case 364' absent -Fq 'hyphenatedKeyValue'
assert_fixture 'case 365' present -Fq 'token: ***REDACTED***'
assert_fixture 'case 366' absent -Fq 'starredSecretValue'
assert_fixture 'case 367' absent -Fq 'secretAtValue123'
assert_fixture 'case 368' present -Fxq 'Authorization: Bearer ***REDACTED***; echo KEEPATSECRET123'
assert_fixture 'case 369' present -Fq 'Authorization: Basic ***REDACTED***'
assert_fixture 'case 370' absent -Fq 'basicCredentialValue'
assert_fixture 'case 371' present -Fq 'Authorization: Digest ***REDACTED***'
assert_fixture 'case 372' absent -Fq 'digestNonceValue'
assert_fixture 'case 373' present -Fq 'Authorization: Token ***REDACTED***'
assert_fixture 'case 374' absent -Fq 'tokenSchemeValue'
assert_fixture 'case 375' absent -Fq 'jsonBasicValue'
assert_fixture 'case 376' absent -Fq 'quotedBasicValue'
assert_fixture 'case 377' absent -Fq 'unterminatedBasicValue'
assert_fixture 'case 378' absent -Fq 'firstHeaderToken123'
assert_fixture 'case 379' absent -Fq 'secondHeaderCred123'
assert_fixture 'case 380' absent -Fq 'curlToken123'
assert_fixture 'case 381' absent -Fq 'curlCred123'
assert_fixture 'case 382' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "Authorization: Basic ***REDACTED***" https://x'
assert_fixture 'case 383' absent -Fq 'schemeLessQuoted123'
assert_fixture 'case 384' absent -Fq 'schemeLessQuoted124'
assert_fixture 'case 385' absent -Fq 'schemedQuoted125'
assert_fixture 'case 386' present -Fxq 'curl -H "Authorization: ***REDACTED***" https://x'
assert_fixture 'case 387' present -Fxq "curl -H 'Authorization: ***REDACTED***' https://x"
assert_fixture 'case 388' present -Fxq "curl -H 'Authorization: Basic ***REDACTED***' https://x"
assert_fixture 'case 389' present -Fxq 'Authorization: ***REDACTED*** ***REDACTED***; echo "KEEP4"'
assert_fixture 'case 390' absent -Fq 'secretValue127'
assert_fixture 'case 391' present -Fxq 'Authorization: ***REDACTED***; echo "KEEP5"'
assert_fixture 'case 392' absent -Fq 'secretValue130'
assert_fixture 'case 393' present -Fxq 'Authorization: ***REDACTED*** ***REDACTED***'
assert_fixture 'case 394' absent -Fq 'secretValue131'
assert_fixture 'case 395' present -Fxq 'curl -H "Authorization: ***REDACTED***" "payload128" https://x'
assert_fixture 'case 396' absent -Fq 'secretValue128'
assert_fixture 'case 397' present -Fxq 'Authorization: ***REDACTED*** ***REDACTED***; echo "K9002"'
assert_fixture 'case 398' absent -Fq 'tokenWithHash#9002'
assert_fixture 'case 399' present -Fxq 'Authorization: ***REDACTED*** ***REDACTED***; echo "K9003"'
assert_fixture 'case 400' absent -Fq 'tokenWithBack\slash9003'
assert_fixture 'case 401' present -Fxq 'Authorization: ***REDACTED*** ***REDACTED*** https://x'
assert_fixture 'case 402' absent -Fq 'realDpopSecret123456'
assert_fixture 'case 403' absent -Fq 'realWsseSecret123456'
assert_fixture 'case 404' absent -Fq 'oddAtDouble999'
assert_fixture 'case 405' absent -Fq 'oddAtSingle999'
assert_fixture 'case 406' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: tailDouble" https://x'
assert_fixture 'case 407' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: tailSingle' https://x"
assert_fixture 'case 408' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keepAtDouble" https://x'
assert_fixture 'case 409' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: tailDouble" https://x'
assert_fixture 'case 410' present -Fxq "curl -H 'Authorization: Bearer ***REDACTED***' -H 'X: tailSingle' https://x"
assert_fixture 'case 411' present -Fxq 'curl -H "X: keep" -H "Authorization: Bearer ***REDACTED***" https://x'
assert_fixture 'case 412' absent -Fq 'atFirstDouble777'
assert_fixture 'case 413' absent -Fq 'atFirstSingle778'
assert_fixture 'case 414' absent -Fq 'atSecondDouble779'
assert_fixture 'case 415' present -Fxq 'Authorization: Bearer ***REDACTED*** -H "X: keep" https://x'
assert_fixture 'case 416' present -Fxq "Authorization: Bearer ***REDACTED*** -H 'X: keep' https://x"
assert_fixture 'case 417' present -Fxq 'Authorization: Digest ***REDACTED***, nonce="***REDACTED***"'
assert_fixture 'case 418' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" https://x'
assert_fixture 'case 419' present -Fxq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 420' absent -Fq 'quoteTail9011'
assert_fixture 'case 421' absent -Fq 'quoteTail9012'
assert_fixture 'case 422' absent -Fq 'nonceTail9014'
assert_fixture 'case 423' present -Fxq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 424' present -Fxq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 425' present -Fxq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 426' present -Fxq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 427' present -Fxq 'Authorization: Digest ***REDACTED***, response="***REDACTED***"'
assert_fixture 'case 428' absent -Fq 'unterminatedDot9021'
assert_fixture 'case 429' absent -Fq 'unterminatedApostrophe9022'
assert_fixture 'case 430' absent -Fq 'Secret9029'
assert_fixture 'case 431' absent -Fq 'untermTail'
assert_fixture 'case 432' absent -Fq 'respSecret9023'
assert_fixture 'case 433' present -Fxq 'Authorization: Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"'
assert_fixture 'case 434' present -Fxq 'Authorization: Digest ***REDACTED***, response="***REDACTED***", nonce="***REDACTED***"'
assert_fixture 'case 435' absent -Fq 'ZxSecretMARKER7788'
assert_fixture 'case 436' absent -Fq 'nonceSecond7789'
assert_fixture 'case 437' present -Fxq 'Authorization" : Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"'
assert_fixture 'case 438' absent -Fq 'sec7788'
assert_fixture 'case 439' absent -Fq 'NONCE7788'
assert_fixture 'case 440' absent -Fq 'RESP7788'
assert_fixture 'case 441' present -Fxq '"Authorization" : Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"'
assert_fixture 'case 442' absent -Fq 'sec7789'
assert_fixture 'case 443' absent -Fq 'NONCE7789'
assert_fixture 'case 444' absent -Fq 'RESP7789'
assert_fixture 'case 445' present -Fxq 'authorization  : Digest ***REDACTED***, nonce="***REDACTED***", response="***REDACTED***"'
assert_fixture 'case 446' absent -Fq 'sec7790'
assert_fixture 'case 447' absent -Fq 'NONCE7790'
assert_fixture 'case 448' absent -Fq 'RESP7790'
assert_fixture 'case 449' present -Fxq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 450' absent -Fq 'secretHash9020'
assert_fixture 'case 451' present -Fxq 'Authorization: Bearer ***REDACTED***; echo KEEPHASH9020'
assert_fixture 'case 452' absent -Fq 'escapedTail9015'
assert_fixture 'case 453' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" https://x; echo KEEPESC9015'
assert_fixture 'case 454' absent -Fq 'tailSECRET9991'
assert_fixture 'case 455' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x'
assert_fixture 'case 456' absent -Fq 'tailSECRET9992'
assert_fixture 'case 457' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://x'
assert_fixture 'case 458' absent -Fq 'tailLEAK9041'
assert_fixture 'case 459' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x'
assert_fixture 'case 460' absent -Fq 'tailLEAK9042'
assert_fixture 'case 461' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://x'
assert_fixture 'case 462' absent -Fq 'tailLEAK9043'
assert_fixture 'case 463' present -Fxq 'curl -H "X: keep" -H "Authorization: Bearer ***REDACTED***" https://x'
assert_fixture 'case 464' absent -Fq 'tailEscBearer9031'
assert_fixture 'case 465' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"X: keepTail9033" https://x'
assert_fixture 'case 466' absent -Fq 'tailEscScheme9032'
assert_fixture 'case 467' present -Fxq 'curl -H "Authorization: ***REDACTED***"X: keepTail9033" https://x'
# Genuinely closed escaped quotes are real word boundaries: keep the next header.
assert_fixture 'case 468' absent -Fq 'tailClosedBearer9031'
assert_fixture 'case 469' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keepClosed" https://x'
assert_fixture 'case 470' absent -Fq 'tailClosedScheme9032'
assert_fixture 'case 471' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keepClosed" https://x'
# The tailEscBearer9031/tailEscScheme9032 fixtures above are malformed shell text.
# Their exact assertions record the fail-closed fallback, not a word boundary.
assert_fixture 'case 472' absent -Fq 'plainQuote9044'
assert_fixture 'case 473' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x'
assert_fixture 'case 474' absent -Fq 'dblSlashQuote9045'
assert_fixture 'case 475' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***'
assert_fixture 'case 476' absent -Fq 'tailAUDIT028'
assert_fixture 'case 477' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://example.test'
assert_fixture 'case 478' absent -Fq 'tailAUDIT027'
assert_fixture 'case 479' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://example.test'
assert_fixture 'case 480' absent -Fq 'tailAUDIT029'
assert_fixture 'case 481' absent -Fq 'innerSPACE'
assert_fixture 'case 482' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://example.test'
assert_fixture 'case 483' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://example.test"
assert_fixture 'case 484' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://example.test"
assert_fixture 'case 485' absent -Fq 'multiDQ90'
assert_fixture 'case 486' absent -Fq 'multiSQ90'
assert_fixture 'case 487' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://example.test'
assert_fixture 'case 488' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://example.test'
assert_fixture 'case 489' absent -Fq 'insideEsc9031'
assert_fixture 'case 490' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://dqesc9031.example.test'
assert_fixture 'case 491' absent -Fq 'insideEsc9033'
assert_fixture 'case 492' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://sqesc9033.example.test"
assert_fixture 'case 493' absent -Fq 'tailDQSpaced9034'
assert_fixture 'case 494' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://dqesc9031.example.test'
assert_fixture 'case 495' absent -Fq 'tailSQSpaced9035'
assert_fixture 'case 496' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H \"X: keep\" https://sqesc9033.example.test"
assert_fixture 'case 497' absent -Fq 'tailBearer9038'
assert_fixture 'case 498' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://example.test'
assert_fixture 'case 499' absent -Fq 'tailEOL9039'
assert_fixture 'case 500' present -Fxq 'curl -H "Authorization: ***REDACTED***'
assert_fixture 'case 501' absent -Fq 'secret123456'
assert_fixture 'case 502' absent -Fq 'TAILAUDIT07'
assert_fixture 'case 503' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo "KEEP07"'
assert_fixture 'case 504' absent -Fq 'TAILAUDIT08'
assert_fixture 'case 505' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***", "KEEP08"'
assert_fixture 'case 506' absent -Fq 'TAILAUDIT09'
assert_fixture 'case 507' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"| :'
assert_fixture 'case 508' absent -Fq 'TAILAUDIT10'
assert_fixture 'case 509' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***">out'
assert_fixture 'case 510' absent -Fq 'TAILAUDIT11'
assert_fixture 'case 511' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***">>out'
assert_fixture 'case 512' absent -Fq 'TAILAUDIT12'
assert_fixture 'case 513' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"<in'
assert_fixture 'case 514' absent -Fq 'TAILAUDIT13'
assert_fixture 'case 515' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" >out'
assert_fixture 'case 516' absent -Fq 'TAILAUDIT14'
assert_fixture 'case 517' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; :'
assert_fixture 'case 518' absent -Fq 'TAILAUDIT15'
assert_fixture 'case 519' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"2>err'
assert_fixture 'case 520' absent -Fq 'TAILAUDIT16'
assert_fixture 'case 521' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"2>&1'
assert_fixture 'case 522' absent -Fq 'TAILAUDIT17'
assert_fixture 'case 523' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"1>>out'
assert_fixture 'case 524' absent -Fq 'TAILAUDIT18'
assert_fixture 'case 525' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"10>out'
assert_fixture 'case 526' absent -Fq 'TAILAUDIT19'
assert_fixture 'case 527' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"& :'
assert_fixture 'case 528' absent -Fq 'TAILAUDIT20'
assert_fixture 'case 529' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"&& :'
assert_fixture 'case 530' absent -Fq 'TAILAUDIT02'
assert_fixture 'case 531' present -Fxq "curl -H 'Authorization: Bearer ***REDACTED***'"
assert_fixture 'case 532' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" "payload123" https://x'
assert_fixture 'case 533' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" "user@host" "other" https://x'
assert_fixture 'case 534' absent -Fq 'brienApostrophe9016'
assert_fixture 'case 535' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: keepAtSingle' https://x"
assert_fixture 'case 536' absent -Fq 'FIRSTSECRET'
assert_fixture 'case 537' absent -Fq 'SECONDSECRET'
assert_fixture 'case 538' absent -Fq 'ONLYSECRET'
assert_fixture 'case 539' absent -Fq 'SINGLESECRET'
assert_fixture 'case 540' present -Fxq 'curl -H "Authorization: Bearer=***REDACTED***; Authorization: ***REDACTED***" https://x; echo KEEPTAIL'
assert_fixture 'case 541' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: keep' https://x; echo KEEPTAIL"
assert_fixture 'case 542' present -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPTAIL'
assert_fixture 'case 543' present -Fxq 'Authorization: Bearer=\"***REDACTED***\"; echo KEEPTAILBARE'
assert_fixture 'case 544' absent -Fq "'tSECRET"
assert_fixture 'case 545' present -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEP6'
assert_fixture 'case 546' absent -Fq 'SECRETADJ'
assert_fixture 'case 547' present -Fxq 'curl -H "Authorization: ***REDACTED***"2>err; echo KEEPTAILADJQ'
assert_fixture 'case 548' present -Fxq "curl -H 'Authorization: ***REDACTED***'2>err; echo KEEPTAILADJS"
assert_fixture 'case 549' absent -Fq 'SECRETADJPQ'
assert_fixture 'case 550' present -Fxq "curl -H 'Authorization: ***REDACTED***'2>err; echo KEEPTAILADJPQ"
assert_fixture 'case 551' absent -Fq 'SECRETADJSQ'
assert_fixture 'case 552' present -Fxq 'curl -H "Authorization: ***REDACTED***"2>err; echo KEEPTAILADJSQ'
assert_fixture 'case 553' present -Fxq 'curl -H "Authorization: Bearer:***REDACTED***"X; echo KEEPTAIL'
assert_fixture 'case 554' present -Fxq 'curl -H '"'"'Authorization: Bearer:***REDACTED***'"'"'X; echo MIRRORTAIL'
assert_fixture 'case 555' absent -Fq SECRETZZ
assert_fixture 'case 556' absent -Fq SECRETMM
assert_fixture 'case 557' present -Fxq 'curl -H"Authorization: Bearer:***REDACTED***"X; echo KEEPTAIL'
assert_fixture 'case 558' present -Fxq 'curl -H'"'"'Authorization: Bearer:***REDACTED***'"'"'X; echo KEEPTAIL'
assert_fixture 'case 559' absent -Fq SECRETZZ
assert_fixture 'case 560' absent -Fq SECRETMM
assert_fixture 'case 561' present -Fxq 'Authorization: Bearer:***REDACTED*** -H "X: keep" https://x; echo KEEPTAIL'
assert_fixture 'case 562' present -Fxq 'Authorization: Bearer:***REDACTED*** -H '"'"'X: keep'"'"' https://x; echo KEEPTAIL'
assert_fixture 'case 563' absent -Fq LEAKMIN987
assert_fixture 'case 564' absent -Fq LEAKMIRROR988
assert_fixture 'case 565' present -Fxq 'curl -H "Authorization: ***REDACTED***"2>err; echo KEEPTAILCLOSURE1'
assert_fixture 'case 566' present -Fxq 'curl -H"Authorization: ***REDACTED***"2>err; echo KEEPTAILCLOSURE2'
assert_fixture 'case 567' present -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPTAILCLOSURE3'
assert_fixture 'case 568' absent -Fq SYNTHCLOSURE901
assert_fixture 'case 569' absent -Fq SYNTHCLOSURE902
assert_fixture 'case 570' absent -Fq SYNTHCLOSURE903
assert_fixture 'case 571' present -Fxq 'Authorization: ***REDACTED***; echo KEEPSEPTAIL1'
assert_fixture 'case 572' present -Fxq 'Authorization: ***REDACTED***; echo KEEPSEPTAIL2'
assert_fixture 'case 573' present -Fxq 'Authorization: ***REDACTED***; echo KEEPSEPTAIL3'
assert_fixture 'case 574' present -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPSEPTAIL4'
assert_fixture 'case 575' absent -Fq SYNTHSEP901
assert_fixture 'case 576' absent -Fq SYNTHSEP902
assert_fixture 'case 577' absent -Fq SYNTHSEP903
assert_fixture 'case 578' absent -Fq SYNTHSEP904
assert_fixture 'case 579' absent -Fq SYNTHQSEP911
assert_fixture 'case 580' absent -Fq SYNTHQSEP912
assert_fixture 'case 581' absent -Fq SYNTHQSEP913
assert_fixture 'case 582' absent -Fq SYNTHQSEP914
assert_fixture 'case 583' absent -Fq SYNTHQSEP915
assert_fixture 'case 584' present -Fq KEEPQSEPTAIL11
assert_fixture 'case 585' present -Fq KEEPQSEPTAIL12
assert_fixture 'case 586' present -Fq KEEPQSEPTAIL13
assert_fixture 'case 587' present -Fq KEEPQSEPTAIL14
assert_fixture 'case 588' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPQSEPTAIL11'
assert_fixture 'case 589' present -Fxq 'curl -H '\''Authorization: ***REDACTED***'\''; echo KEEPQSEPTAIL12'
assert_fixture 'case 590' present -Fxq 'curl -H"Authorization: ***REDACTED***"; echo KEEPQSEPTAIL13'
assert_fixture 'case 591' present -Fxq 'curl -H'\''Authorization: ***REDACTED***'\''; echo KEEPQSEPTAIL14'
# Generic schemes must mask the credential and keep the following shell word.
assert_fixture 'case 592' absent -Fq SYNTHA1
assert_fixture 'case 593' present -Fxq 'curl -H "Authorization: ***REDACTED***" "PAYLOADA1"; echo TAILA1'
assert_fixture 'case 594' absent -Fq SYNTHS1
assert_fixture 'case 595' present -Fxq "curl -H 'Authorization: ***REDACTED***' 'PAYLOADS1'; echo TAILS1"
assert_fixture 'case 596' absent -Fq SYNTHX1
assert_fixture 'case 597' present -Fxq 'curl -H "Authorization: ***REDACTED***" --data "DATAX1"; echo TAILX1'
assert_fixture 'case 598' absent -Fq SYNTHC1
assert_fixture 'case 599' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: KEEPC1" https://x; echo TAILC1'
assert_fixture 'case 600' absent -Fq SYNTHX2
assert_fixture 'case 601' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: KEEPX2' https://x; echo TAILX2"
assert_fixture 'case 602' absent -Fq SYNTHM1
assert_fixture 'case 603' present -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo TAILM1'
assert_fixture 'case 604' absent -Fq SYNTH2
assert_fixture 'case 605' present -Fxq 'curl -H "Authorization: ***REDACTED***" 2>err; echo TAIL2'
assert_fixture 'case 606' absent -Fq SYNTHG1
assert_fixture 'case 607' absent -Fq GLUEDG1
assert_fixture 'case 608' present -Fxq 'curl -H "Authorization: Foo:***REDACTED***"; echo TAILG1'
assert_fixture 'case 609' absent -Fq SYNTHB1
assert_fixture 'case 610' present -Fxq 'curl -H "Authorization: ***REDACTED***" "PAYLOADB1"; echo TAILB1'
assert_fixture 'case 611' absent -Fq SYNTHBC1
assert_fixture 'case 612' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: KEEPC1" https://x; echo TAILBC1'
assert_fixture 'case 613' present -Fxq 'Authorization: ***REDACTED*** https://x; echo KEEPGLUEDTAIL1'
assert_fixture 'case 614' present -Fxq 'Authorization: ***REDACTED*** foo; echo KEEPGLUEDTAIL2'
assert_fixture 'case 615' absent -Fq SYNTHGLUED901
assert_fixture 'case 616' absent -Fq SYNTHGLUED902
assert_fixture 'case 617' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: keep" https://x; echo KEEPARGTAIL1'
assert_fixture 'case 618' present -Fxq 'curl -H "Authorization: Bearer:***REDACTED***"'
assert_fixture 'case 619' absent -Fq SYNTHEOL1001
assert_fixture 'case 620' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPZZ'
assert_fixture 'case 621' present -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPZZ"
assert_fixture 'case 622' present -Fxq 'curl -H "Authorization: ***REDACTED***" -H "Authorization: ***REDACTED***"; echo KEEPZZ9'
assert_fixture 'case 623' present -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'Authorization: ***REDACTED***'; echo KEEPZZ9"
assert_fixture 'case 624' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" -H "X: keep" https://x; echo KEEP88'
assert_fixture 'case 625' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPENDRED1'
assert_fixture 'case 626' present -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPENDRED2"
assert_fixture 'case 627' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPENDRED3'
assert_fixture 'case 628' present -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPENDRED4"
assert_fixture 'case 629' absent -Fq REALSECRET941
assert_fixture 'case 630' absent -Fq REALSECRET942
assert_fixture 'case 631' absent -Fq REALSECRET943
assert_fixture 'case 632' absent -Fq REALSECRET944
assert_fixture 'case 633' present -Fxq "curl -H 'Authorization: Bearer:***REDACTED***'"
assert_fixture 'case 634' absent -Fq SYNTHEOL1002
assert_fixture 'case 635' present -Fxq 'curl -H "Authorization: Basic:***REDACTED***"'
assert_fixture 'case 636' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPSTAR911'
assert_fixture 'case 637' present -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEPAT912"
assert_fixture 'case 638' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPSTAR913'
assert_fixture 'case 639' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPAT914'
assert_fixture 'case 640' absent -Fq SYNTHSTAR911
assert_fixture 'case 641' absent -Fq SYNTHAT912
assert_fixture 'case 642' absent -Fq SYNTHSTAR913
assert_fixture 'case 643' absent -Fq SYNTHAT914
assert_fixture 'case 644' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEP921'
assert_fixture 'case 645' present -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEP922"
assert_fixture 'case 646' present -Fxq "curl -H 'Authorization: ***REDACTED***'; echo KEEP923"
assert_fixture 'case 647' absent -Fq SYNTHSTAR921
assert_fixture 'case 648' absent -Fq SYNTHSTAR922
assert_fixture 'case 649' absent -Fq SYNTHAT923
assert_fixture 'case 650' present -Fxq 'Authorization: ***REDACTED***; echo KEEPGENSC901'
assert_fixture 'case 651' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPGENSC902'
assert_fixture 'case 652' absent -Fq SYNTHGENSC901
assert_fixture 'case 653' absent -Fq SYNTHGENSC902
assert_fixture 'case 654' absent -Fq SYNTHEOL1003
assert_fixture 'case 655' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPNUM1'
assert_fixture 'case 656' absent -Fq 1234567890
assert_fixture 'case 657' present -Fxq "curl -H 'Authorization: Bearer ***REDACTED***'; echo KEEPNUM2"
assert_fixture 'case 658' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPNUM3'
assert_fixture 'case 659' absent -Fq SECRETABC123
assert_fixture 'case 660' absent -Fq SYNTHARG901
assert_fixture 'case 661' present -Fxq 'curl -H '"'"'Authorization: ***REDACTED***'"'"' -H '"'"'X: keep'"'"' https://x; echo KEEPARGTAIL2'
assert_fixture 'case 662' absent -Fq SYNTHARG902
assert_fixture 'case 663' present -Fxq 'curl -H "Authorization: ***REDACTED***" "payload903" https://x; echo KEEPARGTAIL3'
assert_fixture 'case 664' absent -Fq SYNTHARG903
assert_fixture 'case 665' present -Fxq 'curl -H '"'"'Authorization: ***REDACTED***'"'"' '"'"'payload904'"'"' https://x; echo KEEPARGTAIL4'
assert_fixture 'case 666' absent -Fq SYNTHARG904
assert_fixture 'case 667' present -Fxq 'Authorization: ***REDACTED***; echo TAILZZ9'
assert_fixture 'case 668' absent -Fq SECRETZZ9
assert_fixture 'case 669' present -Fxq 'Authorization: ***REDACTED***; echo TAILZZ10'
assert_fixture 'case 670' absent -Fq SECRETZZ10
assert_fixture 'case 671' present -Fxq 'Authorization: ***REDACTED***; echo TAILZZ11'
assert_fixture 'case 672' absent -Fq SECRETZZ11
assert_fixture 'case 673' present -Fxq 'Authorization: my_scheme=\"***REDACTED***\"; echo TAILZZ12'
assert_fixture 'case 674' absent -Fq SYNTHE12
assert_fixture 'case 675' present -Fxq 'Authorization: 2Scheme=\"***REDACTED***\"; echo TAILZZ13'
assert_fixture 'case 676' absent -Fq SYNTHE13
assert_fixture 'case 677' present -Fxq 'Authorization: my_scheme \"***REDACTED***\"; echo TAILZZSP2'
assert_fixture 'case 678' absent -Fq SYNTHSP2
assert_fixture 'case 679' present -Fxq 'Authorization: 2Scheme \"***REDACTED***\"; echo TAILZZSP3'
assert_fixture 'case 680' absent -Fq SYNTHSP3
assert_fixture 'case 681' present -Fxq 'Authorization: my_scheme:"***REDACTED***"; echo KEEPQUOTED1'
assert_fixture 'case 682' absent -Fq SYNTHQUOTED1
assert_fixture 'case 683' present -Fxq "Authorization: my_scheme:'***REDACTED***'; echo KEEPQUOTED2"
assert_fixture 'case 684' absent -Fq SYNTHQUOTED2
assert_fixture 'case 685' present -Fxq 'Authorization: 2Scheme="***REDACTED***"; echo KEEPQUOTED3'
assert_fixture 'case 686' absent -Fq SYNTHQUOTED3
assert_fixture 'case 687' present -Fxq "Authorization: 2Scheme='***REDACTED***'; echo KEEPQUOTED4"
assert_fixture 'case 688' absent -Fq SYNTHQUOTED4
assert_fixture 'case 689' present -Fxq 'Authorization: my_scheme:"***REDACTED***"; echo KEEPGLUEDQ1'
assert_fixture 'case 690' absent -Fq SYNTHGLUEDQ1
assert_fixture 'case 691' present -Fxq "Authorization: 2Scheme:'***REDACTED***'; echo KEEPGLUEDS1"
assert_fixture 'case 692' absent -Fq SYNTHGLUEDS1
assert_fixture 'case 693' present -Fxq 'Authorization: my_scheme:"***REDACTED***" "PAYLOADGLUEDQ2"; echo KEEPGLUEDQ2'
assert_fixture 'case 694' absent -Fq SYNTHGLUEDQ2
assert_fixture 'case 695' present -Fxq 'Authorization: my_scheme:"***REDACTED***"; Authorization: 2scheme:"***REDACTED***"; echo KEEPREPEATQ'
assert_fixture 'case 696' absent -Fq SYNTHREPEATQ1
assert_fixture 'case 697' absent -Fq SYNTHREPEATQ2
assert_fixture 'case 698' present -Fxq 'Authorization: my_scheme:"***REDACTED***"|Authorization: 2scheme:"***REDACTED***"; echo KEEPREPEATPIPE'
assert_fixture 'case 699' absent -Fq SYNTHREPEATPIPE1
assert_fixture 'case 700' absent -Fq SYNTHREPEATPIPE2
assert_fixture 'case 701' present -Fxq 'Authorization: my_scheme:"***REDACTED***" >out; Authorization: 2scheme:"***REDACTED***" <in; echo KEEPREPEATREDIR'
assert_fixture 'case 702' absent -Fq SYNTHREPEATREDIR1
assert_fixture 'case 703' absent -Fq SYNTHREPEATREDIR2
assert_fixture 'case 704' present -Fxq "Authorization: my_scheme:'***REDACTED***'; Authorization: 2scheme:'***REDACTED***'; echo KEEPREPEATSQ"
assert_fixture 'case 705' absent -Fq SYNTHREPEATSQ1
assert_fixture 'case 706' absent -Fq SYNTHREPEATSQ2
assert_fixture 'case 707' present -Fxq "Authorization: my_scheme:'***REDACTED***'|Authorization: 2scheme:'***REDACTED***'; echo KEEPREPEATSQPIPE"
assert_fixture 'case 708' absent -Fq SYNTHREPEATSQPIPE1
assert_fixture 'case 709' absent -Fq SYNTHREPEATSQPIPE2
assert_fixture 'case 710' present -Fxq "Authorization: my_scheme:'***REDACTED***' >out; Authorization: 2scheme:'***REDACTED***' <in; echo KEEPREPEATSQREDIR"
assert_fixture 'case 711' absent -Fq SYNTHREPEATSQREDIR1
assert_fixture 'case 712' absent -Fq SYNTHREPEATSQREDIR2
assert_fixture 'case 713' present -Fxq 'Authorization: my_scheme:"***REDACTED***"&Authorization: 2scheme:"***REDACTED***"; echo KEEPSEPAMP'
assert_fixture 'case 714' absent -Fq SYNTHSEPAMP1
assert_fixture 'case 715' absent -Fq SYNTHSEPAMP2
assert_fixture 'case 716' present -Fxq 'Authorization: my_scheme:"***REDACTED***";Authorization: 2scheme:"***REDACTED***"; echo KEEPSEPSEMI'
assert_fixture 'case 717' absent -Fq SYNTHSEPSEMI1
assert_fixture 'case 718' absent -Fq SYNTHSEPSEMI2
assert_fixture 'case 719' present -Fxq 'Authorization: my_scheme:"***REDACTED***",Authorization: 2scheme:"***REDACTED***"; echo KEEPSEPCOMMA'
assert_fixture 'case 720' absent -Fq SYNTHSEPCOMMA1
assert_fixture 'case 721' absent -Fq SYNTHSEPCOMMA2
assert_fixture 'case 722' present -Fxq "Authorization: my_scheme:'***REDACTED***'&Authorization: 2scheme:'***REDACTED***'; echo KEEPSEPAMPSQ"
assert_fixture 'case 723' absent -Fq SYNTHSEPAMPSQ1
assert_fixture 'case 724' absent -Fq SYNTHSEPAMPSQ2
assert_fixture 'case 725' present -Fxq 'echo "note Authorization: SYNTHNATQ1 ***REDACTED***"; echo KEEPNATQ1'
assert_fixture 'case 726' present -Fq KEEPNATQ1
assert_fixture 'case 727' present -Fxq "echo 'note Authorization: SYNTHNATS1 ***REDACTED***'; echo KEEPNATS1"
assert_fixture 'case 728' present -Fq KEEPNATS1
assert_fixture 'case 729' absent -Fq 'more_secret456'
assert_fixture 'case 730' present -Fxq 'echo KEEPMORE456; Authorization: Bearer ***REDACTED***'
assert_fixture 'case 731' absent -Fq 'w0rd123SECRET'
assert_fixture 'case 732' present -Fxq 'echo KEEPWORD123; Authorization: Basic ***REDACTED***'
assert_fixture 'case 733' present -Fxq 'Authorization: Bearer ***REDACTED***'
assert_fixture 'case 734' present -Fxq 'Authorization: ***REDACTED***'
assert_fixture 'case 735' absent -Fq 'keyPlusHeaderValue123'
assert_fixture 'case 736' present -Fxq '{"api_key": "***REDACTED***", "Authorization": "Basic ***REDACTED***", "keep": "KEEPKEYPLUS"}'
assert_fixture 'case 737' absent -Fq 'keyPlusHeaderCred123'
assert_fixture 'case 738' absent -Fq 'tokenPlusHeaderValue123'
assert_fixture 'case 739' absent -Fq 'tokenPlusHeaderCred123'
assert_fixture 'case 740' present -Fq 'Authorization: ***REDACTED***'
assert_fixture 'case 741' present -Fq 'Authorization: "***REDACTED***"'
assert_fixture 'case 742' present -Fq "Authorization: '***REDACTED***'"
assert_fixture 'case 743' absent -Fq 'bareSchemeLessValue'
assert_fixture 'case 744' absent -Fq 'quotedSchemeLessValue'
assert_fixture 'case 745' absent -Fq 'singleSchemeLessValue'
assert_fixture 'case 746' absent -Fq 'bareLowerSchemeLess'
assert_fixture 'case 747' absent -Fq 'bareCred2'
assert_fixture 'case 748' absent -Fq 'schemeLessJsonCred'
assert_fixture 'case 749' absent -Fq 'bareAtValue'
assert_fixture 'case 750' absent -Fq 'quotedAtValue'
assert_fixture 'case 751' absent -Fq 'unterminatedSchemeLess'
assert_fixture 'case 752' absent -Fq 'oddAtValue'
assert_fixture 'case 753' absent -Fq 's3cr3tToken99'
assert_fixture 'case 754' absent -Fq 'acct99'
assert_fixture 'case 755' present -Fxq 'Authorization: Bearer ***REDACTED*** https://example.com'
assert_fixture 'case 756' absent -Fq 'two999'
assert_fixture 'case 757' absent -Fq 'u@host99'
assert_fixture 'case 758' absent -Fq 'backslashBearerOdd901'
assert_fixture 'case 759' absent -Fq 'backslashSchemeLessOdd902'
assert_fixture 'case 760' absent -Fq 'backslashSingleOdd903'
assert_fixture 'case 761' absent -Fq 'backslashKeyOdd904'
assert_fixture 'case 762' present -Fxq 'Authorization: ***REDACTED***\'
assert_fixture 'case 763' absent -Fq 'continuationSecret444444'
assert_fixture 'case 764' absent -Fq 'hostBackslashOdd905'
assert_fixture 'case 765' present -Fxq 'Authorization: Bearer "***REDACTED***'
assert_fixture 'case 766' present -Fxq 'Authorization: "***REDACTED***'
assert_fixture 'case 767' present -Fxq "Authorization: '***REDACTED***'"
assert_fixture 'case 768' present -Fxq 'MY_TOKEN=***REDACTED***'
assert_fixture 'case 769' absent -Fq 'backslashBearerEven906'
assert_fixture 'case 770' absent -Fq 'backslashSchemeLessEven907'
assert_fixture 'case 771' absent -Fq 'u@host456'
assert_fixture 'case 772' absent -Fq 'keyVal123'
assert_fixture 'case 773' absent -Fq 'foo bar baz'
assert_fixture 'case 774' absent -Fq 'spaces tail'
assert_fixture 'case 775' absent -Fq 'tokenAtValue123'
assert_fixture 'case 776' absent -Fq 'keyAtValue123'
assert_fixture 'case 777' absent -Fq 'unterminated_secret_12345'
assert_fixture 'case 778' absent -Fq 'inner_unterminated_12345'
assert_fixture 'case 779' absent -Fq 'plainTokenValue'
assert_fixture 'case 780' present -Fq '"api_key": "***REDACTED***"'
assert_fixture 'case 781' absent -Fq 'json_secret_value'
assert_fixture 'case 782' present -Fq '"token": "***REDACTED***"'
assert_fixture 'case 783' absent -Fq 'json_token_value'
assert_fixture 'case 784' present -Fq '"password": "***REDACTED***"'
assert_fixture 'case 785' absent -Fq 'value with spaces'
assert_fixture 'case 786' absent -Fq 'quote"BearerSuffix'
assert_fixture 'case 787' present -Fq 'MY_TOKEN=***REDACTED***'
assert_fixture 'case 788' present -Fq "Authorization: 'Bearer ***REDACTED***'"
assert_fixture 'case 789' absent -Fq 'BearerSuffixSingle'
assert_fixture 'case 790' present -Fq "TOKEN='***REDACTED***'"
assert_fixture 'case 791' absent -Fq 'quotedTokenSecret123'
assert_fixture 'case 792' absent -Fq 'defGHI'
assert_fixture 'case 793' present -Fq "DB_PASSWORD=***REDACTED***"
assert_fixture 'case 794' absent -Fq "'w0rd"
assert_fixture 'case 795' present -Fxq 'curl -d "{\"Authorization\":\"Bearer ***REDACTED***\"}" https://x'
assert_fixture 'case 796' absent -Fq 'escapedJsonAuth9001'
assert_fixture 'case 797' present -Fxq 'Authorization\":\"Bearer ***REDACTED***'
assert_fixture 'case 798' absent -Fq 'escapedUnterminated9002'
assert_fixture 'case 799' present -Fxq 'MY_TOKEN\":\"***REDACTED***'
assert_fixture 'case 800' absent -Fq 'escapedKey9003'
assert_fixture 'case 801' present -Fxq 'curl -d "{\"api_key\":\"***REDACTED***\"}" https://x'
assert_fixture 'case 802' absent -Fq 'escapedApiKey9004'
assert_fixture 'case 803' present -Fxq 'curl -d "{\\\"Authorization\\\":\\\"Bearer ***REDACTED***\"}" https://x'
assert_fixture 'case 804' absent -Fq 'doubleEscapedAuth9101'
assert_fixture 'case 805' present -Fxq 'MY_TOKEN\\\":\\\"***REDACTED***'
assert_fixture 'case 806' absent -Fq 'doubleEscapedKey9102'
assert_fixture 'case 807' present -Fxq 'curl -d "{\"Authorization\":\"Bearer ***REDACTED***\"}" https://x'
assert_fixture 'case 808' absent -Fq 'SECRET888'
assert_fixture 'case 809' present -Fxq 'curl -d "{\"MY_TOKEN\":\"***REDACTED***\"}" https://x'
assert_fixture 'case 810' present -Fxq 'curl -d "{\"Authorization\":\"Bearer ***REDACTED***\"}" https://x'
assert_fixture 'case 811' absent -Fq 'tailSECRET999'
assert_fixture 'case 812' present -Fxq 'Authorization\":\"Bearer ***REDACTED***'
assert_fixture 'case 813' absent -Fq 'secretEnding8888'
assert_fixture 'case 814' present -Fxq 'MY_TOKEN\":\"***REDACTED***'
assert_fixture 'case 815' absent -Fq 'secretEnding7777'
assert_fixture 'case 816' present -Fxq 'Authorization\":\"Bearer ***REDACTED***'
assert_fixture 'case 817' absent -Fq 'backslashOddEscapedAuth9011'
assert_fixture 'case 818' present -Fxq 'MY_TOKEN\":\"***REDACTED***'
assert_fixture 'case 819' absent -Fq 'backslashOddEscapedKey9012'
assert_fixture 'case 820' absent -Fq 'brienEscapedAuth9201'
assert_fixture 'case 821' absent -Fq 'brienEscapedUnterm9202'
assert_fixture 'case 822' absent -Fq 'brienEscapedKey9203'
assert_fixture 'case 823' absent -Fq 'bracketCloseAuth9301'
assert_fixture 'case 824' absent -Fq 'bracketCloseKey9302'
assert_fixture 'case 825' present -Fxq 'Authorization\: "Bearer ***REDACTED***"}'
assert_fixture 'case 826' present -Fxq 'MY_TOKEN\: "***REDACTED***"}'
assert_fixture 'case 827' present -Fxq 'Authorization\": "Bearer ***REDACTED***'
assert_fixture 'case 828' present -Fxq "Authorization\\': 'Bearer ***REDACTED***'}"
assert_fixture 'case 829' present -Fxq "Authorization: \\'Bearer ***REDACTED***'"
assert_fixture 'case 830' present -Fxq "Authorization: \\'***REDACTED***'"
assert_fixture 'case 831' present -Fxq "Authorization: \\'Bearer ***REDACTED***'}"
assert_fixture 'case 832' present -Fxq "MY_TOKEN\\': '***REDACTED***'"
assert_fixture 'case 833' present -Fxq "Authorization: \\\"Bearer ***REDACTED***\""
assert_fixture 'case 834' present -Fxq "Authorization: \\\"***REDACTED***\""
assert_fixture 'case 835' present -Fxq "MY_TOKEN\\: \"***REDACTED***\""
assert_fixture 'case 836' present -Fq '"Authorization": "Bearer ***REDACTED***"'
json_count=0
while IFS= read -r json_line; do
  printf '%s' "$json_line" | jq -e . >/dev/null 2>&1 || exit 68
  ((json_count += 1))
done < <(grep '^{"' "$line_file")
((json_count >= 4)) || exit 67
assert_fixture 'case 837' absent -Fq 'BearerSuffix1234567890'
assert_fixture 'case 838' absent -Fq 'json_bearer_value'
assert_fixture 'case 839' present -Fq '123MY_TOKEN=***REDACTED***'
assert_fixture 'case 840' absent -Fq 'SECRETVAL'
assert_fixture 'case 841' present -Fq '"123MY_TOKEN": "***REDACTED***"'
assert_fixture 'case 842' present -Fq -- '-MY_TOKEN=***REDACTED***'
assert_fixture 'case 843' present -Fxq 'token=***REDACTED***; echo KEEPSEMIFIX'
assert_fixture 'case 844' present -Fxq 'TOKEN=***REDACTED***; echo KEEPSEMI2FIX'
assert_fixture 'case 845' present -Fxq 'api_key=***REDACTED***; echo KEEPAPIFIX'
assert_fixture 'case 846' present -Fxq '"token=***REDACTED***"; echo KEEPQUOTEDFIX'
assert_fixture 'case 847' present -Fxq "'token=***REDACTED***'; echo KEEPQUOTED2FIX"
assert_fixture 'case 848' present -Fxq 'token=***REDACTED***'
assert_fixture 'case 849' absent -Fq 'defFIX'
assert_fixture 'case 850' present -Fxq 'token=***REDACTED***; password=***REDACTED***; echo KEEP_TWO'
assert_fixture 'case 851' present -Fxq 'token=***REDACTED***; password=***REDACTED***; key=***REDACTED***; echo KEEP_MULTI'
assert_fixture 'case 852' present -Fxq 'token=***REDACTED***;token2=***REDACTED***; echo KEEPDOUBLEFIX'
assert_fixture 'case 853' absent -Fq 'SYNTHSEMIKEY'
assert_fixture 'case 854' present -Fxq 'echo token=***REDACTED***;token2=***REDACTED***; echo KEEPCHAIN'
assert_fixture 'case 855' absent -Fq 'SYNTHCHAIN'
assert_fixture 'case 856' present -Fxq 'echo token=***REDACTED***'
assert_fixture 'case 857' present -Fxq 'token=***REDACTED***;token2=***REDACTED***;token3=***REDACTED***; echo KEEPCHAIN3'
assert_fixture 'case 858' absent -Fq 'SYNTHCHAIN3'
assert_fixture 'case 859' present -Fxq 'token=***REDACTED***,token2=***REDACTED***;token3=***REDACTED***; echo KEEPMIXCHAIN'
assert_fixture 'case 860' absent -Fq 'SYNTHMIX1'
assert_fixture 'case 861' present -Fxq 'token=***REDACTED***;token2=***REDACTED***,token3=***REDACTED***, echo KEEPMIXCHAIN2'
assert_fixture 'case 862' absent -Fq 'SYNTHMIX4'
assert_fixture 'case 863' present -Fxq 'token = ***REDACTED***;token2 = ***REDACTED***; echo KEEPSPACEKEY'
assert_fixture 'case 864' absent -Fq 'SYNTHSPACE1'
assert_fixture 'case 865' present -Fxq 'token=***REDACTED*** echo KEEPCOMMAOPAQUE'
assert_fixture 'case 866' absent -Fq 'defTAILCOMMA'
assert_fixture 'case 867' present -Fxq 'token=***REDACTED***&token2=***REDACTED***& echo KEEPAMPKEY'
assert_fixture 'case 868' absent -Fq 'SYNTHAMPKEY'
assert_fixture 'case 869' present -Fxq 'token=***REDACTED***|token2=***REDACTED***; echo KEEPPIPEKEY'
assert_fixture 'case 870' absent -Fq 'SYNTHPIPEKEY'
assert_fixture 'case 871' present -Fxq 'token=***REDACTED*** echo KEEPAMPOPAQUE'
assert_fixture 'case 872' absent -Fq 'defTAILAMP'
assert_fixture 'case 873' present -Fxq 'token=***REDACTED*** echo KEEPPIPEOPAQUE'
assert_fixture 'case 874' absent -Fq 'defTAILPIPE'
assert_fixture 'case 875' present -Fxq '"token":***REDACTED***;"password":***REDACTED***; echo KEEPDQKEY'
assert_fixture 'case 876' absent -Fq 'SYNTHDQKEY'
assert_fixture 'case 877' present -Fxq "'test_key':***REDACTED***,'api_key':***REDACTED***, echo KEEPSQKEY"
assert_fixture 'case 878' absent -Fq 'SYNTHSQKEY'
assert_fixture 'case 879' present -Fxq '"token":***REDACTED*** echo KEEPQUOTEDOPAQUE'
assert_fixture 'case 880' absent -Fq 'defTAILQUOTED'
assert_fixture 'case 881' present -Fxq 'token=***REDACTED***,token2=***REDACTED***, echo KEEPCOMMA'
assert_fixture 'case 882' absent -Fq 'SYNTHCOMMA'
assert_fixture 'case 883' present -Fxq 'token=***REDACTED*** echo KEEPOPAQUE'
assert_fixture 'case 884' absent -Fq 'defTAILCHAIN'
assert_fixture 'case 885' absent -Fq 'defFIX'
assert_fixture 'case 886' present -Fxq 'echo token=***REDACTED*** echo KEEPCHAINLEAK'
assert_fixture 'case 887' absent -Fq 'SYNTHCHAINLEAK'
assert_fixture 'case 888' present -Fxq 'x=1;url=//user:***REDACTED***@example.test/path'
assert_fixture 'case 889' absent -Fq 'SYNTHSECRETFIRST'
assert_fixture 'case 890' absent -Fq 'SYNTHSECRETSECOND'
assert_fixture 'case 891' absent -Fq 'SYNTHMULTI'
assert_fixture 'case 892' present -Fxq 'token=***REDACTED***; echo KEEPKEYSemiFIX'
assert_fixture 'case 893' present -Fxq 'token=***REDACTED*** | grep KEEPPIPEFIX'
assert_fixture 'case 894' absent -Fq 'MARKER'
assert_fixture 'case 895' present -Fq '"2fa_secret": "***REDACTED***"'
assert_fixture 'case 896' absent -Fq 'SUPERSECRET123'
assert_fixture 'case 897' present -Fq '"123api_token": "***REDACTED***"'
assert_fixture 'case 898' absent -Fq 'ANOTHERSECRET456'
assert_fixture 'case 899' present -Fq 'gho_***REDACTED***'
assert_fixture 'case 900' present -Fq 'github_pat_***REDACTED***'
assert_fixture 'case 901' present -Fq 'ghs_***REDACTED***'
assert_fixture 'case 902' absent -Fq 'teless_jwt_body'
assert_fixture 'case 903' absent -Fq 'tail_with_underscore'
assert_fixture 'case 904' present -Fq 'API_KEY = ***REDACTED***'
assert_fixture 'case 905' absent -Fq 'spaced-secret-value'
assert_fixture 'case 906' present -Fq 'AKIA***REDACTED***'
assert_fixture 'case 907' present -Fq 'sk_live_***REDACTED***'
assert_fixture 'case 908' present -Fq 'sk_test_***REDACTED***'
assert_fixture 'case 909' present -Fq 'rk_live_***REDACTED***'
assert_fixture 'case 910' present -Fq 'rk_test_***REDACTED***'
assert_fixture 'case 911' absent -Fq 'StripeBodySkLive'
assert_fixture 'case 912' absent -Fq 'StripeBodyRkLive'
assert_fixture 'case 913' present -Fq 'pk_live_StripePublicBody0123456789'
assert_fixture 'case 914' absent -Fq 'IOSFODNN7EXAMPLE'
assert_fixture 'case 915' present -Fq 'xoxb-***REDACTED***'
assert_fixture 'case 916' present -Fq 'glpat-***REDACTED***'
assert_fixture 'case 917' absent -Fq 'abcdefghijklmnopqrstuvwxyz0123'
assert_fixture 'case 918' present -Fq 'AIza***REDACTED***'
assert_fixture 'case 919' absent -Fq 'SyD12345678901234567890123456789012'
assert_fixture 'case 920' absent -Fq '123456789012'
assert_fixture 'case 921' present -Fq '***REDACTED PRIVATE KEY***'
assert_fixture 'case 922' absent -Fq 'FAKE-KEY-BODY-FOR-REDACT-TEST'
assert_fixture 'case 923' absent -Fq 'BEGIN RSA PRIV''ATE KEY'
assert_fixture 'case 924' present -Fxq 'git clone https://oauth2:***REDACTED***@github.example/org/repo.git'
assert_fixture 'case 925' absent -Fq 'cloneTokUrl901'
assert_fixture 'case 926' present -Fxq 'psql postgresql://reporting:***REDACTED***@db.example:5432/analytics'
assert_fixture 'case 927' absent -Fq 'dbPwUrl902'
assert_fixture 'case 928' present -Fxq 'curl "https://u:***REDACTED***@host.example/x" -H "X: keepUrl"'
assert_fixture 'case 929' absent -Fq 'quotedPwUrl903'
assert_fixture 'case 930' present -Fq 'plain@example.com'
assert_fixture 'case 931' present -Fxq 'curl https://example.test:8443?q=alice@example.test'
assert_fixture 'case 932' present -Fxq 'curl https://example.test:8443#alice@example.test'
assert_fixture 'case 933' present -Fxq 'git clone //user:***REDACTED***@example.test/path'
assert_fixture 'case 934' absent -Fq 'git clone //user:pass@example.test/path'
assert_fixture 'case 935' present -Fxq 'echo [//user:***REDACTED***@example.test/path]'
assert_fixture 'case 936' absent -Fq 'passBracket@example.test'
assert_fixture 'case 937' present -Fxq 'echo {user=//user:***REDACTED***@example.test/path}'
assert_fixture 'case 938' absent -Fq 'passBrace@example.test'
assert_fixture 'case 939' present -Fxq 'echo `//user:***REDACTED***@example.test/path`'
assert_fixture 'case 940' absent -Fq 'passTick@example.test'
assert_fixture 'case 941' present -Fxq 'echo "url=//user:***REDACTED***@example.test/path"'
assert_fixture 'case 942' absent -Fq 'passQuotedAssign@example.test'
assert_fixture 'case 943' present -Fxq "echo 'url=//user:***REDACTED***@example.test/path'"
assert_fixture 'case 944' present -Fxq 'db.url=//user:***REDACTED***@example.test/x'
assert_fixture 'case 945' absent -Fq 'passDotted@example.test'
assert_fixture 'case 946' present -Fxq 'spring.datasource.url=//user:***REDACTED***@example.test/x'
assert_fixture 'case 947' absent -Fq 'passSpring@example.test'
assert_fixture 'case 948' present -Fxq 'curl --url=//user:***REDACTED***@example.test/x'
assert_fixture 'case 949' absent -Fq 'passFlag@example.test'
assert_fixture 'case 950' present -Fxq 'java -Ddb.url=//user:***REDACTED***@example.test/x'
assert_fixture 'case 951' absent -Fq 'passD@example.test'
assert_fixture 'case 952' present -Fxq 'db.url=//***REDACTED***@example.test/x'
assert_fixture 'case 953' absent -Fq 'BAREdot123456@example.test'
assert_fixture 'case 954' present -Fxq "curl 'https://example.test/docs#//user:Secret987654@example.test'"
assert_fixture 'case 955' present -Fxq "curl 'https://example.test/?a=1&//user:Secret987654@example.test'"
assert_fixture 'case 956' absent -Fq 'passSingleAssign@example.test'
assert_fixture 'case 957' present -Fxq 'curl https://example.test/?q=//abcdefghijkl@example.test'
assert_fixture 'case 958' present -Fxq "curl 'https://example.test/path?token=***REDACTED***&x=1'"
assert_fixture 'case 959' present -Fxq "curl 'https://example.test/?x=1&token=***REDACTED***'"
assert_fixture 'case 960' present -Fxq "curl 'https://example.test/?x=1;token=***REDACTED***&y=2'"
assert_fixture 'case 961' absent -Fq 'fixtureSemi9001'
assert_fixture 'case 962' present -Fxq "curl 'https://example.test/?x=1,token=***REDACTED***&y=2'"
assert_fixture 'case 963' absent -Fq 'fixtureComma9002'
assert_fixture 'case 964' present -Fxq "curl 'https://example.test/a;token=***REDACTED***?x=1'"
assert_fixture 'case 965' absent -Fq 'fixturePath9003'
assert_fixture 'case 966' present -Fxq 'curl "https://x/?token=***REDACTED***&y=2"'
assert_fixture 'case 967' absent -Fq 'abcQuestionMark9004'
assert_fixture 'case 968' present -Fxq 'echo x;token=***REDACTED***'
assert_fixture 'case 969' absent -Fq 'defLitQ9006'
assert_fixture 'case 970' present -Fxq 'curl "https://x/?token=***REDACTED***&y=2"'
assert_fixture 'case 971' absent -Fq 'defShellLitQ9007'
assert_fixture 'case 972' present -Fxq 'echo x;token=***REDACTED***'
assert_fixture 'case 973' absent -Fq 'abcQuestionShell9005'
assert_fixture 'case 974' present -Fxq 'echo x;token=***REDACTED***'
assert_fixture 'case 975' absent -Fq 'fixtureShell9004'
assert_fixture 'case 976' present -Fxq "curl 'https://example.test/a/token=***REDACTED***'"
assert_fixture 'case 977' present -Fxq 'INFO|token=***REDACTED*** service=web'
assert_fixture 'case 978' present -Fxq 'db:password=***REDACTED***'
assert_fixture 'case 979' present -Fxq '[INFO]token=***REDACTED***'
assert_fixture 'case 980' present -Fxq "curl 'https://example.test/?token=***REDACTED***&at=1'"
assert_fixture 'case 981' present -Fxq "curl 'https://example.test/?token=***REDACTED***&slash=1'"
assert_fixture 'case 982' absent -Fq '@example.com&at=1'
assert_fixture 'case 983' absent -Fq '/def&slash=1'
assert_fixture 'case 984' present -Fxq 'curl "https://x.test/a?token=***REDACTED***&keep=KEEPENC1"'
assert_fixture 'case 985' absent -Fq 'encEqSecret9001'
assert_fixture 'case 986' present -Fxq 'curl "https://x.test/a?api-key=***REDACTED***&keep=KEEPENC2"'
assert_fixture 'case 987' absent -Fq 'encEqSecret9002'
assert_fixture 'case 988' present -Fxq 'curl "https://x.test/a#token=***REDACTED***&keep=KEEPENC3"'
assert_fixture 'case 989' absent -Fq 'encColonSecret9003'
assert_fixture 'case 990' present -Fxq 'curl "https://x.test/a?token=***REDACTED***&keep=KEEPENC4"'
assert_fixture 'case 991' absent -Fq 'encSpaceSecret9004'
assert_fixture 'case 992' present -Fxq 'curl "https://x.test/a?redirect=https%3A//safe.test&keep=KEEPENC5"'
assert_fixture 'case 993' present -Fxq 'curl "https://x.test/a?Authorization:***REDACTED***&keep=KEEP0103"'
assert_fixture 'case 994' absent -Fq 'AUTHENCSECRET0103'
assert_fixture 'case 995' present -Fxq "curl 'https://x.test/a?\"Authorization\":***REDACTED***&keep=KEEP0103'"
assert_fixture 'case 996' present -Fxq "curl 'https://x.test/a?\"token\"=***REDACTED***&keep=KEEP0201'"
assert_fixture 'case 997' absent -Fq 'quotedKeySecret0201'
assert_fixture 'case 998' present -Fxq "curl \"https://x.test/a?'token'=***REDACTED***&keep=KEEP0202\""
assert_fixture 'case 999' absent -Fq 'quotedKeySecret0202'
assert_fixture 'case 1000' absent -Fq 'EscapedQuotedSecret0301'
assert_fixture 'case 1001' present -Fq 'KEEPQ1'
assert_fixture 'case 1002' absent -Fq 'EscapedQuotedSecret0302'
assert_fixture 'case 1003' present -Fq 'KEEPQ2'
assert_fixture 'case 1004' absent -Fq 'EscapedAuthSecret0303'
assert_fixture 'case 1005' present -Fq 'KEEPQ3'
assert_fixture 'case 1006' absent -Fq 'EscapedAuthSecret0304'
assert_fixture 'case 1007' present -Fq 'KEEPQ4'
# Adjacent segments, quoted values and padded separators mask every secret and keep the tail.
assert_fixture 'case 1008' absent -Fq 'SYNTHADJENCA1'
assert_fixture 'case 1009' absent -Fq 'SYNTHADJENCB1'
assert_fixture 'case 1010' present -Fq 'KEEPADJENC1'
assert_fixture 'case 1011' absent -Fq 'SYNTHADJENCA2'
assert_fixture 'case 1012' absent -Fq 'SYNTHADJENCB2'
assert_fixture 'case 1013' present -Fq 'KEEPADJENC2'
assert_fixture 'case 1014' absent -Fq 'SYNTHQUOTEENCA1'
assert_fixture 'case 1015' present -Fq 'KEEPQUOTEENC1'
assert_fixture 'case 1016' absent -Fq 'SYNTHQUOTEENCA2'
assert_fixture 'case 1017' present -Fq 'KEEPQUOTEENC2'
assert_fixture 'case 1018' absent -Fq 'SYNTHPADENCA1'
assert_fixture 'case 1019' present -Fq 'KEEPPADENC1'
assert_fixture 'case 1020' absent -Fq 'SYNTHPADENCA2'
assert_fixture 'case 1021' present -Fq 'KEEPPADENC2'
assert_fixture 'case 1022' present -Fxq 'url=https://x/?a=1&Authorization:***REDACTED***&keep=KEEPSCHEMESPACE1'
assert_fixture 'case 1023' absent -Fq 'SYNTHSCHEMESPACE9001'
assert_fixture 'case 1024' present -Fxq "url=https://x/?a=1&'Authorization':***REDACTED***&keep=KEEPSCHEMESPACE2"
assert_fixture 'case 1025' absent -Fq 'SYNTHSCHEMESPACE9002'
assert_fixture 'case 1026' present -Fxq 'curl "https://x/?Authorization:***REDACTED***" -H "X: keep"; echo KEEPQUOTETAIL9001'
assert_fixture 'case 1027' absent -Fq 'SYNTHQUOTEKEEP9001'
assert_fixture 'case 1028' present -Fxq 'curl "https://x/?Authorization:***REDACTED***"'
assert_fixture 'case 1029' absent -Fq 'SYNTHQUOTEKEEP9002'
assert_fixture 'case 1030' present -Fxq "curl 'https://x/?Authorization:***REDACTED***' -H 'X: keep'; echo KEEPQUOTETAIL9003"
assert_fixture 'case 1031' absent -Fq 'SYNTHQUOTEKEEP9003'
assert_fixture 'case 1032' present -Fxq "curl \"https://x/?Authorization:***REDACTED***\" --data=' keep'; echo KEEPQUOTETAIL9004"
assert_fixture 'case 1033' absent -Fq 'SYNTHQUOTEKEEP9004'
assert_fixture 'case 1034' present -Fxq 'url=https://x/?a=1&Authorization:***REDACTED***&keep=KEEPTAIL540'
assert_fixture 'case 1035' absent -Fq 'SYNTHESCDQ9003'
assert_fixture 'case 1036' present -Fxq 'url=https://x/?a=1&token=***REDACTED***&keep=KEEPTAIL603'
assert_fixture 'case 1037' absent -Fq 'SYNTHKEY9008'
assert_fixture 'case 1038' present -Fxq 'curl "https://example.test/?q=sk_live_***REDACTED***&x=1"'
assert_fixture 'case 1039' absent -Fq 'StripeBodyTail123'
assert_fixture 'case 1040' present -Fxq 'sk_test_***REDACTED***,next=1'
assert_fixture 'case 1041' absent -Fq 'StripeCommaBody456'
assert_fixture 'case 1042' present -Fxq 'curl "https://example.test/?q=ghp_***REDACTED***&x=1"'
assert_fixture 'case 1043' absent -Fq 'GitHubBodyTail456'
assert_fixture 'case 1044' present -Fxq 'curl "https://example.test/?q=AKIA***REDACTED***&x=1"'
assert_fixture 'case 1045' absent -Fq 'AWSBODYTAIL456'
assert_fixture 'case 1046' present -Fxq 'curl "https://example.test/?q=xoxb-***REDACTED***&x=1"'
assert_fixture 'case 1047' absent -Fq 'SlackTail'
assert_fixture 'case 1048' present -Fxq 'curl "https://example.test/?q=glpat-***REDACTED***&x=1"'
assert_fixture 'case 1049' absent -Fq 'GitLabBodyTail456'
assert_fixture 'case 1050' present -Fxq "curl 'https://user:***REDACTED***@example.test/path'"
assert_fixture 'case 1051' absent -Fq 'pass;token=abc@example.test'
assert_fixture 'case 1052' present -Fxq 'TOKEN=***REDACTED*** https://x'
assert_fixture 'case 1053' absent -Fq 'httpsSecret987654'
assert_fixture 'case 1054' present -Fq 'abcdefghijkl@example.test'
assert_fixture 'case 1055' present -Fxq 'curl https://example.test/a//abc:def@example.test'
assert_fixture 'case 1056' present -Fxq 'git clone //***REDACTED***@example.test/path'
assert_fixture 'case 1057' absent -Fq 'BAREabcdefghijkl@example.test/path'
assert_fixture 'case 1058' present -Fxq 'echo url=//user:***REDACTED***@example.test/path'
assert_fixture 'case 1059' absent -Fq 'passAssign@example.test'
assert_fixture 'case 1060' present -Fxq 'echo url=//***REDACTED***@example.test/path'
assert_fixture 'case 1061' absent -Fq 'BAREassign123456@example.test'
assert_fixture 'case 1062' present -Fxq 'url=//user:***REDACTED***@example.test/path'
assert_fixture 'case 1063' absent -Fq 'passAssignLine@example.test'
assert_fixture 'case 1064' present -Fxq 'url=//***REDACTED***@example.test/path'
assert_fixture 'case 1065' absent -Fq 'BAREline123456@example.test'
assert_fixture 'case 1066' present -Fxq 'echo foo,//user:***REDACTED***@example.test/path'
assert_fixture 'case 1067' absent -Fq 'passComma@example.test'
assert_fixture 'case 1068' present -Fxq 'curl "//user:***REDACTED***@example.test/path"'
assert_fixture 'case 1069' absent -Fq 'passDoubleQuote@example.test'
assert_fixture 'case 1070' present -Fxq 'curl "//***REDACTED***@example.test/path"'
assert_fixture 'case 1071' absent -Fq 'BAREdoublequote123@example.test'
assert_fixture 'case 1072' present -Fxq 'foo=bar,//user:***REDACTED***@example.test/path'
assert_fixture 'case 1073' absent -Fq 'passComma2@example.test'
assert_fixture 'case 1074' present -Fxq 'curl https://example.test/?q=//BAREabcdefghijkl@example.test'
assert_fixture 'case 1075' present -Fxq 'git clone https://***REDACTED***@example.test/nope.git'
assert_fixture 'case 1076' absent -Fq 'PATabcdefghijkl'
assert_fixture 'case 1077' present -Fxq 'git clone https://shortus@example.test/nope.git'
assert_fixture 'case 1078' present -Fxq 'git clone https://s3cret@example.test/nope.git'
assert_fixture 'case 1079' present -Fxq "curl 'https://example.test/?a=1;//u:pSemiQuery987654@example.test'"
assert_fixture 'case 1080' present -Fxq "curl 'https://example.test/a,//u:pCommaPath987654@example.test'"
assert_fixture 'case 1081' present -Fxq 'curl "https://x/?q=\"a;//u:pInQuote987654@example.test\""'
assert_fixture 'case 1082' present -Fxq 'curl "https://x/?q=\"a;//BAREesc987654@example.test\""'
assert_fixture 'case 1083' present -Fxq 'echo first;//u:***REDACTED***@example.test'
assert_fixture 'case 1084' present -Fxq "echo '\"';//u:***REDACTED***@example.test; echo '\"'"
assert_fixture 'case 1085' absent -Fq 'fixtureSeq101@example.test'
assert_fixture 'case 1086' present -Fxq "echo 'x';//u:***REDACTED***@example.test; echo 'x'"
assert_fixture 'case 1087' absent -Fq 'fixtureSeq101Control@example.test'
assert_fixture 'case 1088' present -Fxq 'curl "https://x/?a=1;b=2;//u:pSeq113Semi@one.example.test";//u:***REDACTED***@two.example.test'
assert_fixture 'case 1089' absent -Fq 'realSeq113Semi@two.example.test'
assert_fixture 'case 1090' present -Fxq 'curl "https://x/?a=1,b=2,//u:pSeq113Comma@one.example.test",//u:***REDACTED***@two.example.test'
assert_fixture 'case 1091' absent -Fq 'realSeq113Comma@two.example.test'
assert_fixture 'case 1092' present -Fxq "curl 'https://x/?a=;//u:pSeq113One@h;b=;//u:pSeq113Two@h';//u:***REDACTED***@h"
assert_fixture 'case 1093' absent -Fq 'realSeq113Two@h'
assert_fixture 'case 1094' present -Fxq 'a=("https://x/?q=;//u:pArrayData@one.example.test");//u:***REDACTED***@two.example.test'
assert_fixture 'case 1095' absent -Fq 'realArray@two.example.test'
assert_fixture 'case 1096' present -Fxq 'foo("https://x/?q=;//u:pParenData@one.example.test");//u:***REDACTED***@two.example.test'
assert_fixture 'case 1097' absent -Fq 'realParen@two.example.test'
assert_fixture 'case 1098' present -Fxq 'echo {"url":"https://x/?q=;//u:pAnchorData@one.example.test"};//u:***REDACTED***@two.example.test'
assert_fixture 'case 1099' absent -Fq 'realAnchor@two.example.test'
assert_fixture 'case 1100' present -Fxq 'curl "https://mixedsep1.example.test/?q=;//u:pMixedSepData1@one.example.test";//u:***REDACTED***@two.example.test'
assert_fixture 'case 1101' absent -Fq 'pMixedSepReal1'
assert_fixture 'case 1102' present -Fxq 'curl "https://mixedsep2.example.test/?q=;//BAREMixedData2@one.example.test";//***REDACTED***@two.example.test'
assert_fixture 'case 1103' absent -Fq 'BAREMixedReal2'
assert_fixture 'case 1104' present -Fxq 'curl "https://mixedsep3.example.test/?q=,//u:pMixedCommaData3@one.example.test",//u:***REDACTED***@two.example.test'
assert_fixture 'case 1105' absent -Fq 'pMixedCommaReal3'
assert_fixture 'case 1106' present -Fxq "curl 'https://mixedsep4.example.test/?q=;//u:pMixedSquoteData4@one.example.test';//u:***REDACTED***@two.example.test"
assert_fixture 'case 1107' absent -Fq 'pMixedSquoteReal4'
assert_fixture 'case 1108' absent -Fq 'pShellSeparator987654@example.test'
assert_fixture 'case 1109' absent -Fq 'QuoteSemi987654@example.test'
assert_fixture 'case 1110' absent -Fq 'pQuoteEscSep987654@example.test'
assert_fixture 'case 1111' present -Fxq 'echo "a\"b";echo first;//u:***REDACTED***@example.test'
assert_fixture 'case 1112' absent -Fq 'SquoteSemi987654@example.test'
assert_fixture 'case 1113' absent -Fq 'passQuoteComma987654@example.test'
assert_fixture 'case 1114' absent -Fq 'pTrailingQuote987654@example.test'
assert_fixture 'case 1115' absent -Fq ';;//BAREabcdefghijkl@example.test'
assert_fixture 'case 1116' present -Fxq 'echo "q";echo first;//u:***REDACTED***@example.test'
assert_fixture 'case 1117' present -Fxq "echo 'q';echo first;//u:***REDACTED***@example.test"
assert_fixture 'case 1118' present -Fxq 'echo "q";echo foo,//user:***REDACTED***@example.test/path'
assert_fixture 'case 1119' present -Fxq 'echo first;//u:***REDACTED***@example.test "tail"'
assert_fixture 'case 1120' present -Fxq 'echo "q";;//***REDACTED***@example.test'
assert_fixture 'case 1121' present -Fxq 'curl \"https://example.test/?q=a;//user:***REDACTED***@host/KEEPE1\" -H \"X: keepHeader\"'
assert_fixture 'case 1122' present -Fxq 'curl \"https://example.test/?q=a,//user:***REDACTED***@host/KEEPE2\" -H \"X: keepHeader\"'
assert_fixture 'case 1123' present -Fxq '{\"url\":\"https://x/?q=;//user:***REDACTED***@host/KEEPE3\",\"keep\":\"keepValue\"}'
assert_fixture 'case 1124' present -Fxq 'curl \"https://example.test/?q=a;//user:***REDACTED***@host/KEEPE4;b=;//user:***REDACTED***@host/KEEPE4B\" -H \"X: keepHeader\"'
assert_fixture 'case 1125' present -Fxq 'curl \"https://user:***REDACTED***@host/x?q=KEEPREAL\"'
assert_fixture 'case 1126' absent -Fq 'SYNTHREAL'
assert_fixture 'case 1127' present -Fxq 'echo \"q\";//user:***REDACTED***@host/KEEPSEP'
assert_fixture 'case 1128' absent -Fq 'SYNTHSEP'
assert_fixture 'case 1129' present -Fxq 'curl "https://example.test/?q=a;//user:SYNTHPLAIN@host/KEEPPLAIN" -H "X: keepHeader"'
assert_fixture 'case 1130' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" https://x'
assert_fixture 'case 1131' present -Fxq 'echo a;\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND1\"'
assert_fixture 'case 1132' present -Fxq 'echo a|\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND2\"'
assert_fixture 'case 1133' present -Fxq 'echo a&\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND3\"'
assert_fixture 'case 1134' present -Fxq 'echo a#\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND4\"'
assert_fixture 'case 1135' present -Fxq 'foo(\"https://x/?q=a;//user:***REDACTED***@host/KEEPBND5\")'
assert_fixture 'case 1136' present -Fxq 'echo a;\"https://x/?q=a;//user:***REDACTED***@one\";//user:***REDACTED***@evil'
assert_fixture 'case 1137' present -Fxq 'echo \"note;//user:***REDACTED***@host; echo \"'
assert_fixture 'case 1138' present -Fxq 'printf %s \"key;//user:***REDACTED***@host; date\"'
assert_fixture 'case 1139' present -Fxq 'echo \"a,b;//user:***REDACTED***@h\"'
assert_fixture 'case 1140' present -Fxq 'curl \"https://ok/x\" \"note;//user:***REDACTED***@host\"'
assert_fixture 'case 1141' present -Fxq 'echo \"https://ok/x; echo note;//user:***REDACTED***@host; echo \"'
assert_fixture 'case 1142' present -Fxq 'curl \"https://ok/x?q=a\" \"a,b;//user:***REDACTED***@h\"'
assert_fixture 'case 1143' present -Fxq 'echo \"x:// ;//user:***REDACTED***@host\"'
assert_fixture 'case 1144' present -Fxq 'echo \"x://;//user:***REDACTED***@host\"'
assert_fixture 'case 1145' present -Fxq 'echo \"x://,//user:***REDACTED***@host\"'
assert_fixture 'case 1146' present -Fxq "echo 'x://;//user:***REDACTED***@host'"
assert_fixture 'case 1147' present -Fxq 'echo \"https://ok/x\";//user:***REDACTED***@host\"'
assert_fixture 'case 1148' present -Fxq 'curl \"https://ok/x\";//user:***REDACTED***@host\"'
assert_fixture 'case 1149' present -Fxq 'echo \"see https://x/?q=a;//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1150' present -Fxq 'curl \"--url https://x/?q=a;//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1151' present -Fxq 'echo \"prefix https://x/?q=a,//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1152' absent -Fq 'SYNTHZERO'
assert_fixture 'case 1153' absent -Fq 'SYNTHZEROC'
assert_fixture 'case 1154' absent -Fq 'SYNTHSQZERO'
assert_fixture 'case 1155' absent -Fq 'SYNTHBQ'
assert_fixture 'case 1156' absent -Fq 'SYNTHBQC'
assert_fixture 'case 1157' present -Fxq 'echo \"https://ok/x\"a;//user:***REDACTED***@host\"'
assert_fixture 'case 1158' present -Fxq 'echo \"https://ok/x\"note;//user:***REDACTED***@host\"'
assert_fixture 'case 1159' present -Fxq 'curl \"https://x/?q=a!;//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1160' present -Fxq 'echo \"https://x/?q=a*;//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1161' absent -Fq 'SYNTHBQA'
assert_fixture 'case 1162' absent -Fq 'SYNTHBQN'
assert_fixture 'case 1163' present -Fxq 'curl "https://ok/x";//user:***REDACTED***@host"'
assert_fixture 'case 1164' absent -Fq 'SYNTHPLAINLEAK'
assert_fixture 'case 1165' present -Fxq "echo 'https://ok/x';//user:***REDACTED***@host'"
assert_fixture 'case 1166' absent -Fq 'SYNTHSQLOCK'
assert_fixture 'case 1167' present -Fxq 'curl "https://ok/x",//user:***REDACTED***@host"'
assert_fixture 'case 1168' absent -Fq 'SYNTHPLAINCOMMA'
assert_fixture 'case 1169' present -Fxq 'curl \"https://x/?q=a;//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1170' absent -Fq 'SYNTHMIXCLOSE'
assert_fixture 'case 1171' present -Fxq 'curl \"https://x/?q=a;//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1172' absent -Fq 'SYNTHMIXOPEN'
assert_fixture 'case 1173' present -Fxq 'curl "https://x/?q=a;//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1174' absent -Fq 'SYNTHMIXCLOSE2'
assert_fixture 'case 1175' present -Fxq 'curl "https://x/?q=a,//user:***REDACTED***@host/KEEP\"'
assert_fixture 'case 1176' absent -Fq 'SYNTHMIXCLOSE3'
# Paired boundary battery: exact preservation or exact redaction, no leak.
assert_fixture 'case 1177' present -Fxq 'curl "https://x/?q=a;//user:SYNBATDQDSEM@host/KEEPDQDSEM"'
assert_fixture 'case 1178' present -Fq 'SYNBATDQDSEM'
assert_fixture 'case 1179' present -Fxq 'curl "https://ok/x";//user:***REDACTED***@host"'
assert_fixture 'case 1180' absent -Fq 'SYNBATDQDSLP'
assert_fixture 'case 1181' present -Fxq 'curl "https://x/?q=a,//user:SYNBATDQDCOM@host/KEEPDQDCOM"'
assert_fixture 'case 1182' present -Fq 'SYNBATDQDCOM'
assert_fixture 'case 1183' present -Fxq 'curl "https://ok/x",//user:***REDACTED***@host"'
assert_fixture 'case 1184' absent -Fq 'SYNBATDQDCLP'
assert_fixture 'case 1185' present -Fxq "echo 'https://x/?q=a;//user:SYNBATSQDSEM@host/KEEPSQDSEM'"
assert_fixture 'case 1186' present -Fq 'SYNBATSQDSEM'
assert_fixture 'case 1187' present -Fxq "echo 'https://ok/x';//user:***REDACTED***@host'"
assert_fixture 'case 1188' absent -Fq 'SYNBATSQLP'
assert_fixture 'case 1189' present -Fxq "echo 'https://x/?q=a,//user:SYNBATSQDCOM@host/KEEPSQDCOM'"
assert_fixture 'case 1190' present -Fq 'SYNBATSQDCOM'
assert_fixture 'case 1191' present -Fxq "echo 'https://ok/x',//user:***REDACTED***@host'"
assert_fixture 'case 1192' absent -Fq 'SYNBATSQCLP'
assert_fixture 'case 1193' present -Fxq 'curl \"https://x/?q=a;//user:***REDACTED***@host/KEEPEQDSEM\"'
assert_fixture 'case 1194' absent -Fq 'SYNBATEQDSEM'
assert_fixture 'case 1195' present -Fxq 'echo \"q\";//user:***REDACTED***@host\"'
assert_fixture 'case 1196' absent -Fq 'SYNBATEQDSLP'
assert_fixture 'case 1197' present -Fxq 'curl \"https://x/?q=a,//user:***REDACTED***@host/KEEPEQDCOM\"'
assert_fixture 'case 1198' absent -Fq 'SYNBATEQDCOM'
assert_fixture 'case 1199' present -Fxq 'echo \"q\",//user:***REDACTED***@host\"'
assert_fixture 'case 1200' absent -Fq 'SYNBATEQCLP'
assert_fixture 'case 1201' present -Fxq 'curl "https://x/?q=a;//user:***REDACTED***@host/KEEPMIXD\"'
assert_fixture 'case 1202' absent -Fq 'SYNBATMIXD'
assert_fixture 'case 1203' present -Fxq 'curl \"https://ok/x\";//user:***REDACTED***@host\"'
assert_fixture 'case 1204' absent -Fq 'SYNBATMIXL'
# Exact outputs for the separator leak probes and their data controls.
assert_fixture 'case 1205' present -Fxq 'echo \"https://x;cat;//***REDACTED***@host\"'
assert_fixture 'case 1206' absent -Fq 'SYNFIXBARE01'
assert_fixture 'case 1207' present -Fxq 'curl \"https://ok/x;cat;//user:***REDACTED***@host\" -H \"X: keepHeader\"'
assert_fixture 'case 1208' absent -Fq 'SYNFIXCOLON02'
assert_fixture 'case 1209' present -Fxq 'echo \"https://x;echo;//***REDACTED***@host\"'
assert_fixture 'case 1210' absent -Fq 'SYNFIXBARE03'
assert_fixture 'case 1211' present -Fxq 'echo \"https://x,ls;//user:***REDACTED***@host\"'
assert_fixture 'case 1212' absent -Fq 'SYNFIXCOLON04'
assert_fixture 'case 1213' present -Fxq 'echo \"x://;//***REDACTED***@host\"'
assert_fixture 'case 1214' absent -Fq 'SYNFIXEMPTY05'
assert_fixture 'case 1215' present -Fxq 'echo \"x://,//***REDACTED***@host\"'
assert_fixture 'case 1216' absent -Fq 'SYNFIXEMPTY06'
assert_fixture 'case 1217' present -Fxq 'curl \"https://x/?q=a=1;b=2;//u:***REDACTED***@one.example.test\";//u:***REDACTED***@two.example.test'
assert_fixture 'case 1218' absent -Fq 'SYNFIXREAL07'
assert_fixture 'case 1219' present -Fxq 'curl \"https://x/?q=a=1,b=2;//u:***REDACTED***@one.example.test\",//u:***REDACTED***@two.example.test'
assert_fixture 'case 1220' absent -Fq 'SYNFIXREAL08'
assert_fixture 'case 1221' present -Fxq "curl 'https://x/?q=a=1;b=2;//u:pSYNFIXDATA09@one.example.test';//u:***REDACTED***@two.example.test"
assert_fixture 'case 1222' absent -Fq 'SYNFIXREAL09'
assert_fixture 'case 1223' present -Fxq 'echo \"https://x;ls;//user:***REDACTED***@host; echo KEEPTAIL10\"'
assert_fixture 'case 1224' absent -Fq 'SYNFIXCOLON10'
# Query-data controls stay byte-for-byte; assignment words before any ? leak nothing.
assert_fixture 'case 1225' present -Fxq 'curl \"https://x/?q=a=1;b=2;//u:***REDACTED***@one.example.test\";//u:***REDACTED***@two.example.test'
assert_fixture 'case 1226' absent -Fq 'pDATAKEEP11'
assert_fixture 'case 1227' absent -Fq 'realDATAKEEP11'
assert_fixture 'case 1228' present -Fxq 'curl \"https://x/?q=a=1,b=2;//u:***REDACTED***@one.example.test\",//u:***REDACTED***@two.example.test'
assert_fixture 'case 1229' absent -Fq 'pDATAKEEP12'
assert_fixture 'case 1230' absent -Fq 'realDATAKEEP12'
assert_fixture 'case 1231' present -Fxq "curl 'https://x/?q=a=1;b=2;//u:pDATAKEEP13@one.example.test';//u:***REDACTED***@two.example.test"
assert_fixture 'case 1232' present -Fq 'pDATAKEEP13'
assert_fixture 'case 1233' absent -Fq 'realDATAKEEP13'
assert_fixture 'case 1234' present -Fxq 'echo \"https://x;a=b;//u:***REDACTED***@host\"'
assert_fixture 'case 1235' absent -Fq 'LEAKASSIGN01'
assert_fixture 'case 1236' present -Fxq 'echo \"https://x,k=1;//user:***REDACTED***@host\"'
assert_fixture 'case 1237' absent -Fq 'LEAKASSIGN02'
assert_fixture 'case 1238' present -Fxq 'curl \"https://x;cat=1;//user:***REDACTED***@host\" -H \"X: keep\"'
assert_fixture 'case 1239' absent -Fq 'LEAKASSIGN03'
assert_fixture 'case 1240' present -Fxq 'curl \"https://api.example.test/v1?verbose=1;cat=1;//user:***REDACTED***@host\" -H \"X: keep\"'
assert_fixture 'case 1241' absent -Fq 'LEAKQUERY01'
assert_fixture 'case 1242' present -Fxq 'echo \"https://x/?q=hello;cat=1;//user:***REDACTED***@host\"'
assert_fixture 'case 1243' absent -Fq 'LEAKQUERY02'
assert_fixture 'case 1244' present -Fxq 'echo \"https://x/?q=hello,cmd=1;//user:***REDACTED***@host\"'
assert_fixture 'case 1245' absent -Fq 'LEAKQUERY04'
assert_fixture 'case 1246' present -Fxq 'echo \"https://x/path;v=1;b=2;//user:***REDACTED***@host\"'
assert_fixture 'case 1247' absent -Fq 'PATHREDACT03'
# Escaped short assignments leak nothing: exact redaction plus token absence.
assert_fixture 'case 1248' present -Fxq 'echo \"https://x/?q=hello;a=1;//user:***REDACTED***@host\"'
assert_fixture 'case 1249' absent -Fq 'LEAKONE641'
assert_fixture 'case 1250' present -Fxq 'echo \"https://x/?q=hello,b=1;//user:***REDACTED***@host\"'
assert_fixture 'case 1251' absent -Fq 'LEAKCOMMA642'
assert_fixture 'case 1252' present -Fxq 'echo \"https://x/?q=hello;=1;//user:***REDACTED***@host\"'
assert_fixture 'case 1253' absent -Fq 'LEAKEMPTY643'
assert_fixture 'case 1254' present -Fxq 'echo \"https://x/?q=hello;1=1;//user:***REDACTED***@host\"'
assert_fixture 'case 1255' absent -Fq 'LEAKDIGIT644'
assert_fixture 'case 1256' present -Fxq "echo \\'https://x/?q=hello;a=1;//user:***REDACTED***@host\\'"
assert_fixture 'case 1257' absent -Fq 'SQESC649'
assert_fixture 'case 1258' present -Fxq "curl 'https://x/?q=hello;cat=1;//u:pSQPLAIN651@one.example.test';//u:***REDACTED***@two.example.test"
assert_fixture 'case 1259' present -Fq 'pSQPLAIN651'
assert_fixture 'case 1260' absent -Fq 'realSQPLAIN652'
assert_fixture 'case 1261' present -Fxq 'echo \"https://x/?q=a=1;b=2;//u:***REDACTED***@one.test"'
assert_fixture 'case 1262' absent -Fq 'DQESC654'
# Bare escaped authorities redact exactly; the credential never appears.
assert_fixture 'case 1263' present -Fxq 'echo \"https://x/path;//user:***REDACTED***@host\"'
assert_fixture 'case 1264' present -Fxq 'echo \"https://x/path,//user:***REDACTED***@host\"'
assert_fixture 'case 1265' present -Fxq "echo \\'https://x/path;//user:***REDACTED***@host\\'"
assert_fixture 'case 1266' present -Fxq "echo \\'https://x/path,//user:***REDACTED***@host\\'"
assert_fixture 'case 1267' absent -Fq 'BARE77'
# POSIX single-quote close redacts the outside authority exactly.
assert_fixture 'case 1268' present -Fxq "echo 'a\\'b;//user:***REDACTED***@host'"
assert_fixture 'case 1269' absent -Fq 'NORM77'
assert_fixture 'case 1270' present -Fxq 'echo "note;//user:SYNTHPLAIN142@host"'
assert_fixture 'case 1271' present -Fq 'SYNTHPLAIN142'
assert_fixture 'case 1272' absent -Fq 'SYNTHREALBND'
assert_fixture 'case 1273' absent -Fq 'passSemiAssign@example.test'
assert_fixture 'case 1274' present -q 'Question:'
printf 'lmline-meta: model=clip-model tokens=10 prompt=7 completion=3\n' >&2
printf 'lmline-status: m=clip-model; tok=7/3/10\n' >&2
# Generic Authorization schemes must mask backslash-escaped quote values.
assert_fixture 'case 1275' present -Fxq 'Authorization: abc=\"***REDACTED***\"; echo KEEPGESTAIL1'
assert_fixture 'case 1276' absent -Fq SYNTHGESC001
assert_fixture 'case 1277' present -Fxq "Authorization: abc=\'***REDACTED***\'; echo KEEPGESTAIL2"
assert_fixture 'case 1278' absent -Fq SYNTHGESC002
assert_fixture 'case 1279' present -Fxq "curl -H 'Authorization: abc=\'***REDACTED***\''; echo KEEPGESTAIL3"
assert_fixture 'case 1280' absent -Fq SYNTHGESC003
assert_fixture 'case 1281' present -Fxq 'curl -H "Authorization: ***REDACTED***"; echo KEEPGESTAIL4'
assert_fixture 'case 1282' absent -Fq SYNTHGESC004
assert_fixture 'case 1283' present -Fxq 'curl -u user:***REDACTED*** https://x; echo KEEPFLAG901'
assert_fixture 'case 1284' absent -Fq 'SYNTHFLAG901'
assert_fixture 'case 1285' present -Fxq 'curl --user user:***REDACTED*** https://x; echo KEEPFLAG902'
assert_fixture 'case 1286' absent -Fq 'SYNTHFLAG902'
assert_fixture 'case 1287' present -Fxq 'curl -u=***REDACTED*** https://x; echo KEEPFLAG903'
assert_fixture 'case 1288' absent -Fq 'SYNTHFLAG903'
assert_fixture 'case 1289' present -Fxq 'curl --password ***REDACTED*** https://x; echo KEEPFLAG904'
assert_fixture 'case 1290' absent -Fq 'SYNTHFLAG904'
assert_fixture 'case 1291' present -Fxq 'curl -u "user:***REDACTED***" https://x; echo KEEPFLAG905'
assert_fixture 'case 1292' absent -Fq 'SYNTHFLAG905'
assert_fixture 'case 1293' present -Fxq "curl -u 'user:***REDACTED***' https://x; echo KEEPFLAG906"
assert_fixture 'case 1294' absent -Fq 'SYNTHFLAG906'
assert_fixture 'case 1295' present -Fxq 'id --user=1000; echo KEEPFLAG907'
assert_fixture 'case 1296' present -Fxq 'bash -p; echo KEEPFLAG908'
assert_fixture 'case 1297' present -Fxq 'curl -u user:***REDACTED***;echo KEEPFLAG921'
assert_fixture 'case 1298' absent -Fq 'SYNTHFLAG921'
assert_fixture 'case 1299' present -Fxq 'curl -u=user:***REDACTED*** https://x; echo KEEPFLAG922'
assert_fixture 'case 1300' absent -Fq 'SYNTHFLAG922'
assert_fixture 'case 1301' present -Fxq 'curl --u=user:***REDACTED*** https://x; echo KEEPFLAG923'
assert_fixture 'case 1302' absent -Fq 'SYNTHFLAG923'
assert_fixture 'case 1303' present -Fxq 'curl --user=***REDACTED*** https://x; echo KEEPFLAG924'
assert_fixture 'case 1304' absent -Fq 'SYNTHFLAG924'
assert_fixture 'case 1305' present -Fxq 'curl --password "***REDACTED***" https://x; echo KEEPFLAG925'
assert_fixture 'case 1306' absent -Fq 'SYNTHFLAG925'
assert_fixture 'case 1307' present -Fxq "curl --password '***REDACTED***' https://x; echo KEEPFLAG926"
assert_fixture 'case 1308' absent -Fq 'SYNTHFLAG926'
assert_fixture 'case 1309' present -Fxq 'curl -u "user:***REDACTED***" https://x; echo KEEPFLAG927'
assert_fixture 'case 1310' absent -Fq 'SYNTHFLAG927'
assert_fixture 'case 1311' present -Fxq 'curl -u=***REDACTED***&&echo KEEPFLAG928'
assert_fixture 'case 1312' absent -Fq 'SYNTHFLAG928'
assert_fixture 'case 1313' present -Fxq 'curl --password ***REDACTED***|grep KEEPFLAG929'
assert_fixture 'case 1314' absent -Fq 'SYNTHFLAG929'
assert_fixture 'case 1315' present -Fxq 'curl --user=***REDACTED*** https://x; echo KEEPFLAG933'
assert_fixture 'case 1316' absent -Fq 'SYNTHFLAG933'
assert_fixture 'case 1317' present -Fxq 'curl -u=\"user:***REDACTED***\" https://x; echo KEEPE1'
assert_fixture 'case 1318' absent -Fq 'SYNTHQE1'
assert_fixture 'case 1319' present -Fxq 'curl --user=\"***REDACTED***\" https://x; echo KEEPE2'
assert_fixture 'case 1320' absent -Fq 'SYNTHQE2'
assert_fixture 'case 1321' present -Fxq 'curl --user=***REDACTED***>out;echo KEEPOPS1'
assert_fixture 'case 1322' absent -Fq 'SECOPS1'
assert_fixture 'case 1323' present -Fxq 'curl -u=user:***REDACTED***>>out;echo KEEPOPS2'
assert_fixture 'case 1324' absent -Fq 'SECOPS2'
assert_fixture 'case 1325' present -Fxq 'curl --password ***REDACTED***<in;echo KEEPOPS3'
assert_fixture 'case 1326' absent -Fq 'SECOPS3'
assert_fixture 'case 1327' present -Fxq 'mysql -uadmin -p***REDACTED***; echo KEEPP941'
assert_fixture 'case 1328' absent -Fq 'SYNTHP941'
assert_fixture 'case 1329' present -Fxq 'curl -u="user:***REDACTED***" https://x; echo KEEPQ01'
assert_fixture 'case 1330' absent -Fq 'SYNTHQ01'
assert_fixture 'case 1331' present -Fxq "curl --user='user:***REDACTED***' https://x; echo KEEPQ02"
assert_fixture 'case 1332' absent -Fq 'SYNTHQ02'
assert_fixture 'case 1333' present -Fxq 'curl -u="***REDACTED***" https://x; echo KEEPQ03'
assert_fixture 'case 1334' absent -Fq 'SYNTHQ03'
assert_fixture 'case 1335' present -Fxq 'curl --user="***REDACTED***" https://x; echo KEEPQ04'
assert_fixture 'case 1336' absent -Fq 'SYNTHQ04'
assert_fixture 'case 1337' present -Fxq 'mysqldump -p***REDACTED***&&echo KEEPP942'
assert_fixture 'case 1338' absent -Fq 'SYNTHP942'
assert_fixture 'case 1339' present -Fxq 'bash -p; echo KEEPP943'
assert_fixture 'case 1340' present -Fxq 'ls -p /tmp; echo KEEPP944'
assert_fixture 'case 1341' present -Fxq 'mysql -p"***REDACTED***" https://x; echo KEEPP945'
assert_fixture 'case 1342' absent -Fq 'SYNTHP945'
assert_fixture 'case 1343' present -Fxq "mysql -p'***REDACTED***' https://x; echo KEEPP946"
assert_fixture 'case 1344' absent -Fq 'SYNTHP946'
assert_fixture 'case 1345' present -Fxq 'mysql -p"***REDACTED***">out; echo KEEPQDB1'
assert_fixture 'case 1346' absent -Fq 'SYNTHQDB1'
assert_fixture 'case 1347' present -Fxq "mysql -p'***REDACTED***'<in; echo KEEPQDB2"
assert_fixture 'case 1348' present -Fxq 'mkdir -pkeep; echo KEEPPCMDB1'
assert_fixture 'case 1349' present -Fxq 'MKDIR -pKEEPUPPER; echo KEEPPCMDB2'
assert_fixture 'case 1350' present -Fxq 'ls -la -pKEEPPCMDB3; echo KEEPPCMDB3'
assert_fixture 'case 1351' present -Fxq 'echo PREPCMDB4; mysql -uadmin -p***REDACTED***; echo KEEPPCMDB4'
assert_fixture 'case 1352' absent -Fq 'SYNTHPCMDB4'
assert_fixture 'case 1353' present -Fxq 'mkdir -pkeep; mysql -p***REDACTED***; mkdir -pkeep2'
assert_fixture 'case 1354' absent -Fq 'SYNTHPCMDB5'
assert_fixture 'case 1355' present -Fxq '/usr/bin/mysql -p***REDACTED***; echo KEEPPCMDB6'
assert_fixture 'case 1356' absent -Fq 'SYNTHPCMDB6'
assert_fixture 'case 1357' present -Fxq 'sudo /usr/local/bin/mysql -p***REDACTED***; echo KEEPPCMDB7'
assert_fixture 'case 1358' absent -Fq 'SYNTHPCMDB7'
assert_fixture 'case 1359' present -Fxq 'echo $(mysql -p***REDACTED***); echo KEEPPCMDB8'
assert_fixture 'case 1360' absent -Fq 'SYNTHPCMDB8'
assert_fixture 'case 1361' present -Fxq 'x=$(mariadb -p***REDACTED***); echo KEEPPCMDB9'
assert_fixture 'case 1362' absent -Fq 'SYNTHPCMDB9'
assert_fixture 'case 1363' present -Fxq '(mysql -p***REDACTED***); echo KEEPPCMDB10'
assert_fixture 'case 1364' absent -Fq 'SYNTHPCMDB10'
assert_fixture 'case 1365' present -Fxq 'MYSQL -p***REDACTED***; echo KEEPPCMDB11'
assert_fixture 'case 1366' absent -Fq 'SYNTHPCMDB11'
assert_fixture 'case 1367' absent -Fq 'SYNTHQDB2'
assert_fixture 'case 1368' present -Fxq 'mysql -p"***REDACTED***">>out; echo KEEPQDB3'
assert_fixture 'case 1369' absent -Fq 'SYNTHQDB3'
assert_fixture 'case 1370' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***";echo KEEPGLUE101'
assert_fixture 'case 1371' absent -Fq 'SYNTHGLUE101'
assert_fixture 'case 1372' present -Fxq "curl -H 'Authorization: Bearer ***REDACTED***'&&echo KEEPGLUE102"
assert_fixture 'case 1373' absent -Fq 'SYNTHGLUE102'
assert_fixture 'case 1374' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"&echo KEEPGLUE103'
assert_fixture 'case 1375' absent -Fq 'SYNTHGLUE103'
assert_fixture 'case 1376' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"2>err;echo KEEPGLUE104'
assert_fixture 'case 1377' absent -Fq 'SYNTHGLUE104'
assert_fixture 'case 1378' present -Fxq 'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPGLUE105'
assert_fixture 'case 1379' absent -Fq 'SYNTHGLUE105'
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
# Force one assertion mismatch in a copy of the checker: the parent must see
# the case label and no success answer, with every other expectation untouched.
clip_mismatch_engine=$clip_test_dir/engine-forced-mismatch
awk -v target='API_KEY=***REDACTED***' -v replacement='API_KEY=FORCEDMISMATCH' '
  {
    pos = index($0, target)
    if (pos) {
      $0 = substr($0, 1, pos - 1) replacement substr($0, pos + length(target))
      changed++
    }
    print
  }
  END { if (changed != 1) exit 1 }
' "$clip_test_dir/engine" >"$clip_mismatch_engine"
chmod +x "$clip_mismatch_engine"
clip_mismatch_status=0
clip_mismatch_out=$(LMLINE_CONFIG_DIR="$clip_test_dir/config" \
                   LMLINE_ENGINE="$clip_mismatch_engine" \
                   "$repo_dir/lmline/lmline" clip "原因は？" 2>&1) ||
  clip_mismatch_status=$?
(( clip_mismatch_status == 1 )) ||
  fail "forced clip assertion mismatch returned status $clip_mismatch_status"
grep -Fq 'clip fixture assertion failed: case 1' <<<"$clip_mismatch_out" ||
  fail "forced clip assertion mismatch hid the case label"
if grep -Fq 'clip answer' <<<"$clip_mismatch_out"; then
  fail "forced clip assertion mismatch printed the success answer"
fi
# Behavioral checks exercise the shipped redactor only; no source text is rewritten.
redact_clip_line() {
  bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; __lmline_next_realm_shield_prefix; printf "%s\n" "$2" | __lmline_redact_clip_text "$__LMLINE_REALM_SHIELD_PREFIX"' _ \
    "$repo_dir/lmline/actions.bash" "$1"
}
expect_exact() {
  local label=$1 fixture=$2 expected=$3 actual
  actual=$(redact_clip_line "$fixture") || fail "$label: redaction failed"
  [[ $actual == "$expected" ]] || fail "$label: got $actual"
}
expect_masked() {
  local label=$1 fixture=$2 secret=$3 tail=$4 actual
  actual=$(redact_clip_line "$fixture") || fail "$label: redaction failed"
  grep -Fq "$secret" <<<"$actual" && fail "$label: leaked the credential"
  grep -Fq "$tail" <<<"$actual" || fail "$label: lost the command tail"
}

# A masked glued -u value must survive a second pass: a grouping operator
# after it is shell syntax, not part of the password.
expect_idempotent_shell() {
  local label=$1 fixture=$2 secret=$3 tail=$4 once twice
  once=$(redact_clip_line "$fixture") || fail "$label: first redaction failed"
  twice=$(redact_clip_line "$once") || fail "$label: second redaction failed"
  [[ $twice == "$once" ]] || fail "$label: second pass changed $once to $twice"
  grep -Fq '***REDACTED***' <<<"$once" || fail "$label: credential was not masked: $once"
  grep -Fq "$secret" <<<"$once" && fail "$label: leaked the credential"
  grep -Fq "$secret" <<<"$twice" && fail "$label: leaked the credential on second pass"
  grep -Fq "$tail" <<<"$once" || fail "$label: lost the command tail"
  grep -Fq "$tail" <<<"$twice" || fail "$label: lost the command tail on second pass"
  bash -n <<<"$once" || fail "$label: first output is not valid shell: $once"
  bash -n <<<"$twice" || fail "$label: second output is not valid shell: $twice"
}

# A credential key wrapped in shell quotes keeps its closing quote and its
# command tail; a known scheme inside the quoted value is masked with it.
quoted_key_fixtures=(
  'curl -H "X-Api-Key: PROBEX1" https://x; echo KEEPX1'
  "curl -H 'X-Api-Key: PROBEX2' https://x; echo KEEPX2"
  'curl -H "X-Api-Key: Bearer PROBEX3" https://x; echo KEEPX3'
  'curl -H "API_KEY: PROBEX6" https://x; echo KEEPX6'
)
quoted_key_expected=(
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEPX1'
  "curl -H 'X-Api-Key: ***REDACTED***' https://x; echo KEEPX2"
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEPX3'
  'curl -H "API_KEY: ***REDACTED***" https://x; echo KEEPX6'
)
for case_index in "${!quoted_key_fixtures[@]}"; do
  expect_exact "quoted generic key $case_index" \
    "${quoted_key_fixtures[$case_index]}" "${quoted_key_expected[$case_index]}"
  expect_exact "quoted generic key second pass $case_index" \
    "${quoted_key_expected[$case_index]}" "${quoted_key_expected[$case_index]}"
done

# The quoted-key rule leaves other boundaries and credential forms intact.
expect_exact 'quoted generic key keeps a following word' \
  'echo "note X-Api-Key: PROBEX4 tail"; echo KEEPX4' \
  'echo "note X-Api-Key: ***REDACTED*** tail"; echo KEEPX4'
expect_exact 'bare generic key ends at the shell separator' \
  'X-Api-Key: PROBEX5; echo KEEPX5' \
  'X-Api-Key: ***REDACTED***; echo KEEPX5'
expect_exact 'quoted generic key leaves url query redaction intact' \
  "curl 'https://example.test/?x=1&token=abc'" \
  "curl 'https://example.test/?x=1&token=***REDACTED***'"
expect_exact 'quoted generic key leaves url separator redaction intact' \
  "curl 'https://example.test/a;token=abc?x=1'" \
  "curl 'https://example.test/a;token=***REDACTED***?x=1'"
expect_exact 'quoted generic key keeps a numeric user' \
  'curl --user=1000; echo KEEPNEGUSER1' \
  'curl --user=1000; echo KEEPNEGUSER1'
expect_exact 'quoted generic key keeps a user without password' \
  'curl --user admin; echo KEEPNEGUSER2' \
  'curl --user admin; echo KEEPNEGUSER2'
expect_exact 'quoted generic key keeps the password flag rule' \
  'mysql -pkeep; echo KEEPNEGP' \
  'mysql -p***REDACTED***; echo KEEPNEGP'
expect_exact 'quoted generic key keeps the userinfo rule' \
  'curl -u admin:secret; echo KEEPNEGU' \
  'curl -u admin:***REDACTED***; echo KEEPNEGU'
expect_exact 'quoted generic key keeps the authorization rule' \
  'Authorization: Bearer keep; echo KEEPNEGAUTH' \
  'Authorization: Bearer ***REDACTED***; echo KEEPNEGAUTH'
expect_exact 'quoted generic key keeps grouped operators' \
  '(curl -H "X-Api-Key: PROBEXNEG" && echo KEEPNEGGRP); echo KEEPNEGT' \
  '(curl -H "X-Api-Key: ***REDACTED***" && echo KEEPNEGGRP); echo KEEPNEGT'
expect_exact 'quoted generic key keeps grouping characters in a value' \
  'curl -H "X-Api-Key: SEC)RET}tail"; echo KEEPNEGBR' \
  'curl -H "X-Api-Key: ***REDACTED***"; echo KEEPNEGBR'

# An embedded escaped quote or an opposite quote stays inside the quoted value.
expect_exact 'quoted generic key masks escaped quotes' \
  'curl -H "X-Api-Key: \"SECRETTAIL123\"" https://x; echo KEEP' \
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEP'
expect_exact 'quoted generic key masks escaped quotes second pass' \
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEP' \
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEP'
expect_exact 'quoted generic key masks escaped quote after prefix' \
  'curl -H "X-Api-Key: LEAD123\"SECRETTAIL123" https://x; echo KEEP' \
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEP'
expect_exact 'quoted generic key masks escaped quote after prefix second pass' \
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEP' \
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo KEEP'
expect_exact 'quoted generic key masks opposite quote' \
  "curl -H \"X-Password: don'tSECRETTAIL123\" https://x; echo KEEP" \
  'curl -H "X-Password: ***REDACTED***" https://x; echo KEEP'
expect_exact 'quoted generic key masks opposite quote second pass' \
  'curl -H "X-Password: ***REDACTED***" https://x; echo KEEP' \
  'curl -H "X-Password: ***REDACTED***" https://x; echo KEEP'
expect_exact 'quoted generic key masks opposite quote in single quotes' \
  "curl -H 'X-Api-Key: abcd1234\"SECRETTAIL123' https://x; echo KEEP" \
  "curl -H 'X-Api-Key: ***REDACTED***' https://x; echo KEEP"
expect_exact 'quoted generic key masks opposite quote in single quotes second pass' \
  "curl -H 'X-Api-Key: ***REDACTED***' https://x; echo KEEP" \
  "curl -H 'X-Api-Key: ***REDACTED***' https://x; echo KEEP"
expect_exact 'quoted generic key keeps a following word second pass' \
  'echo "note X-Api-Key: ***REDACTED*** tail"; echo KEEPX4' \
  'echo "note X-Api-Key: ***REDACTED*** tail"; echo KEEPX4'
expect_exact 'bare generic key second pass' \
  'X-Api-Key: ***REDACTED***; echo KEEPX5' \
  'X-Api-Key: ***REDACTED***; echo KEEPX5'

# sshpass passwords are command arguments, not generic credentials. Values
# are assembled from parts so no secret-shaped literal enters the tree.
sshpass_word='SECRET'
sshpass_tail='TTT'
sp1="${sshpass_word}${sshpass_tail}1"
sp2="${sshpass_word}${sshpass_tail}2"
sp3="${sshpass_word}${sshpass_tail}3"
sp4="${sshpass_word}${sshpass_tail}4"
sp5="${sshpass_word}${sshpass_tail}5"
sk1="KEEP${sshpass_tail}1"
sk2="KEEP${sshpass_tail}2"
sk3="KEEP${sshpass_tail}3"
sk4="KEEP${sshpass_tail}4"
sk5="KEEP${sshpass_tail}5"
sshpass_attached="sshpass -p${sp1} ssh host; echo ${sk1}"
sshpass_separated="sshpass -p ${sp2} ssh host; echo ${sk2}"
sshpass_double="sshpass -p \"${sp3}\" ssh host; echo ${sk3}"
sshpass_single="sshpass -p '${sp4}' ssh host; echo ${sk4}"
sshpass_long="sshpass --password=${sp5} ssh host; echo ${sk5}"
expect_masked 'sshpass attached password' "$sshpass_attached" "$sp1" "$sk1"
expect_exact 'sshpass attached password output' "$sshpass_attached" \
  "sshpass -p***REDACTED*** ssh host; echo ${sk1}"
expect_masked 'sshpass separated password' "$sshpass_separated" "$sp2" "$sk2"
expect_exact 'sshpass separated password output' "$sshpass_separated" \
  "sshpass -p ***REDACTED*** ssh host; echo ${sk2}"
expect_masked 'sshpass double-quoted password' "$sshpass_double" "$sp3" "$sk3"
expect_exact 'sshpass double-quoted password output' "$sshpass_double" \
  "sshpass -p \"***REDACTED***\" ssh host; echo ${sk3}"
expect_masked 'sshpass single-quoted password' "$sshpass_single" "$sp4" "$sk4"
expect_exact 'sshpass single-quoted password output' "$sshpass_single" \
  "sshpass -p '***REDACTED***' ssh host; echo ${sk4}"
expect_masked 'sshpass long option password' "$sshpass_long" "$sp5" "$sk5"
sp6="${sshpass_word}${sshpass_tail}8"
sk6="KEEP${sshpass_tail}8"
sp7="${sshpass_word}${sshpass_tail}9"
sk7="KEEP${sshpass_tail}9"
sp8="${sshpass_word}${sshpass_tail}10"
sk8="KEEP${sshpass_tail}10"
sp9="${sshpass_word}${sshpass_tail}11"
sk9="KEEP${sshpass_tail}11"
sshpass_quoted="bash -c \"sshpass -p${sp6} ssh host; echo ${sk6}\""
sshpass_paren="(sshpass -p${sp7} ssh host); echo ${sk7}"
sshpass_quoted_single="bash -c \"sshpass -p '${sp8}' ssh host; echo ${sk8}\""
sshpass_paren_double="(sshpass -p \"${sp9}\" ssh host); echo ${sk9}"
expect_masked 'sshpass after double quote' "$sshpass_quoted" "$sp6" "$sk6"
expect_masked 'sshpass after paren' "$sshpass_paren" "$sp7" "$sk7"
expect_masked 'sshpass single-quoted after double quote' "$sshpass_quoted_single" "$sp8" "$sk8"
expect_masked 'sshpass double-quoted after paren' "$sshpass_paren_double" "$sp9" "$sk9"
sp12="${sshpass_word}${sshpass_tail}12"
sk12="KEEP${sshpass_tail}12"
sp13="${sshpass_word}${sshpass_tail}13"
sk13="KEEP${sshpass_tail}13"
sp14="${sshpass_word}${sshpass_tail}14<def"
sk14="KEEP${sshpass_tail}14"
sp15="${sshpass_word}${sshpass_tail}15 with space"
sk15="KEEP${sshpass_tail}15"
sp16="${sshpass_word}${sshpass_tail}16 with space"
sk16="KEEP${sshpass_tail}16"
sp17="${sshpass_word}${sshpass_tail}17"
sk17="KEEP${sshpass_tail}17"
sp18="${sshpass_word}${sshpass_tail}18"
sk18="KEEP${sshpass_tail}18"
sp19="${sshpass_word}${sshpass_tail}19"
sk19="KEEP${sshpass_tail}19"
sp20="${sshpass_word}${sshpass_tail}20"
sp21="${sshpass_word}${sshpass_tail}21<def"
sk21="KEEP${sshpass_tail}21"
sshpass_glued_double="sshpass -p\"${sp12}\" ssh host; echo ${sk12}"
sshpass_glued_single="sshpass -p'${sp13}' ssh host; echo ${sk13}"
sshpass_glued_single_angle="sshpass -p'${sp14}' ssh host; echo ${sk14}"
sshpass_glued_double_angle="sshpass -p\"${sp21}\" ssh host; echo ${sk21}"
sshpass_glued_double_space="sshpass -p\"${sp15}\" ssh host; echo ${sk15}"
sshpass_glued_single_space="sshpass -p'${sp16}' ssh host; echo ${sk16}"
sshpass_verbose_attached="sshpass -v -p${sp17} ssh host; echo ${sk17}"
sshpass_verbose_separated="sshpass -v -p ${sp18} ssh host; echo ${sk18}"
sshpass_spaced_double_control="sshpass -p \"${sp19}\" ssh host; echo ${sk19}"
sshpass_psql_control="sshpass -p${sp20} ssh host; psql -p 5432"
expect_masked 'sshpass glued double password' "$sshpass_glued_double" "$sp12" "$sk12"
expect_exact 'sshpass glued double password output' "$sshpass_glued_double" \
  "sshpass -p\"***REDACTED***\" ssh host; echo ${sk12}"
expect_masked 'sshpass glued single password' "$sshpass_glued_single" "$sp13" "$sk13"
expect_exact 'sshpass glued single password output' "$sshpass_glued_single" \
  "sshpass -p'***REDACTED***' ssh host; echo ${sk13}"
expect_masked 'sshpass glued single angle password' "$sshpass_glued_single_angle" "$sp14" "$sk14"
expect_exact 'sshpass glued single angle password output' "$sshpass_glued_single_angle" \
  "sshpass -p'***REDACTED***' ssh host; echo ${sk14}"
expect_masked 'sshpass glued double angle password' "$sshpass_glued_double_angle" "$sp21" "$sk21"
expect_exact 'sshpass glued double angle password output' "$sshpass_glued_double_angle" \
  "sshpass -p\"***REDACTED***\" ssh host; echo ${sk21}"
expect_masked 'sshpass glued double space password' "$sshpass_glued_double_space" "$sp15" "$sk15"
expect_exact 'sshpass glued double space password output' "$sshpass_glued_double_space" \
  "sshpass -p\"***REDACTED***\" ssh host; echo ${sk15}"
expect_masked 'sshpass glued single space password' "$sshpass_glued_single_space" "$sp16" "$sk16"
expect_exact 'sshpass glued single space password output' "$sshpass_glued_single_space" \
  "sshpass -p'***REDACTED***' ssh host; echo ${sk16}"
expect_masked 'sshpass verbose attached password' "$sshpass_verbose_attached" "$sp17" "$sk17"
expect_exact 'sshpass verbose attached password output' "$sshpass_verbose_attached" \
  "sshpass -v -p***REDACTED*** ssh host; echo ${sk17}"
expect_masked 'sshpass verbose separated password' "$sshpass_verbose_separated" "$sp18" "$sk18"
expect_exact 'sshpass verbose separated password output' "$sshpass_verbose_separated" \
  "sshpass -v -p ***REDACTED*** ssh host; echo ${sk18}"
expect_masked 'sshpass spaced double control' "$sshpass_spaced_double_control" "$sp19" "$sk19"
expect_exact 'sshpass spaced double control output' "$sshpass_spaced_double_control" \
  "sshpass -p \"***REDACTED***\" ssh host; echo ${sk19}"
expect_masked 'sshpass psql control masks only sshpass' "$sshpass_psql_control" "$sp20" "psql -p 5432"
expect_exact 'sshpass psql control output' "$sshpass_psql_control" \
  "sshpass -p***REDACTED*** ssh host; psql -p 5432"
sp22="${sshpass_word}${sshpass_tail}22"
sk22="KEEP${sshpass_tail}22"
sp23="${sshpass_word}${sshpass_tail}23"
sk23="KEEP${sshpass_tail}23"
sp24="${sshpass_word}${sshpass_tail}24"
sk24="KEEP${sshpass_tail}24"
sp25="${sshpass_word}${sshpass_tail}25"
sk25="KEEP${sshpass_tail}25"
sshpass_later_port="sshpass -p${sp22} ssh -p 2222 host; echo ${sk22}"
sshpass_ansi="sshpass -p\$'${sp23}' ssh host; echo ${sk23}"
sshpass_ansi_spaced="sshpass -p \$'${sp24}' ssh host; echo ${sk24}"
sshpass_comma="sshpass -p SEC,${sp25} ssh host; echo ${sk25}"
expect_masked 'sshpass password with later ssh port' "$sshpass_later_port" "$sp22" "$sk22"
# A line-based scanner cannot know that -p after the ssh operand belongs to
# another command; fail closed and mask it rather than leak a same-named secret.
expect_exact 'sshpass nested command flag is fail-closed redacted' "$sshpass_later_port" \
  "sshpass -p***REDACTED*** ssh -p ***REDACTED*** host; echo ${sk22}"
openssl_late_key='openssl enc -k SECRET_A input.txt -K SECRET_B; echo KEEPLATE1'
expect_masked 'openssl masks credential after filename operand' "$openssl_late_key" 'SECRET_A' 'KEEPLATE1'
expect_masked 'openssl masks second key after filename operand' "$openssl_late_key" 'SECRET_B' 'KEEPLATE1'
docker_late_password='docker login -p SECRET_A registry -p SECRET_B; echo KEEPLATE2'
expect_masked 'docker masks password after registry operand' "$docker_late_password" 'SECRET_A' 'KEEPLATE2'
expect_masked 'docker masks repeated password after registry operand' "$docker_late_password" 'SECRET_B' 'KEEPLATE2'
redis_late_password='redis-cli -a SECRET_A key1 -a SECRET_B; echo KEEPLATE3'
expect_masked 'redis masks password after key operand' "$redis_late_password" 'SECRET_A' 'KEEPLATE3'
expect_masked 'redis masks repeated password after key operand' "$redis_late_password" 'SECRET_B' 'KEEPLATE3'
aws_late_key='aws configure set aws_secret_access_key SECRET_A region us-east-1 aws_access_key_id SECRET_B; echo KEEPLATE4'
expect_masked 'aws masks key after region operand' "$aws_late_key" 'SECRET_A' 'KEEPLATE4'
expect_masked 'aws masks access key after region operand' "$aws_late_key" 'SECRET_B' 'KEEPLATE4'
expect_masked 'sshpass ANSI-C quoted password' "$sshpass_ansi" "$sp23" "$sk23"
expect_exact 'sshpass ANSI-C quoted password output' "$sshpass_ansi" \
  "sshpass -p\$'***REDACTED***' ssh host; echo ${sk23}"
expect_masked 'sshpass spaced ANSI-C password' "$sshpass_ansi_spaced" "$sp24" "$sk24"
expect_exact 'sshpass spaced ANSI-C password output' "$sshpass_ansi_spaced" \
  "sshpass -p \$'***REDACTED***' ssh host; echo ${sk24}"
expect_masked 'sshpass comma password' "$sshpass_comma" "$sp25" "$sk25"
expect_exact 'sshpass comma password output' "$sshpass_comma" \
  "sshpass -p ***REDACTED*** ssh host; echo ${sk25}"
expect_exact 'mkdir -p suffix is not a password' \
  'mkdir -pKEEPTTT6; echo KEEPTTT6' 'mkdir -pKEEPTTT6; echo KEEPTTT6'
expect_exact 'psql -p is a port' \
  'psql -p 5432 -c "echo KEEPTTT7"' 'psql -p 5432 -c "echo KEEPTTT7"'
expect_exact 'bash -p is a shell option' \
  'bash -p; echo KEEPBASHP' 'bash -p; echo KEEPBASHP'

# Each sshpass invocation on a shell line owns its own password, and an -p
# inside a quoted option argument is not the password flag.
sp26="${sshpass_word}${sshpass_tail}26"
sp27="${sshpass_word}${sshpass_tail}27"
sk27="KEEP${sshpass_tail}27"
sshpass_two_semicolons="sshpass -p ${sp26} ssh host; sshpass -p ${sp27} ssh host2; echo ${sk27}"
expect_masked 'first sshpass password in shell chain' "$sshpass_two_semicolons" "$sp26" "$sk27"
expect_masked 'second sshpass password in shell chain' "$sshpass_two_semicolons" "$sp27" "$sk27"
expect_exact 'both sshpass passwords in shell chain' "$sshpass_two_semicolons" \
  "sshpass -p ***REDACTED*** ssh host; sshpass -p ***REDACTED*** ssh host2; echo ${sk27}"
sshpass_two_and="sshpass -p ${sp26} ssh host && sshpass -p ${sp27} ssh host2; echo ${sk27}"
expect_masked 'first sshpass password after and' "$sshpass_two_and" "$sp26" "$sk27"
expect_masked 'second sshpass password after and' "$sshpass_two_and" "$sp27" "$sk27"
sp28="${sshpass_word}${sshpass_tail}28"
sk28="KEEP${sshpass_tail}28"
sp29="${sshpass_word}${sshpass_tail}29"
sk29="KEEP${sshpass_tail}29"
sshpass_prompt_option="sshpass -P \"pass -p word\" -p ${sp28} ssh host; echo ${sk28}"
expect_masked 'sshpass password after quoted prompt option' "$sshpass_prompt_option" "$sp28" "$sk28"
expect_exact 'sshpass quoted prompt option output' "$sshpass_prompt_option" \
  "sshpass -P \"pass -p word\" -p ***REDACTED*** ssh host; echo ${sk28}"
sshpass_proxy_option="sshpass -o \"ProxyCommand=nc -p 1234\" -p ${sp29} ssh host; echo ${sk29}"
expect_masked 'sshpass password after quoted proxy option' "$sshpass_proxy_option" "$sp29" "$sk29"
expect_exact 'sshpass quoted proxy option output' "$sshpass_proxy_option" \
  "sshpass -o \"ProxyCommand=nc -p 1234\" -p ***REDACTED*** ssh host; echo ${sk29}"
sp30="${sshpass_word}${sshpass_tail}30"
sk30="KEEP${sshpass_tail}30"
sp31="${sshpass_word}${sshpass_tail}31"
sk31="KEEP${sshpass_tail}31"
sshpass_ansi_escaped="sshpass -p \$'AB\\'${sp30}' ssh host; echo ${sk30}"
expect_masked 'sshpass ANSI-C escaped-quote password' "$sshpass_ansi_escaped" "$sp30" "$sk30"
expect_exact 'sshpass ANSI-C escaped-quote password output' "$sshpass_ansi_escaped" \
  "sshpass -p \$'***REDACTED***' ssh host; echo ${sk30}"
sshpass_dq_escaped="sshpass -p \"AB\\\"${sp31}\" ssh host; echo ${sk31}"
expect_masked 'sshpass double-quoted escaped-quote password' "$sshpass_dq_escaped" "$sp31" "$sk31"
expect_exact 'sshpass double-quoted escaped-quote password output' "$sshpass_dq_escaped" \
  "sshpass -p \"***REDACTED***\" ssh host; echo ${sk31}"

sp32="${sshpass_word}${sshpass_tail}32"
sk32="KEEP${sshpass_tail}32"
sshpass_outer_quote="bash -c \"sshpass -p ${sp32}\" ; echo ${sk32}"
expect_masked 'sshpass password before closing outer quote' "$sshpass_outer_quote" "$sp32" "$sk32"
expect_exact 'sshpass closing outer quote output' "$sshpass_outer_quote" \
  "bash -c \"sshpass -p ***REDACTED***\" ; echo ${sk32}"

# Command-name case and clustered short options stay in the masked family.
sp33="${sshpass_word}${sshpass_tail}33"
sk33="KEEP${sshpass_tail}33"
sp34="${sshpass_word}${sshpass_tail}34"
sk34="KEEP${sshpass_tail}34"
sp35="${sshpass_word}${sshpass_tail}35"
sk35="KEEP${sshpass_tail}35"
sp36="${sshpass_word}${sshpass_tail}36"
sk36="KEEP${sshpass_tail}36"
sshpass_upper="SSHPASS -p ${sp33} ssh host; echo ${sk33}"
sshpass_mixed="Sshpass -p ${sp34} ssh host; echo ${sk34}"
sshpass_cluster="sshpass -vp ${sp35} ssh host; echo ${sk35}"
sshpass_cluster_attached="sshpass -vp${sp36} ssh host; echo ${sk36}"
expect_masked 'uppercase sshpass password' "$sshpass_upper" "$sp33" "$sk33"
expect_exact 'uppercase sshpass output' "$sshpass_upper" \
  "SSHPASS -p ***REDACTED*** ssh host; echo ${sk33}"
expect_masked 'mixed-case sshpass password' "$sshpass_mixed" "$sp34" "$sk34"
expect_exact 'mixed-case sshpass output' "$sshpass_mixed" \
  "Sshpass -p ***REDACTED*** ssh host; echo ${sk34}"
expect_masked 'clustered sshpass password' "$sshpass_cluster" "$sp35" "$sk35"
expect_exact 'clustered sshpass output' "$sshpass_cluster" \
  "sshpass -vp ***REDACTED*** ssh host; echo ${sk35}"
expect_masked 'clustered attached sshpass password' "$sshpass_cluster_attached" "$sp36" "$sk36"
expect_exact 'clustered attached sshpass output' "$sshpass_cluster_attached" \
  "sshpass -vp***REDACTED*** ssh host; echo ${sk36}"

# Escaped quotes after a generic scheme stay masked with their tails intact.
generic_esc_fixtures=(
  'Authorization: abc=\"SYNTHGESC001\"; echo KEEPGESTAIL1'
  "Authorization: abc=\\'SYNTHGESC002\\'; echo KEEPGESTAIL2"
  "curl -H 'Authorization: abc=\\'SYNTHGESC003\\''; echo KEEPGESTAIL3"
  'curl -H "Authorization: abc=\"SYNTHGESC004\""; echo KEEPGESTAIL4'
)
generic_esc_tails=(KEEPGESTAIL1 KEEPGESTAIL2 KEEPGESTAIL3 KEEPGESTAIL4)
for case_index in "${!generic_esc_fixtures[@]}"; do
  expect_masked "escaped generic scheme $case_index" "${generic_esc_fixtures[$case_index]}" \
    "SYNTHGESC00$((case_index + 1))" "${generic_esc_tails[$case_index]}"
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
threshold_255=$(LMLINE_CLIP_USERINFO_MIN=255 bash -c 'source "$1"; __lmline_next_realm_shield_prefix; printf "https://%s@example.test/x\n" "$2" | __lmline_redact_clip_text "$__LMLINE_REALM_SHIELD_PREFIX"' _ "$repo_dir/lmline/actions.bash" "$userinfo_token_255") || fail "userinfo threshold 255 redaction"
grep -Fxq 'https://***REDACTED***@example.test/x' <<<"$threshold_255" || fail "userinfo threshold 255 output"
for invalid_userinfo_min in 256 32768 100000 invalid; do
  fallback_userinfo=$(LMLINE_CLIP_USERINFO_MIN="$invalid_userinfo_min" bash -c 'source "$1"; __lmline_next_realm_shield_prefix; printf "https://abcdefghijkl@example.test/x\n" | __lmline_redact_clip_text "$__LMLINE_REALM_SHIELD_PREFIX"' _ "$repo_dir/lmline/actions.bash") || fail "invalid userinfo threshold $invalid_userinfo_min broke redaction"
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
  quoted_tail_redacted=$(bash -c 'source "$1"; __lmline_next_realm_shield_prefix; printf "%s\n" "$2" | __lmline_redact_clip_text "$__LMLINE_REALM_SHIELD_PREFIX"' _ "$repo_dir/lmline/actions.bash" "$quoted_tail_fixture") || fail "quoted tail redaction: $quoted_tail_fixture"
  printf '%s\n' "$quoted_tail_redacted" | bash -n || fail "quoted tail redaction is not valid shell text: $quoted_tail_redacted"
done

# Credential fields keep their boundary and the following command tail.
keep_url_fixtures=(
  'url=https://x/?\"token\"=\"SYNTHKEEPESCQ1\"&password=SYNTHKEEPESCQ2; echo KEEPESCQ'
  "url=https://x/?\\'token\\'=\\'SYNTHKEEPESCSQ1\\'&password=SYNTHKEEPESCSQ2; echo KEEPESCSQ"
)
keep_url_expected=(
  'url=https://x/?"token"="***REDACTED***"&password=***REDACTED***; echo KEEPESCQ'
  "url=https://x/?'token'='***REDACTED***'&password=***REDACTED***; echo KEEPESCSQ"
)
for case_index in "${!keep_url_fixtures[@]}"; do
  expect_exact "chained key $case_index" "${keep_url_fixtures[$case_index]}" "${keep_url_expected[$case_index]}"
done

# Per-header quoted values are masked without eating the next header.
per_header_fixture='Authorization: Bearer=FIRST"SYNTHUPQ5"; Authorization: Bearer=SECOND"SYNTHUPQ6"; echo KEEPUPQ5'
expect_masked 'per-header quoted value' "$per_header_fixture" SYNTHUPQ5 KEEPUPQ5

# Escaped quoted values keep both credentials masked and the plain-quoted control intact.
escaped_upq_fixtures=(
  "Authorization: Bearer=AAA'SYNTHUPQESC1'; Authorization: Basic=BBB\\\"SYNTHUPQESC1\\\"; echo KEEPUPQESC1"
  "Authorization: Bearer=AAA'SYNTHUPQESC2'; Authorization: Basic=BBB\\\\\"SYNTHUPQESC2\\\\\"; echo KEEPUPQESC2"
)
escaped_upq_secrets=(SYNTHUPQESC1 SYNTHUPQESC2)
escaped_upq_tails=(KEEPUPQESC1 KEEPUPQESC2)
for case_index in "${!escaped_upq_fixtures[@]}"; do
  expect_masked "escaped quoted value $case_index" "${escaped_upq_fixtures[$case_index]}" \
    "${escaped_upq_secrets[$case_index]}" "${escaped_upq_tails[$case_index]}"
done

expect_exact 'plain quoted control' \
  "Authorization: Bearer=AAA'SYNTHUPQESC3'; Authorization: Basic=BBB'SYNTHUPQESC3'; echo KEEPUPQESC3" \
  'Authorization: Bearer=***REDACTED***; Authorization: Basic=***REDACTED***; echo KEEPUPQESC3'

# Custom schemes mask their credentials while URL realms and Digest controls stay readable.
scheme_fixtures=(
  'Authorization: Bearer=FIRST\"SYNTHCUSTM1\"; Authorization: Custom=SECOND\"SYNTHCUSTM2\"; echo KEEPCUSTOM1'
  'Authorization: Custom=ONLY\"SYNTHCUSTM3\"; echo KEEPCUSTOM2'
  'Authorization: X-OAuth2=FIRST\"SYNTHXAUTH1\"; Authorization: X-OAuth2=SECOND\"SYNTHXAUTH2\"; echo KEEPCUSTOM3'
  'url=https://x/?realm=\"example.com\"; echo KEEPTAIL5'
  'Authorization: Digest realm=\"example.com\", nonce=\"abc123\"; echo KEEPTAIL4'
)
scheme_secrets=(SYNTHCUSTM SYNTHCUSTM3 SYNTHXAUTH)
scheme_controls=(
  'url=https://x/?realm=\"example.com\"; echo KEEPTAIL5'
  'Authorization: Digest ***REDACTED***'
)
for case_index in 0 1 2; do
  expect_masked "custom scheme $case_index" "${scheme_fixtures[$case_index]}" \
    "${scheme_secrets[$case_index]}" "KEEPCUSTOM$((case_index + 1))"
done
for case_index in 3 4; do
  expect_exact "scheme control $case_index" "${scheme_fixtures[$case_index]}" "${scheme_controls[$case_index - 3]}"
done

# Quoted -H tails stay readable after both quoted credentials are masked.
quoted_tail_fixtures=(
  "curl -H \"Authorization: Bearer=AAA'FIRSTSECRET'; Authorization: Basic=BBB\\\"SECONDSECRET\\\"\" https://x; echo KEEPTAIL"
  "curl -H 'Authorization: Basic=BBB\\\"ONLYSECRET\\\"' -H 'X: keep' https://x; echo KEEPTAIL"
  "curl -H \"Authorization: Bearer=AAA\\\"SINGLESECRET\\\"\" https://x; echo KEEPTAIL"
  'Authorization: Bearer=\"SYNTHBAREQUOTED4\"; echo KEEPTAILBARE'
)
quoted_tail_expected=(
  'curl -H "Authorization: Bearer=***REDACTED***; Authorization: ***REDACTED***" https://x; echo KEEPTAIL'
  "curl -H 'Authorization: ***REDACTED***' -H 'X: keep' https://x; echo KEEPTAIL"
  'curl -H "Authorization: ***REDACTED***" https://x; echo KEEPTAIL'
  'Authorization: Bearer=\"***REDACTED***\"; echo KEEPTAILBARE'
)
for case_index in "${!quoted_tail_fixtures[@]}"; do
  expect_exact "quoted -H tail $case_index" "${quoted_tail_fixtures[$case_index]}" "${quoted_tail_expected[$case_index]}"
done

# Mixed and bare mixed quote residues mask the credential and preserve the rest of the line.
mixed_quote_fixtures=(
  "curl -H \"Authorization: Bearer:abc\\'\\\"'SECRETZZ\\'\"X; echo KEEPTAIL"
  "curl -H 'Authorization: Bearer:abc\\\"\\'\"SECRETMM\\\"'X; echo MIRRORTAIL"
  "curl -H\"Authorization: Bearer:abc\\'\\\"'SECRETZZ\\'\"X; echo KEEPTAIL"
  "curl -H'Authorization: Bearer:abc\\\"\\'\"SECRETMM\\\"'X; echo KEEPTAIL"
)
mixed_quote_secrets=(SECRETZZ SECRETMM SECRETZZ SECRETMM)
mixed_quote_tails=('X; echo KEEPTAIL' 'X; echo MIRRORTAIL' 'X; echo KEEPTAIL' 'X; echo KEEPTAIL')
for case_index in "${!mixed_quote_fixtures[@]}"; do
  expect_masked "mixed quote $case_index" "${mixed_quote_fixtures[$case_index]}" \
    "${mixed_quote_secrets[$case_index]}" "${mixed_quote_tails[$case_index]}"
done
bare_mixed_fixtures=(
  "Authorization: Bearer:abc\\'\\\"'LEAKMIN987\\'\\\" -H \"X: keep\" https://x; echo KEEPTAIL"
  "Authorization: Bearer:abc\\\"\\'\"LEAKMIRROR988\\\"\\' -H 'X: keep' https://x; echo KEEPTAIL"
)
bare_mixed_secrets=(LEAKMIN987 LEAKMIRROR988)
bare_mixed_tails=('https://x; echo KEEPTAIL' 'https://x; echo KEEPTAIL')
for case_index in "${!bare_mixed_fixtures[@]}"; do
  expect_masked "bare mixed quote $case_index" "${bare_mixed_fixtures[$case_index]}" \
    "${bare_mixed_secrets[$case_index]}" "${bare_mixed_tails[$case_index]}"
done

# A terminal Authorization tail stops at the shell separator.
separator_tail_fixture='curl -H "Authorization: Bearer: SYNTHQSEP931"; echo KEEPQSEPTAIL31'
expect_exact 'separated header tail' "$separator_tail_fixture" \
  'curl -H "Authorization: ***REDACTED***"; echo KEEPQSEPTAIL31'

# Markers inside a live credential do not exempt it, and already-masked headers keep their tails.
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
for case_index in "${!marker_fixtures[@]}"; do
  expect_exact "marker guard $case_index" "${marker_fixtures[$case_index]}" "${marker_expected[$case_index]}"
done

# Live credentials ending in a marker spelling are masked, and masking twice is stable.
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
for case_index in "${!suffix_fixtures[@]}"; do
  expect_exact "suffix redaction $case_index" "${suffix_fixtures[$case_index]}" "${suffix_expected[$case_index]}"
  expect_exact "idempotent suffix $case_index" "${suffix_expected[$case_index]}" "${suffix_expected[$case_index]}"
done

# Loose line-wide guards must not leave a live credential, even next to a masked one.
loose_fixtures=(
  'curl -H "Authorization: Bearer: abc***REDACTED***xyz"; echo KEEPZZ'
  "curl -H 'Authorization: Bearer: abc***REDACTED***xyz'; echo KEEPZZ"
  'curl -H "Authorization: Bearer: ***REDACTED***" -H "Authorization: Bearer: REALSECRET89"; echo KEEPZZ9'
  "curl -H 'Authorization: Bearer: ***REDACTED***' -H 'Authorization: Bearer: REALSECRET89'; echo KEEPZZ9"
)
loose_expected=(
  'curl -H "Authorization: ***REDACTED***"; echo KEEPZZ'
  "curl -H 'Authorization: ***REDACTED***'; echo KEEPZZ"
  'curl -H "Authorization: ***REDACTED***" -H "Authorization: ***REDACTED***"; echo KEEPZZ9'
  "curl -H 'Authorization: ***REDACTED***' -H 'Authorization: ***REDACTED***'; echo KEEPZZ9"
)
for case_index in "${!loose_fixtures[@]}"; do
  expect_exact "loose guard $case_index" "${loose_fixtures[$case_index]}" "${loose_expected[$case_index]}"
done

# A blank after the scheme separator does not protect the credential or its tail.
scheme_space_fixtures=(
  'Authorization: Bearer: SYNTHSEP901; echo KEEPSEPTAIL1'
  'Authorization: Bearer= SYNTHSEP902; echo KEEPSEPTAIL2'
  'Authorization: Basic: SYNTHSEP903; echo KEEPSEPTAIL3'
  'curl -H "Authorization: Bearer: SYNTHQSEP921"; echo KEEPQSEPTAIL21'
  "curl -H 'Authorization: Basic= SYNTHQSEP922'; echo KEEPQSEPTAIL22"
)
scheme_space_secrets=(SYNTHSEP901 SYNTHSEP902 SYNTHSEP903 SYNTHQSEP921 SYNTHQSEP922)
scheme_space_tails=(KEEPSEPTAIL1 KEEPSEPTAIL2 KEEPSEPTAIL3 KEEPQSEPTAIL21 KEEPQSEPTAIL22)
for case_index in "${!scheme_space_fixtures[@]}"; do
  expect_masked "scheme separator $case_index" "${scheme_space_fixtures[$case_index]}" \
    "${scheme_space_secrets[$case_index]}" "${scheme_space_tails[$case_index]}"
done

# Glued scheme values are masked without dropping the following word or command tail.
glued_scheme_fixtures=(
  'Authorization: Bearer=SYNTHGLUED901 https://x; echo KEEPGLUEDTAIL1'
  'Authorization: Basic:abcSYNTHGLUED902 foo; echo KEEPGLUEDTAIL2'
)
glued_scheme_secrets=(SYNTHGLUED901 SYNTHGLUED902)
glued_scheme_tails=('https://x; echo KEEPGLUEDTAIL1' 'foo; echo KEEPGLUEDTAIL2')
for case_index in "${!glued_scheme_fixtures[@]}"; do
  expect_masked "glued scheme $case_index" "${glued_scheme_fixtures[$case_index]}" \
    "${glued_scheme_secrets[$case_index]}" "${glued_scheme_tails[$case_index]}"
done

# A quoted argument after an Authorization header is never consumed as part of the credential.
arg_fixtures=('curl -H "Authorization: Basic=SYNTHARG905" -H "X: keep" https://x; echo KEEPARGTAIL5' 'curl -H '"'"'Authorization: Basic=SYNTHARG906'"'"' -H '"'"'X: keep'"'"' https://x; echo KEEPARGTAIL6' 'curl -H "Authorization: Bearer=SYNTHARG907" "payload907" https://x; echo KEEPARGTAIL7' 'curl -H '"'"'Authorization: Bearer=SYNTHARG908'"'"' '"'"'payload908'"'"' https://x; echo KEEPARGTAIL8')
arg_secrets=(SYNTHARG905 SYNTHARG906 SYNTHARG907 SYNTHARG908)
arg_victims=('X: keep' 'X: keep' payload907 payload908)
for case_index in "${!arg_fixtures[@]}"; do
  expect_masked "quoted argument $case_index" "${arg_fixtures[$case_index]}" \
    "${arg_secrets[$case_index]}" "${arg_victims[$case_index]}"
done

# CLI auth flags mask every credential form while keeping usernames and shell tails.
flag_fixtures=('curl -u user:SYNTHFLAG911 https://x; echo KEEPFLAG911' 'curl --user user:SYNTHFLAG912 https://x; echo KEEPFLAG912' 'curl -u=SYNTHFLAG913 https://x; echo KEEPFLAG913' 'curl --password SYNTHFLAG914 https://x; echo KEEPFLAG914' 'curl -u "user:SYNTHFLAG915" https://x; echo KEEPFLAG915' "curl -u 'user:SYNTHFLAG916' https://x; echo KEEPFLAG916" 'curl -u user:SYNTHFLAG921;echo KEEPFLAG921' 'curl -u=user:SYNTHFLAG922 https://x; echo KEEPFLAG922' 'curl --u=user:SYNTHFLAG923 https://x; echo KEEPFLAG923' 'curl --user=SYNTHFLAG924 https://x; echo KEEPFLAG924' 'curl --password "SYNTHFLAG925" https://x; echo KEEPFLAG925' "curl --password 'SYNTHFLAG926' https://x; echo KEEPFLAG926" 'curl -u "user:pass wordSYNTHFLAG927" https://x; echo KEEPFLAG927' 'curl -u=SYNTHFLAG928&&echo KEEPFLAG928' 'curl --password SYNTHFLAG929|grep KEEPFLAG929' 'curl --user=1SYNTHFLAG933 https://x; echo KEEPFLAG933' 'curl -u="user:SYNTHQ01" https://x; echo KEEPQ01' "curl --user='user:SYNTHQ02' https://x; echo KEEPQ02" 'curl -u="SYNTHQ03" https://x; echo KEEPQ03' 'curl --user="SYNTHQ04" https://x; echo KEEPQ04' 'curl -u=\"user:SYNTHQE1\" https://x; echo KEEPE1' 'curl --user=\"SYNTHQE2\" https://x; echo KEEPE2')
flag_secrets=(SYNTHFLAG911 SYNTHFLAG912 SYNTHFLAG913 SYNTHFLAG914 SYNTHFLAG915 SYNTHFLAG916 SYNTHFLAG921 SYNTHFLAG922 SYNTHFLAG923 SYNTHFLAG924 SYNTHFLAG925 SYNTHFLAG926 SYNTHFLAG927 SYNTHFLAG928 SYNTHFLAG929 SYNTHFLAG933 SYNTHQ01 SYNTHQ02 SYNTHQ03 SYNTHQ04 SYNTHQE1 SYNTHQE2)
flag_tails=(
  KEEPFLAG911 KEEPFLAG912 KEEPFLAG913 KEEPFLAG914 KEEPFLAG915 KEEPFLAG916
  KEEPFLAG921 KEEPFLAG922 KEEPFLAG923 KEEPFLAG924 KEEPFLAG925 KEEPFLAG926
  KEEPFLAG927 KEEPFLAG928 KEEPFLAG929 KEEPFLAG933 KEEPQ01 KEEPQ02 KEEPQ03
  KEEPQ04 KEEPE1 KEEPE2
)
for case_index in "${!flag_fixtures[@]}"; do
  expect_masked "CLI auth flag $case_index" "${flag_fixtures[$case_index]}" \
    "${flag_secrets[$case_index]}" "${flag_tails[$case_index]}"
done
expect_exact 'flag username with equals' 'curl -u=user:SYNTHFLAG922 https://x; echo KEEPFLAG922' \
  'curl -u=user:***REDACTED*** https://x; echo KEEPFLAG922'
expect_exact 'quoted flag username' 'curl -u="user:SYNTHQ01" https://x; echo KEEPQ01' \
  'curl -u="user:***REDACTED***" https://x; echo KEEPQ01'
expect_exact 'flag separator tail' 'curl -u=SYNTHFLAG928&&echo KEEPFLAG928' \
  'curl -u=***REDACTED***&&echo KEEPFLAG928'

# Glued -u arguments mask only the password, keeping the flag, user, quotes and tail.
glued_u_fixtures=(
  'curl -uuser:SYNTHGLUE1 https://x; echo KEEP1'
  'curl -ubob:SYNTHGLUE2 https://x'
  "curl -u'user:SYNTHGLUE3' https://x; echo KEEP3"
  'curl -u"user:SYNTHGLUE4" https://x'
  'curl -uuser:SYNTHGLUE5; echo KEEP5'
)
glued_u_expected=(
  'curl -uuser:***REDACTED*** https://x; echo KEEP1'
  'curl -ubob:***REDACTED*** https://x'
  "curl -u'user:***REDACTED***' https://x; echo KEEP3"
  'curl -u"user:***REDACTED***" https://x'
  'curl -uuser:***REDACTED***; echo KEEP5'
)
for case_index in "${!glued_u_fixtures[@]}"; do
  expect_exact "glued -u argument $case_index" "${glued_u_fixtures[$case_index]}" \
    "${glued_u_expected[$case_index]}"
  expect_exact "idempotent glued -u argument $case_index" "${glued_u_expected[$case_index]}" \
    "${glued_u_expected[$case_index]}"
done
# Glued -u passwords assembled from bare and quoted pieces are masked whole.
glued_mixed_fixtures=(
  'curl -uuser:MYQ1 https://x'
  'curl -uuser:"MYQ2"; echo KEEP2'
  "curl -uuser:'MYQ3'; echo KEEP3"
  'curl -uuser:PRE"POST" https://x; echo KEEP4'
  'curl -uuser:SECRET"X""Y"; echo KEEP5'
  "curl -u'user:MYQ6' https://x"
  'curl -u"user:MYQ7" https://x'
)
glued_mixed_expected=(
  'curl -uuser:***REDACTED*** https://x'
  'curl -uuser:***REDACTED***; echo KEEP2'
  'curl -uuser:***REDACTED***; echo KEEP3'
  'curl -uuser:***REDACTED*** https://x; echo KEEP4'
  'curl -uuser:***REDACTED***; echo KEEP5'
  "curl -u'user:***REDACTED***' https://x"
  'curl -u"user:***REDACTED***" https://x'
)
for case_index in "${!glued_mixed_fixtures[@]}"; do
  expect_exact "mixed glued -u password $case_index" "${glued_mixed_fixtures[$case_index]}" \
    "${glued_mixed_expected[$case_index]}"
  expect_exact "idempotent mixed glued -u password $case_index" "${glued_mixed_expected[$case_index]}" \
    "${glued_mixed_expected[$case_index]}"
done
# A quote-first glued equals-flag value is one credential: mask it whole while
# keeping the flag, one quote pair, separators and the command tail.
quote_first_fixtures=(
  'curl --user="alice":"mypasswordREAL2"; echo KEEPREAL2'
  'curl --user="alice":mypasswordREAL3; echo KEEPREAL3'
  'curl -u="SECRETA2"TAILA2; echo KEEPA2'
  "curl --user=''mypasswordREAL10; echo KEEPREAL10"
  'curl -u="secretB"TAILB; echo KEEPB'
  'curl --u="secretC"TAILC; echo KEEPC'
  "curl -u='secretD'TAILD; echo KEEPD"
  'curl --user="esc\"aped"TAIL; echo KEEPESC'
  "curl --user='esc\\'aped'TAIL; echo KEEPESCS"
  'curl --user="a"&echo KEEPAMP'
  'curl --user="a",echo KEEPCOMMA'
  '(curl --user="a"b); echo KEEPGROUP'
)
quote_first_expected=(
  'curl --user="***REDACTED***"; echo KEEPREAL2'
  'curl --user="***REDACTED***"; echo KEEPREAL3'
  'curl -u="***REDACTED***"; echo KEEPA2'
  "curl --user='***REDACTED***'; echo KEEPREAL10"
  'curl -u="***REDACTED***"; echo KEEPB'
  'curl --u="***REDACTED***"; echo KEEPC'
  "curl -u='***REDACTED***'; echo KEEPD"
  'curl --user="***REDACTED***"; echo KEEPESC'
  "curl --user='***REDACTED***'; echo KEEPESCS"
  'curl --user="***REDACTED***"&echo KEEPAMP'
  'curl --user="***REDACTED***",echo KEEPCOMMA'
  '(curl --user="***REDACTED***"); echo KEEPGROUP'
)
for case_index in "${!quote_first_fixtures[@]}"; do
  expect_exact "quote-first credential $case_index" \
    "${quote_first_fixtures[$case_index]}" "${quote_first_expected[$case_index]}"
  expect_exact "idempotent quote-first credential $case_index" \
    "${quote_first_expected[$case_index]}" "${quote_first_expected[$case_index]}"
done
# The wholly quoted user:password form still keeps its username.
expect_exact 'quote-first keeps one quoted username' \
  'curl --user="alice:mypasswordREAL1"; echo KEEPREAL1' \
  'curl --user="alice:***REDACTED***"; echo KEEPREAL1'
expect_exact 'quote-first keeps glued-user username' \
  'curl -uuser:"MYQ2"; echo KEEP2' \
  'curl -uuser:***REDACTED***; echo KEEP2'
expect_exact 'quote-first keeps numeric user flag' \
  'curl --user=1000 https://x' 'curl --user=1000 https://x'
expect_exact 'quote-first keeps unrelated url flag' \
  'curl --url https://x; echo KEEPURL' 'curl --url https://x; echo KEEPURL'
expect_exact 'quote-first keeps spaced user-only flag' \
  'curl -u user https://x; echo KEEPUSERONLY' \
  'curl -u user https://x; echo KEEPUSERONLY'
expect_exact 'quote-first keeps following word and tail' \
  'curl --user="alice":"secretQF1" --url https://x; echo KEEPTAILQF1' \
  'curl --user="***REDACTED***" --url https://x; echo KEEPTAILQF1'
expect_exact 'quote-first keeps following command' \
  'curl --user="alice":"secretQF2"; echo KEEPTAILQF2; echo KEEPTAILQF3' \
  'curl --user="***REDACTED***"; echo KEEPTAILQF2; echo KEEPTAILQF3'
expect_exact 'quote-first keeps grouped tail' \
  '{ curl --user="alice":secretQF3; echo KEEPTAILQF4; }' \
  '{ curl --user="***REDACTED***"; echo KEEPTAILQF4; }'

# Quoted glued passwords keep shell grouping, escaped quotes and following args intact.
glued_quoted_fixtures=(
  '(curl -uuser:"SYNTHGDQ1"); echo KEEPGDQ1'
  'x=$(curl -uuser:"SYNTHGDQ2"); echo KEEPGDQ2'
  '{ curl -uuser:"SYNTHGDQ3"; echo KEEPGDQ3; }'
  '(curl -uuser:"SYNTHGDQ4"}); echo KEEPGDQ4'
  'curl -uuser:"SYNTHGDQ5\"TAILGDQ5"; echo KEEPGDQ5'
  "curl -uuser:'SYNTHGDQ6\\'TAILGDQ6'; echo KEEPGDQ6"
  'curl -uuser:PRE"SYNTHGDQ7"; echo KEEPGDQ7'
  'curl -uuser:"SYNTHGDQ8" -H "X-Test: KEEPHEADERGDQ8"; echo KEEPGDQ8'
  "curl -uuser:'SYNTHGDQ9' -H 'X-Test: KEEPHEADERGDQ9'; echo KEEPGDQ9"
)
glued_quoted_expected=(
  '(curl -uuser:***REDACTED***); echo KEEPGDQ1'
  'x=$(curl -uuser:***REDACTED***); echo KEEPGDQ2'
  '{ curl -uuser:***REDACTED***; echo KEEPGDQ3; }'
  '(curl -uuser:***REDACTED***}); echo KEEPGDQ4'
  'curl -uuser:***REDACTED***; echo KEEPGDQ5'
  'curl -uuser:***REDACTED***; echo KEEPGDQ6'
  'curl -uuser:***REDACTED***; echo KEEPGDQ7'
  'curl -uuser:***REDACTED*** -H "X-Test: KEEPHEADERGDQ8"; echo KEEPGDQ8'
  "curl -uuser:***REDACTED*** -H 'X-Test: KEEPHEADERGDQ9'; echo KEEPGDQ9"
)
glued_quoted_secrets=(SYNTHGDQ1 SYNTHGDQ2 SYNTHGDQ3 SYNTHGDQ4 SYNTHGDQ5 SYNTHGDQ6 SYNTHGDQ7 SYNTHGDQ8 SYNTHGDQ9)
glued_quoted_tails=(KEEPGDQ1 KEEPGDQ2 KEEPGDQ3 KEEPGDQ4 KEEPGDQ5 KEEPGDQ6 KEEPGDQ7 KEEPGDQ8 KEEPGDQ9)
for case_index in "${!glued_quoted_fixtures[@]}"; do
  fixture=${glued_quoted_fixtures[$case_index]}
  expected=${glued_quoted_expected[$case_index]}
  expect_exact "quoted glued -u boundary $case_index" "$fixture" "$expected"
  expect_masked "quoted glued -u leak check $case_index" "$fixture" \
    "${glued_quoted_secrets[$case_index]}" "${glued_quoted_tails[$case_index]}"
  actual=$(redact_clip_line "$fixture") || fail "quoted glued -u shell check $case_index: redaction failed"
  bash -n <<<"$actual" || fail "quoted glued -u shell check $case_index: output is not valid shell: $actual"
done
expect_idempotent_shell 'idempotent glued -u in subshell' \
  '(curl -uuser:SYNTHIDEMSUB1); echo KEEPIDEMSUB1' SYNTHIDEMSUB1 KEEPIDEMSUB1
expect_idempotent_shell 'idempotent quoted glued -u in subshell' \
  '(curl -uuser:"SYNTHIDEMSUB2"); echo KEEPIDEMSUB2' SYNTHIDEMSUB2 KEEPIDEMSUB2
expect_idempotent_shell 'idempotent glued -u in command substitution' \
  'x=$(curl -uuser:SYNTHIDEMCMD1); echo KEEPIDEMCMD1' SYNTHIDEMCMD1 KEEPIDEMCMD1
expect_idempotent_shell 'idempotent quoted glued -u in command substitution' \
  'x=$(curl -uuser:"SYNTHIDEMCMD2"); echo KEEPIDEMCMD2' SYNTHIDEMCMD2 KEEPIDEMCMD2
expect_idempotent_shell 'idempotent quoted glued -u in grouped braces' \
  '{ curl -uuser:"SYNTHIDEMBR1"; }; echo KEEPIDEMBR1' SYNTHIDEMBR1 KEEPIDEMBR1
# Backslash-escaped delimiters stay inside a glued password.
expect_exact 'glued -u escaped delimiter' 'curl -uuser:SYNTHESC1\;SYNTHESC2 https://x' \
  'curl -uuser:***REDACTED*** https://x'
expect_exact 'idempotent glued -u escaped delimiter' 'curl -uuser:***REDACTED*** https://x' \
  'curl -uuser:***REDACTED*** https://x'
# Long flags and other glued -u spellings are not credential forms.
expect_exact 'numeric long user flag' 'curl --user=1000 https://x' 'curl --user=1000 https://x'
expect_exact 'unrelated url flag' 'curl --url https://x' 'curl --url https://x'
expect_exact 'unrelated url flag with tail' 'curl --url https://x; echo KEEPURL' 'curl --url https://x; echo KEEPURL'
expect_exact 'glued verbose flag' 'curl -uvVALUE https://x' 'curl -uvVALUE https://x'

# Attached password flags mask the value and keep the following word and tail.
p_fixtures=('mysql -uadmin -pSYNTHP941; echo KEEPP941' 'mysql -p"SYNTHP945" https://x; echo KEEPP945')
p_secrets=(SYNTHP941 SYNTHP945)
p_tails=(KEEPP941 KEEPP945)
for case_index in "${!p_fixtures[@]}"; do
  expect_masked "attached password $case_index" "${p_fixtures[$case_index]}" \
    "${p_secrets[$case_index]}" "${p_tails[$case_index]}"
done
expect_exact 'quoted password before redirect' 'mysql -p"SYNTHQDB1">out; echo KEEPQDB1' \
  'mysql -p"***REDACTED***">out; echo KEEPQDB1'

# Spaced quoted values keep the quotes, the tail and their idempotence.
quoted_fixtures=(
  'Authorization: my_scheme: "SYNTHQUOTED1"; echo KEEPQUOTED1'
  "Authorization: my_scheme: 'SYNTHQUOTED2'; echo KEEPQUOTED2"
  'Authorization: 2Scheme= "SYNTHQUOTED3"; echo KEEPQUOTED3'
  "Authorization: 2Scheme= 'SYNTHQUOTED4'; echo KEEPQUOTED4"
)
quoted_expected=(
  'Authorization: my_scheme:"***REDACTED***"; echo KEEPQUOTED1'
  "Authorization: my_scheme:'***REDACTED***'; echo KEEPQUOTED2"
  'Authorization: 2Scheme="***REDACTED***"; echo KEEPQUOTED3'
  "Authorization: 2Scheme='***REDACTED***'; echo KEEPQUOTED4"
)
for case_index in "${!quoted_fixtures[@]}"; do
  expect_exact "spaced quoted value $case_index" "${quoted_fixtures[$case_index]}" "${quoted_expected[$case_index]}"
  expect_exact "idempotent quoted value $case_index" "${quoted_expected[$case_index]}" "${quoted_expected[$case_index]}"
done

# Custom-scheme token shapes mask bare and escaped credentials with their tails intact.
token_fixtures=(
  'Authorization: my_scheme: SECRETZZ9; echo TAILZZ9'
  'Authorization: 2Scheme: SECRETZZ10; echo TAILZZ10'
  'Authorization: x~y: SECRETZZ11; echo TAILZZ11'
  'Authorization: my_scheme=\"SYNTHE12\"; echo TAILZZ12'
  'Authorization: 2Scheme \"SYNTHSP3\"; echo TAILZZSP3'
)
token_expected=(
  'Authorization: ***REDACTED***; echo TAILZZ9'
  'Authorization: ***REDACTED***; echo TAILZZ10'
  'Authorization: ***REDACTED***; echo TAILZZ11'
  'Authorization: my_scheme=\"***REDACTED***\"; echo TAILZZ12'
  'Authorization: 2Scheme \"***REDACTED***\"; echo TAILZZSP3'
)
for case_index in "${!token_fixtures[@]}"; do
  expect_exact "custom token $case_index" "${token_fixtures[$case_index]}" "${token_expected[$case_index]}"
done

# Generic quote-terminated values must not consume a following argument or header.
over_fixtures=(
  'curl -H "Authorization: Foo: SYNTHA1" "PAYLOADA1"; echo TAILA1'
  "curl -H 'Authorization: Foo: SYNTHS1' 'PAYLOADS1'; echo TAILS1"
  'curl -H "Authorization: Foo: SYNTHC1" -H "X: KEEPC1" https://x; echo TAILC1'
)
over_expected=(
  'curl -H "Authorization: ***REDACTED***" "PAYLOADA1"; echo TAILA1'
  "curl -H 'Authorization: ***REDACTED***' 'PAYLOADS1'; echo TAILS1"
  'curl -H "Authorization: ***REDACTED***" -H "X: KEEPC1" https://x; echo TAILC1'
)
for case_index in "${!over_fixtures[@]}"; do
  expect_exact "generic quoted value $case_index" "${over_fixtures[$case_index]}" "${over_expected[$case_index]}"
done

# Quoted or escaped-quote custom-scheme headers must mask every credential
# piece while keeping the following word, second header and command tail.
redact_clip_exact() {
  bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; __lmline_next_realm_shield_prefix; printf "%s" "$2" | __lmline_redact_clip_text "$__LMLINE_REALM_SHIELD_PREFIX"' _ \
    "$repo_dir/lmline/actions.bash" "$1"
}
custom_scheme_tail_fixtures=(
  'curl -H "Authorization: my_scheme=\"SYN26\"" "KEEP26"; echo TAIL26'
  "curl -H 'Authorization: my_scheme: \"SYN27\"' 'KEEP27'; echo TAIL27"
  "curl -H 'Authorization: x~y: \"SYN28\"' -H \"X: KEEP28\"; echo TAIL28"
  'Authorization: my_scheme:SYN29 "KEEP29"; echo TAIL29'
  'curl -H "Authorization: my_scheme:SYN29" -H "X: KEEP29B" https://x; echo TAIL29B'
  'curl -H "Authorization: Foo:SYN33" -H "X: KEEP33" https://x; echo TAIL33'
)
custom_scheme_tail_expected=(
  'curl -H "Authorization: ***REDACTED***" "KEEP26"; echo TAIL26'
  "curl -H 'Authorization: ***REDACTED***' 'KEEP27'; echo TAIL27"
  "curl -H 'Authorization: ***REDACTED***' -H \"X: KEEP28\"; echo TAIL28"
  'Authorization: ***REDACTED*** "KEEP29"; echo TAIL29'
  'curl -H "Authorization: ***REDACTED***" -H "X: KEEP29B" https://x; echo TAIL29B'
  'curl -H "Authorization: ***REDACTED***" -H "X: KEEP33" https://x; echo TAIL33'
)
for case_index in "${!custom_scheme_tail_fixtures[@]}"; do
  fixture=${custom_scheme_tail_fixtures[$case_index]}
  expected=${custom_scheme_tail_expected[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "custom scheme tail $case_index fixture is not valid shell: $fixture"
  printf '%s\n' "$expected" | bash -n || fail "custom scheme tail $case_index expected is not valid shell: $expected"
  actual=$(redact_clip_exact "$fixture") || fail "custom scheme tail $case_index redaction failed"
  [[ $actual == "$expected" ]] || fail "custom scheme tail $case_index: got $actual"
  second=$(redact_clip_exact "$actual") || fail "custom scheme tail $case_index second pass failed"
  [[ $second == "$actual" ]] || fail "custom scheme tail $case_index second pass changed $actual to $second"
done

# Bare Authorization scheme tokens follow RFC 9110 tchar, including '*' and
# an interior apostrophe. Quoted shell headers and canonical markers are not
# bare schemes; every result is stable on a second pass.
bare_tchar_fixtures=(
  'Authorization: foo*bar SYN20'
  "Authorization: foo'bar SYN21"
  '-H "Authorization: Foo:SYN33" -H "X: KEEP33"'
  '-H "Authorization: Bearer ***REDACTED***" -H "X: KEEP33"'
  'Authorization: Bearer ***REDACTED***'
  'Authorization: foo*bar ***REDACTED***'
  'Authorization: Basic @@LMLINE_REDACTED@@'
)
bare_tchar_expected=(
  'Authorization: ***REDACTED***'
  'Authorization: ***REDACTED***'
  '-H "Authorization: ***REDACTED***" -H "X: KEEP33"'
  '-H "Authorization: Bearer ***REDACTED***" -H "X: KEEP33"'
  'Authorization: Bearer ***REDACTED***'
  'Authorization: foo*bar ***REDACTED***'
  'Authorization: Basic ***REDACTED***'
)
for case_index in "${!bare_tchar_fixtures[@]}"; do
  fixture=${bare_tchar_fixtures[$case_index]}
  expected=${bare_tchar_expected[$case_index]}
  actual=$(redact_clip_exact "$fixture") || fail "bare tchar scheme $case_index redaction failed"
  [[ $actual == "$expected" ]] || fail "bare tchar scheme $case_index: got $actual"
  second=$(redact_clip_exact "$actual") || fail "bare tchar scheme $case_index second pass failed"
  [[ $second == "$actual" ]] || fail "bare tchar scheme $case_index second pass changed $actual to $second"
done

# Live credentials beside canonical markers are still masked, and quoted bare
# custom-scheme values leave no internal sentinel in the redacted text.
bare_marker_fixtures=(
  'Authorization: Bearer ***REDACTED***; Authorization: foo*bar LIVESECRET88; echo TAILLIVE'
  'echo ***REDACTED*** ; Authorization: foo*bar LIVESECRET90; echo TAIL90'
  'Authorization: foo*bar "QSECRET78"; echo TAIL78'
  'Authorization: foo*bar="QSECRET79"; echo TAIL79'
)
bare_marker_expected=(
  'Authorization: Bearer ***REDACTED***; Authorization: ***REDACTED***; echo TAILLIVE'
  'echo ***REDACTED*** ; Authorization: ***REDACTED***; echo TAIL90'
  'Authorization: ***REDACTED***; echo TAIL78'
  'Authorization: ***REDACTED***; echo TAIL79'
)
for case_index in "${!bare_marker_fixtures[@]}"; do
  fixture=${bare_marker_fixtures[$case_index]}
  expected=${bare_marker_expected[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "bare marker $case_index fixture is not valid shell: $fixture"
  printf '%s\n' "$expected" | bash -n || fail "bare marker $case_index expected is not valid shell: $expected"
  actual=$(redact_clip_exact "$fixture") || fail "bare marker $case_index redaction failed"
  [[ $actual == "$expected" ]] || fail "bare marker $case_index: got $actual"
  [[ $actual != *LMLINEBARE* ]] || fail "bare marker $case_index leaked an internal sentinel"
  second=$(redact_clip_exact "$actual") || fail "bare marker $case_index second pass failed"
  [[ $second == "$actual" ]] || fail "bare marker $case_index second pass changed $actual to $second"
done

# A colon-separated bare custom scheme must not leave a live credential after
# the scheme token is stripped.
bare_colon_fixtures=(
  'Authorization: foo*bar: LIVESECRET99; echo T'
  'Authorization: mypassword123*: LIVESECRET99; echo T'
  'Authorization: AKIAabcdefghijklmnop*: LIVESECRET99; echo T'
  'Authorization: foo*bar : LIVESECRET99; echo TAILKEEP'
  'Authorization: AKIAabcdefghijklmnop* = LIVESECRET99; echo TAILKEEP'
  'Authorization: foo*bar : : LIVESECRET99; echo TAILKEEP'
  'echo hi;Authorization: : LIVESECRET99; echo KEEP'
  'curl -H "Authorization::LIVESECRET99"; echo KEEP'
  'curl -H Authorization::abc=SHADOWSECRET99 https://x; echo KEEP'
  'echo <Authorization:=REDIRECTSECRET99; echo KEEP'
  'Authorization::SECRET|Authorization: Bearer SYNTH2; echo KEEP'
  "curl -H \"Authorization: token'abc: LIVESECRET99\" -H \"X: KEEP99\"; echo TAIL99"
)
bare_colon_expected=(
  'Authorization: ***REDACTED***; echo T'
  'Authorization: ***REDACTED***; echo T'
  'Authorization: ***REDACTED***; echo T'
  'Authorization: ***REDACTED***; echo TAILKEEP'
  'Authorization: ***REDACTED***; echo TAILKEEP'
  'Authorization: ***REDACTED***; echo TAILKEEP'
  'echo hi;Authorization:***REDACTED***; echo KEEP'
  'curl -H "Authorization: ***REDACTED***"; echo KEEP'
  'curl -H Authorization: ***REDACTED*** https://x; echo KEEP'
  'echo <Authorization: ***REDACTED***; echo KEEP'
  'Authorization: ***REDACTED***|Authorization: Bearer ***REDACTED***; echo KEEP'
  'curl -H "Authorization: ***REDACTED***" -H "X: KEEP99"; echo TAIL99'
)
for case_index in "${!bare_colon_fixtures[@]}"; do
  fixture=${bare_colon_fixtures[$case_index]}
  expected=${bare_colon_expected[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "bare colon $case_index fixture is not valid shell: $fixture"
  printf '%s\n' "$expected" | bash -n || fail "bare colon $case_index expected is not valid shell: $expected"
  actual=$(redact_clip_exact "$fixture") || fail "bare colon $case_index redaction failed"
  [[ $actual == "$expected" ]] || fail "bare colon $case_index: got $actual"
  second=$(redact_clip_exact "$actual") || fail "bare colon $case_index second pass failed"
  [[ $second == "$actual" ]] || fail "bare colon $case_index second pass changed $actual to $second"
done

# A star-leading bare value is live credential data, and canonical markers
# stay idempotent while the following quoted word survives.
star_leading_fixtures=(
  'Authorization: *SYNTHSTARXYZ "PAYLOAD"; echo KEEPSTAR'
  'Authorization: ***REDACTED*** "PAYLOAD"; echo KEEPMARK'
)
star_leading_expected=(
  'Authorization: ***REDACTED*** "PAYLOAD"; echo KEEPSTAR'
  'Authorization: ***REDACTED*** "PAYLOAD"; echo KEEPMARK'
)
for case_index in "${!star_leading_fixtures[@]}"; do
  fixture=${star_leading_fixtures[$case_index]}
  expected=${star_leading_expected[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "star-leading $case_index fixture is not valid shell: $fixture"
  printf '%s\n' "$expected" | bash -n || fail "star-leading $case_index expected is not valid shell: $expected"
  actual=$(redact_clip_exact "$fixture") || fail "star-leading $case_index redaction failed"
  [[ $actual == "$expected" ]] || fail "star-leading $case_index: got $actual"
  second=$(redact_clip_exact "$actual") || fail "star-leading $case_index second pass failed"
  [[ $second == "$actual" ]] || fail "star-leading $case_index second pass changed $actual to $second"
done

# Glued custom-scheme quoted values are masked without eating the tail.
glued_quote_fixtures=(
  'Authorization: my_scheme:"SYNTHGLUEDQ1"; echo KEEPGLUEDQ1'
  "Authorization: 2Scheme:'SYNTHGLUEDS1'; echo KEEPGLUEDS1"
)
glued_quote_expected=(
  'Authorization: my_scheme:"***REDACTED***"; echo KEEPGLUEDQ1'
  "Authorization: 2Scheme:'***REDACTED***'; echo KEEPGLUEDS1"
)
for case_index in "${!glued_quote_fixtures[@]}"; do
  expect_exact "glued quoted value $case_index" "${glued_quote_fixtures[$case_index]}" "${glued_quote_expected[$case_index]}"
done

# Repeated headers of both quote families keep their schemes and command tails.
expect_exact 'repeated double-quoted headers' \
  'Authorization: my_scheme:"SYNTHREPEATQ1"; Authorization: 2scheme:"SYNTHREPEATQ2"; echo KEEPREPEATQ' \
  'Authorization: my_scheme:"***REDACTED***"; Authorization: 2scheme:"***REDACTED***"; echo KEEPREPEATQ'
expect_exact 'repeated single-quoted headers' \
  "Authorization: my_scheme:'SYNTHREPEATSQ1'; Authorization: 2scheme:'SYNTHREPEATSQ2'; echo KEEPREPEATSQ" \
  "Authorization: my_scheme:'***REDACTED***'; Authorization: 2scheme:'***REDACTED***'; echo KEEPREPEATSQ"

# A shell separator is not a URL Authorization separator.
expect_exact 'glued shell headers' \
  'Authorization: my_scheme:"SYNTHSEPAMP1"&Authorization: 2scheme:"SYNTHSEPAMP2"; echo KEEPSEPAMP' \
  'Authorization: my_scheme:"***REDACTED***"&Authorization: 2scheme:"***REDACTED***"; echo KEEPSEPAMP'

# Natural quoted prefixes do not let the fallback eat the command tail.
expect_exact 'natural quoted prefix' 'echo "note Authorization: SYNTHNATQ1 tail"; echo KEEPNATQ1' \
  'echo "note Authorization: SYNTHNATQ1 ***REDACTED***"; echo KEEPNATQ1'

# URL query Authorization values and their trailing separators stay masked.
expect_exact 'late URL Authorization' \
  'curl -H "Authorization: Bearer SYNTHHDRM1"; curl "https://x/?a=1&Authorization=SYNTHURLMUT1"' \
  'curl -H "Authorization: Bearer ***REDACTED***"; curl "https://x/?a=1&Authorization:***REDACTED***"'
expect_exact 'URL Authorization ending' 'url=https://x/?a=1&Authorization=SYNTHCOLEND1:' \
  'url=https://x/?a=1&Authorization:***REDACTED***'
expect_exact 'padded URL Authorization ending' \
  'url=https://x/?a=1&Authorization=SYNTHPADENDMUT==; echo KEEPPADEDMUT' \
  'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPPADEDMUT'

# Encoded credentials keep their surrounding shell quoting and command tails.
expect_exact 'encoded quote and tail' \
  'curl "https://x/?Authorization%3DSYNTHQUOTEKEEP9001" -H "X: keep"; echo KEEPQUOTETAIL9001' \
  'curl "https://x/?Authorization:***REDACTED***" -H "X: keep"; echo KEEPQUOTETAIL9001'
expect_exact 'encoded quote at end' \
  'curl "https://x/?Authorization%3DSYNTHQUOTEKEEP9002"' \
  'curl "https://x/?Authorization:***REDACTED***"'
expect_exact 'encoded single quote and tail' \
  "curl 'https://x/?Authorization%3DSYNTHQUOTEKEEP9003' -H 'X: keep'; echo KEEPQUOTETAIL9003" \
  "curl 'https://x/?Authorization:***REDACTED***' -H 'X: keep'; echo KEEPQUOTETAIL9003"
expect_exact 'encoded quote before option' \
  "curl \"https://x/?Authorization%3DSYNTHQUOTEKEEP9004\" --data=' keep'; echo KEEPQUOTETAIL9004" \
  "curl \"https://x/?Authorization:***REDACTED***\" --data=' keep'; echo KEEPQUOTETAIL9004"
expect_exact 'escaped key with literal space' \
  'url=https://x/?a=1&\"Authorization\"%3DBearer SYNTHESCDQ9003&keep=KEEPTAIL540' \
  'url=https://x/?a=1&Authorization:***REDACTED***&keep=KEEPTAIL540'
expect_exact 'generic key with literal space' \
  'url=https://x/?a=1&token%3Dmy secret SYNTHKEY9008&keep=KEEPTAIL603' \
  'url=https://x/?a=1&token=***REDACTED***&keep=KEEPTAIL603'
# A live quoted header and an encoded credential on one line must both be
# masked without losing either command or the shell quote boundaries.
expect_exact 'live header with encoded credential' \
  'curl -H "Authorization: Bearer a\"b\"cSYNTHLIVEQQ999" https://x/?token%3DENCQQ888; echo KEEPTAILQQ777' \
  'curl -H "Authorization: Bearer ***REDACTED***" https://x/?token=***REDACTED***; echo KEEPTAILQQ777'
expect_exact 'bare quote inside encoded value' \
  "curl \"https://x/?Authorization%3DSYNTHBAREQ999'PART2&keep=KEEPQQ123\"; echo TAILQQ123" \
  "curl \"https://x/?Authorization:***REDACTED***&keep=KEEPQQ123\"; echo TAILQQ123"
expect_exact 'bare quote inside encoded token value' \
  "url=\"https://x/?token%3DSYNTHBARETOK999'PART2&keep=KEEPQQ456\"" \
  "url=\"https://x/?token=***REDACTED***&keep=KEEPQQ456\""
expect_exact 'pasted encoded marker does not disable header masking' \
  'curl -H "Authorization: Bearer a\"b\"cLMLINE_ENCODED_MASK"; echo TAILQQ777' \
  'curl -H "Authorization: Bearer ***REDACTED***"; echo TAILQQ777'
expect_shell_valid() {
  local label=$1 fixture=$2 actual
  actual=$(redact_clip_line "$fixture") || fail "$label: redaction failed"
  bash -n <<<"$actual" || fail "$label: output is not valid shell: $actual"
}
expect_shell_valid 'live header beside encoded credential' \
  'curl -H "Authorization: Bearer a\"b\"cSYNTHLIVEQQ999" https://x/?token%3DENCQQ888; echo KEEPTAILQQ777'
expect_shell_valid 'pasted encoded marker shell syntax' \
  'curl -H "Authorization: Bearer a\"b\"cLMLINE_ENCODED_MASK"; echo TAILQQ777'
expect_shell_valid 'encoded double quote shell syntax' \
  'curl "https://x/?Authorization%3DSYNTHQUOTEKEEP9001" -H "X: keep"; echo KEEPQUOTETAIL9001'
expect_shell_valid 'encoded single quote shell syntax' \
  "curl 'https://x/?Authorization%3DSYNTHQUOTEKEEP9003' -H 'X: keep'; echo KEEPQUOTETAIL9003"

expect_exact 'closing paren after encoded Authorization value' \
  '(curl "https://x/?Authorization%3DSYNTHCLQ1"); echo KEEPCLQ1' \
  '(curl "https://x/?Authorization:***REDACTED***"); echo KEEPCLQ1'
expect_exact 'closing paren after encoded array value' \
  'x=("https://x/?token%3DSYNTHCLQ2"); echo KEEPCLQ2' \
  'x=("https://x/?token=***REDACTED***"); echo KEEPCLQ2'
expect_exact 'word after encoded value closing quote' \
  'curl "https://x/?Authorization%3DSYNTHCLQ3"foo; echo KEEPCLQ3' \
  'curl "https://x/?Authorization:***REDACTED***"foo; echo KEEPCLQ3'
expect_exact 'closing single quote after encoded value' \
  "(curl 'https://x/?token%3DSYNTHCLQ4'); echo KEEPCLQ4" \
  "(curl 'https://x/?token=***REDACTED***'); echo KEEPCLQ4"
expect_shell_valid 'grouped encoded Authorization value shell syntax' \
  '(curl "https://x/?Authorization%3DSYNTHCLQ1"); echo KEEPCLQ1'
expect_shell_valid 'encoded value with following word shell syntax' \
  'curl "https://x/?Authorization%3DSYNTHCLQ3"foo; echo KEEPCLQ3'
# Unquoted redirects survive; quoted and escaped brackets remain credential data.
expect_exact 'bare double quote inside single-quoted encoded value' \
  "curl 'https://x/?Authorization%3DSYNTHDQ999\"PART2DQ&keep=KEEPDQ456'" \
  "curl 'https://x/?Authorization:***REDACTED***\"***REDACTED***&keep=KEEPDQ456'"
expect_shell_valid 'bare double quote inside single-quoted encoded value shell syntax' \
  "curl 'https://x/?Authorization%3DSYNTHDQ999\"PART2DQ&keep=KEEPDQ456'"
# Bare quotes after an encoded credential start more credential data inside a
# single-quoted URL; every segment is masked while the shell tail is preserved.
expect_exact 'space-bearing tail after bare quote' \
  "url='https://x/?token%3DSYNTHSP1\"SYNTHSP2 SYNTHSP3&keep=KEEPSP1'" \
  "url='https://x/?token=***REDACTED***\"***REDACTED***&keep=KEEPSP1'"
expect_exact 'space-bearing Authorization tail after bare quote' \
  "curl 'https://x/?Authorization%3DSYNTHSP4\"SYNTHSP5 secret SYNTHSP6&keep=KEEPSP2'" \
  "curl 'https://x/?Authorization:***REDACTED***\"***REDACTED***&keep=KEEPSP2'"
sp_tab_fixture=$'url=\'https://x/?token%3DSYNTHSP7"SYNTHSP8\tSYNTHSP9&keep=KEEPSP3\''
expect_exact 'tab in tail after bare quote' \
  "$sp_tab_fixture" \
  "url='https://x/?token=***REDACTED***\"***REDACTED***&keep=KEEPSP3'"
expect_exact 'bare quote after encoded Authorization masks the tail' \
  "curl 'https://x/?Authorization%3DSYNTHBQTA\"SYNTHBQTB'; echo KEEPBT1" \
  "curl 'https://x/?Authorization:***REDACTED***\"***REDACTED***'; echo KEEPBT1"
expect_exact 'two bare quotes after encoded Authorization mask both tails' \
  "curl 'https://x/?Authorization%3DSYNTHBQT1\"SYNTHBQT2\"SYNTHBQT3'; echo KEEPBT2" \
  "curl 'https://x/?Authorization:***REDACTED***\"***REDACTED***\"***REDACTED***'; echo KEEPBT2"
# The two-segment rule must also close on a double quote: the fixture above
# ends in a single quote and passes even when that half of the rule is reverted.
expect_exact 'two bare quotes after encoded token close with a double quote' \
  "curl \"https://x/?token%3DSYNTHDQ2A\"SYNTHDQ2B\"SYNTHDQ2C\"; echo KEEPDQ2" \
  "curl \"https://x/?token=***REDACTED***\"***REDACTED***\"***REDACTED***\"; echo KEEPDQ2"
expect_exact 'bare quote after encoded token masks the tail' \
  "curl 'https://x/?token%3DSYNTHBQT4\"SYNTHBQT5'; echo KEEPBT3" \
  "curl 'https://x/?token=***REDACTED***\"***REDACTED***'; echo KEEPBT3"
expect_exact 'bare quote before an embedded semicolon masks the tail' \
  "curl 'https://x/?token%3DSYNTHBQT9\"SYNTHBQTB\"; echo KEEPBT4'" \
  "curl 'https://x/?token=***REDACTED***\"***REDACTED***\"; echo KEEPBT4'"
expect_exact 'bare quote before an embedded ampersand masks the tail' \
  "curl 'https://x/?token%3DSYNTHBQT10\"SYNTHBQTB\"& echo KEEPBT5'" \
  "curl 'https://x/?token=***REDACTED***\"***REDACTED***\"& echo KEEPBT5'"
expect_exact 'closing quote after encoded value keeps the shell separator' \
  'curl "https://x/?Authorization%3DSYNTHBQT6" && echo KEEPSHELL1' \
  'curl "https://x/?Authorization:***REDACTED***" && echo KEEPSHELL1'
expect_exact 'closing quote after encoded token keeps the shell separator' \
  'curl "https://x/?token%3DSYNTHBQT7" && echo KEEPSHELL2' \
  'curl "https://x/?token=***REDACTED***" && echo KEEPSHELL2'
expect_exact 'closing quote after encoded value keeps a semicolon tail' \
  'curl "https://x/?Authorization%3DSYNTHBQT8"; echo KEEPSHELL3' \
  'curl "https://x/?Authorization:***REDACTED***"; echo KEEPSHELL3'
expect_exact 'unquoted redirect after auth flag' \
  'curl --user=SYNTHOPREDIR1>out;echo KEEPOPREDIR1' \
  'curl --user=***REDACTED***>out;echo KEEPOPREDIR1'
expect_exact 'escaped bracket stays in the credential' \
  'curl --user=SYNTHESCBRACKET1\>out;echo KEEPESCB1' \
  'curl --user=***REDACTED***;echo KEEPESCB1'
expect_exact 'escaped dollar at credential start' \
  'curl --user=\$uperSecret;echo KEEPLB1' \
  'curl --user=***REDACTED***;echo KEEPLB1'
expect_exact 'escaped hash at credential start' \
  'curl --user=\#hiddenSecret;echo KEEPLB2' \
  'curl --user=***REDACTED***;echo KEEPLB2'
expect_exact 'escaped bracket at credential start' \
  'curl --user=\>bracketSecret;echo KEEPLB3' \
  'curl --user=***REDACTED***;echo KEEPLB3'
expect_exact 'escaped dollar after leading digits' \
  'curl --user=1\$digitSecret;echo KEEPLB4' \
  'curl --user=***REDACTED***;echo KEEPLB4'
expect_exact 'quoted bracket stays in the credential' \
  'curl --user="SYNTHQUOTEBRACKET1>out";echo KEEPQUOTEB1' \
  'curl --user="***REDACTED***";echo KEEPQUOTEB1'
# Grouped credentials keep their closing group operator, flag spelling and
# quoted header tail; a second pass must not eat the closing quote or group.
grouped_fixtures=(
  '(curl -u user:SYNTHGRP1); echo KEEPGRP1'
  '(curl --user=SYNTHGRP2); echo KEEPGRP2'
  '(curl -u=user:SYNTHGRP9); echo KEEPGRP9'
  '(curl -H "Authorization: Bearer SYNTHGRP5"); echo KEEPGRP5'
  'x=$(curl -H "Authorization: Bearer SYNTHGRP8"); echo KEEPGRP8'
  '{ curl -u user:SYNTHGRP10; echo KEEPGRP10; }'
)
grouped_expected=(
  '(curl -u user:***REDACTED***); echo KEEPGRP1'
  '(curl --user=***REDACTED***); echo KEEPGRP2'
  '(curl -u=user:***REDACTED***); echo KEEPGRP9'
  '(curl -H "Authorization: Bearer ***REDACTED***"); echo KEEPGRP5'
  'x=$(curl -H "Authorization: Bearer ***REDACTED***"); echo KEEPGRP8'
  '{ curl -u user:***REDACTED***; echo KEEPGRP10; }'
)
grouped_secrets=(SYNTHGRP1 SYNTHGRP2 SYNTHGRP9 SYNTHGRP5 SYNTHGRP8 SYNTHGRP10)
grouped_tails=(KEEPGRP1 KEEPGRP2 KEEPGRP9 KEEPGRP5 KEEPGRP8 KEEPGRP10)
for case_index in "${!grouped_fixtures[@]}"; do
  fixture=${grouped_fixtures[$case_index]}
  expected=${grouped_expected[$case_index]}
  expect_exact "grouped credential $case_index" "$fixture" "$expected"
  expect_exact "grouped credential second pass $case_index" "$expected" "$expected"
  grep -Fq "${grouped_secrets[$case_index]}" <<<"$expected" && fail "grouped credential $case_index was not masked"
  grep -Fq "${grouped_tails[$case_index]}" <<<"$expected" || fail "grouped credential $case_index lost its tail"
  printf '%s\n' "$expected" | bash -n || fail "grouped credential $case_index is not valid shell: $expected"
done

# An internal ) or } stays part of the credential; only a trailing one closes
# the group. Tails stay visible and a second pass is stable.
inner_group_fixtures=(
  'curl -u=user:pa)SYNTHINNERU1 https://x; echo TAILINNERU1'
  'curl -u=user:pa}SYNTHINNERU2 https://x; echo TAILINNERU2'
  'curl --user=user:pa)SYNTHINNERU3 https://x; echo TAILINNERU3'
  'curl --user=user:pa}SYNTHINNERU4 https://x; echo TAILINNERU4'
  'curl -u user:pa)SYNTHINNERU5 https://x; echo TAILINNERU5'
  'curl -u user:pa}SYNTHINNERU6 https://x; echo TAILINNERU6'
  'curl -u=pa)SYNTHINNERU7 https://x; echo TAILINNERU7'
  'curl -u=pa}SYNTHINNERU8 https://x; echo TAILINNERU8'
  'curl --user=pa)SYNTHINNERU9 https://x; echo TAILINNERU9'
  'curl --user=pa}SYNTHINNERU10 https://x; echo TAILINNERU10'
  '(curl -u=user:pa)SYNTHINNERG1); echo KEEPINNERG1'
  '(curl --user=user:pa}SYNTHINNERG2); echo KEEPINNERG2'
  '(curl -u user:pa)SYNTHINNERG3); echo KEEPINNERG3'
  '(curl -u=pa)SYNTHINNERG4); echo KEEPINNERG4'
  '(curl --user=pa}SYNTHINNERG5); echo KEEPINNERG5'
  '{ curl -u user:pa}SYNTHINNERG6; echo KEEPINNERG6; }'
)
inner_group_expected=(
  'curl -u=user:***REDACTED*** https://x; echo TAILINNERU1'
  'curl -u=user:***REDACTED*** https://x; echo TAILINNERU2'
  'curl --user=user:***REDACTED*** https://x; echo TAILINNERU3'
  'curl --user=user:***REDACTED*** https://x; echo TAILINNERU4'
  'curl -u user:***REDACTED*** https://x; echo TAILINNERU5'
  'curl -u user:***REDACTED*** https://x; echo TAILINNERU6'
  'curl -u=***REDACTED*** https://x; echo TAILINNERU7'
  'curl -u=***REDACTED*** https://x; echo TAILINNERU8'
  'curl --user=***REDACTED*** https://x; echo TAILINNERU9'
  'curl --user=***REDACTED*** https://x; echo TAILINNERU10'
  '(curl -u=user:***REDACTED***); echo KEEPINNERG1'
  '(curl --user=user:***REDACTED***); echo KEEPINNERG2'
  '(curl -u user:***REDACTED***); echo KEEPINNERG3'
  '(curl -u=***REDACTED***); echo KEEPINNERG4'
  '(curl --user=***REDACTED***); echo KEEPINNERG5'
  '{ curl -u user:***REDACTED***; echo KEEPINNERG6; }'
)
inner_group_secrets=(SYNTHINNERU1 SYNTHINNERU2 SYNTHINNERU3 SYNTHINNERU4 SYNTHINNERU5 SYNTHINNERU6 SYNTHINNERU7 SYNTHINNERU8 SYNTHINNERU9 SYNTHINNERU10 SYNTHINNERG1 SYNTHINNERG2 SYNTHINNERG3 SYNTHINNERG4 SYNTHINNERG5 SYNTHINNERG6)
inner_group_tails=(TAILINNERU1 TAILINNERU2 TAILINNERU3 TAILINNERU4 TAILINNERU5 TAILINNERU6 TAILINNERU7 TAILINNERU8 TAILINNERU9 TAILINNERU10 KEEPINNERG1 KEEPINNERG2 KEEPINNERG3 KEEPINNERG4 KEEPINNERG5 KEEPINNERG6)
for case_index in "${!inner_group_fixtures[@]}"; do
  fixture=${inner_group_fixtures[$case_index]}
  expected=${inner_group_expected[$case_index]}
  expect_exact "inner group credential $case_index" "$fixture" "$expected"
  expect_exact "inner group credential second pass $case_index" "$expected" "$expected"
  grep -Fq "${inner_group_secrets[$case_index]}" <<<"$expected" && fail "inner group credential $case_index was not masked"
  grep -Fq "${inner_group_tails[$case_index]}" <<<"$expected" || fail "inner group credential $case_index lost its tail"
  printf '%s\n' "$expected" | bash -n || fail "inner group credential $case_index is not valid shell: $expected"
done

# Glued equals credentials with an immediately quoted tail are fully masked.
# Both quote families, all three flag spellings, bare and grouped contexts.
glued_equals_fixtures=(
  'curl -u=SYNTHGLUEEQ1"TAILGLUEEQ1"; echo KEEPGLUEEQ1'
  "curl -u=SYNTHGLUEEQ2'TAILGLUEEQ2'; echo KEEPGLUEEQ2"
  'curl --u=SYNTHGLUEEU1"TAILGLUEEU1"; echo KEEPGLUEEU1'
  "curl --u=SYNTHGLUEEU2'TAILGLUEEU2'; echo KEEPGLUEEU2"
  'curl --user=SYNTHGLUEED1"TAILGLUEED1"; echo KEEPGLUEED1'
  "curl --user=SYNTHGLUEED2'TAILGLUEED2'; echo KEEPGLUEED2"
  '(curl -u=SYNTHGLUEG1"TAILGLUEG1"); echo KEEPGLUEG1'
  "(curl --u=SYNTHGLUEG2'TAILGLUEG2'); echo KEEPGLUEG2"
  '(curl --user=SYNTHGLUEG3"TAILGLUEG3"); echo KEEPGLUEG3'
  "{ curl -u=SYNTHGLUEG4'TAILGLUEG4'; echo KEEPGLUEG4; }"
  '{ curl --u=SYNTHGLUEG5"TAILGLUEG5"; echo KEEPGLUEG5; }'
  "{ curl --user=SYNTHGLUEG6'TAILGLUEG6'; echo KEEPGLUEG6; }"
)
glued_equals_expected=(
  'curl -u=***REDACTED***; echo KEEPGLUEEQ1'
  'curl -u=***REDACTED***; echo KEEPGLUEEQ2'
  'curl --u=***REDACTED***; echo KEEPGLUEEU1'
  'curl --u=***REDACTED***; echo KEEPGLUEEU2'
  'curl --user=***REDACTED***; echo KEEPGLUEED1'
  'curl --user=***REDACTED***; echo KEEPGLUEED2'
  '(curl -u=***REDACTED***); echo KEEPGLUEG1'
  '(curl --u=***REDACTED***); echo KEEPGLUEG2'
  '(curl --user=***REDACTED***); echo KEEPGLUEG3'
  '{ curl -u=***REDACTED***; echo KEEPGLUEG4; }'
  '{ curl --u=***REDACTED***; echo KEEPGLUEG5; }'
  '{ curl --user=***REDACTED***; echo KEEPGLUEG6; }'
)
glued_equals_prefix=(SYNTHGLUEEQ1 SYNTHGLUEEQ2 SYNTHGLUEEU1 SYNTHGLUEEU2 SYNTHGLUEED1 SYNTHGLUEED2 SYNTHGLUEG1 SYNTHGLUEG2 SYNTHGLUEG3 SYNTHGLUEG4 SYNTHGLUEG5 SYNTHGLUEG6)
glued_equals_quoted=(TAILGLUEEQ1 TAILGLUEEQ2 TAILGLUEEU1 TAILGLUEEU2 TAILGLUEED1 TAILGLUEED2 TAILGLUEG1 TAILGLUEG2 TAILGLUEG3 TAILGLUEG4 TAILGLUEG5 TAILGLUEG6)
glued_equals_tails=(KEEPGLUEEQ1 KEEPGLUEEQ2 KEEPGLUEEU1 KEEPGLUEEU2 KEEPGLUEED1 KEEPGLUEED2 KEEPGLUEG1 KEEPGLUEG2 KEEPGLUEG3 KEEPGLUEG4 KEEPGLUEG5 KEEPGLUEG6)
for case_index in "${!glued_equals_fixtures[@]}"; do
  fixture=${glued_equals_fixtures[$case_index]}
  expected=${glued_equals_expected[$case_index]}
  expect_exact "glued equals credential $case_index" "$fixture" "$expected"
  expect_exact "glued equals credential second pass $case_index" "$expected" "$expected"
  grep -Fq "${glued_equals_prefix[$case_index]}" <<<"$expected" && fail "glued equals credential $case_index leaked its prefix"
  grep -Fq "${glued_equals_quoted[$case_index]}" <<<"$expected" && fail "glued equals credential $case_index leaked its quoted tail"
  grep -Fq "${glued_equals_tails[$case_index]}" <<<"$expected" || fail "glued equals credential $case_index lost its tail"
  printf '%s\n' "$expected" | bash -n || fail "glued equals credential $case_index is not valid shell: $expected"
done
# Glued equals with user: prefix and quoted passwords are fully masked.
# All three flag spellings, both quote families, bare and grouped contexts,
# including partial prefixes and escaped quotes.
glued_user_equals_fixtures=(
  'curl -u=user:"SYNTHUEQ1"; echo KEEPUEQ1'
  'curl --u=user:"SYNTHUEQ2"; echo KEEPUEQ2'
  'curl --user=user:"SYNTHUEQ3"; echo KEEPUEQ3'
  "curl -u=user:'SYNTHUEQ4'; echo KEEPUEQ4"
  "curl --u=user:'SYNTHUEQ5'; echo KEEPUEQ5"
  "curl --user=user:'SYNTHUEQ6'; echo KEEPUEQ6"
  'curl -u=user:"my secretSYNTHUEQ7"; echo KEEPUEQ7'
  'curl --u=user:"my secretSYNTHUEQ8"; echo KEEPUEQ8'
  'curl --user=user:"my secretSYNTHUEQ9"; echo KEEPUEQ9'
  'curl -u=user:PRE"SYNTHUEQ10" https://x; echo KEEPUEQ10'
  'curl --u=user:PRE"SYNTHUEQ11" https://x; echo KEEPUEQ11'
  'curl --user=user:PRE"SYNTHUEQ12" https://x; echo KEEPUEQ12'
  "curl -u=user:PRE'SYNTHUEQ13'; echo KEEPUEQ13"
  "curl --u=user:PRE'SYNTHUEQ14'; echo KEEPUEQ14"
  "curl --user=user:PRE'SYNTHUEQ15'; echo KEEPUEQ15"
  'curl -u=user:"SYNTHUEQ16\"TAILUEQ16"; echo KEEPUEQ16'
  'curl --u=user:"SYNTHUEQ17\"TAILUEQ17"; echo KEEPUEQ17'
  'curl --user=user:"SYNTHUEQ18\"TAILUEQ18"; echo KEEPUEQ18'
  "curl -u=user:'SYNTHUEQ19\\'TAILUEQ19'; echo KEEPUEQ19"
  "curl --u=user:'SYNTHUEQ20\\'TAILUEQ20'; echo KEEPUEQ20"
  "curl --user=user:'SYNTHUEQ21\\'TAILUEQ21'; echo KEEPUEQ21"
  'curl -u=SECRETB"TAILUEQ22\"B"; echo KEEPE22'
  '(curl -u=user:"SYNTHUEQG1"); echo KEEPUEQG1'
  '(curl --u=user:"SYNTHUEQG2"); echo KEEPUEQG2'
  '(curl --user=user:"SYNTHUEQG3"); echo KEEPUEQG3'
  'x=$(curl -u=user:"SYNTHUEQG4"); echo KEEPUEQG4'
  '{ curl --u=user:"SYNTHUEQG5"; echo KEEPUEQG5; }'
  '(curl --user=user:"SYNTHUEQG6"}); echo KEEPUEQG6'
  '(curl -u=user:"SYNTHUEQG7\"TAILUEQG7"); echo KEEPUEQG7'
  "(curl -u=user:'SYNTHUEQG8\\'TAILUEQG8'); echo KEEPUEQG8"
  "(curl -u=user:'SYNTHUEQG9'); echo KEEPUEQG9"
  'x=$(curl --u=user:"SYNTHUEQG10"); echo KEEPUEQG10'
)
glued_user_equals_expected=(
  'curl -u=***REDACTED***; echo KEEPUEQ1'
  'curl --u=***REDACTED***; echo KEEPUEQ2'
  'curl --user=***REDACTED***; echo KEEPUEQ3'
  'curl -u=***REDACTED***; echo KEEPUEQ4'
  'curl --u=***REDACTED***; echo KEEPUEQ5'
  'curl --user=***REDACTED***; echo KEEPUEQ6'
  'curl -u=***REDACTED***; echo KEEPUEQ7'
  'curl --u=***REDACTED***; echo KEEPUEQ8'
  'curl --user=***REDACTED***; echo KEEPUEQ9'
  'curl -u=***REDACTED*** https://x; echo KEEPUEQ10'
  'curl --u=***REDACTED*** https://x; echo KEEPUEQ11'
  'curl --user=***REDACTED*** https://x; echo KEEPUEQ12'
  'curl -u=***REDACTED***; echo KEEPUEQ13'
  'curl --u=***REDACTED***; echo KEEPUEQ14'
  'curl --user=***REDACTED***; echo KEEPUEQ15'
  'curl -u=***REDACTED***; echo KEEPUEQ16'
  'curl --u=***REDACTED***; echo KEEPUEQ17'
  'curl --user=***REDACTED***; echo KEEPUEQ18'
  'curl -u=***REDACTED***; echo KEEPUEQ19'
  'curl --u=***REDACTED***; echo KEEPUEQ20'
  'curl --user=***REDACTED***; echo KEEPUEQ21'
  'curl -u=***REDACTED***; echo KEEPE22'
  '(curl -u=***REDACTED***); echo KEEPUEQG1'
  '(curl --u=***REDACTED***); echo KEEPUEQG2'
  '(curl --user=***REDACTED***); echo KEEPUEQG3'
  'x=$(curl -u=***REDACTED***); echo KEEPUEQG4'
  '{ curl --u=***REDACTED***; echo KEEPUEQG5; }'
  '(curl --user=***REDACTED***}); echo KEEPUEQG6'
  '(curl -u=***REDACTED***); echo KEEPUEQG7'
  '(curl -u=***REDACTED***); echo KEEPUEQG8'
  '(curl -u=***REDACTED***); echo KEEPUEQG9'
  'x=$(curl --u=***REDACTED***); echo KEEPUEQG10'
)
for case_index in "${!glued_user_equals_fixtures[@]}"; do
  fixture=${glued_user_equals_fixtures[$case_index]}
  expected=${glued_user_equals_expected[$case_index]}
  expect_exact "glued user equals $case_index" "$fixture" "$expected"
  expect_exact "glued user equals second pass $case_index" "$expected" "$expected"
  printf '%s\n' "$expected" | bash -n || fail "glued user equals $case_index is not valid shell: $expected"
done

# Marker-shaped prefixes are still live credentials when the whole value is not
# a canonical redaction marker.
expect_exact 'live credential starting with star' \
  'curl -H "Authorization: Bearer *SYNTHSTAR14"; echo KEEPSTAR14' \
  'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPSTAR14'
expect_exact 'idempotent live credential starting with star' \
  'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPSTAR14' \
  'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPSTAR14'
expect_exact 'live credential starting with at' \
  'curl -H "Authorization: Bearer @SYNTHAT15"; echo KEEPAT15' \
  'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPAT15'
expect_exact 'idempotent live credential starting with at' \
  'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPAT15' \
  'curl -H "Authorization: Bearer ***REDACTED***"; echo KEEPAT15'

# A user name without a password and unrelated flag clusters stay verbatim.
grouped_negative_fixtures=(
  '(curl --user SYNTHGRP3); echo KEEPGRP3'
  '(curl --user=1000); echo KEEPGRPN1'
  '(curl --url https://x); echo KEEPGRPN2'
  '(curl -uvVALUE https://x); echo KEEPGRPN3'
  'mkdir -pkeep; echo KEEPGRPN4'
  "mysql -P3306 -e 'select 1'; echo KEEPGRPN5"
)
for case_index in "${!grouped_negative_fixtures[@]}"; do
  fixture=${grouped_negative_fixtures[$case_index]}
  expect_exact "grouped non-credential $case_index" "$fixture" "$fixture"
  printf '%s\n' "$fixture" | bash -n || fail "grouped non-credential $case_index is not valid shell: $fixture"
done

# A shell continuation can split a credential across physical lines. The
# redactor shields each continuation outside single quotes with a per-call
# alphanumeric token, runs the line rules, then restores the token to
# backslash-newline. Inside single quotes the backslash is literal, so those
# lines stay as they are unless they hold a complete header prefix (a value
# split); an even number of trailing backslashes is an escaped backslash.
# The --user= whitespace rule still covers shielded splits such as
# --user=SHIELD alice:SECRET.
split_continuation_fixtures=(
  $'curl --user=ali\\\nce:SECRETJOIN1; echo MARKJ1'
  $'curl -u \\\nalice:SECRETJOIN2; echo MARKJ2'
  $'curl --user=\\\n alice:SECRETCONT123; echo MARKCONT'
  $'curl --user=ali\\\n ce:SECRETMID123; echo MARKMID'
  'curl --user=alice:SECRETPLAIN123; echo MARKPLAIN'
  $'curl --user=alice:SECRETIN123\\\n; echo MARKIN'
  $'curl --user=alice:SECRETEVEN123\\\\\necho MARKEVEN'
  $'curl --user=alice:***REDACTED***\\\n; echo MARKMASKED'
  $'Authorization: ***REDACTED***; curl --user=ali\\\nce:SECRETSPLIT9; echo MARKSPLIT9'
  $'Authorization: Bearer HALFA\\\nHALFB10; echo TAILA10'
  $'curl -H "X-Api-Key: HALFA\\\nHALFB1" https://x; echo TAILQ1'
  $'curl -H \'X-Api-Key: HALFA\\\nHALFB1\' https://x; echo TAILQ1'
  $'curl -H "X-Api-Key: \'HALFA\\\nHALFB1\'" https://x; echo TAILQ1'
)
split_continuation_expected=(
  $'curl --user=ali\\\nce:***REDACTED***; echo MARKJ1'
  $'curl -u \\\nalice:***REDACTED***; echo MARKJ2'
  'curl --user=***REDACTED***; echo MARKCONT'
  'curl --user=***REDACTED***; echo MARKMID'
  'curl --user=alice:***REDACTED***; echo MARKPLAIN'
  'curl --user=alice:***REDACTED***; echo MARKIN'
  $'curl --user=alice:***REDACTED***\necho MARKEVEN'
  'curl --user=alice:***REDACTED***; echo MARKMASKED'
  $'Authorization: ***REDACTED***; curl --user=ali\\\nce:***REDACTED***; echo MARKSPLIT9'
  'Authorization: Bearer ***REDACTED***; echo TAILA10'
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo TAILQ1'
  "curl -H 'X-Api-Key: ***REDACTED***' https://x; echo TAILQ1"
  'curl -H "X-Api-Key: ***REDACTED***" https://x; echo TAILQ1'
)
split_continuation_secrets=(
  SECRETJOIN1 SECRETJOIN2 SECRETCONT123 SECRETMID123 SECRETPLAIN123
  SECRETIN123 SECRETEVEN123 NOTPRESENT SECRETSPLIT9
  HALFB10 HALFB1 HALFB1 HALFB1
)
split_continuation_tails=(
  'echo MARKJ1' 'echo MARKJ2' 'echo MARKCONT' 'echo MARKMID' 'echo MARKPLAIN'
  'echo MARKIN' 'echo MARKEVEN' 'echo MARKMASKED' 'echo MARKSPLIT9'
  'echo TAILA10' 'echo TAILQ1' 'echo TAILQ1' 'echo TAILQ1'
)
for case_index in "${!split_continuation_fixtures[@]}"; do
  fixture=${split_continuation_fixtures[$case_index]}
  expected=${split_continuation_expected[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "split continuation $case_index is not valid shell: $fixture"
  printf '%s\n' "$expected" | bash -n || fail "split continuation $case_index expected is not valid shell: $expected"
  expect_exact "split continuation $case_index" "$fixture" "$expected"
  expect_exact "split continuation second pass $case_index" "$expected" "$expected"
  expect_idempotent_shell "split continuation $case_index" "$fixture" \
    "${split_continuation_secrets[$case_index]}" "${split_continuation_tails[$case_index]}"
done

# CRLF continuations keep their CR bytes. A masked credential consumes the
# shield; non-credential text and literal single-quoted backslashes survive
# byte-for-byte, including on a second pass.
crlf_dir="$cfg_tmp/crlf"
mkdir -p "$crlf_dir"
crlf_redact_file() { # input output
  bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; __lmline_next_realm_shield_prefix; __lmline_redact_clip_text "$__LMLINE_REALM_SHIELD_PREFIX"' _ \
    "$repo_dir/lmline/actions.bash" <"$1" >"$2"
}
crlf_case() {
  local label=$1 input=$2 expected=$3 secret=$4 tail=$5 actual="$crlf_dir/actual"
  crlf_redact_file "$input" "$actual" || fail "$label: redaction failed"
  if ! cmp -s "$actual" "$expected"; then
    printf 'not ok - %s bytes; expected:\n' "$label" >&2
    od -An -tx1 "$expected" >&2
    printf 'actual:\n' >&2
    od -An -tx1 "$actual" >&2
    fail "$label: exact bytes changed"
  fi
  grep -q $'\r' "$actual" || fail "$label: lost CR bytes"
  [[ -z $secret ]] || ! grep -Fq "$secret" "$actual" || fail "$label: leaked $secret"
  grep -Fq "$tail" "$actual" || fail "$label: lost $tail"
  crlf_redact_file "$actual" "$crlf_dir/second" || fail "$label: second pass failed"
  cmp -s "$crlf_dir/second" "$actual" || fail "$label: second pass changed bytes"
  ok "$label"
}

printf 'curl -H "X-API-Key: HALFAC\\\r\nHALFBC" https://x; echo TAILC\r\n' >"$crlf_dir/masked.in"
printf 'curl -H "X-API-Key: ***REDACTED***" https://x; echo TAILC\r\n' >"$crlf_dir/masked.expected"
crlf_case 'CRLF split credential' "$crlf_dir/masked.in" "$crlf_dir/masked.expected" HALF 'echo TAILC'

printf 'echo foo\\\r\nbar; echo TAILNC\r\n' >"$crlf_dir/plain.in"
cp "$crlf_dir/plain.in" "$crlf_dir/plain.expected"
crlf_case 'CRLF non-credential continuation' "$crlf_dir/plain.in" "$crlf_dir/plain.expected" '' 'echo TAILNC'

printf 'echo KEEPPLAIN\r\n' >"$crlf_dir/line.in"
cp "$crlf_dir/line.in" "$crlf_dir/line.expected"
crlf_case 'CRLF non-continuation line' "$crlf_dir/line.in" "$crlf_dir/line.expected" '' 'echo KEEPPLAIN'

printf "echo 'abc\\\r\ndef'; echo TAILS\r\n" >"$crlf_dir/single.in"
cp "$crlf_dir/single.in" "$crlf_dir/single.expected"
crlf_case 'CRLF literal single-quoted backslash' "$crlf_dir/single.in" "$crlf_dir/single.expected" '' 'echo TAILS'

printf "%s\r\n" "curl -H 'X-Api-Key: HALFA\\" "HALFB1' https://x; echo TAILQ1" >"$crlf_dir/single-split.in"
printf "%s\r\n" "curl -H 'X-Api-Key: ***REDACTED***' https://x; echo TAILQ1" >"$crlf_dir/single-split.expected"
crlf_case 'CRLF single-quoted split credential' "$crlf_dir/single-split.in" "$crlf_dir/single-split.expected" HALFB1 'echo TAILQ1'

# Single-quoted literals keep their backslash-newline byte-for-byte: the
# backslash is literal inside single quotes, not a continuation. The printf
# format string and an unquoted non-credential continuation are the same
# controls: no masking, second pass identical, valid shell.
shield_preservation_fixtures=(
  $'echo \'abc\\\ndef\'; echo TAILSQ'
  $'printf \'%s\\\nEND\''
  $'echo foo\\\nbar; echo TAILNC'
)
for case_index in "${!shield_preservation_fixtures[@]}"; do
  fixture=${shield_preservation_fixtures[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "shield preservation $case_index is not valid shell: $fixture"
  expect_exact "shield preservation $case_index" "$fixture" "$fixture"
  expect_exact "shield preservation second pass $case_index" "$fixture" "$fixture"
  preserved=$(redact_clip_line "$fixture") || fail "shield preservation $case_index redaction failed"
  [[ $preserved == "$fixture" ]] || fail "shield preservation $case_index changed bytes: $preserved"
  printf '%s\n' "$preserved" | bash -n || fail "shield preservation $case_index output is not valid shell: $preserved"
  [[ $preserved != *'***REDACTED***'* ]] || fail "shield preservation $case_index over-masked: $preserved"
done

# Open-quote continuations keep the logical line joined: a buffered prefix
# that ends inside a quote is not flushed even when the next line starts a
# header, so the closing quote and command tail survive with valid syntax.
open_quote_fixture=$'echo "hello\\\nAuthorization: Bearer SECRETN2"; echo TAILN2'
open_quote_expected=$'echo "hello\\\nAuthorization: Bearer ***REDACTED***"; echo TAILN2'
printf '%s\n' "$open_quote_fixture" | bash -n || fail "open-quote flush fixture is not valid shell"
printf '%s\n' "$open_quote_expected" | bash -n || fail "open-quote flush expected is not valid shell"
expect_exact "open-quote flush" "$open_quote_fixture" "$open_quote_expected"
expect_exact "open-quote flush second pass" "$open_quote_expected" "$open_quote_expected"
expect_idempotent_shell "open-quote flush" "$open_quote_fixture" "SECRETN2" "echo TAILN2"

# Single-quoted credential splits are joined via the header-aware gate:
# -u/--user, --password, spaced Authorization, api_key and key assignments
# mask fully with tails preserved; ordinary literals stay byte-identical.
single_quote_cred_fixtures=(
  $'curl -u \'alice:PASSA\\\nWORDA\' https://x; echo TAILUA'
  $'mysql --password \'PASSA\\\nWORDA\'; echo TAILPA'
  $'export \'MYKEY=PASSA\\\nWORDA\'; echo TAILKE'
  $'curl -H \'Authorization : Bearer HALFS\\\nHALFT\' https://x; echo TAILH1'
  $'curl -H \'api_key: SECRETK1\\\nSECRETK2\' https://x; echo TAILK'
)
single_quote_cred_expected=(
  "curl -u 'alice:***REDACTED***' https://x; echo TAILUA"
  "mysql --password '***REDACTED***'; echo TAILPA"
  "export 'MYKEY=***REDACTED***'; echo TAILKE"
  "curl -H 'Authorization : Bearer ***REDACTED***' https://x; echo TAILH1"
  "curl -H 'api_key: ***REDACTED***' https://x; echo TAILK"
)
single_quote_cred_secrets=(
  PASSA PASSA PASSA HALFS SECRETK1
)
single_quote_cred_tails=(
  'echo TAILUA' 'echo TAILPA' 'echo TAILKE' 'echo TAILH1' 'echo TAILK'
)
for case_index in "${!single_quote_cred_fixtures[@]}"; do
  fixture=${single_quote_cred_fixtures[$case_index]}
  expected=${single_quote_cred_expected[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "single-quote cred $case_index is not valid shell: $fixture"
  printf '%s\n' "$expected" | bash -n || fail "single-quote cred $case_index expected is not valid shell: $expected"
  expect_exact "single-quote cred $case_index" "$fixture" "$expected"
  expect_exact "single-quote cred second pass $case_index" "$expected" "$expected"
  expect_idempotent_shell "single-quote cred $case_index" "$fixture" "${single_quote_cred_secrets[$case_index]}" "${single_quote_cred_tails[$case_index]}"
done

# Non-credential single-quoted backslash-newlines stay byte-identical.
noncred_fixtures=(
  $'echo \'abc\\\ndef\''
  $'printf \'%s\\\nEND\''
)
for case_index in "${!noncred_fixtures[@]}"; do
  fixture=${noncred_fixtures[$case_index]}
  printf '%s\n' "$fixture" | bash -n || fail "non-credential control $case_index is not valid shell: $fixture"
  expect_exact "non-credential control $case_index" "$fixture" "$fixture"
  expect_exact "non-credential control second pass $case_index" "$fixture" "$fixture"
  preserved=$(redact_clip_line "$fixture") || fail "non-credential control $case_index redaction failed"
  [[ $preserved == "$fixture" ]] || fail "non-credential control $case_index changed bytes: $preserved"
  printf '%s\n' "$preserved" | bash -n || fail "non-credential control $case_index output is not valid shell: $preserved"
  [[ $preserved != *'***REDACTED***'* ]] || fail "non-credential control $case_index over-masked: $preserved"
done

# Pasted continuation tokens survive byte-identical via protection tokens.
deterministic_prefix='@@LMLINE_REALM_SHIELD_99_99_'
deterministic_raw="LMLINECONT${deterministic_prefix//[^A-Za-z0-9]/}"
for suffix in LF CR P ""; do
  token="${deterministic_raw}${suffix}"
  fixture="echo ${token} tail; echo KEEPTOK"
  actual=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$3" | __lmline_redact_clip_text "$2"' _ "$repo_dir/lmline/actions.bash" "$deterministic_prefix" "$fixture") || fail "token collision $suffix redaction failed"
  [[ $actual == "$fixture" ]] || fail "token collision $suffix changed bytes: $actual"
  printf '%s\n' "$actual" | bash -n || fail "token collision $suffix output is not valid shell: $actual"
  second=$(bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; printf "%s\n" "$3" | __lmline_redact_clip_text "$2"' _ "$repo_dir/lmline/actions.bash" "$deterministic_prefix" "$actual") || fail "token collision $suffix second pass failed"
  [[ $second == "$actual" ]] || fail "token collision $suffix second pass changed bytes: $second"
done
ok "token collision protection"


# The shield nonce must be unique per clip call even in zsh command substitution.
if command -v zsh >/dev/null 2>&1; then
  zsh_marker_out=$(zsh -c 'unset RANDOM; source "$1"; __lmline_next_realm_shield_prefix; first=$__LMLINE_REALM_SHIELD_PREFIX; __lmline_next_realm_shield_prefix; second=$__LMLINE_REALM_SHIELD_PREFIX; [[ $first != $second ]] || exit 11; fixture="curl \"https://x/?Authorization=${first}FOO@@\" ; echo KEEPZSHCLIP"; printf "%s\n" "$fixture" | __lmline_redact_clip_text "$second"' _ "$repo_dir/lmline/actions.bash") || fail "zsh realm shield nonce is not per-invocation"
  grep -Fq 'echo KEEPZSHCLIP' <<<"$zsh_marker_out" || fail "zsh pasted shield marker lost its command tail"
  grep -Fq '@@LMLINE_REALM_SHIELD_' <<<"$zsh_marker_out" || fail "zsh pasted shield marker was rewritten"
  ! grep -Fq '***REDACTED***' <<<"$zsh_marker_out" || fail "zsh pasted shield marker was treated as a credential"
  ok "zsh realm shield nonce is per-invocation"
fi

# Long backslash continuations complete in linear time. A quadratic
# preprocessor rescanned the whole buffer per line and took seconds for a
# few hundred lines; the bounded incremental state finishes well under a
# second and passes non-credential bytes through unchanged.
long_cont_tmp="$cfg_tmp/long_cont.in"
long_cont_out="$cfg_tmp/long_cont.out"
{ for _ in $(seq 1 400); do printf 'echo \\\n'; done; printf 'done\n'; } >"$long_cont_tmp"
long_cont_start=$SECONDS
bash -c '__lmline_tmp_root() { :; }; __lmline_engine_error_message() { :; }; source "$1"; __lmline_next_realm_shield_prefix; __lmline_redact_clip_text "$__LMLINE_REALM_SHIELD_PREFIX"' _ \
  "$repo_dir/lmline/actions.bash" <"$long_cont_tmp" >"$long_cont_out" || fail "long continuation redaction failed"
long_cont_elapsed=$(( SECONDS - long_cont_start ))
(( long_cont_elapsed <= 3 )) || fail "long continuation took ${long_cont_elapsed}s, expected <=3s"
cmp -s "$long_cont_tmp" "$long_cont_out" || fail "long continuation changed bytes"
ok "long continuation linear"


# Command-specific credential arguments come from the installed policy TSV.
# Values are assembled from parts so no secret-shaped literal enters the tree.
arg_word='SECRET'
arg_tail='TTT'
d1="${arg_word}${arg_tail}141"
d2="${arg_word}${arg_tail}142"
d3="${arg_word}${arg_tail}143"
d4="${arg_word}${arg_tail}144"
r1="${arg_word}${arg_tail}145"
o1="${arg_word}${arg_tail}146"
o2="${arg_word}${arg_tail}147"
a1="${arg_word}${arg_tail}148"
d5="${arg_word}${arg_tail}149"
custom1="${arg_word}${arg_tail}152"

docker_attached="docker login -p${d1} --username alice; echo KEEP141"
docker_separated="docker login -p ${d2} --username alice; echo KEEP142"
docker_quoted="docker login --password \"${d3}\" --username alice; echo KEEP143"
docker_long="docker login --password ${d4} --username alice; echo KEEP144"
redis_port="redis-cli -a ${r1} -p 6379; echo KEEP145"
openssl_key="openssl enc -aes-256-cbc -k ${o1} -in input.txt; echo KEEP146"
openssl_long="openssl enc -passin ${o2} -aes-256-cbc; echo KEEP147"
aws_key="aws configure set aws_secret_access_key ${a1}; echo KEEP148"

expect_masked 'docker attached password' "$docker_attached" "$d1" 'echo KEEP141'
expect_exact 'docker attached password output' "$docker_attached" \
  "docker login -p***REDACTED*** --username alice; echo KEEP141"
expect_masked 'docker separated password' "$docker_separated" "$d2" 'echo KEEP142'
expect_exact 'docker separated password output' "$docker_separated" \
  "docker login -p ***REDACTED*** --username alice; echo KEEP142"
expect_masked 'docker long quoted password' "$docker_quoted" "$d3" 'echo KEEP143'
expect_exact 'docker long quoted password output' "$docker_quoted" \
  "docker login --password \"***REDACTED***\" --username alice; echo KEEP143"
expect_masked 'docker long separated password' "$docker_long" "$d4" 'echo KEEP144'
expect_exact 'docker long separated password output' "$docker_long" \
  "docker login --password ***REDACTED*** --username alice; echo KEEP144"
expect_masked 'redis password keeps later port' "$redis_port" "$r1" '6379'
expect_exact 'redis password output' "$redis_port" \
  "redis-cli -a ***REDACTED*** -p 6379; echo KEEP145"
expect_masked 'openssl enc key' "$openssl_key" "$o1" 'echo KEEP146'
expect_exact 'openssl enc key output' "$openssl_key" \
  "openssl enc -aes-256-cbc -k ***REDACTED*** -in input.txt; echo KEEP146"
expect_masked 'openssl longest-match flag' "$openssl_long" "$o2" 'echo KEEP147'
expect_exact 'openssl longest-match flag output' "$openssl_long" \
  "openssl enc -passin ***REDACTED*** -aes-256-cbc; echo KEEP147"
expect_masked 'aws positional key' "$aws_key" "$a1" 'echo KEEP148'
expect_exact 'aws positional key output' "$aws_key" \
  "aws configure set aws_secret_access_key ***REDACTED***; echo KEEP148"

expect_idempotent_shell 'docker attached idempotent' "$docker_attached" "$d1" 'echo KEEP141'
expect_idempotent_shell 'docker long quoted idempotent' "$docker_quoted" "$d3" 'echo KEEP143'
expect_idempotent_shell 'redis port idempotent' "$redis_port" "$r1" '6379'
expect_idempotent_shell 'openssl key idempotent' "$openssl_key" "$o1" 'echo KEEP146'
expect_idempotent_shell 'aws positional idempotent' "$aws_key" "$a1" 'echo KEEP148'

# Commands without a policy row keep their unrelated -p flags untouched.
expect_exact 'unrelated docker build -p stays intact' \
  "docker build -p ${d5}; echo KEEP149" "docker build -p ${d5}; echo KEEP149"
expect_exact 'psql -p stays intact' \
  'psql -p 5432 -c "echo KEEP150"' 'psql -p 5432 -c "echo KEEP150"'
expect_exact 'redis port without credential stays intact' \
  'redis-cli -p 6379 info; echo KEEP151' 'redis-cli -p 6379 info; echo KEEP151'

# Bare operands do not end the argument scan, and each command occurrence
# masks every credential in its own argument list. Keep controls prove that
# the same flag spelling stays intact for commands without a policy row.
op1="${arg_word}${arg_tail}153"
op2="${arg_word}${arg_tail}154"
op3="${arg_word}${arg_tail}155"
op4="${arg_word}${arg_tail}156"
op5="${arg_word}${arg_tail}157"
op6="${arg_word}${arg_tail}158"
op7="${arg_word}${arg_tail}159"
op8="${arg_word}${arg_tail}160"
op9="${arg_word}${arg_tail}161"
op10="${arg_word}${arg_tail}162"

docker_operand="docker login registry.example.invalid -p ${op1}; echo KEEP153"
docker_repeat="docker login -p '${op2}' -p '${op3}'; echo KEEP154"
redis_operand="redis-cli key1 -a ${op4} -p 6379 -a ${op5}; echo KEEP155"
openssl_operand="openssl enc -aes-256-cbc input.txt -k ${op6} -K ${op7}; echo KEEP156"
aws_multi="aws configure set --profile dev aws_secret_access_key ${op8} aws_access_key_id ${op9}; echo KEEP157"
shell_wrapped="bash -c \"docker login registry.example.invalid -p ${op10}; echo KEEP158\""

expect_masked 'docker registry operand keeps later password masked' "$docker_operand" "$op1" 'echo KEEP153'
expect_exact 'docker registry operand output' "$docker_operand" \
  "docker login registry.example.invalid -p ***REDACTED***; echo KEEP153"
expect_masked 'docker repeated password second value masked' "$docker_repeat" "$op3" 'echo KEEP154'
expect_exact 'docker repeated password output' "$docker_repeat" \
  "docker login -p '***REDACTED***' -p '***REDACTED***'; echo KEEP154"
expect_masked 'redis operand keeps later password masked' "$redis_operand" "$op5" '6379'
expect_exact 'redis operand output' "$redis_operand" \
  "redis-cli key1 -a ***REDACTED*** -p 6379 -a ***REDACTED***; echo KEEP155"
expect_masked 'openssl operand keeps later key masked' "$openssl_operand" "$op7" 'echo KEEP156'
expect_exact 'openssl operand output' "$openssl_operand" \
  "openssl enc -aes-256-cbc input.txt -k ***REDACTED*** -K ***REDACTED***; echo KEEP156"
expect_masked 'aws profile option keeps later keys masked' "$aws_multi" "$op9" 'echo KEEP157'
expect_exact 'aws profile option output' "$aws_multi" \
  "aws configure set --profile dev aws_secret_access_key ***REDACTED*** aws_access_key_id ***REDACTED***; echo KEEP157"
expect_masked 'quoted command keeps inner credential masked' "$shell_wrapped" "$op10" 'echo KEEP158'
expect_exact 'quoted command output' "$shell_wrapped" \
  "bash -c \"docker login registry.example.invalid -p ***REDACTED***; echo KEEP158\""

expect_idempotent_shell 'docker operand idempotent' "$docker_operand" "$op1" 'echo KEEP153'
expect_idempotent_shell 'docker repeated idempotent' "$docker_repeat" "$op3" 'echo KEEP154'
expect_idempotent_shell 'redis operand idempotent' "$redis_operand" "$op5" '6379'
expect_idempotent_shell 'openssl operand idempotent' "$openssl_operand" "$op7" 'echo KEEP156'
expect_idempotent_shell 'aws profile idempotent' "$aws_multi" "$op9" 'echo KEEP157'

expect_exact 'docker run port stays intact' \
  'docker run -d -p 3000:3000 image; echo KEEP159' \
  'docker run -d -p 3000:3000 image; echo KEEP159'
expect_exact 'aws non-credential setting stays intact' \
  'aws configure set region us-east-1; echo KEEP160' \
  'aws configure set region us-east-1; echo KEEP160'
expect_exact 'openssl key file stays intact' \
  'openssl enc -kfile keyfile -in input.txt; echo KEEP161' \
  'openssl enc -kfile keyfile -in input.txt; echo KEEP161'

# An explicit policy file overrides the installed defaults; an unreadable one
# stops redaction instead of sending pasted text unmasked.
custom_policy="$cfg_tmp/credential_arguments.tsv"
printf 'mytool\tx\t\t\n' >"$custom_policy"
custom_out=$(LMLINE_CREDENTIAL_ARGUMENTS_FILE="$custom_policy" \
  redact_clip_line "mytool -x ${custom1}; echo KEEP152") || fail 'explicit policy redaction failed'
[[ $custom_out == "mytool -x ***REDACTED***; echo KEEP152" ]] ||
  fail "explicit policy was not applied: $custom_out"
if LMLINE_CREDENTIAL_ARGUMENTS_FILE="$cfg_tmp/missing-credential-arguments.tsv" \
   redact_clip_line "$docker_attached" >/dev/null 2>&1; then
  fail 'unreadable credential arguments file did not fail closed'
fi
invalid_policy="$cfg_tmp/invalid-credential-arguments.tsv"
printf 'mytool\tx|y\t\t\n' >"$invalid_policy"
if LMLINE_CREDENTIAL_ARGUMENTS_FILE="$invalid_policy" \
   redact_clip_line "$docker_attached" >/dev/null 2>&1; then
  fail 'invalid credential arguments row did not fail closed'
fi
ok "command credential arguments"

ok "clip cli"
