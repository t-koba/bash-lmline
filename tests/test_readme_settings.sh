#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the README settings tables drift from the settings catalog, or the
# PS0 default drifts between the catalog, README, CLI, and widget inits.

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the README settings check"
python3 - "$repo_dir" <<'PY'
import os
import re
import shutil
import subprocess
import sys
import tempfile
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
with tempfile.TemporaryDirectory() as config_dir:
    env = os.environ.copy()
    env.pop("LMLINE_PS0", None)
    env["LMLINE_CONFIG_DIR"] = config_dir
    described = subprocess.run(
        ["bash", str(repo / "lmline" / "lmline"), "config", "describe", "LMLINE_PS0"],
        check=True, capture_output=True, text=True, env=env,
    ).stdout
    fields = {}
    for line in described.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value
    actual = fields.get("value")
    default = fields.get("default")
    if actual is None or default is None:
        problems.append("LMLINE_PS0: config describe did not report value and default")
    else:
        if actual != default:
            problems.append(f"LMLINE_PS0: applied value {actual!r}, catalog default {default!r}")
        if readme.get("LMLINE_PS0") != actual:
            problems.append(f"LMLINE_PS0: README {readme.get('LMLINE_PS0')!r}, applied value {actual!r}")
        bash_probe = subprocess.run(
            ["bash", "--norc", "--noprofile", "-i", "-c",
             'source "$1" >/dev/null 2>&1 || exit 1; printf "%s" "$LMLINE_PS0"',
             "_", str(repo / "lmline" / "init.bash")],
            capture_output=True, text=True, env=env,
        )
        if bash_probe.returncode != 0:
            problems.append("lmline/init.bash: could not source the widget init")
        elif bash_probe.stdout != actual:
            problems.append(f"lmline/init.bash: PS0 default {bash_probe.stdout!r}, applied value {actual!r}")
        if shutil.which("zsh"):
            zsh_probe = subprocess.run(
                ["zsh", "-f", "-i", "-c",
                 'source "$1" >/dev/null 2>&1 || exit 1; print -rn -- "$LMLINE_PS0"',
                 "_", str(repo / "lmline" / "init.zsh")],
                capture_output=True, text=True, env=env,
            )
            if zsh_probe.returncode != 0:
                problems.append("lmline/init.zsh: could not source the widget init")
            elif zsh_probe.stdout != actual:
                problems.append(f"lmline/init.zsh: PS0 default {zsh_probe.stdout!r}, applied value {actual!r}")

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
print(f"README settings match the catalog; PS0 defaults match across CLI, Bash, and Zsh ({len(catalog)} settings)")
PY
ok "README and PS0 defaults match the catalog"
