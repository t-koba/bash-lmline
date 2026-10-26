#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

iso_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-isolation.XXXXXX")
trap 'rm -rf "$iso_tmp"' EXIT

# 1. Executable startup is protected via /usr/bin/env -S bash -p.
for entry in lmline/validate lmline/engine lmline/lmline; do
  head -n 1 "$repo_dir/$entry" | grep -qx '#!/usr/bin/env -S bash -p' \
    || fail "shebang is not protected: $entry"
  [[ -x "$repo_dir/$entry" ]] || fail "entry is not executable: $entry"
done
ok "executables use /usr/bin/env -S bash -p"

# 2. Direct execution starts privileged before BASH_ENV/ENV, function import,
# or script code; explicit `bash script` bypasses the shebang (documented).
# Noninteractive Bash normally reads BASH_ENV, not ENV. With both hooks set,
# assert that this actual protected invocation runs neither; this does not
# exercise an interactive/POSIX startup mode in which ENV would be active.
printf 'echo BASH_ENV_HOOK_RAN\n' >"$iso_tmp/hook"
printf 'echo ENV_HOOK_RAN\n' >"$iso_tmp/env-hook"
if ENV="$iso_tmp/env-hook" BASH_ENV="$iso_tmp/hook" "$repo_dir/lmline/validate" candidate 'printf safe' rewrite bash >"$iso_tmp/direct.out" 2>&1; then
  grep -q HOOK_RAN "$iso_tmp/direct.out" && fail "direct validate sourced BASH_ENV or ENV"
  grep -qx ok "$iso_tmp/direct.out" || fail "direct validate: $(cat "$iso_tmp/direct.out")"
else
  fail "direct validate failed"
fi
if ENV="$iso_tmp/env-hook" BASH_ENV="$iso_tmp/hook" "$BASH" -p "$repo_dir/lmline/validate" candidate 'printf safe' rewrite bash >"$iso_tmp/protected.out" 2>&1; then
  grep -q HOOK_RAN "$iso_tmp/protected.out" && fail "explicit protected validate sourced BASH_ENV or ENV"
  grep -qx ok "$iso_tmp/protected.out" || fail "explicit protected validate: $(cat "$iso_tmp/protected.out")"
else
  fail "explicit protected validate failed"
fi
if ENV="$iso_tmp/env-hook" BASH_ENV="$iso_tmp/hook" "$repo_dir/lmline/engine" --mode invalid >"$iso_tmp/engine.out" 2>&1; then
  fail "invalid direct engine invocation unexpectedly succeeded"
fi
grep -q HOOK_RAN "$iso_tmp/engine.out" && fail "direct engine sourced BASH_ENV or ENV"
if BASH_ENV="$iso_tmp/hook" bash "$repo_dir/lmline/validate" candidate 'printf safe' rewrite bash >"$iso_tmp/explicit.out" 2>&1; then
  fail "explicit bash validate should fail closed (bypasses shebang)"
fi
grep -q HOOK_RAN "$iso_tmp/explicit.out" || fail "explicit bash should run the startup hook (bypass documented)"
ok "protected noninteractive startup runs neither BASH_ENV nor ENV hook; explicit bash reads BASH_ENV"
if ENV="$iso_tmp/env-hook" BASH_ENV="$iso_tmp/hook" "$repo_dir/lmline/lmline" --help >"$iso_tmp/direct-help" 2>&1; then
  grep -q HOOK_RAN "$iso_tmp/direct-help" && fail "direct lmline sourced BASH_ENV or ENV"
else
  fail "direct lmline --help failed"
fi
BASH_ENV="$iso_tmp/hook" bash "$repo_dir/lmline/lmline" --help >"$iso_tmp/explicit-help" 2>&1 || fail "explicit lmline --help failed"
grep -q HOOK_RAN "$iso_tmp/explicit-help" || fail "explicit lmline should run the hook (bypass documented)"
ok "CLI startup documents the shebang bypass"

# 3. Actual collector: names only, bodies never imported/evaluated or leaked.
(
  # shellcheck disable=SC2329
  lmline_iso_evil() { : >"$iso_tmp/body-ran"; }
  export -f lmline_iso_evil
  out=$("$repo_dir/lmline/validate" candidate 'lmline_iso_evil' rewrite bash) || fail "direct inherited export rejected"
  [[ "$out" == ok ]] || fail "direct inherited export: $out"
  protected=$("$BASH" -p "$repo_dir/lmline/validate" candidate 'lmline_iso_evil' rewrite bash) || fail "protected bash inherited export rejected"
  [[ "$protected" == ok ]] || fail "protected bash inherited export: $protected"
  [[ ! -e "$iso_tmp/body-ran" ]] || fail "exported body ran during validation"
  names=$(bash -p -c 'source "$1/validation-boundary.bash"; __lmline_collect_inherited_exported_functions' _ "$repo_dir/lmline") || fail "inherited collector failed"
  [[ $'\n'"$names"$'\n' == *$'\n'lmline_iso_evil$'\n'* ]] || fail "inherited collector missed name"
  [[ "$names" != *body-ran* ]] || fail "inherited collector leaked a body"
  [[ ! -e "$iso_tmp/body-ran" ]] || fail "collector evaluated a body"
  # The protected child never imports the function: no definition exists there.
  if bash -p -c 'declare -F lmline_iso_evil >/dev/null 2>&1'; then
    fail "protected child imported a function body"
  fi
)
[[ ! -e "$iso_tmp/body-ran" ]] || fail "body ran outside the subshell"
out=$("$repo_dir/lmline/validate" candidate 'lmline_iso_evil' rewrite bash) || fail "validate runner failed"
[[ "$out" == command-not-found ]] || fail "unexported name should fail closed: $out"
ok "inherited collector is names-only without import or leak"

# 4. Exported scratch-variable attack: caller-exported scratch names must not
# change the result or leak raw records to children.
(
  # These exported names deliberately collide with child-local scratch; the
  # values must reach the protected collector to exercise that boundary.
  # shellcheck disable=SC2031
  export entry=ATTACKER_SENTINEL name_part=ATTACKER value=ATTACKER \
    fd=ATTACKER producer=ATTACKER
  # shellcheck disable=SC2329
  lmline_iso_scratch() { :; }
  export -f lmline_iso_scratch
  names=$(bash -p -c 'source "$1/validation-boundary.bash"; __lmline_collect_inherited_exported_functions' _ "$repo_dir/lmline") || fail "collector failed with exported scratch"
  [[ $'\n'"$names"$'\n' == *$'\n'lmline_iso_scratch$'\n'* ]] || fail "scratch attack lost a name"
  # Raw records hold bodies; only names may be emitted, never bodies.
  [[ "$names" != *ATTACKER_SENTINEL* && "$names" != *'()'* ]] || fail "scratch attack leaked raw records"
  out=$(entry=ATTACKER_SENTINEL "$repo_dir/lmline/validate" candidate 'lmline_iso_scratch' rewrite bash) || fail "validate with exported scratch failed"
  [[ "$out" == ok ]] || fail "scratch attack changed validation: $out"
)
ok "exported scratch variables do not leak or alter names"

# 5. Producer completion is checked explicitly: a successful/empty read does
# not prove the env producer succeeded (evidence: exit 7 with one NUL record).
(
  exec {iso_fd}< <(printf 'record\0'; exit 7)
  iso_producer=$!
  iso_records=0
  while IFS= read -r -d '' iso_record <&"$iso_fd"; do
    iso_records=$((iso_records + 1))
  done
  exec {iso_fd}<&-
  if wait "$iso_producer"; then
    fail "producer failure was ignored"
  fi
  [[ "$iso_records" == 1 ]] || fail "expected one record, got $iso_records"
)
ok "env producer completion is checked explicitly"

# 6. Punctuation names survive the protected path; ordinary PATH is preserved.
(
  # shellcheck disable=SC2329
  lmline-caller-probe() { :; }
  # shellcheck disable=SC2329
  a:b() { :; }
  # shellcheck disable=SC2329
  a.b() { :; }
  export -f lmline-caller-probe a:b a.b
  for probe in lmline-caller-probe a:b a.b; do
    out=$("$repo_dir/lmline/validate" candidate "$probe" rewrite bash) || fail "punctuation probe failed: $probe"
    [[ "$out" == ok ]] || fail "punctuation name rejected: $probe -> $out"
  done
)
path_dir=$iso_tmp/path-only
mkdir "$path_dir" || fail "mkdir path probe"
true_path=$(type -P true) || fail "no true for PATH probe"
ln -s "$true_path" "$path_dir/lmline_iso_path_probe" || fail "ln path probe"
out=$(PATH="$path_dir:$PATH" "$repo_dir/lmline/validate" candidate 'lmline_iso_path_probe' rewrite bash) || fail "PATH probe failed"
[[ "$out" == ok ]] || fail "ordinary PATH lookup lost: $out"
ok "punctuation names and ordinary PATH survive protected validation"

# 7. One canonical route: direct, in-process isolated, launcher, and Copilot
# filter agree; candidates never execute.
side_effect_path=$iso_tmp/candidate-side-effect
[[ ! -e "$side_effect_path" ]] || fail "candidate marker must start absent"
(
  # shellcheck disable=SC2329
  lmline_iso_backend() { :; }
  export -f lmline_iso_backend
  candidate='lmline_iso_backend'
  direct=$("$repo_dir/lmline/validate" candidate "$candidate" rewrite bash) || fail "direct backend failed"
  isolated=$(__LMLINE_VALIDATION_ISOLATED=1 LMLINE_SHELL_FUNCTIONS='' LMLINE_EXPORTED_FUNCTIONS='lmline_iso_backend' __lmline_candidate_rejection_reason "$candidate" rewrite bash) || fail "isolated backend failed"
  via_run=$(LMLINE_SHELL_FUNCTIONS='' LMLINE_EXPORTED_FUNCTIONS='lmline_iso_backend' __lmline_validation_run candidate "$candidate" rewrite bash) || fail "launcher backend failed"
  copilot_out=$(printf 'tok\t%s\n' "$candidate" | LMLINE_SHELL_FUNCTIONS='' LMLINE_EXPORTED_FUNCTIONS='lmline_iso_backend' __lmline_validation_run copilot bash rewrite) || fail "copilot backend failed"
  [[ "$direct" == ok && "$isolated" == ok && "$via_run" == ok ]] || fail "backend mismatch: $direct/$isolated/$via_run"
  [[ "$copilot_out" == *$'\t'"$candidate" ]] || fail "copilot route lost the candidate"
  # Embed the unique absolute path as literal candidate text, not a variable
  # that would be unset in an accidentally executing child.
  printf -v bad 'touch %q' "$side_effect_path"
  evil="lmline_iso_backend; $bad"
  for candidate in "$bad" "$evil"; do
    for route in direct isolated launcher copilot; do
      case $route in
        direct) got=$("$repo_dir/lmline/validate" candidate "$candidate" rewrite bash) || fail "direct side-effect check failed" ;;
        isolated) got=$(__LMLINE_VALIDATION_ISOLATED=1 __lmline_candidate_rejection_reason "$candidate" rewrite bash) || fail "isolated side-effect check failed" ;;
        launcher) got=$(__lmline_validation_run candidate "$candidate" rewrite bash) || fail "launcher side-effect check failed" ;;
        copilot) got=$(printf 'tok\t%s\n' "$candidate" | __lmline_validation_run copilot bash rewrite) || fail "copilot side-effect check failed" ;;
      esac
      [[ ! -e "$side_effect_path" ]] || fail "candidate executed via $route route: $candidate"
      if [[ $route == copilot ]]; then
        [[ -z "$got" || "$got" == *$'\t'"$candidate" ]] || fail "unexpected copilot result: $got"
      else
        [[ "$got" == command-not-found || "$got" == ok ]] || fail "unexpected $route result: $got"
      fi
    done
  done
)
ok "backends agree and candidates never execute"
