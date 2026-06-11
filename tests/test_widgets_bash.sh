#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

widget_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-widget-test.XXXXXX")
printf '#!/usr/bin/env bash\nprintf "lmline-status: m=widget-model; tok=100/23/123\\n" >&2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo one\\nlmline-candidate: low\\tno matching risk rule\\t-\\techo two\\n"\n' >"$widget_tmp/engine"
chmod +x "$widget_tmp/engine"
LMLINE_CONFIG_DIR="$widget_tmp/config" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine" LMLINE_HISTORY_DIR="$widget_tmp/history" bash --norc -i -c '
  source "$1/lmline/init.bash"
  [[ $(__lmline_infer_mode "# request") == generate ]]
  [[ $(__lmline_infer_mode "#another request") == generate ]]
  [[ $(__lmline_infer_mode "?") == generate ]]
  [[ $(__lmline_infer_mode "? request") == generate ]]
  [[ $(__lmline_infer_mode "?foo") == rewrite ]]
  [[ $(__lmline_infer_mode "") == generate ]]
  [[ $(__lmline_infer_mode "ls | ") == continue ]]
  [[ $(__lmline_infer_mode "ls |") == continue ]]
  [[ $(__lmline_infer_mode $'"'"'ls |\t'"'"') == continue ]]
  [[ $(__lmline_infer_mode "request") == rewrite ]]
  [[ $(__lmline_infer_mode "printf foo") == rewrite ]]
  READLINE_LINE="# say one"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-sync.out 2>/tmp/lmline-widget-sync.err
  [[ "$READLINE_LINE" == "echo one" ]]
  grep -q "2 candidates; m=widget-model; tok=100/23/123" /tmp/lmline-widget-sync.err
' _ "$repo_dir" || fail "sync widget"
printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: curl: (28) Operation timed out after 12003 milliseconds with 0 bytes received\\n" >&2\nexit 1\n' >"$widget_tmp/engine-fail"
chmod +x "$widget_tmp/engine-fail"
LMLINE_CONFIG_DIR="$widget_tmp/config-fail" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-fail" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# say one"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-fail.out 2>/tmp/lmline-widget-fail.err
  [[ "$READLINE_LINE" == "# say one" ]]
  grep -q "request timed out" /tmp/lmline-widget-fail.err
  grep -q "LMLINE_ENGINE_TIMEOUT" /tmp/lmline-widget-fail.err
' _ "$repo_dir" || fail "engine failure is surfaced"
printf '#!/usr/bin/env bash\nprintf "lmline-candidate: medium\\twrites to a file or descriptor\\t-\\techo hi > out.txt\\n"\n' >"$widget_tmp/engine-medium"
chmod +x "$widget_tmp/engine-medium"
LMLINE_CONFIG_DIR="$widget_tmp/config-medium" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-medium" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# medium"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-medium.out 2>/tmp/lmline-widget-medium.err
  [[ "$READLINE_LINE" == "echo hi > out.txt" ]]
  grep -q "medium-risk; review before Enter" /tmp/lmline-widget-medium.err
' _ "$repo_dir" || fail "bash medium risk hint"
printf '#!/usr/bin/env bash\nprintf "lmline-candidate: high\\trecursive remove\\t-\\trm -rf /tmp/lmline-risk-test\\n"\n' >"$widget_tmp/engine-high"
chmod +x "$widget_tmp/engine-high"
LMLINE_CONFIG_DIR="$widget_tmp/config-high" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-high" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# high"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-high.out 2>/tmp/lmline-widget-high.err
  [[ "$READLINE_LINE" == "# REVIEW REQUIRED: rm -rf /tmp/lmline-risk-test" ]]
  grep -q "high-risk; inserted as comment" /tmp/lmline-widget-high.err
' _ "$repo_dir" || fail "bash high risk hint"
cat >"$widget_tmp/engine-explain" <<'EOF'
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
if [[ "$mode" == explain ]]; then
  printf 'lmline-meta: model=explain-model tokens=66 prompt=50 completion=16\n' >&2
  printf 'lmline-status: m=explain-model; tok=50/16/66\n' >&2
  printf 'explained command\n'
  [[ -n "$line_file" ]] && printf 'line-bytes=%s\n' "$(wc -c <"$line_file")"
else
  printf 'lmline-candidate: low\tno matching risk rule\t-\techo default\n'
fi
EOF
chmod +x "$widget_tmp/engine-explain"
long_explain_cmd=$(printf "printf %s " "%s"; printf "'"; printf "b%.0s" {1..5000}; printf "'")
LMLINE_CONFIG_DIR="$widget_tmp/config-explain" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="echo hi"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_explain_widget >/tmp/lmline-widget-explain.out 2>/tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] command: echo hi" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] risk=low" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] command summary:" /tmp/lmline-widget-explain.err
  grep -q "^echo is" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] model explanation:" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] m=explain-model; tok=50/16/66" /tmp/lmline-widget-explain.err
  grep -q "explained command" /tmp/lmline-widget-explain.err
' _ "$repo_dir" || fail "bash explain widget"
LMLINE_CONFIG_DIR="$widget_tmp/config-explain-long" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE=$2
  READLINE_POINT=${#READLINE_LINE}
  __lmline_explain_widget >/tmp/lmline-widget-explain-long.out 2>/tmp/lmline-widget-explain-long.err
  grep -q "\\[lm\\] command: printf" /tmp/lmline-widget-explain-long.err
  grep -q "line-bytes=.*${#READLINE_LINE}" /tmp/lmline-widget-explain-long.err
' _ "$repo_dir" "$long_explain_cmd" || fail "bash explain long line"
cli_explain_out=$(LMLINE_CONFIG_DIR="$widget_tmp/config-explain-cli" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" "$repo_dir/lmline/lmline" explain "echo hi")
grep -q "\\[lm\\] command: echo hi" <<<"$cli_explain_out" || fail "cli explain command"
grep -q "\\[lm\\] risk=low" <<<"$cli_explain_out" || fail "cli explain risk"
grep -q "\\[lm\\] command summary:" <<<"$cli_explain_out" || fail "cli explain command summary"
grep -q '^echo is' <<<"$cli_explain_out" || fail "cli explain type summary"
grep -q "\\[lm\\] model explanation:" <<<"$cli_explain_out" || fail "cli explain heading"
grep -q "\\[lm\\] m=explain-model; tok=50/16/66" <<<"$cli_explain_out" || fail "cli explain metadata"
grep -q "explained command" <<<"$cli_explain_out" || fail "cli explain model"
! grep -q '^$' <<<"$cli_explain_out" || fail "cli explain blank lines"
cli_long_explain_out=$(LMLINE_CONFIG_DIR="$widget_tmp/config-explain-cli-long" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" "$repo_dir/lmline/lmline" explain "$long_explain_cmd")
grep -q "line-bytes=.*${#long_explain_cmd}" <<<"$cli_long_explain_out" || fail "cli explain long line"
cat >"$widget_tmp/engine-explain-long-response" <<'EOF'
#!/usr/bin/env bash
while (($#)); do shift; done
printf 'x%.0s' {1..2000}
EOF
chmod +x "$widget_tmp/engine-explain-long-response"
cli_truncated_explain_out=$(LMLINE_EXPLAIN_MAX_OUTPUT_BYTES=1000 LMLINE_CONFIG_DIR="$widget_tmp/config-explain-truncated" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain-long-response" "$repo_dir/lmline/lmline" explain "echo hi")
grep -q "explanation-truncated .*max_bytes=1000" <<<"$cli_truncated_explain_out" || fail "cli explain truncation marker"
cli_pipeline_explain_out=$(LMLINE_CONFIG_DIR="$widget_tmp/config-explain-pipeline" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" "$repo_dir/lmline/lmline" explain "yes '' | nl -b a -v 0 | head -n 31 | xargs -I @ date -d '20201201 +@days' +'%Y%m%d' | factor | awk 'NF==2&&\$0=\$2'")
grep -q '^date is ' <<<"$cli_pipeline_explain_out" || fail "cli explain covers xargs command"
grep -q '^awk is ' <<<"$cli_pipeline_explain_out" || fail "cli explain covers long pipeline"
LMLINE_CONFIG_DIR="$widget_tmp/config" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine" LMLINE_HISTORY_DIR="$widget_tmp/history" bash --norc -i -c '
  source "$1/lmline/init.bash"
  LMLINE_SELECTOR=definitely-not-a-selector
  READLINE_LINE=""
  READLINE_POINT=0
  __lmline_rewrite_widget >/tmp/lmline-widget-rewrite-empty.out 2>/tmp/lmline-widget-rewrite-empty.err
  [[ "$READLINE_LINE" == "" ]]
  READLINE_LINE="echo old"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_rewrite_widget >/tmp/lmline-widget-rewrite.out 2>/tmp/lmline-widget-rewrite.err
  [[ "$READLINE_LINE" == "echo one" ]]
  grep -q "selector unavailable" /tmp/lmline-widget-rewrite.err
  __lmline_next_widget
  [[ "$READLINE_LINE" == "echo two" ]]
  __lmline_next_widget
  [[ "$READLINE_LINE" == "echo old" ]]
  __lmline_prev_widget
  [[ "$READLINE_LINE" == "echo two" ]]
' _ "$repo_dir" || fail "rewrite candidate cycling"
LMLINE_CONFIG_DIR="$widget_tmp/config" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine" LMLINE_HISTORY_DIR="$widget_tmp/history" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# say one"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-async1.out 2>/tmp/lmline-widget-async1.err
  sleep 0.2
  __lmline_generate_widget >/tmp/lmline-widget-async2.out 2>/tmp/lmline-widget-async2.err
  [[ "$READLINE_LINE" == "echo one" ]]
' _ "$repo_dir" || fail "async widget"
printf '#!/usr/bin/env bash\nsleep 0.3\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo slow\\n"\n' >"$widget_tmp/engine-slow"
chmod +x "$widget_tmp/engine-slow"
LMLINE_CONFIG_DIR="$widget_tmp/config-clean" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-slow" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# first"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-clean1.out 2>/tmp/lmline-widget-clean1.err
  old_file=$__LMLINE_ASYNC_FILE
  READLINE_LINE="# second"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-clean2.out 2>/tmp/lmline-widget-clean2.err
  [[ "$old_file" != "$__LMLINE_ASYNC_FILE" ]]
  [[ ! -e "$old_file" ]]
' _ "$repo_dir" || fail "async cleanup"
printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: synthetic async failure\\n" >&2\nexit 1\n' >"$widget_tmp/engine-fail"
chmod +x "$widget_tmp/engine-fail"
LMLINE_CONFIG_DIR="$widget_tmp/config-async-fail" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-fail" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# fail"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-fail1.out 2>/tmp/lmline-widget-fail1.err
  sleep 0.2
  __lmline_generate_widget >/tmp/lmline-widget-fail2.out 2>/tmp/lmline-widget-fail2.err
  grep -q "synthetic async failure" /tmp/lmline-widget-fail2.err
' _ "$repo_dir" || fail "async failure hint"
rm -rf "$widget_tmp"
ok "widgets"
