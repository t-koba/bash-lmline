# Candidate-syntax parser. Sourced by policy.bash; not a standalone script.

# Make an availability-only copy with case/function/static Zsh loop headers
# removed, not bodies.
# Definitions inside conditional (if), case-branch, loop or subshell bodies
# are scoped to that body and never leak past their control flow.
# Token boundaries, quotes and escapes distinguish syntax from arguments. A
# stack keeps nested cases independent; pattern parentheses do not open bodies.
# Substitutions are checked recursively, including those inside quoted selectors.
# The target shell's syntax-only parser finds their closing delimiter, so nested
# substitutions and case-pattern ')' characters cannot truncate the check.
# The literal-only mode collects literal eval/trap/shell-c words without rewriting outer
# syntax or broadening substitution checks; status 2 marks a recognized invalid literal.
__lmline_case_command_copy() {
  local cmd=$1 shell=$2 only_substitutions=${3:-0} functions=${4:-} only_literal_evals=${5:-0} out="" substitutions=""
  local name header remaining zsh_for_words eval_status trap_status shellc_status command_word marked_word eval_functions eval_function_name eval_retained
  local trap_functions trap_retained trap_function_name shellc_cwd_uncertain substitution_cwd_uncertain
  # Named state results report surviving input bindings, not action-local
  # replacements of removed names. Mirror the existing isolation snapshots.
  local retained_functions=$functions
  # Exact-name provenance, independent of input multiplicity. Recursive scans
  # reset retained_functions to their input, so that list alone cannot tell an
  # inherited candidate definition from a transported binding. Only declaration
  # sites add names here; removals and isolation follow the active-list scopes.
  local __lmline_candidate_defined_functions=${__lmline_candidate_defined_functions-}
  local provenance_name provenance_input=$__lmline_candidate_defined_functions
  __lmline_candidate_defined_functions=""
  while IFS= read -r provenance_name; do
    [[ -n "$provenance_name" ]] || continue
    if [[ $'\n'"$functions"$'\n' == *$'\n'"$provenance_name"$'\n'* ]]; then
      __lmline_candidate_defined_functions+=$'\n'"$provenance_name"$'\n'
    fi
  done <<<"$provenance_input"
  local -a retained_scope_saved=() retained_function_scope_saved=() retained_brace_saved=()
  local -a candidate_scope_saved=() candidate_function_scope_saved=() candidate_brace_saved=()
  local retained_closed_brace="" retained_background=""
  local candidate_closed_brace="" candidate_background=""
  local function_header='^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*(\([[:space:]]*\)[[:space:]]*)?\{([[:space:]]|$)'
  local paren_header='^[[:space:]]*\([[:space:]]*\)[[:space:]]*\{([[:space:]]|$)'
  local function_name='^[a-zA-Z_][a-zA-Z0-9_]*$'
  local paren_signature='^[[:space:]]*\([[:space:]]*\)'
  local zsh_for_prefix='^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*[(]'
  local zsh_for_header='^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*[(](([^()]|[(][^()]*[)])*)[)]'
  local coproc_compound_keywords='!|if|for|while|until|case|select|time|function|coproc'
  [[ "$shell" != zsh ]] || coproc_compound_keywords+='|repeat'
  local coproc_named_compound='^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(\{|\[|\()|^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+('"$coproc_compound_keywords"')([[:space:];]|$)'
  local i=0 start ch next token quote end fragment inner words word scope_idx compound_end=0 previous_compound_end
  local zsh_unscoped_loop_seen=0 zsh_repeat_count_pending=0
  local depth=0 command_start=1 pattern_started=0 pattern_depth=0 opaque_arguments=0
  local time_option_pending=0 assignment_prefix='^[a-zA-Z_][a-zA-Z0-9_]*\+?='
  local if_pending=0 elif_pending=0 brace_depth=0
  # Definitions in and/or lists or pipelines need control-flow reasoning.
  # Conservatively fail closed for those lists rather than evaluating their
  # conditions or depending on the shell's last-pipeline-member options.
  # Brace bodies get independent list state, so ordinary pipelines inside a
  # function do not make an otherwise direct definition unavailable.
  local -a list_operator=(0) list_definition=(0) brace_definition=(0)
  # Ordinary braces run in this shell unless their completed command is
  # backgrounded. Retain the entry snapshot through any trailing redirects.
  local -a brace_functions_saved=()
  local closed_brace_pending=0 closed_brace_functions=""
  local amp_is_redirect=0 next_amp_is_redirect=0
  local -a state=(body) scope_saved=() scope_kind=() function_scope_saved=() function_scope_depth=()
  # Installer metadata shares the existing function-body stack. Only immediate
  # declarations are collected; their bodies still pass through every check.
  local -a function_ids=() installer_pure=() installer_children=() remover_pure=() remover_targets=() remover_scope_top_level=()
  # Immutable, scan-local summaries use declaration occurrence IDs, not names.
  # A child list retains declaration order so the last binding wins, including
  # a non-installer redefinition. Only the pending direct edge is callable.
  local -a declaration_names=() declaration_children=() declaration_removals=() declaration_unsafe=()
  local pending_installers="" installer_called=0 selected_installer=0 child_id
  local pending_remover="" remover_called=0 selected_remover=0 remover_scan_idx=0 remover_target=""
  local pending_function_definition_id="" remover_redefinition_ambiguous=0
  local remover_top_level=0 remover_redefinition_unsafe=""
  local direct_start=1 was_direct_start installer_idx installer_loop_pending=0
  local removal_mode="" removal_wrapper=0 removal_word removal_pattern removal_scope
  local removal_background_pending=0 removal_background_functions=""
  local remover_call_wrapper=0 remover_call_bypass=0
  while (( i < ${#cmd} )); do
    ch=${cmd:i:1}
    if [[ "$ch" == [[:space:]] ]]; then
      out+=$ch
      if [[ "$ch" == $'\n' ]]; then
        removal_mode=""
        removal_wrapper=0
        removal_background_pending=0
        remover_call_wrapper=0
        remover_call_bypass=0
        closed_brace_pending=0
        pending_function_definition_id=""
        command_start=1
        direct_start=1
        opaque_arguments=0
        if (( installer_called )); then
          pending_installers=${declaration_children[selected_installer]}
          for child_id in $pending_installers; do
            functions+=$'\n'"${declaration_names[child_id]}"$'\n'
            if [[ $'\n'"$__lmline_candidate_defined_functions"$'\n' != *$'\n'"${declaration_names[child_id]}"$'\n'* ]]; then
              __lmline_candidate_defined_functions+=$'\n'"${declaration_names[child_id]}"$'\n'
            fi
          done
          installer_called=0
        fi
        if (( remover_called )); then
          for remover_target in ${declaration_removals[selected_remover]}; do
            removal_pattern=$'\n'"$remover_target"$'\n'
            while [[ $'\n'"$functions"$'\n' == *"$removal_pattern"* ]]; do
              functions=$'\n'"$functions"$'\n'
              functions=${functions//"$removal_pattern"/$'\n'}
              retained_functions=$'\n'"$retained_functions"$'\n'
              __lmline_candidate_defined_functions=$'\n'"$__lmline_candidate_defined_functions"$'\n'
              retained_functions=${retained_functions//"$removal_pattern"/$'\n'}
              __lmline_candidate_defined_functions=${__lmline_candidate_defined_functions//"$removal_pattern"/$'\n'}
            done
          done
          pending_remover=""
          remover_called=0
        fi
      fi
      i=$((i + 1))
      continue
    fi
    # A comment starts only at an unquoted token boundary. Do not scan its
    # apparent headers, separators or substitutions as executable syntax.
    if [[ "$ch" == '#' ]]; then
      while (( i < ${#cmd} )) && [[ ${cmd:i:1} != $'\n' ]]; do
        i=$((i + 1))
      done
      continue
    fi
    start=$i
    amp_is_redirect=$next_amp_is_redirect
    next_amp_is_redirect=0
    case "$ch" in
      ';'|'|'|'&'|'('|')')
        token=$ch
        next=${cmd:i+1:1}
        if [[ "$ch$next" == ';;' || "$ch$next" == ';&' || "$ch$next" == ';|' || "$ch$next" == '&&' || "$ch$next" == '||' ]]; then
          token+=$next
          i=$((i + 1))
          if [[ "$token" == ';;' && ${cmd:i+1:1} == '&' ]]; then
            token+='&'
            i=$((i + 1))
          fi
        fi
        i=$((i + 1))
        ;;
      *)
        quote=""
        while (( i < ${#cmd} )); do
          ch=${cmd:i:1}
          next=${cmd:i+1:1}
          if [[ "$quote" != "'" && "$ch" == '\' ]]; then
            i=$((i + 2))
            continue
          fi
          if [[ "$quote" != "'" && ( "$ch$next" == '$(' || "$ch" == '`' ) ]]; then
            # Parse only: never expand or execute the fragment. The wrapper's
            # double quotes also work for substitutions in double-quoted words.
            end=$((i + 1))
            while (( end < ${#cmd} )); do
              if [[ ( "$ch" == '$' && ${cmd:end:1} == ')' ) || ( "$ch" == '`' && ${cmd:end:1} == '`' ) ]]; then
                fragment=${cmd:i:end-i+1}
                if [[ "$shell" == zsh ]]; then
                  command zsh -f -n -c ": \"$fragment\"" >/dev/null 2>&1 && break
                else
                  "$BASH" -p -n -c ": \"$fragment\"" >/dev/null 2>&1 && break
                fi
              fi
              end=$((end + 1))
            done
            (( end < ${#cmd} )) || return 1
            if (( only_literal_evals || opaque_arguments )); then
              # Unsupported eval/trap/shell-c arguments stay opaque even when
              # caller names require the function-aware scan. Syntax is parsed
              # above, but the dynamic text is neither inspected nor executed.
              i=$((end + 1))
              continue
            fi
            # Substitutions inherit the cwd at this position just like a
            # literal child shell. Carry only uncertainty, never a candidate
            # directory or evaluated substitution, into the recursive scan.
            substitution_cwd_uncertain=0
            if __lmline_has_relative_cwd_risk "$out" "$shell" "$cmd" cwd-state; then
              substitution_cwd_uncertain=1
            fi
            if [[ ${fragment:0:3} == '$((' ]]; then
              inner=${fragment:3:${#fragment}-5}
              words=$(__lmline_cwd_uncertain=$substitution_cwd_uncertain __lmline_case_command_copy "$inner" "$shell" 1 "$functions") || return 1
              substitutions+=$words
            else
              if [[ "$ch" == '$' ]]; then
                inner=${fragment:2:${#fragment}-3}
              else
                inner=${fragment:1:${#fragment}-2}
                # Escaped nested backticks need another unquoting pass. Leave
                # such unsupported forms closed rather than dropping commands.
                [[ "$inner" != *'\`'* ]] || return 1
              fi
              words=$(__lmline_cwd_uncertain=$substitution_cwd_uncertain __lmline_extract_command_words "$inner" "$shell" 1 "$functions") || return 1
              while IFS= read -r word; do
                [[ -z "$word" ]] || substitutions+="; $word "
              done <<<"$words"
            fi
            i=$((end + 1))
            continue
          fi
          if [[ -n "$quote" ]]; then
            [[ "$ch" != "$quote" ]] || quote=""
          else
            case "$ch" in
              "'"|'"') quote=$ch ;;
              '<'|'>') [[ "$next" != '&' ]] || next_amp_is_redirect=1 ;;
              [[:space:]]|';'|'|'|'&'|'('|')') break ;;
            esac
          fi
          i=$((i + 1))
        done
        token=${cmd:start:i-start}
        ;;
    esac
    # Decode supported literal command spellings as data, not shell code.
    # Keep the original token for syntax/removal recognition; the decoded word
    # is only for function calls and their occurrence-bound summaries.
    command_word=$token
    if (( command_start )) && [[ "$token" == *\'* || "$token" == *\"* ]]; then
      marked_word=$(__lmline_split_pipeline "$token" 2 "" "$shell" command-prefix)
      if [[ "$token" == */* ]]; then
        command_word=$(__lmline_literal_command_word "$marked_word") || command_word=$token
      else
        command_word=$(__lmline_literal_command_name "$marked_word") || command_word=$token
      fi
    fi
    # Bash's reserved time accepts only the bounded -p form here. Do not
    # mistake its option for a command or infer function effects from it.
    if (( time_option_pending )); then
      time_option_pending=0
      case "$token" in
        -p) out+=' '; continue ;;
        -*) return 1 ;;
      esac
    fi
    was_direct_start=$direct_start
    direct_start=0
    previous_compound_end=$compound_end
    compound_end=0
    case "${state[depth]}" in
      selector) state[depth]=in ;;
      in)
        [[ "$token" == in ]] || return 1
        state[depth]=pattern
        pattern_started=0
        pattern_depth=0
        ;;
      pattern)
        case "$token" in
          "esac")
            (( pattern_started == 0 )) || return 1
            depth=$((depth - 1))
            out+=' '
            command_start=0
            compound_end=1
            ;;
          '(')
            (( pattern_started == 0 )) || pattern_depth=$((pattern_depth + 1))
            pattern_started=1
            ;;
          ')')
            if (( pattern_depth > 0 )); then
              pattern_depth=$((pattern_depth - 1))
            else
              state[depth]=body
              command_start=1
              out+='; '
              # A case branch body is conditional: definitions inside are
              # visible only within that branch, never after the case.
              scope_saved+=("$functions")
              retained_scope_saved+=("$retained_functions")
              candidate_scope_saved+=("$__lmline_candidate_defined_functions")
              scope_kind+=("case-branch")
            fi
            ;;
          *) pattern_started=1 ;;
        esac
        ;;
      body)
        if [[ -n "$pending_function_definition_id" ]]; then
          case "$token" in
            '&')
              if (( ! amp_is_redirect )) && [[ ${cmd:i:1} != '>' ]]; then
                remover_redefinition_ambiguous=1
              fi
              ;;
            '|'|'&&'|'||'|'('|')'|'}') remover_redefinition_ambiguous=1 ;;
            ';'|';;'|';&'|';;&'|';|') pending_function_definition_id="" ;;
          esac
          if (( remover_redefinition_ambiguous )); then
            for (( remover_scan_idx=pending_function_definition_id-1; remover_scan_idx>=0; remover_scan_idx-- )); do
              if [[ "${declaration_names[remover_scan_idx]}" == "${declaration_names[pending_function_definition_id]}" ]]; then
                if [[ -n "${declaration_removals[remover_scan_idx]}${declaration_unsafe[remover_scan_idx]}" ]] \
                  && [[ -z "${declaration_removals[pending_function_definition_id]}" ]]; then
                  declaration_unsafe[pending_function_definition_id]=1
                fi
                break
              fi
            done
            pending_function_definition_id=""
            remover_redefinition_ambiguous=0
          fi
        fi
        if (( closed_brace_pending )); then
          case "$token" in
            '&')
              # >& / <& and &> are redirections, not async terminators.
              if (( ! amp_is_redirect )) && [[ ${cmd:i:1} != '>' ]]; then
                functions=$closed_brace_functions
                retained_functions=$retained_closed_brace
                __lmline_candidate_defined_functions=$candidate_closed_brace
                closed_brace_pending=0
              fi
              ;;
            ';'|';;'|';&'|';;&'|';|'|'&&'|'||'|'|'|'('|')') closed_brace_pending=0 ;;
          esac
        fi
        # Recognize only static, brace-bodied definitions at command boundaries.
        # Consuming the header (including its opening brace) leaves every body
        # command visible. Names are local to this scan, not installed in a shell;
        # recursive substitution scans inherit them but cannot add names here.
        # Headers win over removal words so `unset`/`unfunction` can be defined.
        name=""
        remaining=${cmd:i}
        if (( command_start )) && [[ "$shell" == zsh && "$token" == for && "$remaining" =~ $zsh_for_prefix ]]; then
          # Track every short form, including dynamic lists whose substitutions
          # remain visible to the recursive availability scan below.
          zsh_unscoped_loop_seen=1
        fi
        if (( command_start )) && [[ "$token" == function ]]; then
          [[ "$remaining" =~ $function_header ]] || return 1
          header=${BASH_REMATCH[0]}
          name=${BASH_REMATCH[1]}
        elif (( command_start )) && [[ "$remaining" =~ $paren_signature ]]; then
          # Other names/body forms need parsing we do not provide. Do not let
          # an installed executable with the same name mask an unsupported header.
          [[ "$token" =~ $function_name && "$remaining" =~ $paren_header ]] || return 1
          header=${BASH_REMATCH[0]}
          name=$token
        fi
        # A deliberately small removal grammar, using the same lexical tokens
        # as declarations: unset -f NAME..., unset -v ..., unfunction NAME....
        # No expansion, option guessing, redirects or wrapped removals. Reject
        # uncertain branch/loop contexts rather than restoring stale availability
        # from their snapshots. Subshell/function and async-brace snapshots stay
        # isolated; ordinary braces lose names. Non-direct list positions fail
        # closed too, without reasoning about pipeline/and-or execution.
        if [[ "$token" == '&' && $removal_background_pending == 1 ]] \
          && (( ! amp_is_redirect )) && [[ ${cmd:i:1} != '>' ]]; then
          # A literal remover run asynchronously changes only its child shell.
          functions=$removal_background_functions
          retained_functions=$retained_background
          __lmline_candidate_defined_functions=$candidate_background
          removal_background_pending=0
        fi
        case "$token" in
          ';'|'|'|'&'|'&&'|'||'|'('|')'|'}')
            removal_mode=""
            removal_wrapper=0
            removal_background_pending=0
            ;;
        esac
        if [[ -n "$removal_mode" ]]; then
          case "$removal_mode" in
            option)
              case "$token" in
                -f)
                  removal_mode=names
                  removal_background_functions=$functions
                  retained_background=$retained_functions
                  candidate_background=$__lmline_candidate_defined_functions
                  removal_background_pending=1
                  ;;
                -v) removal_mode=variables ;;
                *) return 1 ;;
              esac
              ;;
            names|variables)
              if [[ "$removal_mode" == variables ]]; then
                [[ "$token" =~ $function_name ]] || return 1
              else
                # Function operands may use the transported literal alphabet,
                # but an option-looking word is still an unsupported form.
                [[ "$token" != -* ]] && __lmline_valid_caller_function_name "$token" || return 1
              fi
              if [[ "$removal_mode" == names ]]; then
                (( if_pending == 0 && elif_pending == 0 && installer_loop_pending == 0 && zsh_unscoped_loop_seen == 0 )) || return 1
                for removal_scope in "${scope_kind[@]}"; do
                  [[ "$removal_scope" == subshell ]] || return 1
                done
                removal_pattern=$'\n'"$token"$'\n'
                while [[ $'\n'"$functions"$'\n' == *"$removal_pattern"* ]]; do
                  functions=$'\n'"$functions"$'\n'
                  functions=${functions//"$removal_pattern"/$'\n'}
                  retained_functions=$'\n'"$retained_functions"$'\n'
                  __lmline_candidate_defined_functions=$'\n'"$__lmline_candidate_defined_functions"$'\n'
                  retained_functions=${retained_functions//"$removal_pattern"/$'\n'}
                  __lmline_candidate_defined_functions=${__lmline_candidate_defined_functions//"$removal_pattern"/$'\n'}
                done
              fi
              ;;
          esac
        else
          # Strip quote/escape characters only to detect unsupported literal
          # spellings and fail closed, never to expand a candidate word.
          removal_word=${token//\\/}
          removal_word=${removal_word//\"/}
          removal_word=${removal_word//\'/}
          if [[ "$removal_word" == unset || ( "$shell" == zsh && "$removal_word" == unfunction ) ]] \
            && (( command_start || removal_wrapper )) && [[ -z "$name" ]]; then
            # A candidate-defined function shadows the builtin remover: the
            # call is an ordinary known-function call, not a removal. An
            # explicit wrapper still fails closed below.
            if (( ! removal_wrapper )) && [[ $'\n'"$functions"$'\n' == *$'\n'"$removal_word"$'\n'* ]]; then
              :
            else
              (( command_start && was_direct_start && ! removal_wrapper )) || return 1
              [[ "$token" == "$removal_word" ]] || return 1
              if [[ "$token" != unfunction ]]; then
                removal_mode=option
              else
                removal_mode=names
                removal_background_functions=$functions
                retained_background=$retained_functions
                candidate_background=$__lmline_candidate_defined_functions
                removal_background_pending=1
              fi
            fi
          fi
        fi
        # Track only potential wrapper/assignment command positions, not ordinary
        # arguments such as `printf unset`. A removal behind a wrapper fails closed.
        if (( command_start )); then
          case "$removal_word" in
            builtin|command|env|exec|sudo|time|'!') removal_wrapper=1 ;;
            *=*) removal_wrapper=1 ;;
          esac
        fi
        # Track a command behind wrappers/assignments for remover calls too.
        # `time remover` and `X=1 remover` still run the function and must fail
        # closed, while `command`/`builtin`/`env` bypass functions and leave the
        # parent availability unchanged. Only the first word after the wrapper
        # chain is a command; later words are arguments and stay unchecked here.
        case "$token" in
          ';'|'|'|'&'|'&&'|'||'|'('|')'|'}') remover_call_wrapper=0; remover_call_bypass=0 ;;
        esac
        if (( command_start )) && [[ -z "$name" ]]; then
          case "$removal_word" in
            builtin|command|env)
              remover_call_wrapper=1
              if [[ $'\n'"$functions"$'\n' == *$'\n'"$removal_word"$'\n'* ]]; then
                # A candidate-defined function shadows the bypass builtin.
                remover_call_bypass=0
              else
                remover_call_bypass=1
              fi
              ;;
            exec|sudo|time|'!') remover_call_wrapper=1; remover_call_bypass=0 ;;
            *=*) remover_call_wrapper=1; remover_call_bypass=0 ;;
          esac
        fi

        # Query operands are data, not wrapped remover invocations. Keep
        # substitution scanning intact, but do not infer effects from a name
        # such as `unset` in `command -v unset`.
        if (( command_start )) && [[ "$token" == command && "$remaining" =~ ^[[:blank:]]+-(v|V|pv|pV|vp|Vp|vV|Vv)([[:blank:]]|$) ]]; then
          removal_wrapper=0
          remover_call_wrapper=0
          remover_call_bypass=0
        fi

        # The existing scope stack starts at then/do, not at the condition.
        # Never infer an installation in a condition/header. Count only loop
        # headers here; if/elif already have pending counters below.
        if (( command_start )) && [[ -z "$name" ]]; then
          case "$token" in
            for|select|while|until) installer_loop_pending=$((installer_loop_pending + 1)) ;;
            do) (( installer_loop_pending == 0 )) || installer_loop_pending=$((installer_loop_pending - 1)) ;;
          esac
        fi
        # Any token between declaration and call (or between call and its
        # terminator) cancels the transfer. This also prevents pending state
        # crossing a scope boundary, without interpreting any control flow.
        if [[ -n "$pending_installers" ]]; then
          if [[ "$token" == ';' ]]; then
            if (( installer_called )); then
              pending_installers=${declaration_children[selected_installer]}
              for child_id in $pending_installers; do
                functions+=$'\n'"${declaration_names[child_id]}"$'\n'
                if [[ $'\n'"$__lmline_candidate_defined_functions"$'\n' != *$'\n'"${declaration_names[child_id]}"$'\n'* ]]; then
                  __lmline_candidate_defined_functions+=$'\n'"${declaration_names[child_id]}"$'\n'
                fi
              done
              installer_called=0
            fi
          elif (( ! installer_called && command_start && was_direct_start )) \
            && (( list_operator[brace_depth] == 0 )) && [[ -z "$name" ]]; then
            for child_id in $pending_installers; do
              if [[ "$token" == "${declaration_names[child_id]}" ]]; then
                selected_installer=$child_id
                installer_called=1
              fi
            done
            (( installer_called )) || pending_installers=""
          else
            pending_installers=""
            installer_called=0
          fi
        fi
        # Remover edges transfer only across the immediately adjacent bare
        # direct call, like installers. A bare call with trailing words,
        # redirections, list operators or backgrounding before its terminator
        # fails closed, except for a list-terminating background ampersand
        # which runs the remover in a child shell and leaves the parent
        # availability unchanged.
        if [[ -n "$pending_remover" ]]; then
          if [[ "$token" == ';' ]]; then
            if (( remover_called )); then
              for remover_target in ${declaration_removals[selected_remover]}; do
                removal_pattern=$'\n'"$remover_target"$'\n'
                while [[ $'\n'"$functions"$'\n' == *"$removal_pattern"* ]]; do
                  functions=$'\n'"$functions"$'\n'
                  functions=${functions//"$removal_pattern"/$'\n'}
                  retained_functions=$'\n'"$retained_functions"$'\n'
                  __lmline_candidate_defined_functions=$'\n'"$__lmline_candidate_defined_functions"$'\n'
                  retained_functions=${retained_functions//"$removal_pattern"/$'\n'}
                  __lmline_candidate_defined_functions=${__lmline_candidate_defined_functions//"$removal_pattern"/$'\n'}
                done
              done
              pending_remover=""
              remover_called=0
            fi
          elif (( ! remover_called && command_start && was_direct_start )) \
            && (( list_operator[brace_depth] == 0 )) && [[ -z "$name" ]]; then
            if [[ "$command_word" == "${declaration_names[pending_remover]}" ]]; then
              selected_remover=$pending_remover
              remover_called=1
            else
              pending_remover=""
              remover_called=0
            fi
          else
            if (( remover_called )); then
              if [[ "$token" == '&' ]] && (( ! amp_is_redirect )) && [[ ${cmd:i:1} != '>' ]]; then
                pending_remover=""
                remover_called=0
              else
                return 1
              fi
            else
              if [[ -z "$name" && "$command_word" == "${declaration_names[pending_remover]}" ]]; then
                return 1
              fi
              pending_remover=""
              remover_called=0
            fi
          fi
        fi
        # A command-position call to a recognized remover outside its adjacent
        # top-level edge (including conditions and and/or lists) fails closed: the body would run in the parent shell and remove its
        # targets, which the adjacent-only transfer did not model. Definitions
        # are never calls, and arguments behind ordinary commands stay data.
        # Wrapper-bypassed names (`command`/`builtin`/`env`) never run the
        # function, so they stay unchecked; other wrappers still fail closed.
        if [[ -z "$pending_remover" ]] && [[ -z "$name" ]]; then
          if (( command_start )); then
            for (( remover_scan_idx=${#declaration_names[@]}-1; remover_scan_idx>=0; remover_scan_idx-- )); do
              if [[ "${declaration_names[remover_scan_idx]}" == "$command_word" ]]; then
                if [[ -n "${declaration_removals[remover_scan_idx]}" ]] || [[ -n "${declaration_unsafe[remover_scan_idx]}" ]]; then
                  return 1
                fi
                break
              fi
            done
          elif (( remover_call_wrapper )) && (( ! remover_call_bypass )); then
            case "$token" in
              builtin|command|env|exec|sudo|time|'!') : ;;
              --) : ;;
              *=*) : ;;
              *)
                if [[ "$token" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                  for (( remover_scan_idx=${#declaration_names[@]}-1; remover_scan_idx>=0; remover_scan_idx-- )); do
                    if [[ "${declaration_names[remover_scan_idx]}" == "$token" ]]; then
                      if [[ -n "${declaration_removals[remover_scan_idx]}" ]] || [[ -n "${declaration_unsafe[remover_scan_idx]}" ]]; then
                        return 1
                      fi
                      break
                    fi
                  done
                  remover_call_wrapper=0
                  remover_call_bypass=0
                fi
                ;;
            esac
          elif (( remover_call_wrapper )) && (( remover_call_bypass )); then
            case "$token" in
              builtin|command|env|exec|sudo|time|'!') : ;;
              --) : ;;
              *=*) : ;;
              *) remover_call_wrapper=0; remover_call_bypass=0 ;;
            esac
          fi
        fi
        # At the direct level of a function body, only named declarations and
        # their separators qualify. Commands, wrappers, redirects and control
        # constructs disqualify the body. Child summaries advance only when
        # their own immediate installer is explicitly called.
        if (( ${#function_scope_depth[@]} > 0 )); then
          installer_idx=$((${#function_scope_depth[@]} - 1))
          if (( function_scope_depth[installer_idx] == brace_depth )); then
            if [[ -n "$name" ]]; then
              installer_children[installer_idx]+=" ${#declaration_names[@]}"
            elif [[ "$token" != ';' && "$token" != '}' ]]; then
              installer_pure[installer_idx]=0
            fi
            # A body-local pure remover holds only supported literal function
            # removals and their separators. Any declaration or other command
            # disqualifies the body; targets are collected occurrence-bound.
            if [[ -n "$name" ]]; then
              remover_pure[installer_idx]=0
            elif [[ "$token" == ';' || "$token" == '}' ]]; then
              :
            elif [[ "$token" == unset && "$removal_mode" == option ]]; then
              :
            elif [[ "$token" == unfunction && "$shell" == zsh && "$removal_mode" == names ]]; then
              :
            elif [[ "$token" == -f && "$removal_mode" == names ]]; then
              :
            elif [[ "$removal_mode" == names ]] && __lmline_valid_caller_function_name "$token"; then
              remover_targets[installer_idx]+=" $token"
            else
              remover_pure[installer_idx]=0
            fi
          elif (( function_scope_depth[installer_idx] < brace_depth )) \
            && [[ "$removal_mode" == names ]] && __lmline_valid_caller_function_name "$token"; then
            # A removal nested in a function body's ordinary brace or subshell
            # cannot be transferred as a pure summary, but the enclosing call
            # must not restore and trust a binding that it may remove.
            remover_pure[installer_idx]=0
            remover_targets[installer_idx]+=" $token"
          fi
        fi
        if (( zsh_repeat_count_pending )); then
          # The count is data, but its substitutions were scanned above. Start
          # a new command boundary so compound bodies get their own headers
          # recognized too, rather than leaking short-for values as commands.
          case "$token" in ';'|'|'|'&'|'&&'|'||'|'('|')') return 1 ;; esac
          zsh_repeat_count_pending=0
          out+='; '
          command_start=1
        elif (( command_start )) && [[ "$shell" == zsh && "$token" == repeat ]]; then
          zsh_repeat_count_pending=1
          zsh_unscoped_loop_seen=1
          out+=' '
          command_start=0
        elif (( command_start )) && [[ "$token" == eval && -z "$name" && $'\n'"$functions"$'\n' != *$'\n'eval$'\n'* ]]; then
          if __lmline_extract_literal_eval_words "$remaining" "$shell" "$functions" words eval_functions; then
            # Literal eval runs now in this shell. Transfer removals, not new
            # declarations: their installer/remover metadata belongs to the
            # inner scan and cannot authorize later outer calls.
            retained_background=$retained_functions
            candidate_background=$__lmline_candidate_defined_functions
            eval_retained=""
            while IFS= read -r eval_function_name; do
              [[ -n "$eval_function_name" ]] || continue
              if [[ $'\n'"$eval_functions"$'\n' == *$'\n'"$eval_function_name"$'\n'* ]]; then
                eval_retained+=$'\n'"$eval_function_name"$'\n'
              else
                removal_pattern=$'\n'"$eval_function_name"$'\n'
                __lmline_candidate_defined_functions=$'\n'"$__lmline_candidate_defined_functions"$'\n'
                __lmline_candidate_defined_functions=${__lmline_candidate_defined_functions//"$removal_pattern"/$'\n'}
                while [[ $'\n'"$retained_functions"$'\n' == *"$removal_pattern"* ]]; do
                  retained_functions=$'\n'"$retained_functions"$'\n'
                  retained_functions=${retained_functions//"$removal_pattern"/$'\n'}
                done
                # Eval has no transferable function-body summary. Refuse a
                # removal there rather than restoring stale state at body end.
                (( ${#function_scope_depth[@]} == 0 )) || return 1
                # Match direct removals' refusal of uncertain outer scopes.
                (( was_direct_start && if_pending == 0 && elif_pending == 0 && installer_loop_pending == 0 && zsh_unscoped_loop_seen == 0 )) || return 1
                for removal_scope in "${scope_kind[@]}"; do
                  [[ "$removal_scope" == subshell ]] || return 1
                done
              fi
            done <<<"$functions"
            removal_background_functions=$functions
            removal_background_pending=1
            functions=$eval_retained
            while IFS= read -r word; do
              [[ -z "$word" ]] || substitutions+="; $word "
            done <<<"$words"
          else
            eval_status=$?
            (( eval_status == 2 )) || return 2
            opaque_arguments=1
          fi
          out+=$token
          command_start=0
        elif (( command_start )) && [[ "$token" == trap && -z "$name" && $'\n'"$functions"$'\n' != *$'\n'trap$'\n'* ]]; then
          if __lmline_extract_literal_trap_words "$remaining" "$shell" "$functions" words trap_functions; then
            # Non-EXIT traps may run before a subsequent command. Forget any
            # active transported binding the action removes (EXIT is exempt);
            # do not install action-local definitions or affect unrelated names.
            retained_background=$retained_functions
            candidate_background=$__lmline_candidate_defined_functions
            trap_retained=""
            while IFS= read -r trap_function_name; do
              [[ -n "$trap_function_name" ]] || continue
              if [[ $'\n'"${__lmline_trap_caller_functions-}"$'\n' == *$'\n'"$trap_function_name"$'\n'* && $'\n'"$trap_functions"$'\n' != *$'\n'"$trap_function_name"$'\n'* ]]; then
                removal_pattern=$'\n'"$trap_function_name"$'\n'
                __lmline_candidate_defined_functions=$'\n'"$__lmline_candidate_defined_functions"$'\n'
                __lmline_candidate_defined_functions=${__lmline_candidate_defined_functions//"$removal_pattern"/$'\n'}
                while [[ $'\n'"$retained_functions"$'\n' == *"$removal_pattern"* ]]; do
                  retained_functions=$'\n'"$retained_functions"$'\n'
                  retained_functions=${retained_functions//"$removal_pattern"/$'\n'}
                done
                # As with eval, do not lose a possible removal when a function
                # or uncertain control-flow scope restores its entry snapshot.
                (( ${#function_scope_depth[@]} == 0 && was_direct_start && if_pending == 0 && elif_pending == 0 && installer_loop_pending == 0 && zsh_unscoped_loop_seen == 0 )) || return 2
                for removal_scope in "${scope_kind[@]}"; do
                  [[ "$removal_scope" == subshell ]] || return 2
                done
              else
                trap_retained+=$'\n'"$trap_function_name"$'\n'
              fi
            done <<<"$functions"
            removal_background_functions=$functions
            removal_background_pending=1
            functions=$trap_retained
            while IFS= read -r word; do
              [[ -z "$word" ]] || substitutions+="; $word "
            done <<<"$words"
          else
            trap_status=$?
            (( trap_status == 2 )) || return 2
            opaque_arguments=1
          fi
          out+=$token
          command_start=0
        elif (( command_start )) && [[ ( "$token" == bash || "$token" == zsh ) && -z "$name" ]]; then
          shellc_cwd_uncertain=0
          # Reuse the cwd model on the analysis prefix, retaining the original
          # syntax for its bounded pipeline-isolation proof. This also carries
          # inherited uncertainty through further literal child shells.
          if __lmline_has_relative_cwd_risk "$out$token" "$shell" "$cmd" cwd-state; then
            shellc_cwd_uncertain=1
          fi
          if __lmline_extract_literal_shell_c_words "$token" "$remaining" "$functions" "$shell" "$retained_functions" "$shellc_cwd_uncertain"; then
            :
          else
            shellc_status=$?
            (( shellc_status == 2 )) || return 2
            opaque_arguments=1
          fi
          out+=$token
          command_start=0
        elif (( command_start )) && [[ "$token" == coproc ]]; then
          # A coprocess body runs asynchronously, so it is checked like any
          # other command: consume only the header and leave the body as a new
          # command boundary. A NAME names the coprocess and precedes only a
          # compound body (`{ ...; }`, `( ... )`, `[[ ... ]]`, keyword bodies);
          # a simple body has no NAME, so the next word is the command itself
          # and stays visible. Never executes the body here.
          out+='; '
          command_start=1
          if [[ "$remaining" =~ $coproc_named_compound ]]; then
            [[ "$remaining" =~ ^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]* ]]
            i=$((i + ${#BASH_REMATCH[0]}))
            out+=' '
          fi
        elif (( command_start )) && [[ "$shell" == zsh && "$token" == for && "$remaining" =~ $zsh_for_header ]]; then
          header=${BASH_REMATCH[0]}
          zsh_for_words=${BASH_REMATCH[2]}
          # Parentheses in simple glob qualifiers such as *.txt(N) are static
          # list data. Leave substitutions, executable e-qualifiers and other
          # complex forms untouched so their commands remain conservatively scanned.
          if [[ "$zsh_for_words" == *'$('* || "$zsh_for_words" == *'`'* ||
                "$zsh_for_words" == *'<('* || "$zsh_for_words" == *'>('* ||
                "$zsh_for_words" == *'=('* || "$zsh_for_words" == *':'* ||
                "$zsh_for_words" == *';'* || "$zsh_for_words" == *'|'* ||
                "$zsh_for_words" == *'&'* || "$zsh_for_words" == *'+'* ||
                "$zsh_for_words" == *'#'* || "$zsh_for_words" == *'!'* ||
                "$zsh_for_words" == *'{'* || "$zsh_for_words" == *'}'* ||
                "$zsh_for_words" == *'\\'* || "$zsh_for_words" == *'"'* ||
                "$zsh_for_words" == *"'"* ]]; then
            out+=$token
            command_start=0
          else
            zsh_unscoped_loop_seen=1
            i=$((i + ${#header}))
            out+='; '
            command_start=1
          fi
        elif [[ -n "$name" ]]; then
          # Definitions in or after short-for/repeat loops need control-flow
          # reasoning to prove they run. Fail closed rather than let a possibly
          # skipped body satisfy a later call.
          (( zsh_unscoped_loop_seen == 0 )) || return 1
          (( list_operator[brace_depth] == 0 )) || return 1
          list_definition[brace_depth]=1
          brace_definition[brace_depth]=1
          brace_depth=$((brace_depth + 1))
          list_operator[brace_depth]=0
          list_definition[brace_depth]=0
          brace_definition[brace_depth]=0
          # Only an unconditional top-level declaration can offer a removal
          # edge. Nested/scoped bodies still collect targets so their calls
          # fail closed instead of losing effects on snapshot restoration.
          remover_top_level=$((was_direct_start && brace_depth == 1 && ${#function_scope_depth[@]} == 0 && ${#scope_saved[@]} == 0 && depth == 0 && if_pending == 0 && elif_pending == 0 && installer_loop_pending == 0))
          remover_redefinition_unsafe=""
          if (( ! remover_top_level )); then
            # A nested/scoped benign definition is not proof that a previous
            # remover binding was replaced. Do not let its lexical occurrence
            # mask that binding in the fail-closed lookup below.
            for (( remover_scan_idx=${#declaration_names[@]}-1; remover_scan_idx>=0; remover_scan_idx-- )); do
              if [[ "${declaration_names[remover_scan_idx]}" == "$name" ]]; then
                if [[ -n "${declaration_removals[remover_scan_idx]}${declaration_unsafe[remover_scan_idx]}" ]]; then
                  remover_redefinition_unsafe=1
                fi
                break
              fi
            done
          fi
          functions+=$'\n'"$name"$'\n'
          if [[ $'\n'"$__lmline_candidate_defined_functions"$'\n' != *$'\n'"$name"$'\n'* ]]; then
            __lmline_candidate_defined_functions+=$'\n'"$name"$'\n'
          fi
          function_scope_saved+=("$functions")
          retained_function_scope_saved+=("$retained_functions")
          candidate_function_scope_saved+=("$__lmline_candidate_defined_functions")
          function_scope_depth+=("$brace_depth")
          function_ids+=("${#declaration_names[@]}")
          declaration_names+=("$name")
          declaration_children+=("")
          declaration_removals+=("")
          declaration_unsafe+=("$remover_redefinition_unsafe")
          installer_pure+=("$((was_direct_start && if_pending == 0 && elif_pending == 0 && installer_loop_pending == 0))")
          installer_children+=("")
          remover_pure+=("$remover_top_level")
          remover_targets+=("")
          remover_scope_top_level+=("$remover_top_level")
          direct_start=1
          i=$((i + ${#header}))
          out+='; '
          command_start=1
        elif [[ "$token" == case && $command_start == 1 ]]; then
          depth=$((depth + 1))
          state[depth]=selector
          out+=' '
        elif (( depth > 0 )) && [[ "$token" == ';;' || "$token" == ';&' || "$token" == ';;&' || "$token" == ';|' ]]; then
          (( ${#scope_saved[@]} > 0 )) || return 1
          scope_idx=$((${#scope_saved[@]} - 1))
          [[ ${scope_kind[scope_idx]} == "case-branch" ]] || return 1
          functions=${scope_saved[scope_idx]}
          retained_functions=${retained_scope_saved[scope_idx]}
          __lmline_candidate_defined_functions=${candidate_scope_saved[scope_idx]}
          unset "candidate_scope_saved[$scope_idx]" "retained_scope_saved[$scope_idx]" "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          state[depth]=pattern
          pattern_started=0
          pattern_depth=0
          out+='; '
        elif (( depth > 0 && command_start == 1 )) && [[ "$token" == "esac" ]]; then
          if (( ${#scope_saved[@]} > 0 )); then
            scope_idx=$((${#scope_saved[@]} - 1))
            if [[ ${scope_kind[scope_idx]} == "case-branch" ]]; then
              functions=${scope_saved[scope_idx]}
              retained_functions=${retained_scope_saved[scope_idx]}
              __lmline_candidate_defined_functions=${candidate_scope_saved[scope_idx]}
              unset "candidate_scope_saved[$scope_idx]" "retained_scope_saved[$scope_idx]" "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
            fi
          fi
          depth=$((depth - 1))
          out+=' '
          command_start=0
          compound_end=1
        else
          case "$token" in
            '&&'|'||'|'|')
              (( list_definition[brace_depth] == 0 )) || return 1
              list_operator[brace_depth]=1
              ;;
            ';')
              list_operator[brace_depth]=0
              list_definition[brace_depth]=0
              ;;
            '{')
              if (( command_start )); then
                brace_depth=$((brace_depth + 1))
                list_operator[brace_depth]=0
                list_definition[brace_depth]=0
                brace_definition[brace_depth]=0
                brace_functions_saved[brace_depth]=$functions
                retained_brace_saved[brace_depth]=$retained_functions
                candidate_brace_saved[brace_depth]=$__lmline_candidate_defined_functions
              fi
              ;;
            '}')
              if (( command_start || previous_compound_end )); then
                (( brace_depth > 0 )) || return 1
                name=${brace_definition[brace_depth]}
                closed_brace_pending=0
                if [[ ${brace_functions_saved[brace_depth]+saved} ]]; then
                  closed_brace_functions=${brace_functions_saved[brace_depth]}
                  retained_closed_brace=${retained_brace_saved[brace_depth]}
                  candidate_closed_brace=${candidate_brace_saved[brace_depth]}
                  closed_brace_pending=1
                  unset 'candidate_brace_saved[brace_depth]' 'retained_brace_saved[brace_depth]' 'brace_functions_saved[brace_depth]'
                fi
                if (( ${#function_scope_depth[@]} > 0 )); then
                  scope_idx=$((${#function_scope_depth[@]} - 1))
                  if (( function_scope_depth[scope_idx] == brace_depth )); then
                    functions=${function_scope_saved[scope_idx]}
                    retained_functions=${retained_function_scope_saved[scope_idx]}
                    __lmline_candidate_defined_functions=${candidate_function_scope_saved[scope_idx]}
                    if (( installer_pure[scope_idx] )) && [[ -n "${installer_children[scope_idx]}" ]]; then
                      child_id=${function_ids[scope_idx]}
                      declaration_children[child_id]=${installer_children[scope_idx]}
                      pending_installers=$child_id
                      installer_called=0
                      pending_remover=""
                      remover_called=0
                    elif (( remover_pure[scope_idx] )) && [[ -n "${remover_targets[scope_idx]}" ]]; then
                      child_id=${function_ids[scope_idx]}
                      declaration_removals[child_id]=${remover_targets[scope_idx]}
                      declaration_unsafe[child_id]=""
                      pending_remover=$child_id
                      remover_called=0
                      pending_installers=""
                      installer_called=0
                    elif [[ -n "${remover_targets[scope_idx]//[[:space:]]/}" ]]; then
                      # An impure body that still holds a direct literal removal
                      # would run that removal when called. It never transfers;
                      # any call to it must fail closed.
                      child_id=${function_ids[scope_idx]}
                      declaration_removals[child_id]=""
                      declaration_unsafe[child_id]=1
                    fi
                    if (( remover_scope_top_level[scope_idx] )); then
                      pending_function_definition_id=${function_ids[scope_idx]}
                    fi
                    unset "candidate_function_scope_saved[$scope_idx]" "retained_function_scope_saved[$scope_idx]" "function_scope_saved[$scope_idx]" "function_scope_depth[$scope_idx]"
                    unset "function_ids[$scope_idx]" "installer_pure[$scope_idx]" "installer_children[$scope_idx]"
                    unset "remover_pure[$scope_idx]" "remover_targets[$scope_idx]" "remover_scope_top_level[$scope_idx]"
                  fi
                fi
                brace_depth=$((brace_depth - 1))
                if (( name )); then
                  (( list_operator[brace_depth] == 0 )) || return 1
                  list_definition[brace_depth]=1
                  brace_definition[brace_depth]=1
                fi
                compound_end=1
              fi
              ;;
          esac
          # Conditional bodies are scoped: definitions inside an if branch,
          # loop body or subshell are visible only within that body, never
          # after the containing control flow. Direct unconditional
          # definitions and calls still pass through.
          if [[ "$token" == "if" && $command_start == 1 ]]; then
            if_pending=$((if_pending + 1))
          elif [[ "$token" == "then" && $command_start == 1 ]]; then
            if (( elif_pending > 0 )); then
              elif_pending=$((elif_pending - 1))
              (( ${#scope_saved[@]} > 0 )) || return 1
            elif (( if_pending > 0 )); then
              if_pending=$((if_pending - 1))
              scope_saved+=("$functions")
              retained_scope_saved+=("$retained_functions")
              candidate_scope_saved+=("$__lmline_candidate_defined_functions")
              scope_kind+=("if")
            else
              return 1
            fi
          elif [[ "$token" == "elif" && $command_start == 1 ]]; then
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "if" ]] || return 1
            functions=${scope_saved[scope_idx]}
            retained_functions=${retained_scope_saved[scope_idx]}
            __lmline_candidate_defined_functions=${candidate_scope_saved[scope_idx]}
            elif_pending=$((elif_pending + 1))
          elif [[ "$token" == "else" && $command_start == 1 ]]; then
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "if" ]] || return 1
            functions=${scope_saved[scope_idx]}
            retained_functions=${retained_scope_saved[scope_idx]}
            __lmline_candidate_defined_functions=${candidate_scope_saved[scope_idx]}
          elif [[ "$token" == "fi" && $command_start == 1 ]]; then
            compound_end=1
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "if" ]] || return 1
            functions=${scope_saved[scope_idx]}
            retained_functions=${retained_scope_saved[scope_idx]}
            __lmline_candidate_defined_functions=${candidate_scope_saved[scope_idx]}
            unset "candidate_scope_saved[$scope_idx]" "retained_scope_saved[$scope_idx]" "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          elif [[ "$token" == "do" && $command_start == 1 ]]; then
            scope_saved+=("$functions")
            retained_scope_saved+=("$retained_functions")
            candidate_scope_saved+=("$__lmline_candidate_defined_functions")
            scope_kind+=("loop")
          elif [[ "$token" == "done" && $command_start == 1 ]]; then
            compound_end=1
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "loop" ]] || return 1
            functions=${scope_saved[scope_idx]}
            retained_functions=${retained_scope_saved[scope_idx]}
            __lmline_candidate_defined_functions=${candidate_scope_saved[scope_idx]}
            unset "candidate_scope_saved[$scope_idx]" "retained_scope_saved[$scope_idx]" "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          elif [[ "$token" == '(' ]]; then
            scope_saved+=("$functions")
            retained_scope_saved+=("$retained_functions")
            candidate_scope_saved+=("$__lmline_candidate_defined_functions")
            scope_kind+=("subshell")
          elif [[ "$token" == ')' ]]; then
            compound_end=1
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "subshell" ]] || return 1
            functions=${scope_saved[scope_idx]}
            retained_functions=${retained_scope_saved[scope_idx]}
            __lmline_candidate_defined_functions=${candidate_scope_saved[scope_idx]}
            unset "candidate_scope_saved[$scope_idx]" "retained_scope_saved[$scope_idx]" "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          fi
          # Active caller/candidate functions need no external executable.
          # Removed names retain ordinary builtin/PATH/explicit-path lookup.
          # Keep wrappers such as `command name` unchanged.
          if (( command_start )) && [[ $'\n'"$functions"$'\n' == *$'\n'"$command_word"$'\n'* ]]; then
            out+=':'
          else
            out+=$token
          fi
          case "$token" in
            ';'|'|'|'&'|'&&'|'||'|'('|')') command_start=1 ;;
            # Reserved words preserve an existing command boundary, but the
            # same words used as arguments must not manufacture a repeat body.
            '!'|if|then|else|do|while|until) : ;;
            time)
              # Preserve the position-local function namespace through time,
              # without restoring the stricter direct_start inference edge.
              [[ "$shell" != bash || $command_start != 1 ]] || time_option_pending=1
              ;;
            '{') : ;; # A brace argument does not start a command.
            *)
              # Assignment values remain data (substitutions were scanned
              # above). Only literal identifier assignments preserve an
              # existing command boundary, never ordinary argument words.
              if (( command_start )) && [[ "$token" == *=* ]]; then
                [[ "$token" =~ $assignment_prefix ]] || return 1
              else
                command_start=0
              fi
              ;;
          esac
        fi
        ;;
    esac
    # Unlike command_start, this boundary is not preserved by !/time/while or
    # other prefixes. Both the declaration and call must be standalone.
    if (( command_start )); then
      opaque_arguments=0
      case "$token" in
        ';'|'{'|'('|')'|then|else|do) direct_start=1 ;;
        '&')
          # Only a list-terminating ampersand starts a new direct command;
          # >& / <& / &> are redirections and must not widen inference.
          if (( ! amp_is_redirect )) && [[ ${cmd:i:1} != '>' ]]; then
            direct_start=1
          fi
          ;;
      esac
    fi
  done
  (( depth == 0 && brace_depth == 0 && zsh_repeat_count_pending == 0 )) || return 1
  (( ${#scope_saved[@]} == 0 )) || return 1
  (( if_pending == 0 && elif_pending == 0 )) || return 1
  if (( only_substitutions || only_literal_evals )); then
    out=$substitutions
  else
    out+=$substitutions
  fi
  # Optional named results keep eval/trap state in-process without encoding it
  # into command words. Ordinary callers retain the stdout-only interface.
  if [[ -n ${6:-} ]]; then
    printf -v "$6" '%s' "$out"
    printf -v "$7" '%s' "$retained_functions"
  else
    printf '%s' "$out"
  fi
}

__lmline_extract_command_words() {
  local cmd=$1 shell=${2:-bash} scan_substitutions=${3:-0} functions=${4:-} stripped segment token arithmetic array_assignment coproc_skip_next=0 eval_copy eval_status
  local extracted_copy extracted_functions extracted_words="" cwd_syntax=$cmd
  # Nested literal scripts cannot use the direct-prefix lookup: their
  # surrounding command/wrapper has a separate environment. Fail closed.
  if (( scan_substitutions )) && __lmline_has_path_prefix "$cmd" "$shell"; then
    return 1
  fi
  local enable_query=0 disable_query=0 expect_redirection_operand literal lookup_context command_options time_options
  local -a tokens
  local assignment_prefix='^[A-Za-z_][A-Za-z0-9_]*(\[[^]]+\])?\+?='
  # Bash documents these no-name forms as builtin-list queries; `-n NAME`
  # remains a mutating operation and is rejected below.
  [[ "$cmd" =~ ^[[:space:]]*enable[[:space:]]+-(a|n|p|s)[[:space:]]*$ ]] && enable_query=1
  # Zsh's no-argument `disable` lists disabled names without changing state.
  [[ "$cmd" =~ ^[[:space:]]*disable[[:space:]]*$ ]] && disable_query=1
  local function_definition='[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\([[:space:]]*\)'
  local coproc_compound_keywords='!|if|for|while|until|case|select|time|function|coproc'
  [[ "$shell" != zsh ]] || coproc_compound_keywords+='|repeat'
  local coproc_named_keywords='coproc[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+('"$coproc_compound_keywords"')([[:space:];]|$)'
  local arithmetic_pattern='\(\([^()]*\)\)' array_pattern='[a-zA-Z_][a-zA-Z0-9_]*=\([^()]*\)'
  if [[ -n "$functions" || "$cmd" == *case* || "$cmd" == *function* || "$cmd" == *coproc* || "$cmd" =~ $function_definition || ( "$shell" == zsh && ( "$cmd" == *for* || "$cmd" == *repeat* ) ) ]] || (( scan_substitutions )); then
    if [[ -n ${5:-} ]]; then
      __lmline_case_command_copy "$cmd" "$shell" 0 "$functions" 0 extracted_copy extracted_functions || return 1
      cmd=$extracted_copy
    else
      cmd=$(__lmline_case_command_copy "$cmd" "$shell" 0 "$functions") || return 1
    fi
  elif [[ "$cmd" == *eval* || "$cmd" == *trap* || "$cmd" == *bash* || "$cmd" == *zsh* ]]; then
    # Reuse token boundaries without rewriting the original simple-command
    # path or checking substitutions in unsupported/dynamic eval/trap/shell-c arguments.
    # Unsupported outer syntax remains subject to the existing extractor.
    if eval_copy=$(__lmline_case_command_copy "$cmd" "$shell" 0 "$functions" 1); then
      # A literal eval copy must survive a trailing shell comment in the
      # original text; this is an analysis-only newline, not candidate execution.
      cmd+=$'\n'$eval_copy
    else
      eval_status=$?
      (( eval_status != 2 )) || return 1
    fi
  fi
  # Flat ((...)) arithmetic groups are shell expressions, not command words.
  # Strip them only from this availability-check copy; other policy checks
  # still see the original candidate, and nested forms remain conservative.
  while [[ "$cmd" =~ $arithmetic_pattern ]]; do
    arithmetic=${BASH_REMATCH[0]}
    cmd=${cmd/"$arithmetic"/ }
  done
  # Flat static array assignments contain data words, not commands. Keep
  # nested substitutions conservative by matching only simple parenthesis-free
  # values; other policy checks still use the unmodified candidate.
  while [[ "$cmd" =~ $array_pattern ]]; do
    array_assignment=${BASH_REMATCH[0]}
    cmd=${cmd/"$array_assignment"/ }
  done
  # A conservative lexical approximation: split at command separators and keep
  # the first simple command word after env assignments, negation, and builtins.
  # For zsh, parentheses attached to a glob word are its glob qualifier, not a
  # subshell boundary; the splitter preserves those pairs for this check only.
  __lmline_has_relative_cwd_risk "$cmd" "$shell" "$cwd_syntax" && return 1
  stripped=$(__lmline_split_pipeline "$cmd" 2 "()" "$shell" command-prefix)

  while IFS= read -r segment; do
    coproc_skip_next=0
    lookup_context=""
    command_options=0
    time_options=0
    expect_redirection_operand=0
    read -r -a tokens <<<"$segment"
    for token in "${tokens[@]}"; do
      # Redirection targets are data, including leading redirects before the
      # command. Keep their slash words out of command availability checks.
      if (( expect_redirection_operand )); then
        expect_redirection_operand=0
        continue
      fi
      if [[ "$token" =~ ^([0-9]+)?(>>?|<{1,3}|<>|\>&|<&|&>>?|&>)$ ]]; then
        expect_redirection_operand=1
        continue
      fi
      [[ ! "$token" =~ ^([0-9]+)?(>>?|<{1,3}|<>|\>&|<&|&>>?|&>).+ ]] || continue
      if (( coproc_skip_next )); then
        coproc_skip_next=0
        continue
      fi
      # Keep option refusal consistent even on the simple-command fast path,
      # where the position-local scanner need not have rewritten time's -p.
      if (( time_options )); then
        time_options=0
        case "$token" in
          -p) continue ;;
          -*) return 1 ;;
        esac
      fi
      [[ "$token" =~ $assignment_prefix ]] && continue
      if [[ "$shell" == bash && "$token" == time && -z "$lookup_context" ]]; then
        time_options=1
        continue
      fi
      if [[ "$shell" == zsh && "$token" == repeat ]]; then
        # Supported repeat headers were removed by the syntax-aware copy.
        # Do not let an unsupported wrapper position mask its body by resolving
        # the reserved word itself as an available Zsh command.
        return 1
      fi
      if [[ "$token" == coproc ]]; then
        # A header the syntax-aware copy did not consume in an unsupported
        # wrapper position. Skip it and any same-segment NAME so the body
        # stays visible; cross-segment NAME forms were already consumed by
        # the copy when at a boundary.
        if [[ "$segment" =~ coproc[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(\{|\[|\() ]]; then
          coproc_skip_next=1
        elif [[ "$segment" =~ $coproc_named_keywords ]]; then
          coproc_skip_next=1
        fi
        continue
      fi
      if [[ "$token" == for ]]; then
        # A static word-list loop header names an iteration variable and
        # values, not commands; the semicolon splitter leaves its body in
        # following segments, where command checks continue as usual.
        break
      fi
      # Queries inspect names, they do not invoke their operands. Only the
      # bounded command options are recognized; unknown options fail closed.
      if (( command_options )); then
        case "$token" in
          -v|-V|-pv|-pV|-vp|-Vp|-vV|-Vv) break ;;
          --) command_options=0; continue ;;
          -*) return 1 ;;
        esac
        command_options=0
      fi
      if [[ "$lookup_context" != external ]]; then
        case "$token" in
          command) lookup_context=command; command_options=1; continue ;;
          env) lookup_context=external; continue ;;
        esac
      fi
      if [[ -z "$lookup_context" ]] && __lmline_word_is_command_prefix "$token"; then
        continue
      fi
      case "$token" in
        '{'|[\<\>\&]*)
          continue
          ;;
      esac
      # A standalone `$` is the existing splitter's command-substitution
      # boundary; the following segment contains its command words.
      if [[ "$token" != '$' && ( "$token" == */* || "$token" == *$'\001'* || "$token" == '$'* ) ]]; then
        if [[ "$token" == */* ]]; then
          # Slash paths retain the stricter whole-literal path grammar.
          literal=$(__lmline_literal_command_word "$token") || return 1
        else
          # Adjacent inert quote fragments are valid bare command names (for
          # example t''rue); decode them without expanding or globbing.
          literal=$(__lmline_literal_command_name "$token") || return 1
        fi
        # Quoted wrapper/syntax words are not part of this bounded subset.
        __lmline_word_is_command_prefix "$literal" && return 1
        token=$literal
        if [[ "$token" == */* ]]; then
          __lmline_command_path_available "$token" || return 1
        fi
      fi
      # Bash hash options/operands can mutate remembered command paths. Keep
      # only the unambiguous no-argument and `-l` listing queries; do not
      # simulate the shell's mutable hash table.
      if [[ "$shell" == bash && "$token" == hash ]]; then
        case "$segment" in
          hash|"hash -l") ;;
          *) return 1 ;;
        esac
      fi
      # Bash enable and Zsh disable can change builtin availability. Fail
      # closed rather than interpreting state; only documented no-name queries
      # are safe. Literal eval/trap/shell-c scripts reuse this extractor.
      if [[ "$shell" == bash && "$token" == enable ]] && (( ! enable_query )); then
        return 1
      fi
      if [[ "$shell" == zsh && "$token" == disable ]] && (( ! disable_query )); then
        return 1
      fi
      if [[ -n "$lookup_context" ]]; then
        [[ "$token" != -* ]] || return 1
        if [[ "$lookup_context" == external ]]; then
          __lmline_word_available_without_functions "$token" "$shell" 1 || return 1
        else
          __lmline_word_available_without_functions "$token" "$shell" || return 1
        fi
        # Availability was proved in the wrapper's namespace, not the
        # validator's ambient function namespace or its syntax skip list.
        break
      fi
      [[ -z "$token" || "$token" == '$'* ]] || extracted_words+="$token"$'\n'
      break
    done
  done <<<"$stripped"
  if [[ -n ${5:-} ]]; then
    printf -v "$5" '%s' "$extracted_words"
    printf -v "$6" '%s' "$extracted_functions"
  else
    printf '%s' "$extracted_words"
  fi
}

# Target-shell command check for candidate validation only (never executes
# the word): zsh -f skips startup files, and the quoted $1 stays data.
__lmline_word_available_in_zsh() {
  local word=$1
  command -v zsh >/dev/null 2>&1 || return 1
  command zsh -f -c 'command -v "$1" >/dev/null 2>&1' _ "$word"
}

# Invoked-shell command check for literal `zsh -f -c` scripts: ask one fresh
# Zsh process about all collected words so caller-shell functions and aliases
# do not leak into the new shell's command namespace. Builtins and
# PATH lookups resolve in the child, so they stay available. The words stay
# data in "$@"; only `command -v` lookups run, the candidate script never runs.
__lmline_words_available_in_zsh() {
  (( $# )) || return 0
  command zsh -f -c 'for _lmline_word in "$@"; do command -v "$_lmline_word" >/dev/null 2>&1 || exit 1; done' _ "$@"
}

# Invoked-shell command check for literal `bash -c` scripts: ask one fresh Bash
# process about all collected words so unexported caller-shell functions and
# aliases do not leak into the new shell's command namespace. Exported
# functions are handled positionally by the scanner. The fallback probe must
# ignore them, including exports still present in the validator environment
# after a modeled removal. Words stay data in "$@"; only builtin type lookups
# run, never the candidate script or the resolved commands.
__lmline_words_available_in_bash() {
  (( $# )) || return 0
  "$BASH" -p -c 'for _lmline_word in "$@"; do
    _lmline_found=0
    while IFS= read -r _lmline_kind; do
      case "$_lmline_kind" in builtin|file) _lmline_found=1;; esac
    done < <(builtin type -a -t -- "$_lmline_word" 2>/dev/null)
    (( _lmline_found )) || exit 1
  done' _ "$@"
}

# The clean process reads the exported-name snapshot. Direct internal helper
# tests outside it can request a protected live names-only collection.
__lmline_exported_function_names() {
  if [[ ${__LMLINE_EXPORTED_FUNCTIONS+x} ]]; then
    printf '%s' "$__LMLINE_EXPORTED_FUNCTIONS"
  else
    __lmline_collect_exported_functions
  fi
}

# Static fallback for wrappers and removed imported functions. `type -a`
# exposes real builtins/PATH entries even when a function shadows the name.
# Neither the function nor any PATH executable is invoked.
__lmline_word_available_without_functions() {
  local word=$1 shell=${2:-bash} external_only=${3:-0} kind
  if (( external_only )); then
    builtin type -P -- "$word" >/dev/null 2>&1
    return $?
  fi
  if [[ "$shell" == zsh ]]; then
    __lmline_word_available_in_zsh "$word"
    return $?
  fi
  while IFS= read -r kind; do
    case "$kind" in builtin|file) return 0 ;; esac
  done < <(builtin type -a -t -- "$word" 2>/dev/null)
  return 1
}

# Caller-shell function state is names-only data from validation-boundary.bash.
# Top-level scans get all caller names; ordinary nested Bash scans get only
# still-active exported names. Neither list contains function definitions.
__lmline_valid_caller_function_name() {
  # Match the parser's bounded literal command alphabet rather than the
  # identifier grammar: Bash and Zsh both allow punctuation (and slash) in
  # function names. Names remain newline-delimited data and are never eval'd.
  [[ ${1-} =~ ^[A-Za-z0-9_/:.+@-]+$ ]]
}

# Names of functions defined in the interactive editing shell. The engine's
# snapshot wins once taken; otherwise the live transport is used (frontend
# in-process validation and tests).
__lmline_caller_functions_data() {
  if [[ -n ${__LMLINE_CALLER_FUNCTIONS-} ]]; then
    printf '%s' "$__LMLINE_CALLER_FUNCTIONS"
  else
    # shellcheck disable=SC2031 # Read the frontend's current-process transport.
    printf '%s' "${LMLINE_SHELL_FUNCTIONS-}"
  fi
}

# Snapshot both transports. Entry points do this inline before subprocesses;
# this helper is for trusted initialization/tests, not the validation boundary.
__lmline_snapshot_caller_functions() {
  # shellcheck disable=SC2031 # Snapshot the caller transport in this process.
  __LMLINE_CALLER_FUNCTIONS=${LMLINE_SHELL_FUNCTIONS-}
  export -n __LMLINE_CALLER_FUNCTIONS 2>/dev/null || true
  # shellcheck disable=SC2031 # Snapshot the export transport in this process.
  __LMLINE_EXPORTED_FUNCTIONS=${LMLINE_EXPORTED_FUNCTIONS-}
  export -n __LMLINE_EXPORTED_FUNCTIONS 2>/dev/null || true
  unset LMLINE_SHELL_FUNCTIONS LMLINE_EXPORTED_FUNCTIONS
}

# Inspect only command-prefix positions. The shared splitter hides quoted
# data/comments but retains opaque word markers, so a quoted command still
# ends its prefix. Lists restart inspection; wrappers use the same vocabulary
# as command extraction. Detection does not imply support: the validator below
# deliberately rejects PATH-bearing wrappers and lists.
__lmline_has_path_prefix() {
  local cmd=$1 shell=${2:-bash} segment token expect_redirection_operand
  local -a tokens
  [[ "$cmd" == *PATH=* || "$cmd" == *PATH+=* || ( "$shell" == zsh && ( "$cmd" == *path=* || "$cmd" == *path+=* ) ) ]] || return 1
  while IFS= read -r segment; do
    read -r -a tokens <<<"$segment"
    expect_redirection_operand=0
    for token in "${tokens[@]}"; do
      if (( expect_redirection_operand )); then
        expect_redirection_operand=0
        continue
      fi
      if [[ "$token" =~ ^([0-9]+)?(>>?|<{1,3}|<>|\>&|<&|&>>?|&>)$ ]]; then
        expect_redirection_operand=1
        continue
      fi
      if [[ "$token" =~ ^([0-9]+)?(>>?|<{1,3}|<>|\>&|<&|&>>?|&>).+ ]]; then
        continue
      fi
      case "$token" in
        PATH=*|PATH+=*) return 0 ;;
        path=*|path+=*) [[ "$shell" == zsh ]] && return 0 ;;
        [A-Za-z_]*=*) continue ;;
        -*) continue ;;
        '{'|'}') continue ;;
        for) break ;;
      esac
      __lmline_word_is_command_prefix "${token##*/}" && continue
      break
    done
  done <<<"$(__lmline_split_pipeline "$cmd" 0 "()" "$shell" command-prefix)"
  return 1
}

# Decode only a whitespace-free literal command word. The command-prefix
# splitter marks each quote/escape: a single leading quote marker is allowed,
# but embedded markers (concatenation/escaping) are not. No shell expansion.
# Even quoted paths use this bounded ASCII alphabet; spaces and metacharacters
# are unsupported rather than requiring another shell-word parser.
__lmline_literal_command_word() {
  local word=$1 quote
  if [[ "$word" == $'\001'* ]]; then
    word=${word#$'\001'}
    quote=${word:0:1}
    [[ "$quote" == "'" || "$quote" == '"' ]] || return 1
    [[ ${#word} -ge 2 && "${word: -1}" == "$quote" ]] || return 1
    word=${word:1:${#word}-2}
  fi
  [[ "$word" =~ ^[A-Za-z0-9_/:.+@-]+$ ]] || return 1
  printf '%s\n' "$word"
}

# Decode a bare command name from a bounded shell-word subset. The opt-in
# splitter marks quote openings with byte 001; accept adjacent single/double
# quote fragments (including empty ones) only when the decoded name uses inert
# ASCII characters. Escapes, expansions, whitespace, metacharacters and slash
# paths are rejected; slash paths use the stricter path decoder above.
__lmline_literal_command_name() {
  local raw=$1 decoded="" quote="" ch i
  for ((i = 0; i < ${#raw}; i++)); do
    ch=${raw:i:1}
    if [[ "$ch" == $'\001' ]]; then
      [[ -z "$quote" ]] || return 1
      ((i + 1 < ${#raw})) || return 1
      i=$((i + 1))
      quote=${raw:i:1}
      [[ "$quote" == "'" || "$quote" == '"' ]] || return 1
      continue
    fi
    if [[ -n "$quote" && "$ch" == "$quote" ]]; then
      quote=""
      continue
    fi
    [[ "$ch" =~ ^[A-Za-z0-9_.:+@-]$ ]] || return 1
    decoded+=$ch
  done
  [[ -z "$quote" && -n "$decoded" ]] || return 1
  printf '%s\n' "$decoded"
}

# Explicit command paths use filesystem metadata only, following symlinks.
# Neither candidate text nor the file is executed.
__lmline_command_path_available() {
  [[ -f "$1" && -x "$1" ]]
}

# Check one direct PATH-prefixed simple command using the extractor's words,
# not a second token walk. The extractor intentionally discards assignment
# values; this bounded raw-prefix match retains only the value needed for
# lookup. Wrappers, compound syntax, extra assignments,
# and nested code are unsupported here and fail closed. Quoted/expanded PATH
# values are opaque: only a guaranteed builtin (or slash path) can use them.
__lmline_validate_path_prefix() {
  local cmd=$1 shell=$2 words=$3 value word literal=0 structure segment path_names=PATH
  local -a structure_segments=()
  [[ "$shell" != zsh ]] || path_names='PATH|path'
  local prefix="^[[:blank:]]*(${path_names})(\\+)?=([^[:space:]]*)[[:blank:]]+([^[:space:]]+)"
  # Reject compound/list syntax only when the quote-aware splitter sees it as
  # structure. Delimiters in quoted arguments and comments are inert data.
  structure=$(__lmline_split_pipeline "$cmd" 0 '(){}' "$shell" command-prefix)
  while IFS= read -r segment; do
    [[ -n "$segment" ]] || continue
    structure_segments+=("$segment")
  done <<<"$structure"
  ((${#structure_segments[@]} == 1)) || return 1
  [[ "$cmd" =~ $prefix ]] || return 1
  value=${BASH_REMATCH[3]}
  word=${BASH_REMATCH[4]}
  [[ -z "${BASH_REMATCH[2]}" && "$value" =~ ^[A-Za-z0-9_/:.+@-]*$ ]] && literal=1
  case "$word" in
    \"*|\'*) word=$'\001'"$word" ;;
  esac
  word=$(__lmline_literal_command_word "$word") || return 1
  # The first extracted word must agree with the raw command position.
  # Trailing comment text may contribute extra lexical words to the lossy
  # extractor; the quote-aware structural view above already strips it.
  [[ "${words%%$'\n'*}" == "$word" ]] || return 1
  __lmline_word_is_command_prefix "$word" && return 1
  __lmline_risk_is_runner "$word" && return 1
  __lmline_word_is_shell "${word##*/}" && return 1
  case "$word" in
    eval|trap|source|.) return 1 ;;
  esac
  if [[ "$word" == */* ]]; then
    __lmline_command_path_available "$word"
    return $?
  fi
  __lmline_word_available_under_path "$word" "$value" "$shell" "$literal"
}

# Resolve the probe shell before changing PATH. Candidate values stay data in
# positional parameters; only builtin lookup runs, never the candidate word.
# Set PATH inside the shell, since zsh restores a default on an empty inherited
# PATH. Bash uses the current interpreter with -p so neither a PATH-selected
# shell nor imported functions/startup hooks can handle the probe. An opaque
# value must not be evaluated: accept only a builtin instead.
__lmline_word_available_under_path() {
  local word=$1 path_value=$2 shell=${3:-bash} literal=${4:-1} bin
  if [[ "$shell" == zsh ]]; then
    bin=$(builtin type -P zsh) || return 1
    [[ "$bin" == */* ]] || return 1
    "$bin" -f -c 'if [[ "$3" == 1 ]]; then PATH="$1"; command -v "$2" >/dev/null 2>&1; else [[ $(whence -w "$2") == "$2: builtin" ]]; fi' _ "$path_value" "$word" "$literal"
  else
    "$BASH" -p -c 'if [[ "$3" == 1 ]]; then PATH="$1"; command -v "$2" >/dev/null 2>&1; else [[ $(type -t -- "$2") == builtin ]]; fi' _ "$path_value" "$word" "$literal"
  fi
}

# A relative PATH component (including an empty one) is resolved against the
# current directory, so a shell directory change can invalidate a lookup.
__lmline_path_has_relative_entry() {
  [[ -n "${PATH+set}" ]] || return 1
  local rest=$PATH entry
  while [[ "$rest" == *:* ]]; do
    entry=${rest%%:*}
    [[ "$entry" == /* ]] || return 0
    rest=${rest#*:}
  done
  [[ "$rest" == /* ]] || return 0
  return 1
}

# Find whether a bare external currently resolves through a relative PATH
# entry. Ignore validator functions: only real builtins (unless the wrapper
# requires an external) are independent of PATH. No command body runs.
__lmline_word_resolves_via_relative_path() {
  local word=$1 shell=${2:-bash} lookup_context=${3:-} resolved
  if [[ "$lookup_context" != external ]]; then
    # The cross-shell skip vocabulary is not evidence of a builtin in this
    # target. Reuse the function-free opaque-PATH probe's builtin-only mode.
    __lmline_word_available_under_path "$word" "" "$shell" 0 && return 1
  fi
  resolved=$(builtin type -P -- "$word") || return 1
  [[ -n "$resolved" && "$resolved" != /* ]]
}

# Prove only a literal flat simple-list grammar, not arbitrary shell code.
# Quotes, comments, escapes, assignments, redirections, glob qualifiers,
# grouping and non-pipeline operators all retain the old conservative scan.
# Reserved words are excluded even in argument positions: this is deliberately
# a bounded proof, not another shell parser (syntax is checked separately).
__lmline_is_flat_simple_list() {
  local cmd=$1 word empty_single=$'\047\047' empty_double='""'
  local literal_list='^[A-Za-z0-9_/:.+@;|[:space:]-]+$'
  local -a words
  # Adjacent matching quote delimiters are empty/concatenated fragments; they
  # cannot hide list operators. Nonempty quoted content remains unsupported.
  cmd=${cmd//"$empty_single"/}
  cmd=${cmd//"$empty_double"/}
  [[ "$cmd" =~ $literal_list && "$cmd" != *'||'* ]] || return 1
  cmd=${cmd//[;|]/ }
  cmd=${cmd//$'\n'/ }
  read -r -a words <<<"$cmd"
  for word in "${words[@]}"; do
    case "$word" in
      if|then|elif|else|fi|for|foreach|while|until|do|done|case|in|'esac'|select|function|time|coproc|repeat|end|always|nocorrect|noglob)
        return 1 ;;
    esac
  done
  return 0
}

# Inspect quote-aware command segments for directory-changing builtins. Later
# relative slash paths and bare externals using relative PATH are unreliable.
# Opaque command positions are treated as possible directory changes; candidate
# code is never evaluated.
__lmline_has_relative_cwd_risk() {
  local cmd=$1 shell=${2:-bash} segment token first decoded_first changed=${__lmline_cwd_uncertain:-0} expect_redirection_operand nonfinal
  local split_mode=command-prefix lookup_context command_options
  local -a tokens
  # Prove isolation against the original syntax, not just an analysis copy:
  # function-aware rewriting removes comments/quotes and can make a formerly
  # conservative command look like a flat pipeline. Inspect the copy below
  # for command positions, but never broaden the original grammar proof.
  __lmline_is_flat_simple_list "${3-$cmd}" && split_mode=cwd-pipeline
  while IFS= read -r segment; do
    nonfinal=0
    if [[ "$split_mode" == cwd-pipeline && "$segment" == *$'\003' ]]; then
      nonfinal=1
      segment=${segment%$'\003'}
    fi
    read -r -a tokens <<<"$segment" || continue
    first=""
    lookup_context=""
    command_options=0
    expect_redirection_operand=0
    for token in "${tokens[@]}"; do
      if (( expect_redirection_operand )); then
        expect_redirection_operand=0
        continue
      fi
      if [[ "$token" =~ ^([0-9]+)?(>>?|<{1,3}|<>|\>&|<&|&>>?|&>)$ ]]; then
        expect_redirection_operand=1
        continue
      fi
      if [[ "$token" =~ ^([0-9]+)?(>>?|<{1,3}|<>|\>&|<&|&>>?|&>).+ ]]; then
        continue
      fi
      case "$token" in
        [A-Za-z_]*=*) continue ;;
        '{'|'}') continue ;;
      esac
      # Keep the extractor's bounded command/env lookup context while
      # skipping prefixes. In particular env's operand cannot use a builtin
      # (or the policy skip list) to hide a relative external lookup.
      if (( command_options )); then
        case "$token" in
          -v|-V|-pv|-pV|-vp|-Vp|-vV|-Vv) break ;;
          --) command_options=0; continue ;;
          -*) break ;; # The extractor rejects unsupported options.
        esac
        command_options=0
      fi
      if [[ "$lookup_context" != external ]]; then
        case "$token" in
          command) lookup_context=command; command_options=1; continue ;;
          env) lookup_context=external; continue ;;
        esac
        case "${token##*/}" in
          eval|trap|source|.)
            first=$token
            break
            ;;
        esac
      fi
      if [[ -z "$lookup_context" ]] && __lmline_word_is_command_prefix "${token##*/}"; then
        continue
      fi
      first=$token
      break
    done
    [[ -n "$first" ]] || continue
    if [[ "$first" == *$'\001'* ]]; then
      if ! decoded_first=$(__lmline_literal_command_word "$first"); then
        # Keep opaque words as possible cwd mutators, but do not skip their
        # lookup after a prior change when a bounded bare name is recoverable.
        if (( changed )); then
          [[ "$first" != */* ]] || return 0
          if __lmline_path_has_relative_entry; then
            decoded_first=$(__lmline_literal_command_name "$first") || return 0
            __lmline_word_resolves_via_relative_path "$decoded_first" "$shell" "$lookup_context" && return 0
          fi
        fi
        changed=1
        continue
      fi
      first=$decoded_first
    fi
    if [[ "$lookup_context" != external ]]; then
      case "$first" in
      cd|pushd|popd)
        # A proven non-final stage cannot change its siblings' or parent's
        # cwd. Never clear a prior persistent change; final stages remain
        # conservative for lastpipe and target-shell option differences.
        (( nonfinal )) || changed=1
        continue
        ;;
      chdir)
        [[ "$shell" == zsh ]] && { (( nonfinal )) || changed=1; continue; }
        ;;
      eval|trap|source|.)
        changed=1
        continue
        ;;
      esac
    fi
    (( changed )) || continue
    if [[ "$first" == */* ]]; then
      [[ "$first" == /* ]] || return 0
      continue
    fi
    __lmline_path_has_relative_entry || continue
    __lmline_word_resolves_via_relative_path "$first" "$shell" "$lookup_context" || continue
    return 0
  done <<<"$(__lmline_split_pipeline "$cmd" 2 "(){}" "$shell" "$split_mode")"
  # A literal child needs the position-local state even when this prefix has
  # not itself attempted a cwd-dependent lookup.
  [[ ${4:-} == cwd-state ]] && (( changed )) && return 0
  return 1
}

__lmline_validate_commands_available() {
  local cmd=$1 shell=${2:-bash}
  local word words line caller_list functions="" __lmline_trap_caller_functions __lmline_candidate_defined_functions=""
  local __lmline_exported_functions
  __lmline_exported_functions=$(__lmline_exported_function_names)
  caller_list=$(__lmline_caller_functions_data)
  [[ "$shell" != bash ]] || caller_list+=$'\n'"$__lmline_exported_functions"
  while IFS= read -r line || [[ -n "$line" ]]; do
    __lmline_valid_caller_function_name "$line" || continue
    [[ $'\n'"$functions"$'\n' != *$'\n'"$line"$'\n'* ]] || continue
    functions+=$'\n'"$line"$'\n'
  done <<<"$caller_list"
  # Dynamically scoped context: fresh shell -c clears the caller transport
  # and filters inherited exports against the position-local surviving list.
  __lmline_trap_caller_functions=$functions
  words=$(__lmline_extract_command_words "$cmd" "$shell" 0 "$functions") || return 1
  if __lmline_has_path_prefix "$cmd" "$shell"; then
    __lmline_validate_path_prefix "$cmd" "$shell" "$words"
    return $?
  fi
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    [[ "$word" == */* ]] && continue
    __lmline_word_is_policy_skip "$word" && continue
    # Active caller/candidate functions were resolved by the scanner. Any
    # remaining word must have a real target-shell builtin/PATH fallback;
    # policy helpers in this Bash process are not candidate bindings.
    __lmline_word_available_without_functions "$word" "$shell" && continue
    return 1
  done <<<"$words"
  return 0
}
