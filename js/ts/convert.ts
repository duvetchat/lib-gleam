// Between Gleam's values and plain JavaScript ones. Each function here knows one
// kind of value; tool/gen.ts composes them from the types.
import * as prelude from "../build/dev/javascript/libduvet_js/gleam.mjs";
import * as dict from "../build/dev/javascript/gleam_stdlib/gleam/dict.mjs";
import * as option from "../build/dev/javascript/gleam_stdlib/gleam/option.mjs";
import * as timestamp from "../build/dev/javascript/gleam_time/gleam/time/timestamp.mjs";
import * as duration from "../build/dev/javascript/gleam_time/gleam/time/duration.mjs";
import * as error from "../build/dev/javascript/libduvet/libduvet/error.mjs";
import type { DuvetError as DuvetErrorDetail } from "./generated.js";

const { BitArray, Ok, toList } = prelude as any;
export const None: any = (option as any).None;
const Some: any = (option as any).Some;

export const listOut = <T>(list: any, read: (value: any) => T): T[] => [...list].map(read);
export const listIn = <T>(items: readonly T[] | null | undefined, write: (value: T) => any): any =>
  toList((items ?? []).map(write));

export const optionOut = <T>(value: any, read: (value: any) => T): T | null =>
  value instanceof Some ? read(value[0]) : null;
export const optionIn = <T>(value: T | null | undefined, write: (value: T) => any): any =>
  value === null || value === undefined ? new None() : new Some(write(value));

export const dictOut = <T>(value: any, read: (value: any) => T): Record<string, T> => {
  const out: Record<string, T> = {};
  for (const [key, item] of (dict as any).to_list(value)) out[key] = read(item);
  return out;
};
export const dictIn = <T>(value: Record<string, T> | null | undefined, write: (value: T) => any): any =>
  (dict as any).from_list(toList(Object.entries(value ?? {}).map(([key, item]) => [key, write(item)])));

export const bytesOut = (value: any): Uint8Array => value.rawBuffer;
export const bytesIn = (value: Uint8Array): any => new BitArray(value);

export const timestampOut = (value: any): Date => {
  const [seconds, nanoseconds] = (timestamp as any).to_unix_seconds_and_nanoseconds(value);
  return new Date(seconds * 1000 + Math.floor(nanoseconds / 1_000_000));
};
export const timestampIn = (value: Date): any => {
  const ms = value.getTime();
  const seconds = Math.floor(ms / 1000);
  return (timestamp as any).from_unix_seconds_and_nanoseconds(seconds, (ms - seconds * 1000) * 1_000_000);
};

/** A duration, as milliseconds. */
export const durationOut = (value: any): number => (duration as any).to_milliseconds(value);

/** What a failed call throws. `detail` says which failure it was. */
export class DuvetError extends Error {
  readonly detail: DuvetErrorDetail;
  /** The HTTP status, when the API answered. */
  readonly status: number | null;

  constructor(raw: any, detail: DuvetErrorDetail) {
    super((error as any).message(raw));
    this.name = "DuvetError";
    this.detail = detail;
    this.status = optionOut((error as any).status_code(raw), (code) => code);
  }
}

let readError: (raw: any) => DuvetErrorDetail = (raw) => raw;
/** generated.ts knows the error's shape, and convert.ts can't import it back. */
export const useErrorReader = (reader: (raw: any) => DuvetErrorDetail) => {
  readError = reader;
};

export const unwrap = <T>(result: any, read: (value: any) => T): T => {
  if (result instanceof Ok) return read(result[0]);
  throw new DuvetError(result[0], readError(result[0]));
};
