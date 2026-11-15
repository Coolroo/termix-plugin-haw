// Helpers for the rehearsal driver. Runs inside the Termix container and
// talks to Termix over loopback only (BASE), as the browser does: the jwt
// cookie from /users/login.
import { createRequire } from "node:module";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

export const BASE = process.env.TERMIX_BASE ?? "http://127.0.0.1:8080";
export const DIR = process.env.REH_DIR ?? "/tmp/haw-reh";
const STATE = `${DIR}/state.json`;

// Termix's own copy of ws, for the terminal socket with a cookie.
const require = createRequire("/app/package.json");
export const WebSocket = require("ws");

export function load() {
  return existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : {};
}
export function save(state) {
  writeFileSync(STATE, JSON.stringify(state, null, 2), { mode: 0o600 });
}

/** One request. `auth` is { cookie } or { bearer }. */
export async function req(
  method,
  path,
  { auth, body, raw, headers = {} } = {},
) {
  const h = { ...headers };
  if (auth?.cookie) h.cookie = `jwt=${auth.cookie}`;
  if (auth?.bearer) h.authorization = `Bearer ${auth.bearer}`;
  let payload;
  if (raw !== undefined) {
    payload = raw;
    h["content-type"] ??= "application/octet-stream";
  } else if (body !== undefined) {
    payload = JSON.stringify(body);
    h["content-type"] = "application/json";
  }
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: h,
    body: payload,
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = text;
  }
  return {
    status: res.status,
    body: json,
    setCookie: res.headers.getSetCookie?.() ?? [],
  };
}

/** Signs in; returns the jwt cookie's value. */
export async function login(username, password) {
  const r = await req("POST", "/users/login", { body: { username, password } });
  const cookie = r.setCookie
    .map((c) => /^jwt=([^;]+)/.exec(c)?.[1])
    .find(Boolean);
  if (r.status !== 200 || !cookie) {
    throw new Error(
      `login ${username}: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`,
    );
  }
  return decodeURIComponent(cookie);
}

/**
 * Opens the SSH terminal's socket for a saved host, as the terminal tab does,
 * and answers Termix's new-host-key prompt with `action`. Termix stores the
 * key when the person accepts. Resolves with what the socket said.
 */
export function answerHostKey(cookie, host, action = "accept") {
  return new Promise((resolve) => {
    const seen = [];
    const ws = new WebSocket(
      `${BASE.replace(/^http/, "ws")}/plugin-ws/ssh-terminal/terminal`,
      {
        headers: { cookie: `jwt=${cookie}` },
      },
    );
    const done = (result) => {
      clearTimeout(timer);
      try {
        ws.close();
      } catch {}
      resolve({ ...result, seen });
    };
    const timer = setTimeout(
      () => done({ prompted: false, timeout: true }),
      30000,
    );
    let prompted = null;
    ws.on("open", () => {
      ws.send(
        JSON.stringify({
          type: "connectToHost",
          data: {
            cols: 80,
            rows: 24,
            hostConfig: {
              id: host.id,
              ip: host.ip,
              port: host.port,
              username: host.username,
              authType: "credential",
              credentialId: host.credentialId,
            },
          },
        }),
      );
    });
    ws.on("message", (data) => {
      let msg;
      try {
        msg = JSON.parse(String(data));
      } catch {
        return;
      }
      seen.push(msg.type);
      if (msg.type === "host_key_verification_required") {
        prompted = msg.data;
        ws.send(
          JSON.stringify({
            type: "host_key_verification_response",
            data: { action },
          }),
        );
        return;
      }
      // After the key: the login and the forced command, or an error. Either
      // way the key exchange is over.
      if (
        prompted &&
        ["connected", "error", "disconnected", "data"].includes(msg.type)
      ) {
        done({ prompted, after: msg.type, message: msg.message });
      }
    });
    ws.on("close", () => done({ prompted, closed: true }));
    ws.on("error", (e) => done({ prompted, error: String(e) }));
  });
}

/** Records one check: PASS or FAIL, with the status and the key part. */
export function recorder() {
  const results = [];
  const check = (name, ok, status, evidence) => {
    const line = { name, result: ok ? "PASS" : "FAIL", status, evidence };
    results.push(line);
    console.log(
      `${line.result} ${name} [${status}] ${typeof evidence === "string" ? evidence : JSON.stringify(evidence)}`,
    );
    return ok;
  };
  return { results, check };
}
