#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: a failed redaction filter must never let clip text reach the model.

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-clip-redaction-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model

mkdir -p "$cfg_tmp/bin" "$cfg_tmp/config"
cat >"$cfg_tmp/bin/fakeclip-nonempty" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'REDACTIONFAILNONEMPTY=unredacted-line'
EOF
cat >"$cfg_tmp/bin/fakeclip-empty" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'REDACTIONFAILEMPTY=unredacted-line'
EOF
chmod +x "$cfg_tmp/bin/fakeclip-nonempty" "$cfg_tmp/bin/fakeclip-empty"
{
  printf 'nonemptyfail\t%s\n' "$cfg_tmp/bin/fakeclip-nonempty"
  printf 'emptyfail\t%s\n' "$cfg_tmp/bin/fakeclip-empty"
} >"$cfg_tmp/config/clipboard_providers.tsv"

cat >"$cfg_tmp/engine" <<'EOF'
#!/usr/bin/env bash
: >"${LMLINE_TEST_ENGINE_CALLED:?}"
printf '%s\n' 'unexpected engine call'
EOF
chmod +x "$cfg_tmp/engine"

real_sed=$(command -v sed)
cat >"$cfg_tmp/bin/sed" <<EOF
#!/usr/bin/env bash
payload=\$(cat)
if [[ "\$payload" == *REDACTIONFAILNONEMPTY* ]]; then
  printf '%s\n' "\$payload"
  exit 42
fi
if [[ "\$payload" == *REDACTIONFAILEMPTY* ]]; then
  exit 42
fi
printf '%s' "\$payload" | '$real_sed' "\$@"
EOF
chmod +x "$cfg_tmp/bin/sed"

for provider in nonemptyfail emptyfail; do
  called="$cfg_tmp/engine-called-$provider"
  if PATH="$cfg_tmp/bin:$PATH" \
     LMLINE_CONFIG_DIR="$cfg_tmp/config" \
     LMLINE_ENGINE="$cfg_tmp/engine" \
     LMLINE_TEST_ENGINE_CALLED="$called" \
     "$repo_dir/lmline/lmline" clip --provider "$provider" 'explain' >"$cfg_tmp/out-$provider" 2>&1; then
    fail "clip accepted failed redaction filter: $provider"
  fi
  [[ ! -e "$called" ]] || fail "engine invoked after failed redaction: $provider"
  if grep -Fq 'REDACTIONFAIL' "$cfg_tmp/out-$provider"; then
    fail "failed redaction output reached the prompt: $provider"
  fi
done

printf 'ok - clip redaction failure stops before engine\n'
