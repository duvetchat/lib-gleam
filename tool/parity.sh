#!/usr/bin/env bash
# Keeps PARITY.md honest: every public type, endpoint and client method of the
# Dart package (../duvet-client) must have a line of its own in PARITY.md, and
# --strict fails while any of them is still marked unported.
#
#   tool/parity.sh            check that every Dart symbol is listed
#   tool/parity.sh --strict   also fail while any line says `- [ ]`
#   tool/parity.sh --write    add missing lines, keeping the ones ticked so far
#
# The list lives between the parity:begin and parity:end markers in PARITY.md;
# the prose around it is never touched.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
client="$(cd "${CLIENT_DIR:-$root/../duvet-client}" && pwd)"

exec python3 - "$client" "$root/PARITY.md" "$@" <<'PY'
import re
import sys
from pathlib import Path

client = Path(sys.argv[1])
parity = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else "check"

# Where each kind of Dart symbol comes from, and what to call it here.
SOURCES = [
    ("Models", "lib/models/types.dart", "type"),
    ("REST types", "lib/models/rest_types.dart", "type"),
    ("Gateway envelope", "lib/models/gateway_envelope.dart", "type"),
    ("REST endpoints", "lib/http/methods.dart", "method"),
    ("Gateway client", "lib/gateway/client.dart", "method"),
    ("Gateway manager", "lib/gateway/manager.dart", "method"),
    ("Gateway events", "lib/gateway/events.dart", "method"),
    ("Voice and calls", "lib/gateway/webrtc_controller.dart", "method"),
]

TYPE = re.compile(
    r"^(?:final |sealed |abstract |base |interface )?"
    r"(?:class|enum|mixin|typedef)\s+([A-Za-z_]\w*)"
)
METHOD = re.compile(
    r"^  (?:(?:static|factory)\s+)?"
    r"(?:Future|Stream|void|bool|String|int|double|num|List|Map|Set|Duration|"
    r"Uri|Never|dynamic|Object|[A-Z]\w*)"
    r"(?:<[^>]*(?:>[^>]*)?>)?\s+([a-zA-Z_]\w*)\s*\("
)
GETTER = re.compile(r"^  (?:[A-Za-z_][\w<>, ?]*)\s+get\s+([a-zA-Z_]\w*)")

# Inherited from Object; nothing to port.
OBJECT_MEMBERS = {"toString", "hashCode", "noSuchMethod", "runtimeType"}


def symbols(path: Path, kind: str):
    found = []
    if not path.exists():
        return found
    for line in path.read_text().splitlines():
        match = (TYPE if kind == "type" else METHOD).match(line)
        if match:
            name = match.group(1)
            if name.startswith("_") or name in OBJECT_MEMBERS:
                continue
            found.append(name)
            continue
        if kind == "method":
            match = GETTER.match(line)
            if match and not match.group(1).startswith("_"):
                found.append(match.group(1))
    # Keep the source order, drop duplicates.
    return list(dict.fromkeys(found))


wanted = []
for section, rel, kind in SOURCES:
    for name in symbols(client / rel, kind):
        wanted.append((section, name))

names = {name for _, name in wanted}

begin = "<!-- parity:begin -->"
end = "<!-- parity:end -->"
text = parity.read_text() if parity.exists() else "# Parity with duvet-client\n\n<!-- parity:begin -->\n<!-- parity:end -->\n"
if begin not in text or end not in text:
    text = text.rstrip() + "\n\n" + begin + "\n" + end + "\n"

body = text.split(begin, 1)[1].split(end, 1)[0]

# What is already listed, and whether it is ticked.
listed = {}
line_of = {}
for line in body.splitlines():
    match = re.match(r"^- \[([ x])\] `([^`]+)`", line)
    if match:
        listed[match.group(2)] = match.group(1) == "x"
        line_of[match.group(2)] = line

missing = sorted(names - set(listed))
extra = sorted(set(listed) - names)
pending = sorted(name for name, done in listed.items() if not done)

if mode == "--write":
    out = ["", ""]
    for section, rel, _ in SOURCES:
        section_names = [name for s, name in wanted if s == section]
        if not section_names:
            continue
        out.append(f"## {section}")
        out.append("")
        for name in section_names:
            out.append(line_of.get(name, f"- [ ] `{name}`"))
        out.append("")
    text = text.split(begin, 1)[0] + begin + "\n".join(out).rstrip() + "\n" + end + text.split(end, 1)[1]
    parity.write_text(text)
    print(f"{len(wanted)} Dart symbols listed in {parity}")
    if missing:
        print(f"{len(missing)} were missing and have been added")
    raise SystemExit(0)

for name in extra:
    print(f"PARITY.md lists `{name}`, which the Dart package does not have")
for name in missing:
    print(f"PARITY.md has no line for `{name}`")

print(
    f"{len(names)} Dart symbols, {len(listed)} listed, "
    f"{len(pending)} unported, {len(missing)} missing, {len(extra)} stale"
)
if missing or extra:
    raise SystemExit(1)
if mode == "--strict" and pending:
    raise SystemExit(1)
PY
