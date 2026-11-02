#!/usr/bin/env bash
# Copies the JSON fixtures from duvet-client into test/fixtures.
#
#   tool/sync-fixtures.sh [CLIENT_DIR]
#
# The canonical generator lives in duvet-client (tool/fixtures/generate.sh):
# it derives the fixtures from the API and gateway Go types. This repository
# consumes the generated files so the two clients decode exactly the same
# payloads. Never edit test/fixtures by hand; regenerate upstream and re-run
# this script.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
client="$(cd "${1:-$root/../duvet-client}" && pwd)"
src="$client/test/fixtures"
out="$root/test/fixtures"

if [[ ! -d "$src" ]]; then
	echo "no fixtures at $src" >&2
	exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp "$src"/*.json "$out"/
echo "$(ls "$out" | wc -l) fixtures copied from $src"
