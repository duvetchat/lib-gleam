#!/bin/sh
# Packs the package and uses it the way a consumer does: installed into an empty
# project, run under Bun and Node, and type-checked with tsc. Run after a build.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$here"
bun pm pack --destination "$work" >/dev/null
tarball=$(ls "$work"/*.tgz)
tar -tzf "$tarball" > "$work/contents"
grep -q 'package/dist/index.js' "$work/contents"
grep -q 'package/dist/index.d.ts' "$work/contents"
grep -q 'package/build/dev/javascript/libduvet_js/libduvet_js/methods.mjs' "$work/contents"
if grep -qE '\.(erl|d\.mts)$' "$work/contents"; then
  echo "the package carries build leftovers" >&2
  exit 1
fi

mkdir "$work/consumer"
cd "$work/consumer"
echo '{ "name": "consumer", "private": true, "type": "module" }' > package.json
bun add "$tarball" >/dev/null
bun add -d typescript @types/node >/dev/null

cat > use.ts <<'EOF'
import { createServer } from "node:http";
import { DuvetClient, DuvetError, type GatewayMessage } from "libduvet";

const message = {
  id: "m1",
  room_id: "r1",
  content: "hello",
  type: 0,
  created_at: "2026-10-22T10:00:00Z",
  updated_at: "2026-10-22T10:00:00Z",
};
const server = createServer((request, response) => {
  if (request.url!.startsWith("/api/rooms/r1/messages") && request.method === "POST") {
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify(message));
  } else {
    response.statusCode = 404;
    response.end("no");
  }
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const { port } = server.address() as { port: number };

const client = new DuvetClient({ api: `127.0.0.1:${port}`, secure: false, token: "t" });
const sent: GatewayMessage = await client.sendMessage("r1", "hello");
const content: string | null = sent.content;
if (content !== "hello" || !(sent.createdAt instanceof Date)) throw new Error("wrong message");

const failure = await client.getMessages("nope", null, 1).catch((cause: unknown) => cause);
if (!(failure instanceof DuvetError) || failure.status !== 404) throw new Error("wrong failure");
if (failure.detail.tag !== "ApiError") throw new Error("wrong detail");

const gateway = client.gateway();
if (gateway.state !== "disconnected") throw new Error("wrong state");
gateway.on("event", (event) => {
  if (event.tag === "MessageCreateEvent") console.log(event.data.id);
});

// The types are real: each of these must be refused.
// @ts-expect-error a message's ID is a string
const wrong: number = sent.id;
// @ts-expect-error an optional field can be null
const notNull: string = sent.content;
// @ts-expect-error sendMessage needs its content
client.sendMessage("r1").catch(() => {});
void wrong, notNull;

server.close();
console.log("ok");
EOF

test "$(bun run use.ts)" = ok
echo "bun: ok"

cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "esnext",
    "module": "esnext",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": false,
    "outDir": "out",
    "skipLibCheck": false,
    "lib": ["esnext", "dom"],
    "types": ["node"]
  },
  "files": ["use.ts"]
}
EOF
./node_modules/.bin/tsc -p .
echo "tsc: ok"

if command -v node >/dev/null; then
  test "$(node out/use.js)" = ok
  echo "node: ok"
fi
