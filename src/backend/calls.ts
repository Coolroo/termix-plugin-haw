/**
 * What the tab's routes and the service haw.vms share about a vmctl call:
 * the status of each way it fails, the VM name rule, and how a failed or
 * broken reply becomes a refusal.
 */

import { InputError } from "./errors.js";
import type { CallFailure, CallResult } from "./vmctl.js";
import { ProtocolError } from "../shared/protocol.js";
import type { Failure } from "../shared/api.js";

/** HTTP status for each way a call fails. */
export const STATUS: Record<CallFailure, number> = {
  "bad-request": 400,
  version: 409,
  "unknown-verb": 409,
  "not-in-this-version": 409,
  "name-not-allowed": 409,
  protected: 409,
  ceiling: 409,
  "not-found": 404,
  "wrong-state": 409,
  config: 409,
  backend: 502,
  "no-access": 403,
  "not-ssh": 400,
  "no-host-key": 409,
  unreachable: 502,
  timeout: 504,
  "no-reply": 502,
  protocol: 502,
};

/** VM names in a path: what the host may hold, never a wildcard. */
export const VM_NAME = /^[^*?[\]\u0000-\u001f]{1,100}$/;

export function failure(result: Extract<CallResult, { ok: false }>): Failure {
  return {
    error: result.message || result.code,
    code: result.code,
    ...(result.detail ? { detail: result.detail } : {}),
    ...(result.versions ? { versions: result.versions } : {}),
  };
}

export function refuse(result: Extract<CallResult, { ok: false }>): never {
  const { error, ...extra } = failure(result);
  throw new InputError(error, STATUS[result.code], extra);
}

/** A result the protocol checks turn down is the host's fault: 502. */
export function checked<T>(read: () => T): T {
  try {
    return read();
  } catch (error) {
    if (error instanceof ProtocolError) {
      throw new InputError(error.message, 502, { code: "protocol" });
    }
    throw error;
  }
}
