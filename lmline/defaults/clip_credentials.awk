    function is_sep(c) {
      return c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "<" || c == ">"
    }
    function redact_value(v) {
      if (substr(v, 1, 2) == "$" sq && substr(v, length(v), 1) == sq)
        return "$" sq "***REDACTED***" sq
      if (substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"")
        return "\"***REDACTED***\""
      if (substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq)
        return sq "***REDACTED***" sq
      return "***REDACTED***"
    }
    function parse_word(s, i,    c, out, n, q) {
      out = ""
      n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c ~ /[[:space:]]/ || is_sep(c)) break
        if ((c == "\"" || c == sq || (c == "$" && substr(s, i + 1, 1) == sq)) &&
            (out == "" || (i < n && substr(s, i + 1, 1) !~ /[[:space:]]/ && !is_sep(substr(s, i + 1, 1))))) {
          q = c
          if (q == "$") { out = out "$"; i++; q = sq }
          out = out q; i++
          while (i <= n) {
            c = substr(s, i, 1)
            out = out c; i++
            if (c == "\\" && i <= n) { out = out substr(s, i, 1); i++; continue }
            if (c == q) break
          }
          continue
        }
        if (c == "\"" || c == sq || (c == "$" && substr(s, i + 1, 1) == sq)) break
        out = out c; i++
      }
      word_text = out
      word_end = i
    }
    BEGIN {
      sq = sprintf("%c", 39)
      no_value = ",v,e,T,h,"
      rule_count = 0
      rows = split(credential_spec, rule_rows, "[|]")
      for (r = 1; r <= rows; r++) {
        if (rule_rows[r] == "") continue
        fields = split(rule_rows[r], cols, ":")
        for (pad = fields + 1; pad <= 4; pad++) cols[pad] = ""
        rule_count++
        rule_cmd[rule_count] = tolower(cols[1])
        rule_cred[rule_count] = "," cols[2] ","
        rule_keep[rule_count] = "," cols[3] ","
        rule_pos[rule_count] = "," tolower(cols[4]) ","
        cred_n[rule_count] = split(cols[2], tmp_flags, ",")
        for (j = 1; j <= cred_n[rule_count]; j++) cred_f[rule_count, j] = tmp_flags[j]
        keep_n[rule_count] = split(cols[3], tmp_flags, ",")
        for (j = 1; j <= keep_n[rule_count]; j++) keep_f[rule_count, j] = tmp_flags[j]
      }
    }
    function has_flag(list, flag) {
      return index(list, "," flag ",") > 0
    }
    # A command phrase in the policy marks a boundary: process() can re-enter
    # with the rule for that command instead of applying the outer rule further.
    function command_at(pos,    ci, clen, best, before, after) {
      best = 0
      for (ci = 1; ci <= rule_count; ci++) {
        if (rule_cred[ci] == ",," && rule_pos[ci] == ",,") continue
        clen = length(rule_cmd[ci])
        if (clen <= best || substr(line_low, pos, clen) != rule_cmd[ci]) continue
        before = pos > 1 ? substr(line_text, pos - 1, 1) : ""
        after = substr(line_text, pos + clen, 1)
        if ((pos == 1 || is_before(before) || before == sq) &&
            (after == "" || is_after(after) || after == sq)) best = clen
      }
      return best
    }
    function match_long(name,    j, f, best) {
      matched_flag = ""; matched_kind = ""; best = 0
      for (j = 1; j <= cred_n[cur_rule]; j++) {
        f = cred_f[cur_rule, j]
        if (f != "" && tolower(f) == tolower(name) && length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "cred"
        }
      }
      for (j = 1; j <= keep_n[cur_rule]; j++) {
        f = keep_f[cur_rule, j]
        if (f != "" && tolower(f) == tolower(name) && length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "keep"
        }
      }
    }
    # Short flags are case-sensitive; longer names match case-insensitively.
    # The longest policy flag wins, so -passin is not split into -pass plus data.
    function match_at(name, from,    j, f, cand, best) {
      matched_flag = ""; matched_kind = ""; best = 0
      for (j = 1; j <= cred_n[cur_rule]; j++) {
        f = cred_f[cur_rule, j]
        cand = substr(name, from, length(f))
        if (f != "" && ((length(f) == 1 && cand == f) ||
                        (length(f) > 1 && tolower(cand) == tolower(f))) &&
            length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "cred"
        }
      }
      for (j = 1; j <= keep_n[cur_rule]; j++) {
        f = keep_f[cur_rule, j]
        cand = substr(name, from, length(f))
        if (f != "" && ((length(f) == 1 && cand == f) ||
                        (length(f) > 1 && tolower(cand) == tolower(f))) &&
            length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "keep"
        }
      }
    }
    # Consume one following word, keeping whitespace and separators byte-exact.
    # A preserved flag does not swallow the next flag as its value.
    function append_value(mask, from,    j) {
      value_out = ""; value_end = from
      j = from
      while (j <= scan_n && substr(scan_s, j, 1) ~ /[[:space:]]/) {
        value_out = value_out substr(scan_s, j, 1); j++
      }
      if (j <= scan_n && !is_sep(substr(scan_s, j, 1)) &&
          (mask || substr(scan_s, j, 1) != "-")) {
        parse_word(scan_s, j)
        value_out = value_out (mask ? redact_value(word_text) : word_text)
        value_end = word_end
      } else {
        value_end = j
      }
    }
    function scan(s, start,    i, c, out, w, k, name, eq, attached, has_eq, stub, j, pending, rest, tail, clen) {
      scan_s = s; scan_n = length(s)
      out = ""; i = start; scan_end = scan_n + 1
      while (i <= scan_n) {
        c = substr(s, i, 1)
        if (c ~ /[[:space:]]/) { out = out c; i++; continue }
        if (i > start && command_at(i) > 0) { scan_end = i; return out }
        if (is_sep(c)) { out = out c; scan_end = i + 1; return out }
        parse_word(s, i)
        w = word_text; k = word_end
        # A quoted word can contain a whole command line; stop inside it so
        # process() can match the nested command with its own policy row.
        for (j = i + 1; j < k; j++) {
          if (command_at(j) > 0) {
            out = out substr(s, i, j - i); scan_end = j; return out
          }
        }
        if (w == "--help" || w == "--version") { out = out w; i = k; continue }
        # Bare operands (a registry, a key name, a filename) are copied, not
        # treated as the end of the command. Later arguments still get scanned.
        if (substr(w, 1, 1) != "-" && has_flag(rule_pos[cur_rule], tolower(w))) {
          append_value(1, k)
          out = out w value_out
          i = value_end
          continue
        }
        if (substr(w, 1, 2) == "--") {
          name = substr(w, 3)
          eq = index(name, "=")
          if (eq > 0) {
            attached = substr(name, eq + 1); name = substr(name, 1, eq - 1); has_eq = 1
          } else {
            attached = ""; has_eq = 0
          }
          match_long(name)
          if (matched_flag != "") {
            stub = "--" name (has_eq ? "=" : "")
            if (attached != "") {
              out = out stub (matched_kind == "cred" ? redact_value(attached) : attached)
                            i = k
              continue
            }
            append_value(matched_kind == "cred", k)
            out = out stub value_out
                        i = value_end
            continue
          }
          out = out w; i = k; continue
        }
        if (substr(w, 1, 1) == "-" && length(w) > 1) {
          name = substr(w, 2)
          eq = index(name, "=")
          if (eq > 0) { tail = substr(name, eq + 1); name = substr(name, 1, eq - 1) }
          else tail = ""
          j = 1; pending = 1
          while (j <= length(name)) {
            match_at(name, j)
            if (matched_flag != "") {
              out = out "-" substr(name, pending, j - pending) substr(name, j, length(matched_flag))
              pending = j + length(matched_flag)
              rest = substr(name, pending)
              if (rest != "" || tail != "") {
                out = out (rest != "" ? "" : "=") \
                  (matched_kind == "cred" ? redact_value(rest tail) : rest tail)
                                i = k
                break
              }
              append_value(matched_kind == "cred", k)
              out = out value_out
                            i = value_end
              break
            }
            if (has_flag(no_value, substr(name, j, 1))) { j++; continue }
            out = out "-" substr(name, pending)
            if (tail != "") out = out "=" tail
            i = k
            break
          }
          if (j > length(name)) { out = out "-" substr(name, pending); i = k }
          continue
        }
        out = out w; i = k
      }
      return out
    }
    function is_before(c) {
      return (c ~ /[[:space:]]/ || c == ";" || c == "," || c == "&" || c == "|" ||
              c == "(" || c == "/" || c == "=" || c == "\"")
    }
    function is_after(c) {
      return (c ~ /[[:space:]]/ || c == ";" || c == "," || c == "&" || c == "|" ||
              c == ")" || c == "/" || c == "=" || c == "\"")
    }
    # Match whole command phrases, longest first, then scan only their tail.
    function process(s,    out, low, n, i, ci, clen, best, best_rule, before, after, seg) {
      out = ""
      line_text = s; line_low = tolower(s)
      low = line_low
      n = length(s)
      i = 1
      while (i <= n) {
        best = 0; best_rule = 0
        for (ci = 1; ci <= rule_count; ci++) {
          clen = length(rule_cmd[ci])
          if (clen <= best || substr(low, i, clen) != rule_cmd[ci]) continue
          before = i > 1 ? substr(s, i - 1, 1) : ""
          after = substr(s, i + clen, 1)
          if ((i == 1 || is_before(before) || before == sq) &&
              (after == "" || is_after(after) || after == sq)) {
            best = clen; best_rule = ci
          }
        }
        if (best == 0) { out = out substr(s, i, 1); i++; continue }
        out = out substr(s, i, best)
        cur_rule = best_rule
        seg = scan(s, i + best)
        out = out seg
        i = scan_end
      }
      return out
    }
    { print process($0) }
