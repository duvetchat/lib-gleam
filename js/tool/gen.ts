// Generates the JavaScript bindings from the BEAM sources, so that the two can't
// drift apart:
//
//   src/libduvet_js/methods.gleam, bot.gleam   http/methods and http/bot with the
//     same bodies, returning promises (the BEAM's block; fetch can't).
//   ts/generated.ts   plain TypeScript types for every type those functions
//     reach, the conversions to and from Gleam's values, and one class method
//     per function, all read from `gleam export package-interface`.

import { mkdirSync } from "node:fs";
import { join } from "node:path";

const js = join(import.meta.dir, "..");
const root = join(js, "..");

// ---------------------------------------------------------------------------
// The Gleam half
// ---------------------------------------------------------------------------

type Block = { name: string | null; text: string };

/** Top-level declarations of a formatted Gleam file; the rest stays as it is. */
function blocks(source: string): Block[] {
  const out: Block[] = [];
  let current: string[] = [];
  let name: string | null = null;
  const flush = () => {
    if (current.length > 0) out.push({ name, text: current.join("\n") });
    current = [];
    name = null;
  };
  for (const line of source.split("\n")) {
    const opened = line.match(/^(?:pub )?fn ([a-z_0-9]+)\(/);
    if (opened) {
      flush();
      name = opened[1]!;
    }
    current.push(line);
    if (name !== null && line === "}") flush();
  }
  flush();
  return out;
}

/** The functions that return a Result yet do no I/O. */
const syncFunctions = new Set(["decode_optional_json", "expect_json", "error_malformed"]);
/** Answer Nil on the BEAM after a request, and so become a promise here. */
const nilRequests = new Set(["send_typing_indicator", "send_recording_indicator"]);

function asyncFunction(block: Block): string {
  if (syncFunctions.has(block.name!)) return block.text;
  const open = block.text.search(/ \{\n/);
  const signature = block.text.slice(0, open);
  const body = block.text.slice(open);
  const arrow = signature.lastIndexOf(") -> ");
  const returned = signature.slice(arrow + 5);
  const isRequest = /^Result\([\s\S]*DuvetError,?\s*\)$/.test(returned) || nilRequests.has(block.name!);
  if (!isRequest) return block.text;
  return (
    signature.slice(0, arrow + 5) +
    `Promise(${returned})` +
    body.replaceAll("|> result.map(", "|> map_ok(").replaceAll("|> result.try(", "|> then_ok(")
  );
}

const promiseHelpers = `
fn map_ok(
  outcome: Promise(Result(a, e)),
  f: fn(a) -> b,
) -> Promise(Result(b, e)) {
  promise.map(outcome, result.map(_, f))
}

fn then_ok(
  outcome: Promise(Result(a, e)),
  f: fn(a) -> Result(b, e),
) -> Promise(Result(b, e)) {
  promise.map(outcome, result.try(_, f))
}
`;

/** What can't stay the same text, because it reads a request's answer itself. */
const methodOverrides: Record<string, string> = {
  ignore_errors: `fn ignore_errors(outcome: Promise(Result(a, DuvetError))) -> Promise(Nil) {
  promise.map(outcome, fn(_) { Nil })
}`,
  get_mention_counts: `pub fn get_mention_counts(client: client.RestClient) -> Promise(Dict(String, Int)) {
  use outcome <- promise.map(request_map(
    client,
    "GET",
    "/api/users/@me/mentions/counts",
    "get mention counts",
    core.NoBody,
    client_default_meta(client),
  ))
  case outcome {
    Ok(object) ->
      object
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, decoding.int_value(pair.1, pair.0)) })
      |> dict.from_list
    Error(_) -> dict.new()
  }
}`,
  use_command: `pub fn use_command(
  client: client.RestClient,
  room_id: String,
  application_id: String,
  data: rest.CommandUse,
) -> Promise(Result(rest.InteractionReply, DuvetError)) {
  let payload = [
    #("type", json.int(2)),
    #("room_id", json.string(room_id)),
    #("application_id", json.string(application_id)),
    #("data", rest.command_use_to_json(data)),
  ]
  use outcome <- promise.map(interact(client, "use command", payload))
  case outcome {
    Ok(reply) -> Ok(reply)
    Error(failure) -> {
      // The command may have changed or gone: the next use asks for the lists
      // again.
      client.clear_commands(client)
      Error(failure)
    }
  }
}`,
  get_space_commands: `pub fn get_space_commands(
  client: client.RestClient,
  space_id: String,
) -> Promise(Result(rest.SpaceCommands, DuvetError)) {
  let now = timestamp.system_time()
  case client.cached_commands(client, space_id, now) {
    Some(cached) -> promise.resolve(Ok(cached))
    None -> {
      use outcome <- promise.map(request_model(
        client,
        "GET",
        "/api/spaces/" <> space_id <> "/commands",
        "get space commands",
        core.NoBody,
        client_default_meta(client),
        rest.space_commands_from_json,
      ))
      case outcome {
        Ok(space_commands) -> {
          client.cache_commands(client, space_id, now, space_commands)
          Ok(space_commands)
        }
        Error(failure) -> Error(failure)
      }
    }
  }
}`,
  forget_space_commands: `pub fn forget_space_commands(
  client: client.RestClient,
  space_id: String,
) -> Nil {
  client.forget_commands(client, space_id)
}`,
};

function generateGleam(source: string, overrides: Record<string, string>): string {
  const text = blocks(source)
    .map((block) => {
      if (block.name === null) return block.text;
      const override = overrides[block.name];
      return override ?? asyncFunction(block);
    })
    .join("\n")
    .replace("import libduvet/http/client\n", "import gleam/javascript/promise.{type Promise}\nimport libduvet_js/rest as client\n")
    .replace("import libduvet/http/commands\n", "")
    .replaceAll(
      /Error\(error\.InvalidArgument\("([^"]*)"\)\)/g,
      'promise.resolve(Error(error.InvalidArgument("$1")))',
    );
  return `// Generated by tool/gen.ts. Edit src/libduvet/http/ instead.\n${text}\n${promiseHelpers}`;
}

await Bun.write(
  join(js, "src/libduvet_js/methods.gleam"),
  generateGleam(await Bun.file(join(root, "src/libduvet/http/methods.gleam")).text(), methodOverrides),
);
await Bun.write(
  join(js, "src/libduvet_js/bot.gleam"),
  generateGleam(await Bun.file(join(root, "src/libduvet/http/bot.gleam")).text(), {}),
);

// ---------------------------------------------------------------------------
// The TypeScript half
// ---------------------------------------------------------------------------

type GleamType =
  | { kind: "named"; name: string; module: string; package: string; parameters: GleamType[] }
  | { kind: "variable"; id: number }
  | { kind: "tuple"; elements: GleamType[] }
  | { kind: "fn"; parameters: GleamType[]; return: GleamType };
type Parameter = { label: string | null; type: GleamType };
type Constructor = { name: string; documentation: string | null; parameters: Parameter[] };
type TypeDefinition = { documentation: string | null; parameters: number; constructors: Constructor[] };
type FunctionDefinition = { documentation: string | null; parameters: Parameter[]; return: GleamType };
type Interface = {
  modules: Record<string, { types: Record<string, TypeDefinition>; functions: Record<string, FunctionDefinition> }>;
};

const interfacePath = join(js, "build/libduvet-interface.json");
mkdirSync(join(js, "build"), { recursive: true });
const exported = Bun.spawnSync(["gleam", "export", "package-interface", "--out", interfacePath], {
  cwd: root,
  stdout: "ignore",
  stderr: "inherit",
});
if (exported.exitCode !== 0) throw new Error("gleam export package-interface failed");
const iface: Interface = await Bun.file(interfacePath).json();

/** Where a Gleam module is once built, relative to ts/ and to dist/. */
function runtimePath(module: string): string {
  if (module === "libduvet/http/methods") return "../build/dev/javascript/libduvet_js/libduvet_js/methods.mjs";
  if (module === "libduvet/http/bot") return "../build/dev/javascript/libduvet_js/libduvet_js/bot.mjs";
  return `../build/dev/javascript/libduvet/${module}.mjs`;
}

const imports = new Map<string, string>();
function moduleVar(module: string): string {
  let name = imports.get(module);
  if (!name) {
    name = `$${imports.size}`;
    imports.set(module, name);
  }
  return name;
}

const camel = (name: string) =>
  name.replace(/_+$/, "").replace(/_+([a-zA-Z0-9])/g, (_, c: string) => c.toUpperCase());
/** A parameter can't be called what strict mode reserves; Gleam's names only reach these few. */
const safe = (name: string) => (["public", "private", "default", "class", "new", "in"].includes(name) ? `${name}_` : name);
const pascal = (name: string) => {
  const c = camel(name);
  return c.charAt(0).toUpperCase() + c.slice(1);
};
const jsdoc = (text: string | null | undefined, indent = "") => {
  const lines = (text ?? "").trim().replaceAll("*/", "* /").split("\n").map((line) => line.trim());
  if (lines.join("") === "") return "";
  return `${indent}/**\n${lines.map((line) => `${indent} * ${line}`.trimEnd()).join("\n")}\n${indent} */\n`;
};

type Mode = "out" | "in";
const named = (t: GleamType, module: string, name: string) =>
  t.kind === "named" && t.module === module && t.name === name;
const isSubject = (t: GleamType) => named(t, "gleam/erlang/process", "Subject");
const isOption = (t: GleamType) => named(t, "gleam/option", "Option");
const isList = (t: GleamType) => named(t, "gleam", "List");

const namesInUse = new Map<string, string>();
function tsName(module: string, name: string): string {
  const key = `${module}.${name}`;
  const taken = namesInUse.get(name);
  if (taken && taken !== key) return `${pascal(module.split("/").at(-1)!)}${name}`;
  namesInUse.set(name, key);
  return name;
}

const wanted = new Map<string, { module: string; name: string; mode: Mode }>();
function want(module: string, name: string, mode: Mode) {
  wanted.set(`${module}.${name}.${mode}`, { module, name, mode });
}

/** A type that has one constructor with one nameless field is that field. */
function wrapper(definition: TypeDefinition): GleamType | null {
  const only = definition.constructors[0];
  if (definition.constructors.length !== 1 || !only || only.parameters.length !== 1) return null;
  return only.parameters[0]!.label === null ? only.parameters[0]!.type : null;
}

function definitionOf(t: Extract<GleamType, { kind: "named" }>): TypeDefinition {
  const definition = iface.modules[t.module]?.types[t.name];
  if (!definition) throw new Error(`no definition for ${t.module}.${t.name}`);
  if (definition.constructors.length === 0) throw new Error(`${t.module}.${t.name} is opaque`);
  return definition;
}

const wrap = (s: string) => (/[|&(]/.test(s) ? `(${s})` : s);
const allStrings = (definition: TypeDefinition) => definition.constructors.every((c) => c.parameters.length === 0);

function tsType(t: GleamType, mode: Mode): string {
  switch (t.kind) {
    case "variable":
      return "unknown";
    case "tuple":
      return `[${t.elements.map((e) => tsType(e, mode)).join(", ")}]`;
    case "fn":
      return `(${t.parameters.map((p, i) => `arg${i}: ${tsType(p, "out")}`).join(", ")}) => ${tsType(t.return, "out")}`;
    case "named": {
      const key = `${t.module}.${t.name}`;
      switch (key) {
        case "gleam.String":
          return "string";
        case "gleam.Int":
        case "gleam.Float":
          return "number";
        case "gleam.Bool":
          return "boolean";
        case "gleam.Nil":
          return "void";
        case "gleam.BitArray":
          return "Uint8Array";
        case "gleam.List":
          return `${wrap(tsType(t.parameters[0]!, mode))}[]`;
        case "gleam/option.Option":
          return `${wrap(tsType(t.parameters[0]!, mode))} | null${mode === "in" ? " | undefined" : ""}`;
        case "gleam/dict.Dict":
          return `Record<string, ${tsType(t.parameters[1]!, mode)}>`;
        case "gleam/dynamic.Dynamic":
        case "gleam/json.Json":
          return "unknown";
        case "gleam/time/timestamp.Timestamp":
          return "Date";
        case "gleam/time/duration.Duration":
          return "number";
      }
      const definition = definitionOf(t);
      const inner = wrapper(definition);
      if (inner) return tsType(inner, mode);
      want(t.module, t.name, mode);
      return tsName(t.module, t.name) + (mode === "in" && !allStrings(definition) ? "Input" : "");
    }
  }
}

/** The field names a constructor has in TypeScript. */
function fieldNames(constructor: Constructor): string[] {
  const nameless = constructor.parameters.filter((p) => p.label === null).length;
  let index = 0;
  return constructor.parameters.map((p) =>
    p.label !== null ? camel(p.label) : nameless === 1 ? "value" : `value${index++}`,
  );
}

function decodeExpr(t: GleamType, value: string): string {
  switch (t.kind) {
    case "variable":
    case "fn":
      return value;
    case "tuple":
      return `[${t.elements.map((e, i) => decodeExpr(e, `${value}[${i}]`)).join(", ")}]`;
    case "named": {
      const key = `${t.module}.${t.name}`;
      switch (key) {
        case "gleam.String":
        case "gleam.Int":
        case "gleam.Float":
        case "gleam.Bool":
        case "gleam/dynamic.Dynamic":
        case "gleam/json.Json":
          return value;
        case "gleam.Nil":
          return "undefined";
        case "gleam.BitArray":
          return `bytesOut(${value})`;
        case "gleam.List":
          return `listOut(${value}, (v: any) => ${decodeExpr(t.parameters[0]!, "v")})`;
        case "gleam/option.Option":
          return `optionOut(${value}, (v: any) => ${decodeExpr(t.parameters[0]!, "v")})`;
        case "gleam/dict.Dict":
          return `dictOut(${value}, (v: any) => ${decodeExpr(t.parameters[1]!, "v")})`;
        case "gleam/time/timestamp.Timestamp":
          return `timestampOut(${value})`;
        case "gleam/time/duration.Duration":
          return `durationOut(${value})`;
      }
      const definition = definitionOf(t);
      const inner = wrapper(definition);
      if (inner) return decodeExpr(inner, `${value}[0]`);
      want(t.module, t.name, "out");
      return `decode${tsName(t.module, t.name)}(${value})`;
    }
  }
}

function encodeExpr(t: GleamType, value: string): string {
  switch (t.kind) {
    case "variable":
    case "fn":
      return value;
    case "tuple":
      return `[${t.elements.map((e, i) => encodeExpr(e, `${value}[${i}]`)).join(", ")}]`;
    case "named": {
      const key = `${t.module}.${t.name}`;
      switch (key) {
        case "gleam.String":
        case "gleam.Int":
        case "gleam.Float":
        case "gleam.Bool":
        case "gleam/dynamic.Dynamic":
        case "gleam/json.Json":
          return value;
        case "gleam.Nil":
          return "undefined";
        case "gleam.BitArray":
          return `bytesIn(${value})`;
        case "gleam.List":
          return `listIn(${value}, (v: any) => ${encodeExpr(t.parameters[0]!, "v")})`;
        case "gleam/option.Option":
          return `optionIn(${value}, (v: any) => ${encodeExpr(t.parameters[0]!, "v")})`;
        case "gleam/dict.Dict":
          return `dictIn(${value}, (v: any) => ${encodeExpr(t.parameters[1]!, "v")})`;
        case "gleam/time/timestamp.Timestamp":
          return `timestampIn(${value})`;
      }
      const definition = definitionOf(t);
      const only = definition.constructors[0]!;
      const inner = wrapper(definition);
      if (inner) return `new ${moduleVar(t.module)}.${only.name}(${encodeExpr(inner, value)})`;
      want(t.module, t.name, "in");
      return `encode${tsName(t.module, t.name)}(${value})`;
    }
  }
}

/** Options and lists may be left out of what goes in. */
const skippable = (t: GleamType) => isOption(t) || isList(t);
const hasSubject = (t: GleamType): boolean => isSubject(t) || (t.kind === "named" && t.parameters.some(hasSubject));

function emitType(module: string, name: string, mode: Mode): string {
  const definition = iface.modules[module]!.types[name]!;
  const ts = tsName(module, name);
  const m = moduleVar(module);
  const doc = jsdoc(definition.documentation);
  const fields = (c: Constructor) => {
    const names = fieldNames(c);
    return c.parameters
      .map((p, i) => {
        if (hasSubject(p.type)) return "";
        const optional = mode === "in" && skippable(p.type) ? "?" : "";
        return `  ${names[i]}${optional}: ${tsType(p.type, mode)};\n`;
      })
      .join("");
  };

  // Constructors without fields read as their names.
  if (allStrings(definition)) {
    const union = definition.constructors.map((c) => `"${c.name}"`).join(" | ");
    const cases =
      mode === "in"
        ? definition.constructors.map((c) => `    case "${c.name}": return new ${m}.${c.name}();`).join("\n")
        : definition.constructors.map((c) => `  if (v instanceof ${m}.${c.name}) return "${c.name}";`).join("\n");
    const declaration = `${doc}export type ${ts} = ${union};\n`;
    return mode === "in"
      ? `${wanted.has(`${module}.${name}.out`) ? "" : declaration}export function encode${ts}(v: ${ts}): any {\n  switch (v) {\n${cases}\n  }\n}\n`
      : `${declaration}export function decode${ts}(v: any): ${ts} {\n${cases}\n  throw new Error("unknown ${ts}");\n}\n`;
  }

  const suffix = mode === "in" ? "Input" : "";
  const single = definition.constructors.length === 1;
  const types = definition.constructors
    .map((c) => {
      if (single) return `${doc}export interface ${ts}${suffix} {\n${fields(c)}}\n`;
      return `${jsdoc(c.documentation)}export interface ${ts}${suffix}_${c.name} {\n  tag: "${c.name}";\n${fields(c)}}\n`;
    })
    .join("");
  const union = single
    ? ""
    : `${doc}export type ${ts}${suffix} = ${definition.constructors.map((c) => `${ts}${suffix}_${c.name}`).join(" | ")};\n`;

  const fieldAccess = (c: Constructor, i: number) => {
    const label = c.parameters[i]!.label;
    return label !== null ? `v.${label === "prototype" ? "prototype$" : label}` : `v[${i}]`;
  };

  if (mode === "out") {
    const object = (c: Constructor) => {
      const names = fieldNames(c);
      const tag = single ? "" : `tag: "${c.name}", `;
      const parts = c.parameters.map((p, i) =>
        hasSubject(p.type) ? "" : `${names[i]}: ${decodeExpr(p.type, fieldAccess(c, i))}`,
      );
      return `{ ${tag}${parts.filter(Boolean).join(", ")} }`;
    };
    const body = single
      ? `  return ${object(definition.constructors[0]!)};\n`
      : definition.constructors.map((c) => `  if (v instanceof ${m}.${c.name}) return ${object(c)};\n`).join("") +
        `  throw new Error("unknown ${ts}");\n`;
    return `${types}${union}export function decode${ts}(v: any): ${ts} {\n${body}}\n`;
  }

  const construct = (c: Constructor) => {
    const names = fieldNames(c);
    const args = c.parameters.map((p, i) =>
      hasSubject(p.type) ? "new None()" : encodeExpr(p.type, `v.${names[i]}`),
    );
    return `new ${m}.${c.name}(${args.join(", ")})`;
  };
  const body = single
    ? `  return ${construct(definition.constructors[0]!)};\n`
    : `  switch (v.tag) {\n${definition.constructors.map((c) => `    case "${c.name}": return ${construct(c)};`).join("\n")}\n  }\n`;
  return `${types}${union}export function encode${ts}(v: ${ts}Input): any {\n${body}}\n`;
}

/** The parameters' names, which the interface keeps only for labelled ones. */
function parameterNames(source: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const block of blocks(source)) {
    if (block.name === null || !block.text.includes(`pub fn ${block.name}(`)) continue;
    const start = block.text.indexOf(`pub fn ${block.name}(`) + `pub fn ${block.name}(`.length;
    let depth = 1;
    const names: string[] = [];
    let piece = "";
    for (let i = start; i < block.text.length && depth > 0; i++) {
      const c = block.text[i]!;
      if (c === "(") depth++;
      if (c === ")") depth--;
      if ((c === "," && depth === 1) || depth === 0) {
        const parameter = piece.trim().split(":")[0]!.trim();
        if (parameter) names.push(parameter.split(/\s+/)[0]!);
        piece = "";
      } else piece += c;
    }
    out.set(block.name, names);
  }
  return out;
}

const isClient = (t: GleamType | undefined) => t !== undefined && named(t, "libduvet/http/client", "RestClient");
const isOptions = (t: GleamType) => named(t, "libduvet/http/methods", "SendMessageOptions");

function emitMethods(className: string, module: string, names: Map<string, string[]>): string {
  const m = moduleVar(module);
  const functions = iface.modules[module]!.functions;
  const methods = Object.entries(functions)
    .filter(([, f]) => isClient(f.parameters[0]?.type))
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, f]) => {
      const parameters = f.parameters.slice(1);
      const given = names.get(name)?.slice(1) ?? [];
      const paramNames = parameters.map((p, i) => safe(camel(p.label ?? given[i] ?? `arg${i}`)));
      // Only what no later parameter needs can be left out.
      let trailing = true;
      const declared = parameters
        .map((p, i) => ({ p, i }))
        .reverse()
        .map(({ p, i }) => {
          const leaveOut = trailing && (isOption(p.type) || isList(p.type) || isOptions(p.type));
          if (!leaveOut) trailing = false;
          return `${paramNames[i]}${leaveOut ? "?" : ""}: ${tsType(p.type, "in")}`;
        })
        .reverse();
      const args = parameters.map((p, i) =>
        encodeExpr(p.type, isOptions(p.type) ? `(${paramNames[i]} ?? {})` : paramNames[i]!),
      );
      const call = `${m}.${name}(${["this.$handle", ...args].join(", ")})`;
      const out = f.return;
      const doc = jsdoc(f.documentation, "  ");
      const method = camel(name);
      if (named(out, "gleam", "Result")) {
        const success = (out as Extract<GleamType, { kind: "named" }>).parameters[0]!;
        return `${doc}  async ${method}(${declared.join(", ")}): Promise<${tsType(success, "out")}> {\n    return unwrap(await ${call}, (v: any) => ${decodeExpr(success, "v")});\n  }\n`;
      }
      if (name === "forget_space_commands") {
        return `${doc}  ${method}(${declared.join(", ")}): void {\n    ${call};\n  }\n`;
      }
      return `${doc}  async ${method}(${declared.join(", ")}): Promise<${tsType(out, "out")}> {\n    return ${decodeExpr(out, `(await ${call})`)};\n  }\n`;
    })
    .join("\n");
  return `export class ${className} {\n  /** @internal */\n  constructor(protected readonly $handle: unknown) {}\n\n${methods}}\n`;
}

const methodsClass = emitMethods(
  "RestMethods",
  "libduvet/http/methods",
  parameterNames(await Bun.file(join(root, "src/libduvet/http/methods.gleam")).text()),
);
const botClass = emitMethods(
  "BotMethods",
  "libduvet/http/bot",
  parameterNames(await Bun.file(join(root, "src/libduvet/http/bot.gleam")).text()),
);

// What index.ts and gateway.ts read besides the methods.
for (const [module, name] of [
  ["libduvet/error", "DuvetError"],
  ["libduvet/http/sign_in", "SignIn"],
  ["libduvet/model/envelope", "GatewayEventPayload"],
  ["libduvet/model/envelope", "GatewayCloseReason"],
  ["libduvet/gateway/feed", "GatewayConnectFailure"],
] as const) {
  want(module, name, "out");
}

// Emitting a type can want more of them, so go until nothing new turns up.
const emitted = new Map<string, string>();
for (;;) {
  const next = [...wanted.entries()].find(([key]) => !emitted.has(key));
  if (!next) break;
  const [key, { module, name, mode }] = next;
  emitted.set(key, emitType(module, name, mode));
}

const importLines = [...imports.entries()]
  .map(([module, name]) => `import * as ${name}_ from "${runtimePath(module)}";\nconst ${name}: any = ${name}_;`)
  .join("\n");

await Bun.write(
  join(js, "ts/generated.ts"),
  `// Generated by tool/gen.ts from \`gleam export package-interface\`. Don't edit.
import {
  None,
  bytesIn,
  bytesOut,
  dictIn,
  dictOut,
  durationOut,
  listIn,
  listOut,
  optionIn,
  optionOut,
  timestampIn,
  timestampOut,
  unwrap,
  useErrorReader,
} from "./convert.js";
${importLines}

${[...emitted.values()].join("\n")}
${methodsClass}
${botClass}
useErrorReader(decodeDuvetError);
`,
);

const count = (module: string) =>
  Object.values(iface.modules[module]!.functions).filter((f) => isClient(f.parameters[0]?.type)).length;
console.log(
  `generated ${count("libduvet/http/methods")} REST and ${count("libduvet/http/bot")} bot methods, ${emitted.size} types`,
);
