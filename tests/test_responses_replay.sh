#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-responses-replay-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT

cat >"$cfg_tmp/response.json" <<'RESP_EOF'
{"id":"resp_1","object":"response","model":"gpt-5-mini","status":"completed",
 "output":[
  {"type":"reasoning","id":"rs_1","encrypted_content":"placeholder-encrypted"},
  {"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"checking"}]},
  {"type":"function_call","id":"fc_1","call_id":"call_1","name":"command_exists","arguments":"{\"commands\":\"awk\"}"}
 ],
 "usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}
RESP_EOF

__lmline_normalize_response responses "$cfg_tmp/response.json"
[[ $(jq -r '.choices[0].message.content' "$cfg_tmp/response.json") == checking ]] || fail "normalized text"
[[ $(jq -r '.choices[0].message.tool_calls[0].function.name' "$cfg_tmp/response.json") == command_exists ]] || fail "normalized call"
[[ $(jq '[.choices[0].message.responses_replay[]? | select(.type=="reasoning")] | length' "$cfg_tmp/response.json") == 1 ]] || fail "stashed reasoning"

# Append the assistant turn and tool result exactly as the buffered tool loop does.
jq -n '[{role:"system",content:"sys"},{role:"user",content:"do it"}]' >"$cfg_tmp/messages.json"
jq -s '.[0] + [.[1].choices[0].message]' "$cfg_tmp/messages.json" "$cfg_tmp/response.json" >"$cfg_tmp/messages.1.json"
jq -n '{role:"tool",tool_call_id:"call_1",name:"command_exists",content:"awk found"}' >"$cfg_tmp/tool.json"
jq -s '.[0] + .[1:]' "$cfg_tmp/messages.1.json" "$cfg_tmp/tool.json" >"$cfg_tmp/messages.2.json"
jq -n --slurpfile m "$cfg_tmp/messages.2.json" '{model:"gpt-5-mini",messages:$m[0],temperature:0.1,max_tokens:100}' >"$cfg_tmp/source.json"
__lmline_payload_for_format responses "$cfg_tmp/source.json" "$cfg_tmp/next.json"

[[ $(jq '[.input[]? | select(.type=="reasoning")] | length' "$cfg_tmp/next.json") == 1 ]] || fail "replayed reasoning count"
[[ $(jq -r '[.input[]? | select(.type=="reasoning")][0] | "\(.id) \(.encrypted_content)"' "$cfg_tmp/next.json") == "rs_1 placeholder-encrypted" ]] || fail "replayed reasoning verbatim"
[[ $(jq '[.input | to_entries[] | select(.value.type=="reasoning" or .value.type=="function_call" or .value.type=="function_call_output") | .key] | .[0] < .[1] and .[1] < .[2]' "$cfg_tmp/next.json") == "true" ]] || fail "replay order"
[[ $(jq -r '[.input[]? | select(.type=="function_call") | .call_id] | join(" ")' "$cfg_tmp/next.json") == "call_1" ]] || fail "replayed call id"
[[ $(jq -r '[.input[]? | select(.type=="function_call_output") | .call_id] | join(" ")' "$cfg_tmp/next.json") == "call_1" ]] || fail "replayed output id"
[[ $(jq '[.input[]? | select(.type=="message")] | length' "$cfg_tmp/next.json") == 0 ]] || fail "message item duplicated"
[[ $(jq '[.input[]? | select(.role=="assistant")] | length' "$cfg_tmp/next.json") == 1 ]] || fail "assistant text duplicated"

# Chat payloads never carry replay state (reachable after a compatibility round).
__lmline_payload_for_format chat "$cfg_tmp/source.json" "$cfg_tmp/chat.json"
[[ $(jq '[.messages[]? | has("responses_replay")] | any' "$cfg_tmp/chat.json") == "false" ]] || fail "chat replay leak"
[[ $(jq -r '.messages[] | select(.role=="assistant") | .content' "$cfg_tmp/chat.json") == checking ]] || fail "chat content"

# Turns without replay state (older cached shapes) convert as before.
jq -n '[{role:"user",content:"do it"},{role:"assistant",content:"",tool_calls:[{id:"call_9",type:"function",function:{name:"command_exists",arguments:"{}"}}]}]' >"$cfg_tmp/legacy-messages.json"
jq -n --slurpfile m "$cfg_tmp/legacy-messages.json" '{model:"gpt-5-mini",messages:$m[0],temperature:0.1,max_tokens:100}' >"$cfg_tmp/legacy-source.json"
__lmline_payload_for_format responses "$cfg_tmp/legacy-source.json" "$cfg_tmp/legacy-next.json"
[[ $(jq -r '[.input[]? | select(.type=="function_call") | .call_id] | join(" ")' "$cfg_tmp/legacy-next.json") == "call_9" ]] || fail "legacy call"
[[ $(jq '[.input[]? | select(.type=="reasoning")] | length' "$cfg_tmp/legacy-next.json") == 0 ]] || fail "legacy reasoning"

ok "responses reasoning replay"
