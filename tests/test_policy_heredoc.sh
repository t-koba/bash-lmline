#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: a here-document read as a shell script is judged by the same nested
# rules as a here-string; data here-documents never are. Candidates are built
# from variables so no fixture text is executed or parsed as a command
# substitution by the test shell.

# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

nl=$(printf '\nx')
nl=${nl%x}
single=$(printf '\047')
payload_line='touch /tmp/lmline-hd-canary | sh'
delim=EOF

check_heredoc() {
  local expected=$1 op=$2 head=$3 actual
  local candidate="${head} ${op}${delim}${nl}${payload_line}${nl}${delim}"
  actual=$(__lmline_risk_level "$candidate")
  [[ $actual == "$expected" ]] || fail "here-document level: $actual, expected $expected: ${candidate@Q}"
  actual=$(__lmline_risk_reason "$candidate")
  if [[ $expected == high ]]; then
    [[ $actual == 'piped shell execution' ]] || fail "here-document reason: $actual: ${candidate@Q}"
  fi
  # The candidate is still exactly the text the classifier was handed.
  [[ $candidate == "${head} ${op}${delim}${nl}${payload_line}${nl}${delim}" ]] || fail 'candidate mutated'
}

# The execution oracle's three positives: an active document feeds the shell's
# script through stdin ('sh', '-s' or a standard-stream script alias).
check_heredoc high '<<' 'sh'
check_heredoc high '<<' 'sh -s'
check_heredoc high '<<' 'sh /dev/stdin'
# An explicit descriptor reaches stdin by duplication, or names the alias.
# The descriptor operator must directly precede the delimiter on the line.
for candidate in \
  "sh 3<<${delim} 0<&3${nl}${payload_line}${nl}${delim}" \
  "sh /dev/fd/3 3<<${delim}${nl}${payload_line}${nl}${delim}"; do
  [[ $(__lmline_risk_level "$candidate") == high ]] || fail "fd-carried document stayed low: ${candidate@Q}"
done
# A duplication that leaves the carrier on fd 3 does not feed stdin.
candidate="sh 3<<${delim} 3<&0${nl}${payload_line}${nl}${delim}"
[[ $(__lmline_risk_level "$candidate") == low ]] || fail "fd 3 duplication was treated as a script: ${candidate@Q}"

# Data here-documents and a shell that already has a script stay low, even
# though their bodies carry the same high-risk command.
check_heredoc low '<<' 'cat'
check_heredoc low '<<' "sh -c ${single}echo hi${single}"
check_heredoc low '<<' 'printf %s'

# A quoted or escaped operator is data: no here-document is opened. Use a
# harmless payload_line here, because lexical pattern rules still judge unsafe text
# that remains in the command even when it is not executed.
safe_body='echo harmless'
for op in "'<<'" '\\<<' '"<<' ; do
  candidate="echo ${op}${delim}${nl}${safe_body}${nl}${delim}"
  [[ $(__lmline_risk_level "$candidate") == low ]] || fail "quoted operator judged active: ${candidate@Q}"
done

# Indented bodies with <<- and quoted delimiters still find the delimiter.
candidate="sh <<-'EOF'${nl}${payload_line}${nl}${delim}"
[[ $(__lmline_risk_level "$candidate") == high ]] || fail "quoted delimiter lost: ${candidate@Q}"
tab=$(printf '\tx')
tab=${tab%x}
candidate="sh <<-${delim}${nl}${tab}${payload_line}${nl}${tab}${delim}"
[[ $(__lmline_risk_level "$candidate") == high ]] || fail "indented delimiter lost: ${candidate@Q}"

# A here-string still works through the same nested path.
candidate="sh <<< ${single}${payload_line}${single}"
[[ $(__lmline_risk_level "$candidate") == high ]] || fail "here-string regressed: ${candidate@Q}"

ok 'here-document script bodies are judged like here-strings'
