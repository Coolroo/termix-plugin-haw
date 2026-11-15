/**
 * One vmctl call on a VM host: the request on standard input through
 * Termix's SSH pipeline, as the person who asked, and the reply checked
 * against the protocol. Every way it can fail ends in a code the page knows.
 */

import { randomUUID } from "node:crypto";
import type { PluginContext } from "@termix-ssh/plugin-sdk/backend";
import {
  buildRequest,
  clip,
  encodeRequest,
  MAX_REPLY_BYTES,
  parseReply,
  ProtocolError,
  type ErrorCode,
  type Verb,
} from "../shared/protocol.js";
import { INTERFACES, type InterfaceId } from "../shared/interfaces.js";
import { isSshHost } from "../shared/hosts.js";

/** HAW's own failure codes, beside the protocol's. */
export type CallFailure =
  | ErrorCode
  | "no-access"
  | "not-ssh"
  | "no-host-key"
  | "unreachable"
  | "timeout"
  | "no-reply"
  | "protocol";

export type CallResult =
  | { ok: true; result: unknown }
  | {
      ok: false;
      code: CallFailure;
      message: string;
      /** What vmctl wrote to standard error, cut short, for "no-reply". */
      detail?: string;
      versions?: number[];
    };

/** The most a vmctl call may take; the protocol asks back ends for 120 s. */
export const CALL_TIMEOUT_MS = 150_000;

export type Vmctl = (
  hostId: number,
  iface: InterfaceId,
  verb: Verb,
  args?: Record<string, unknown>,
) => Promise<CallResult>;

export function createVmctl(ctx: PluginContext): Vmctl {
  return async (hostId, iface, verb, args = {}) => {
    // The host as the acting person may connect to it. Without a stored host
    // key, a connection with no person to ask takes whatever key the server
    // shows: refuse instead.
    const host = await ctx.ssh.resolveHost(hostId);
    if (!host) {
      return {
        ok: false,
        code: "no-access",
        message: "you can't connect to this host",
      };
    }
    if (!isSshHost(host)) {
      return { ok: false, code: "not-ssh", message: "this host has no SSH" };
    }
    if (!host.hostKeyFingerprint) {
      return {
        ok: false,
        code: "no-host-key",
        message: "Termix has no stored host key for this host",
      };
    }
    const request = buildRequest(randomUUID(), verb, args);
    let out;
    try {
      out = await ctx.ssh.exec(host, INTERFACES[iface].command, {
        purpose: "haw",
        stdin: encodeRequest(request),
        timeoutMs: CALL_TIMEOUT_MS,
        maxOutputBytes: MAX_REPLY_BYTES,
      });
    } catch (error) {
      return {
        ok: false,
        code: "unreachable",
        message: clip(
          error instanceof Error ? error.message : String(error),
          500,
        ),
      };
    }
    if (out.timedOut) {
      return {
        ok: false,
        code: "timeout",
        message: "vmctl did not answer in time",
      };
    }
    if (out.truncated) {
      return {
        ok: false,
        code: "protocol",
        message: "vmctl's reply is too large",
      };
    }
    try {
      const reply = parseReply(out.stdout, request);
      if (reply.ok) return { ok: true, result: reply.result };
      return {
        ok: false,
        code: reply.error.code,
        message: reply.error.message,
        ...(reply.error.versions ? { versions: reply.error.versions } : {}),
      };
    } catch (error) {
      if (!(error instanceof ProtocolError)) throw error;
      const noReply = !out.stdout.trim();
      const detail = clip(`${out.stderr}\n${out.stdout}`.trim(), 2048);
      return {
        ok: false,
        code: noReply ? "no-reply" : "protocol",
        message: noReply
          ? `vmctl sent no reply (exit code ${out.code ?? "none"})`
          : error.message,
        ...(detail ? { detail } : {}),
      };
    }
  };
}
