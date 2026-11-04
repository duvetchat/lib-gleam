import { BitArray, Error as GleamError, Ok, toList } from "../gleam.mjs";
import { Response } from "../../libduvet/libduvet/http/transport.mjs";
import { Network, TimedOut } from "../../libduvet/libduvet/http/send.mjs";
import { Some } from "../../gleam_stdlib/gleam/option.mjs";

export const new_cell = (value) => ({ value });
export const get_cell = (cell) => cell.value;
export const set_cell = (cell, value) => {
  cell.value = value;
  return undefined;
};

function joined(parts) {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

// One exchange. As on the BEAM, the timeout is idle time: each chunk of the
// answer restarts it.
export async function exchange(method, url, headers, pieces, timeoutMs, onProgress) {
  const body = joined([...pieces].map((piece) => piece.rawBuffer));
  const abort = new AbortController();
  let timer;
  const restart = () => {
    clearTimeout(timer);
    timer = setTimeout(() => abort.abort(), timeoutMs);
  };
  try {
    restart();
    const response = await fetch(url, {
      method,
      headers: [...headers].map(([name, value]) => [name, value]),
      body: body.length > 0 ? body : undefined,
      signal: abort.signal,
    });
    // shortcut: fetch doesn't report upload progress, so this only says the whole body went; upgrade if fetch gains it.
    if (onProgress instanceof Some && body.length > 0) onProgress[0](body.length, body.length);
    const chunks = [];
    if (response.body) {
      for await (const chunk of response.body) {
        restart();
        chunks.push(chunk);
      }
    }
    const answer = toList([...response.headers.entries()]);
    return new Ok(new Response(response.status, answer, new BitArray(joined(chunks))));
  } catch (cause) {
    if (abort.signal.aborted) {
      return new GleamError(new TimedOut(method, new URL(url).pathname, timeoutMs));
    }
    return new GleamError(new Network(cause instanceof Error ? cause.message : String(cause)));
  } finally {
    clearTimeout(timer);
  }
}
