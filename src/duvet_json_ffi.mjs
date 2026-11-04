// The JavaScript side of duvet_json_ffi.erl, for the modules js/ builds on.
import { toList } from "./gleam.mjs";

export const is_null = (value) => value === null || value === undefined;

export const bytes = (text) => toList([...new TextEncoder().encode(text)]);

export const byte_to_string = (byte) => String.fromCharCode(byte);

let counter = 0;
export const unique_integer = () => `${Date.now()}${++counter}`;
