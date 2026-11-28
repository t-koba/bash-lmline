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
grep -Fxq 'Authorization: ***REDACTED*** 2>err; echo KEEPFDNUM123' "$line_file" || exit 411
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
grep -Fxq 'Note LMLINE_REALM_EQ_SENTINEL is only a temporary marker.' "$line_file" || exit 1253
grep -Fxq 'Note @@LMLINE_REALM_SHIELD_FOO@@ stays intact.' "$line_file" || exit 1254
grep -Fxq -- 'curl "https://x/?Authorization:@@LMLINE_REALM_SHIELD_FOO@@" ; echo KEEPPASTEDSHIELD' "$line_file" || exit 1257
grep -Fxq -- 'curl "https://x/?Authorization:@@LMLINE_REALM_SHIELD_FOO@@\"example.com\"; echo KEEPPASTEDSHIELDGLUED' "$line_file" || exit 1258
grep -Fxq '?Authorization:REALM="example.com"; echo KEEPREALMCASE' "$line_file" || exit 1255
grep -Fxq -- 'url=https://x/?Authorization:realm="example.com"; echo KEEPCOLONEQREALM' "$line_file" || exit 1256
grep -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPURLAMP1' "$line_file" || exit 889
grep -Fq SYNTHURLAMP1 "$line_file" && exit 890
grep -Fxq -- 'url=https://x/?a=1;Authorization:***REDACTED***' "$line_file" || exit 891
grep -Fq SYNTHURLSEMI1 "$line_file" && exit 892
grep -Fxq -- 'url=https://x/?a=1,Authorization:***REDACTED***' "$line_file" || exit 893
grep -Fq SYNTHURLCOMMA1 "$line_file" && exit 894
grep -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***' "$line_file" || exit 895
grep -Fq SYNTHURLBEARER1 "$line_file" && exit 896
grep -Fxq 'Authorization: Bearer="***REDACTED***";token=***REDACTED***; echo KEEPEQCHAIN' "$line_file" || exit 737
grep -Fxq -- 'curl -H "Authorization: Bearer ***REDACTED***"; curl "https://x/?a=1&Authorization:***REDACTED***"' "$line_file" || exit 897
grep -Fq SYNTHURLSAME2 "$line_file" && exit 898
grep -Fxq -- 'curl "https://x/?a=1&Authorization:***REDACTED***"' "$line_file" || exit 899
grep -Fq SYNTHURLDQ2 "$line_file" && exit 900
grep -Fxq -- "curl 'https://x/?a=1&Authorization:***REDACTED***'" "$line_file" || exit 901
grep -Fq SYNTHURLSQ2 "$line_file" && exit 902
grep -Fxq -- 'curl "https://x/?a=1&Authorization:***REDACTED***"; echo KEEPURLSP2' "$line_file" || exit 903
grep -Fq SYNTHURLSP2 "$line_file" && exit 904
grep -Fq 'SYNTHEQCHAIN' "$line_file" && exit 738
grep -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPURLCOLEND1' "$line_file" || exit 905
grep -Fq SYNTHCOLEND1 "$line_file" && exit 906
grep -Fxq -- 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPURLEQEND1' "$line_file" || exit 907
grep -Fq SYNTHEQEND1 "$line_file" && exit 908
grep -Fxq -- "curl 'https://x/?a=1&Authorization:***REDACTED***'; echo KEEPURLCOLQUOTE1" "$line_file" || exit 909
grep -Fq SYNTHCOLQUOTE1 "$line_file" && exit 910
grep -Fq U1lOVEhCQVNFNjQx== "$line_file" && exit 1200
grep -Fxq 'url=https://x/?a=1&Authorization:***REDACTED***; echo KEEPPADEQ1' "$line_file" || exit 1201
grep -Fq U1lOVEhCQVNFNjQy=== "$line_file" && exit 1202
grep -Fxq 'url=https://x/?a=1;Authorization:***REDACTED***; echo KEEPPADEQ2' "$line_file" || exit 1203
grep -Fq U1lOVEhCQVNFNjQz== "$line_file" && exit 1204
grep -Fxq 'url=https://x/?a=1,Authorization:***REDACTED***; echo KEEPPADEQ3' "$line_file" || exit 1205
grep -Fq U1lOVEhCQVNFNjQ0== "$line_file" && exit 1206
grep -Fxq "curl 'https://x/?a=1&Authorization:***REDACTED***'; echo KEEPPADEQ4" "$line_file" || exit 1207
grep -Fq U1lOVEhCQVNFNjQ1== "$line_file" && exit 1208
grep -Fxq 'curl "https://x/?a=1;Authorization:***REDACTED***"; echo KEEPPADEQ5' "$line_file" || exit 1209
grep -Fq U1lOVEhCQVNFNjQ2=== "$line_file" && exit 1210
grep -Fxq 'curl "https://x/?a=1&Authorization:***REDACTED***; echo KEEPPADEQ6"' "$line_file" || exit 1211
grep -Fq U1lOVEhCQVNFNjQ3=== "$line_file" && exit 1212
grep -Fxq "curl 'https://x/?a=1&Authorization:***REDACTED***; echo KEEPPADEQ7'" "$line_file" || exit 1213
grep -Fq U1lOVEhCQVNFNjQ4== "$line_file" && exit 1214
grep -Fxq 'curl "https://x/?a=1&Authorization:***REDACTED***"; echo KEEPPADEQ8' "$line_file" || exit 1215
grep -Fq U1lOVEhCQVNFNjQ5=== "$line_file" && exit 1216
grep -Fxq "curl 'https://x/?a=1&Authorization:***REDACTED***'; echo KEEPPADEQ9" "$line_file" || exit 1217
grep -Fq U1lOVEhCQVNFNjQ6= "$line_file" && exit 1218
grep -Fxq 'curl "https://x/?a=1&Authorization:***REDACTED***"; echo KEEPSINGLEEQ1' "$line_file" || exit 1219
grep -Fq U1lOVEhCQVNFNjQ7= "$line_file" && exit 1220
grep -Fxq "curl 'https://x/?a=1;Authorization:***REDACTED***'; echo KEEPSINGLEEQ2" "$line_file" || exit 1221
grep -Fq U1lOVEhCQVNFNjQ8= "$line_file" && exit 1222
grep -Fxq 'curl "https://x/?a=1,Authorization:***REDACTED***"; echo KEEPSINGLEEQ3' "$line_file" || exit 1223
grep -Fq U1lOVEhCQVFCMQ== "$line_file" && exit 1224
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"; echo TAILFQ1' "$line_file" || exit 1225
grep -Fq U1lOVEhCQVFCMg== "$line_file" && exit 1226
grep -Fxq "curl 'https://x/?Authorization:***REDACTED***'; echo TAILFQ2" "$line_file" || exit 1227
grep -Fq U1lOVEhCQVFCMw=== "$line_file" && exit 1228
grep -Fxq 'url=https://x/?Authorization:***REDACTED***; echo TAILFQ3' "$line_file" || exit 1229
grep -Fq U1lOVEhCQVFCNDo: "$line_file" && exit 1230
grep -Fxq 'url=https://x/?Authorization:***REDACTED***; echo TAILFQ4' "$line_file" || exit 1231
grep -Fq YWI= "$line_file" && exit 1232
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"; echo TAILB64ONE' "$line_file" || exit 1233
grep -Fq YWJjZGVmZ2hpamtsbW5vcHE= "$line_file" && exit 1234
grep -Fxq "curl 'https://x/?Authorization:***REDACTED***'; echo TAILB64LONG" "$line_file" || exit 1235
grep -Fq SYNTHSINGLEEQ4= "$line_file" && exit 1236
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"; echo TAILSINGLE4' "$line_file" || exit 1237
grep -Fq SYNTHSINGLEEQ5= "$line_file" && exit 1238
grep -Fxq "curl 'https://x/?Authorization:***REDACTED***'; echo TAILSINGLE5" "$line_file" || exit 1239
grep -Fq SYNTHESCAPED1= "$line_file" && exit 1240
grep -Fxq 'curl \"https://x/?Authorization:***REDACTED***\"; echo TAILESC' "$line_file" || exit 1241
grep -Fq SYNTHGT1= "$line_file" && exit 1242
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***">out; echo TAILGT' "$line_file" || exit 1243
grep -Fq SYNTHPAR1= "$line_file" && exit 1244
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"); echo TAILPAR' "$line_file" || exit 1245
grep -Fq SYNTHMULTIGT1== "$line_file" && exit 1246
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***">out; echo TAILMULTIGT' "$line_file" || exit 1247
grep -Fq U1lOVEhCQVFCMA== "$line_file" && exit 1248
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"]; echo KEEPBASE1' "$line_file" || exit 1249
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"?x=1; echo KEEPBASE2' "$line_file" || exit 1250
grep -Fq SYNTHSUFFIX1= "$line_file" && exit 1251
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"]; echo TAILSUFFIX1' "$line_file" || exit 1252
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
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPTAILAPOS987' "$line_file" || exit 959
grep -Fq 'LEAKAPOSTROPHE988' "$line_file" && exit 960
grep -Fxq 'Authorization: Custom=***REDACTED***; echo KEEPTAILCUSTOM988' "$line_file" || exit 961
grep -Fq 'LEAKDQUOTE989' "$line_file" && exit 962
grep -Fxq 'Authorization: Bearer=***REDACTED***; echo KEEPTAILDQUOTE989' "$line_file" || exit 963
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
grep -Fxq 'Authorization: Bearer ***REDACTED***; echo KEEPATSECRET123' "$line_file" || exit 9522
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
grep -Fxq 'Authorization: Bearer ***REDACTED***; echo KEEPHASH9020' "$line_file" || exit 9531
grep -Fq 'escapedTail9015' "$line_file" && exit 178
grep -Fxq 'curl -H "Authorization: Bearer ***REDACTED***" https://x; echo KEEPESC9015' "$line_file" || exit 9532
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
# Generic schemes must mask the credential and keep the following shell word.
grep -Fq SYNTHA1 "$line_file" && exit 9501
grep -Fxq 'curl -H "Authorization: ***REDACTED***" "PAYLOADA1"; echo TAILA1' "$line_file" || exit 9502
grep -Fq SYNTHS1 "$line_file" && exit 9503
grep -Fxq "curl -H 'Authorization: ***REDACTED***' 'PAYLOADS1'; echo TAILS1" "$line_file" || exit 9504
grep -Fq SYNTHX1 "$line_file" && exit 9505
grep -Fxq 'curl -H "Authorization: ***REDACTED***" --data "DATAX1"; echo TAILX1' "$line_file" || exit 9506
grep -Fq SYNTHC1 "$line_file" && exit 9507
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: KEEPC1" https://x; echo TAILC1' "$line_file" || exit 9508
grep -Fq SYNTHX2 "$line_file" && exit 9509
grep -Fxq "curl -H 'Authorization: ***REDACTED***' -H 'X: KEEPX2' https://x; echo TAILX2" "$line_file" || exit 9510
grep -Fq SYNTHM1 "$line_file" && exit 9511
grep -Fxq 'curl -H "Authorization: ***REDACTED***" https://x; echo TAILM1' "$line_file" || exit 9512
grep -Fq SYNTH2 "$line_file" && exit 9513
grep -Fxq 'curl -H "Authorization: ***REDACTED***" 2>err; echo TAIL2' "$line_file" || exit 9514
grep -Fq SYNTHG1 "$line_file" && exit 9515
grep -Fq GLUEDG1 "$line_file" && exit 9516
grep -Fxq 'curl -H "Authorization: Foo:***REDACTED***"; echo TAILG1' "$line_file" || exit 9517
grep -Fq SYNTHB1 "$line_file" && exit 9518
grep -Fxq 'curl -H "Authorization: ***REDACTED***" "PAYLOADB1"; echo TAILB1' "$line_file" || exit 9519
grep -Fq SYNTHBC1 "$line_file" && exit 9520
grep -Fxq 'curl -H "Authorization: ***REDACTED***" -H "X: KEEPC1" https://x; echo TAILBC1' "$line_file" || exit 9521
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
grep -Fxq 'Authorization: my_scheme:"***REDACTED***"; echo KEEPQUOTED1' "$line_file" || exit 9401
grep -Fq SYNTHQUOTED1 "$line_file" && exit 9402
grep -Fxq "Authorization: my_scheme:'***REDACTED***'; echo KEEPQUOTED2" "$line_file" || exit 9403
grep -Fq SYNTHQUOTED2 "$line_file" && exit 9404
grep -Fxq 'Authorization: 2Scheme="***REDACTED***"; echo KEEPQUOTED3' "$line_file" || exit 9405
grep -Fq SYNTHQUOTED3 "$line_file" && exit 9406
grep -Fxq "Authorization: 2Scheme='***REDACTED***'; echo KEEPQUOTED4" "$line_file" || exit 9407
grep -Fq SYNTHQUOTED4 "$line_file" && exit 9408
grep -Fxq 'Authorization: my_scheme:"***REDACTED***"; echo KEEPGLUEDQ1' "$line_file" || exit 9409
grep -Fq SYNTHGLUEDQ1 "$line_file" && exit 9410
grep -Fxq "Authorization: 2Scheme:'***REDACTED***'; echo KEEPGLUEDS1" "$line_file" || exit 9411
grep -Fq SYNTHGLUEDS1 "$line_file" && exit 9412
grep -Fxq 'Authorization: my_scheme:"***REDACTED***" "PAYLOADGLUEDQ2"; echo KEEPGLUEDQ2' "$line_file" || exit 9413
grep -Fq SYNTHGLUEDQ2 "$line_file" && exit 9414
grep -Fxq 'Authorization: my_scheme:"***REDACTED***"; Authorization: 2scheme:"***REDACTED***"; echo KEEPREPEATQ' "$line_file" || exit 9415
grep -Fq SYNTHREPEATQ1 "$line_file" && exit 9416
grep -Fq SYNTHREPEATQ2 "$line_file" && exit 9417
grep -Fxq 'Authorization: my_scheme:"***REDACTED***"|Authorization: 2scheme:"***REDACTED***"; echo KEEPREPEATPIPE' "$line_file" || exit 9418
grep -Fq SYNTHREPEATPIPE1 "$line_file" && exit 9419
grep -Fq SYNTHREPEATPIPE2 "$line_file" && exit 9420
grep -Fxq 'Authorization: my_scheme:"***REDACTED***" >out; Authorization: 2scheme:"***REDACTED***" <in; echo KEEPREPEATREDIR' "$line_file" || exit 9421
grep -Fq SYNTHREPEATREDIR1 "$line_file" && exit 9422
grep -Fq SYNTHREPEATREDIR2 "$line_file" && exit 9423
grep -Fxq "Authorization: my_scheme:'***REDACTED***'; Authorization: 2scheme:'***REDACTED***'; echo KEEPREPEATSQ" "$line_file" || exit 9424
grep -Fq SYNTHREPEATSQ1 "$line_file" && exit 9425
grep -Fq SYNTHREPEATSQ2 "$line_file" && exit 9426
grep -Fxq "Authorization: my_scheme:'***REDACTED***'|Authorization: 2scheme:'***REDACTED***'; echo KEEPREPEATSQPIPE" "$line_file" || exit 9427
grep -Fq SYNTHREPEATSQPIPE1 "$line_file" && exit 9428
grep -Fq SYNTHREPEATSQPIPE2 "$line_file" && exit 9429
grep -Fxq "Authorization: my_scheme:'***REDACTED***' >out; Authorization: 2scheme:'***REDACTED***' <in; echo KEEPREPEATSQREDIR" "$line_file" || exit 9430
grep -Fq SYNTHREPEATSQREDIR1 "$line_file" && exit 9431
grep -Fq SYNTHREPEATSQREDIR2 "$line_file" && exit 9432
grep -Fxq 'Authorization: my_scheme:"***REDACTED***"&Authorization: 2scheme:"***REDACTED***"; echo KEEPSEPAMP' "$line_file" || exit 9433
grep -Fq SYNTHSEPAMP1 "$line_file" && exit 9434
grep -Fq SYNTHSEPAMP2 "$line_file" && exit 9435
grep -Fxq 'Authorization: my_scheme:"***REDACTED***";Authorization: 2scheme:"***REDACTED***"; echo KEEPSEPSEMI' "$line_file" || exit 9436
grep -Fq SYNTHSEPSEMI1 "$line_file" && exit 9437
grep -Fq SYNTHSEPSEMI2 "$line_file" && exit 9438
grep -Fxq 'Authorization: my_scheme:"***REDACTED***",Authorization: 2scheme:"***REDACTED***"; echo KEEPSEPCOMMA' "$line_file" || exit 9439
grep -Fq SYNTHSEPCOMMA1 "$line_file" && exit 9440
grep -Fq SYNTHSEPCOMMA2 "$line_file" && exit 9441
grep -Fxq "Authorization: my_scheme:'***REDACTED***'&Authorization: 2scheme:'***REDACTED***'; echo KEEPSEPAMPSQ" "$line_file" || exit 9442
grep -Fq SYNTHSEPAMPSQ1 "$line_file" && exit 9443
grep -Fq SYNTHSEPAMPSQ2 "$line_file" && exit 9444
grep -Fxq 'echo "note Authorization: SYNTHNATQ1 ***REDACTED***"; echo KEEPNATQ1' "$line_file" || exit 9445
grep -Fq KEEPNATQ1 "$line_file" || exit 9446
grep -Fxq "echo 'note Authorization: SYNTHNATS1 ***REDACTED***'; echo KEEPNATS1" "$line_file" || exit 9447
grep -Fq KEEPNATS1 "$line_file" || exit 9448
grep -Fq 'more_secret456' "$line_file" && exit 129
grep -Fxq 'echo KEEPMORE456; Authorization: Bearer ***REDACTED***' "$line_file" || exit 9533
grep -Fq 'w0rd123SECRET' "$line_file" && exit 130
grep -Fxq 'echo KEEPWORD123; Authorization: Basic ***REDACTED***' "$line_file" || exit 9534
grep -Fxq 'Authorization: Bearer ***REDACTED***' "$line_file" || exit 127
grep -Fxq 'Authorization: ***REDACTED***' "$line_file" || exit 128
grep -Fq 'keyPlusHeaderValue123' "$line_file" && exit 100
grep -Fxq '{"api_key": "***REDACTED***", "Authorization": "Basic ***REDACTED***", "keep": "KEEPKEYPLUS"}' "$line_file" || exit 9535
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
grep -Fxq 'curl "https://x.test/a?token=***REDACTED***&keep=KEEPENC1"' "$line_file" || exit 330
grep -Fq 'encEqSecret9001' "$line_file" && exit 331
grep -Fxq 'curl "https://x.test/a?api-key=***REDACTED***&keep=KEEPENC2"' "$line_file" || exit 332
grep -Fq 'encEqSecret9002' "$line_file" && exit 333
grep -Fxq 'curl "https://x.test/a#token=***REDACTED***&keep=KEEPENC3"' "$line_file" || exit 334
grep -Fq 'encColonSecret9003' "$line_file" && exit 335
grep -Fxq 'curl "https://x.test/a?token=***REDACTED***&keep=KEEPENC4"' "$line_file" || exit 336
grep -Fq 'encSpaceSecret9004' "$line_file" && exit 337
grep -Fxq 'curl "https://x.test/a?redirect=https%3A//safe.test&keep=KEEPENC5"' "$line_file" || exit 338
grep -Fxq 'curl "https://x.test/a?Authorization:***REDACTED***&keep=KEEP0103"' "$line_file" || exit 339
grep -Fq 'AUTHENCSECRET0103' "$line_file" && exit 340
grep -Fxq "curl 'https://x.test/a?\"Authorization\":***REDACTED***&keep=KEEP0103'" "$line_file" || exit 341
grep -Fxq "curl 'https://x.test/a?\"token\"=***REDACTED***&keep=KEEP0201'" "$line_file" || exit 342
grep -Fq 'quotedKeySecret0201' "$line_file" && exit 343
grep -Fxq "curl \"https://x.test/a?'token'=***REDACTED***&keep=KEEP0202\"" "$line_file" || exit 344
grep -Fq 'quotedKeySecret0202' "$line_file" && exit 345
grep -Fq 'EscapedQuotedSecret0301' "$line_file" && exit 346
grep -Fq 'KEEPQ1' "$line_file" || exit 347
grep -Fq 'EscapedQuotedSecret0302' "$line_file" && exit 348
grep -Fq 'KEEPQ2' "$line_file" || exit 349
grep -Fq 'EscapedAuthSecret0303' "$line_file" && exit 350
grep -Fq 'KEEPQ3' "$line_file" || exit 351
grep -Fq 'EscapedAuthSecret0304' "$line_file" && exit 352
grep -Fq 'KEEPQ4' "$line_file" || exit 353
# Adjacent segments, quoted values and padded separators mask every secret and keep the tail.
grep -Fq 'SYNTHADJENCA1' "$line_file" && exit 480
grep -Fq 'SYNTHADJENCB1' "$line_file" && exit 481
grep -Fq 'KEEPADJENC1' "$line_file" || exit 482
grep -Fq 'SYNTHADJENCA2' "$line_file" && exit 483
grep -Fq 'SYNTHADJENCB2' "$line_file" && exit 484
grep -Fq 'KEEPADJENC2' "$line_file" || exit 485
grep -Fq 'SYNTHQUOTEENCA1' "$line_file" && exit 486
grep -Fq 'KEEPQUOTEENC1' "$line_file" || exit 487
grep -Fq 'SYNTHQUOTEENCA2' "$line_file" && exit 488
grep -Fq 'KEEPQUOTEENC2' "$line_file" || exit 489
grep -Fq 'SYNTHPADENCA1' "$line_file" && exit 490
grep -Fq 'KEEPPADENC1' "$line_file" || exit 491
grep -Fq 'SYNTHPADENCA2' "$line_file" && exit 492
grep -Fq 'KEEPPADENC2' "$line_file" || exit 493
grep -Fxq 'url=https://x/?a=1&Authorization:***REDACTED***&keep=KEEPSCHEMESPACE1' "$line_file" || exit 494
grep -Fq 'SYNTHSCHEMESPACE9001' "$line_file" && exit 495
grep -Fxq "url=https://x/?a=1&'Authorization':***REDACTED***&keep=KEEPSCHEMESPACE2" "$line_file" || exit 496
grep -Fq 'SYNTHSCHEMESPACE9002' "$line_file" && exit 497
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***" -H "X: keep"; echo KEEPQUOTETAIL9001' "$line_file" || exit 510
grep -Fq 'SYNTHQUOTEKEEP9001' "$line_file" && exit 511
grep -Fxq 'curl "https://x/?Authorization:***REDACTED***"' "$line_file" || exit 512
grep -Fq 'SYNTHQUOTEKEEP9002' "$line_file" && exit 513
grep -Fxq "curl 'https://x/?Authorization:***REDACTED***' -H 'X: keep'; echo KEEPQUOTETAIL9003" "$line_file" || exit 514
grep -Fq 'SYNTHQUOTEKEEP9003' "$line_file" && exit 515
grep -Fxq "curl \"https://x/?Authorization:***REDACTED***\" --data=' keep'; echo KEEPQUOTETAIL9004" "$line_file" || exit 516
grep -Fq 'SYNTHQUOTEKEEP9004' "$line_file" && exit 517
grep -Fxq 'url=https://x/?a=1&Authorization:***REDACTED***&keep=KEEPTAIL540' "$line_file" || exit 518
grep -Fq 'SYNTHESCDQ9003' "$line_file" && exit 519
grep -Fxq 'url=https://x/?a=1&token=***REDACTED***&keep=KEEPTAIL603' "$line_file" || exit 520
grep -Fq 'SYNTHKEY9008' "$line_file" && exit 521
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
grep -Fxq 'curl --user=***REDACTED***>out;echo KEEPOPS1' "$line_file" || exit 9154
grep -Fq 'SECOPS1' "$line_file" && exit 9155
grep -Fxq 'curl -u=user:***REDACTED***>>out;echo KEEPOPS2' "$line_file" || exit 9156
grep -Fq 'SECOPS2' "$line_file" && exit 9157
grep -Fxq 'curl --password ***REDACTED***<in;echo KEEPOPS3' "$line_file" || exit 9158
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
grep -Fxq 'mkdir -pkeep; echo KEEPPCMDB1' "$line_file" || exit 9190
grep -Fxq 'MKDIR -pKEEPUPPER; echo KEEPPCMDB2' "$line_file" || exit 9191
grep -Fxq 'ls -la -pKEEPPCMDB3; echo KEEPPCMDB3' "$line_file" || exit 9192
grep -Fxq 'echo PREPCMDB4; mysql -uadmin -p***REDACTED***; echo KEEPPCMDB4' "$line_file" || exit 9193
grep -Fq 'SYNTHPCMDB4' "$line_file" && exit 9194
grep -Fxq 'mkdir -pkeep; mysql -p***REDACTED***; mkdir -pkeep2' "$line_file" || exit 9195
grep -Fq 'SYNTHPCMDB5' "$line_file" && exit 9196
grep -Fxq '/usr/bin/mysql -p***REDACTED***; echo KEEPPCMDB6' "$line_file" || exit 9197
grep -Fq 'SYNTHPCMDB6' "$line_file" && exit 9198
grep -Fxq 'sudo /usr/local/bin/mysql -p***REDACTED***; echo KEEPPCMDB7' "$line_file" || exit 9199
grep -Fq 'SYNTHPCMDB7' "$line_file" && exit 9200
grep -Fxq 'echo $(mysql -p***REDACTED***); echo KEEPPCMDB8' "$line_file" || exit 9201
grep -Fq 'SYNTHPCMDB8' "$line_file" && exit 9202
grep -Fxq 'x=$(mariadb -p***REDACTED***); echo KEEPPCMDB9' "$line_file" || exit 9203
grep -Fq 'SYNTHPCMDB9' "$line_file" && exit 9204
grep -Fxq '(mysql -p***REDACTED***); echo KEEPPCMDB10' "$line_file" || exit 9205
grep -Fq 'SYNTHPCMDB10' "$line_file" && exit 9206
grep -Fxq 'MYSQL -p***REDACTED***; echo KEEPPCMDB11' "$line_file" || exit 9207
grep -Fq 'SYNTHPCMDB11' "$line_file" && exit 9208
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
expect_exact 'sshpass leaves later ssh port intact' "$sshpass_later_port" \
  "sshpass -p***REDACTED*** ssh -p 2222 host; echo ${sk22}"
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


# The shield nonce must be unique per clip call even in zsh command substitution.
if command -v zsh >/dev/null 2>&1; then
  zsh_marker_out=$(zsh -c 'unset RANDOM; source "$1"; __lmline_next_realm_shield_prefix; first=$__LMLINE_REALM_SHIELD_PREFIX; __lmline_next_realm_shield_prefix; second=$__LMLINE_REALM_SHIELD_PREFIX; [[ $first != $second ]] || exit 11; fixture="curl \"https://x/?Authorization=${first}FOO@@\" ; echo KEEPZSHCLIP"; printf "%s\n" "$fixture" | __lmline_redact_clip_text "$second"' _ "$repo_dir/lmline/actions.bash") || fail "zsh realm shield nonce is not per-invocation"
  grep -Fq 'echo KEEPZSHCLIP' <<<"$zsh_marker_out" || fail "zsh pasted shield marker lost its command tail"
  grep -Fq '@@LMLINE_REALM_SHIELD_' <<<"$zsh_marker_out" || fail "zsh pasted shield marker was rewritten"
  ! grep -Fq '***REDACTED***' <<<"$zsh_marker_out" || fail "zsh pasted shield marker was treated as a credential"
  ok "zsh realm shield nonce is per-invocation"
fi

ok "clip cli"
