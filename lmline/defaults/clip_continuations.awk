    BEGIN {
      sq = sprintf("%c", 39)
      dq = sprintf("%c", 34)
      bs = sprintf("%c", 92)
      cr = sprintf("%c", 13)
      in_s = 0
      in_d = 0
      buf = ""
      has_buf = 0
      buf_shield = ""
      buf_restore = ""
      buf_in_s = 0
      buf_in_d = 0
      buf_has_auth = 0
      buf_has_apikey = 0
      buf_cred = 0
      buf_tail_lc = ""
      buf_trail_has_kw = 0
    }
    # Count trailing backslashes before an optional CR: a CRLF continuation
    # ends with backslash + CR, while the CR is ordinary text on other lines.
    function count_trail(s,    n, i) {
      n = length(s)
      if (n > 0 && substr(s, n, 1) == cr) n--
      i = n
      n = 0
      for (; i >= 1 && substr(s, i, 1) == bs; i--) n++
      return n
    }
    function scan_prefix(s,    i, c, n) {
      n = length(s)
      i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (in_s) {
          if (c == sq) in_s = 0
          i++
        } else if (in_d) {
          if (c == bs) { i += 2 }
          else if (c == dq) { in_d = 0; i++ }
          else { i++ }
        } else {
          if (c == bs) { if (i < n) i += 2; else i++ }
          else if (c == sq) { in_s = 1; i++ }
          else if (c == dq) { in_d = 1; i++ }
          else { i++ }
        }
      }
    }
    # Incremental quote state for the buffered logical line. The buffer ends
    # with an alphanumeric shield and any kept backslashes are an even run,
    # so both are neutral, but they are scanned to stay exact.
    function scan_buf_seg(s,    i, c, n) {
      n = length(s)
      i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (buf_in_s) {
          if (c == sq) buf_in_s = 0
          i++
        } else if (buf_in_d) {
          if (c == bs) { i += 2 }
          else if (c == dq) { buf_in_d = 0; i++ }
          else { i++ }
        } else {
          if (c == bs) { if (i < n) i += 2; else i++ }
          else if (c == sq) { buf_in_s = 1; i++ }
          else if (c == dq) { buf_in_d = 1; i++ }
          else { i++ }
        }
      }
    }
    {
      line = $0
      gsub(raw_token, shield_protect, line)
      # A buffered continuation and a new credential on this line are
      # separate credentials, not one split value: emit the buffered line
      # with its backslash preserved instead of swallowing the next line.
      # A split value continues with a bare fragment (no new prefix), while
      # a new header, URL or command starts its own credential. An open
      # single or double quote in the buffered prefix keeps the logical
      # line joined so the closing quote and command tail survive with
      # valid syntax. A buffer that already holds a credential header and
      # a new header on this line are separate credentials even when the
      # buffer ends open. The open test and the header tests use bounded
      # incremental state so each line costs only its own length.
      if (has_buf && (!(buf_in_s || buf_in_d) || buf_has_auth || buf_has_apikey)) {
        ll = tolower(line)
        if (match(ll, /^[[:space:]]*(authorization[[:space:]]*:|.*api-key[[:space:]]*:|url=|curl([[:space:]]|$))/)) {
          prev = substr(buf, 1, length(buf) - length(buf_shield)) buf_restore
          print prev
          buf = ""
          has_buf = 0
          buf_shield = ""
          buf_restore = ""
          buf_in_s = 0
          buf_in_d = 0
          buf_has_auth = 0
          buf_has_apikey = 0
          buf_cred = 0
          buf_tail_lc = ""
          buf_trail_has_kw = 0
        }
      }
      n_bs = count_trail(line)
      odd = (n_bs % 2)
      has_cr = (length(line) > 0 && substr(line, length(line), 1) == cr)
      pre_len = length(line) - n_bs - (has_cr ? 1 : 0)
      prefix = substr(line, 1, pre_len)
      trail = substr(line, pre_len + 1)
      scan_prefix(prefix)
      # Inside single quotes the backslash is literal, except when the
      # logical line already holds a complete header prefix (a value split):
      # then joining lets the line rules mask the whole credential instead
      # of leaking its second half. Prefix splits without a complete prefix
      # stay unjoined to avoid creating a credential from literal text.
      # Work per line is bounded: the global quote scan covers the current
      # prefix only, the credential tests cover the current prefix plus a
      # bounded tail, and the buffered flags are maintained incrementally.
      is_cred = 0
      prefix_lc = ""
      if (odd) {
        prefix_lc = tolower(prefix)
        if (!has_buf) {
          if (match(prefix_lc, /authorization[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /api[-_]key[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /(^|[^a-z0-9])(-u|--u|--user)[[:space:]=]/)) is_cred = 1
          else if (match(prefix_lc, /--password([[:space:]]|=)/)) is_cred = 1
          else if (match(prefix_lc, /[a-z0-9_.-]*(token|secret|password|pass|key)[a-z0-9_-]*[[:space:]]*[=:]/)) is_cred = 1
        } else if (buf_cred) {
          is_cred = 1
        } else {
          if (match(prefix_lc, /authorization[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /api[-_]key[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /[^a-z0-9](-u|--u|--user)[[:space:]=]/)) is_cred = 1
          else if (match(prefix_lc, /--password([[:space:]]|=)/)) is_cred = 1
          else if (match(prefix_lc, /[a-z0-9_.-]*(token|secret|password|pass|key)[a-z0-9_-]*[[:space:]]*[=:]/)) is_cred = 1
          else if (buf_trail_has_kw && match(prefix_lc, /^[a-z0-9_-]*[[:space:]]*[=:]/)) is_cred = 1
        }
      }
      if (odd && (!in_s || is_cred)) {
        keep = (n_bs > 1) ? substr(trail, 1, n_bs - 1) : ""
        buf_shield = has_cr ? shield_cr : shield_lf
        buf_restore = has_cr ? bs cr : bs
        scan_buf_seg(prefix)
        if (keep != "") scan_buf_seg(keep)
        scan_buf_seg(buf_shield)
        if (prefix_lc == "") prefix_lc = tolower(prefix)
        p_auth = match(prefix_lc, /authorization[[:space:]]*:/)
        p_apikey = match(prefix_lc, /api[-_]key[[:space:]]*:/)
        old_tail = buf_tail_lc
        old_has_kw = buf_trail_has_kw
        shield_lc = tolower(buf_shield)
        seg_lc = prefix_lc keep shield_lc
        tmp_tail = old_tail seg_lc
        if (length(tmp_tail) > 128) buf_tail_lc = substr(tmp_tail, length(tmp_tail) - 127)
        else buf_tail_lc = tmp_tail
        seg_len = length(seg_lc)
        last_break = 0
        for (k = seg_len; k >= 1; k--) {
          cc = substr(seg_lc, k, 1)
          if (!((cc >= "a" && cc <= "z") || (cc >= "0" && cc <= "9") || cc == "_" || cc == "-")) {
            last_break = k
            break
          }
        }
        if (last_break > 0) {
          suffix = substr(seg_lc, last_break + 1)
          buf_trail_has_kw = match(suffix, /(token|secret|password|pass|key)/) ? 1 : 0
        } else {
          if (old_has_kw) buf_trail_has_kw = 1
          else {
            if (length(old_tail) >= 7) old_suffix = substr(old_tail, length(old_tail) - 6)
            else old_suffix = old_tail
            buf_trail_has_kw = match(old_suffix seg_lc, /(token|secret|password|pass|key)/) ? 1 : 0
          }
        }
        buf_has_auth = (buf_has_auth || p_auth) ? 1 : 0
        buf_has_apikey = (buf_has_apikey || p_apikey) ? 1 : 0
        buf_cred = is_cred ? 1 : 0
        if (has_buf) buf = buf prefix keep buf_shield
        else { buf = prefix keep buf_shield; has_buf = 1 }
        next
      } else {
        if (has_buf) { print buf line; buf = ""; has_buf = 0; buf_in_s = 0; buf_in_d = 0; buf_has_auth = 0; buf_has_apikey = 0; buf_cred = 0; buf_tail_lc = ""; buf_trail_has_kw = 0 }
        else print line
      }
    }
    END {
      if (has_buf) {
        buf = substr(buf, 1, length(buf) - length(buf_shield)) buf_restore
        print buf
      }
    }
