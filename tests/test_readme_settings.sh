#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the README settings tables drift from the command's settings catalog.

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the README settings check"
python3 - "$repo_dir" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
output = subprocess.run(
    ["bash", str(repo / "lmline" / "lmline"), "config", "defaults"],
    check=True, capture_output=True, text=True,
).stdout
catalog = {}
for line in output.splitlines()[1:]:
    fields = line.split("\t")
    if len(fields) >= 2 and fields[0].startswith("LMLINE_"):
        catalog[fields[0]] = fields[1]
if not catalog:
    print("no settings found in config defaults", file=sys.stderr)
    raise SystemExit(1)

row = re.compile(r'^\|\s*`(LMLINE_[A-Z0-9_]+)`\s*\|\s*(.*?)\s*\|')
readme = {}
conflicts = []
for number, line in enumerate((repo / "README.md").read_text().splitlines(), 1):
    match = row.match(line)
    if not match:
        continue
    name = match.group(1)
    cell = match.group(2).strip()
    quoted = re.match(r'`([^`]*)`', cell)
    default = quoted.group(1) if quoted else cell
    if name in readme and readme[name] != default:
        conflicts.append((number, name, readme[name], default))
    readme[name] = default

problems = []
missing = sorted(set(catalog) - set(readme))
extra = sorted(set(readme) - set(catalog))
if missing:
    problems.append("missing from README: " + ", ".join(missing))
if extra:
    problems.append("not in the catalog: " + ", ".join(extra))
for number, name, first, again in conflicts:
    problems.append(f"README.md:{number}: {name} has {again!r} after {first!r}")
for name in sorted(set(catalog) & set(readme)):
    if catalog[name] != readme[name]:
        problems.append(f"{name}: catalog {catalog[name]!r}, README {readme[name]!r}")
if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
print(f"README settings match the catalog ({len(catalog)} settings)")
PY
ok "README settings match the catalog"
