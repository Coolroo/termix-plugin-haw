/**
 * Which plugins may act for a person through the service haw.vms, and proof
 * that a call comes from the plugin it names.
 *
 * Core does not tell a service provider which plugin is calling: it passes
 * only the arguments and runs the call as the acting user. A plugin id given
 * as an argument could be any plugin's, so it is never trusted on its own.
 * What core does guarantee is that ctx.registry.provide takes keys under the
 * caller's own id only ("<pluginId>.something"). So a consumer provides a
 * receiver function under "<its id>.hawVmsKey", and bindPlugin("<id>") hands
 * that plugin's key to that receiver and to nothing else. Every call carries
 * the key. This is OpenBao Secrets' handshake (its plugin-areas.ts).
 *
 * The key is an HMAC of the plugin id under a random key made when HAW
 * starts and kept in memory only: a restart of HAW makes new keys, and a
 * consumer binds again when its key is refused (code "bad-key").
 */

import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import type { PluginContext } from "@termix-ssh/plugin-sdk/backend";

/** The registry key suffix a consumer provides its receiver under. */
export const RECEIVER_SUFFIX = "hawVmsKey";

/** The admin setting: plugin ids allowed to act for a person, one a line. */
export const ALLOWED_SETTING = "servicePlugins";

/** Plugin ids as the manifest allows them. */
export const PLUGIN_ID = /^[a-z][a-z0-9-]{1,39}$/;
const KEY = /^[0-9a-f]{64}$/;
const MAX_ALLOWED = 50;

/** The allow-list setting as ids, or a problem for the settings form. */
export function parseAllowed(
  value: unknown,
  self: string,
): { ids: string[]; problem: string | null } {
  if (value === undefined || value === null || value === "") {
    return { ids: [], problem: null };
  }
  if (typeof value !== "string") {
    return { ids: [], problem: "Write one plugin id a line" };
  }
  const ids = [
    ...new Set(
      value
        .split(/[\s,]+/)
        .map((part) => part.trim())
        .filter(Boolean),
    ),
  ];
  const bad = ids.find((id) => !PLUGIN_ID.test(id));
  if (bad) {
    return {
      ids: [],
      problem: `"${bad.slice(0, 40)}" is not a plugin id: use lower-case letters, digits and "-"`,
    };
  }
  if (ids.includes(self)) {
    return { ids: [], problem: `HAW (${self}) does not call its own service` };
  }
  if (ids.length > MAX_ALLOWED) {
    return { ids: [], problem: `At most ${MAX_ALLOWED} plugins` };
  }
  return { ids, problem: null };
}

/** Why a caller is refused, with the service's error code. */
export class CallerError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 403,
  ) {
    super(message);
    this.name = "CallerError";
  }
}

export type Callers = ReturnType<typeof createCallers>;

export function createCallers(ctx: PluginContext) {
  const master = randomBytes(32);
  const keyFor = (pluginId: string) =>
    createHmac("sha256", master).update(`haw.vms:${pluginId}`).digest("hex");

  /** The allow-list as it is now. A broken value allows nothing. */
  async function allowed(): Promise<string[]> {
    const { ids, problem } = parseAllowed(
      await ctx.settings.get<string>(ALLOWED_SETTING),
      ctx.manifest.id,
    );
    return problem ? [] : ids;
  }

  async function mustBeAllowed(pluginId: string): Promise<void> {
    if (!(await allowed()).includes(pluginId)) {
      throw new CallerError(
        `plugin ${pluginId} may not act for people in HAW: an admin adds it to "Plugins that may act for a person" in HAW's settings`,
        "plugin-not-allowed",
      );
    }
  }

  return {
    allowed,

    /**
     * Hands `pluginId` its key through the receiver it provided in
     * ctx.registry. Only that plugin can have provided it, and only a plugin
     * on the allow-list gets a key.
     */
    async bind(pluginId: unknown): Promise<void> {
      if (typeof pluginId !== "string" || !PLUGIN_ID.test(pluginId)) {
        throw new CallerError(
          "bindPlugin needs a plugin id",
          "bad-request",
          400,
        );
      }
      await mustBeAllowed(pluginId);
      // Plugin API 2 answers registry reads with a Promise (the receiver is
      // in the consumer's own process); API 1 answers at once. Await both.
      const receiver: unknown = await ctx.registry.consume<unknown>(
        `${pluginId}.${RECEIVER_SUFFIX}`,
      );
      if (typeof receiver !== "function") {
        throw new CallerError(
          `plugin ${pluginId} has no ${pluginId}.${RECEIVER_SUFFIX} receiver in ctx.registry`,
          "no-receiver",
          409,
        );
      }
      try {
        await (receiver as (key: string) => unknown)(keyFor(pluginId));
      } catch {
        throw new CallerError(
          `plugin ${pluginId} refused its key`,
          "no-receiver",
          409,
        );
      }
    },

    /** The plugin id a caller is, once its key checks out and it is allowed. */
    async verify(plugin: unknown, key: unknown): Promise<string> {
      if (
        typeof plugin !== "string" ||
        !PLUGIN_ID.test(plugin) ||
        typeof key !== "string" ||
        !KEY.test(key)
      ) {
        throw new CallerError(
          "a caller is { plugin, key, user }: call bindPlugin(<your id>) for the key",
          "bad-request",
          400,
        );
      }
      const expected = Buffer.from(keyFor(plugin), "hex");
      if (!timingSafeEqual(expected, Buffer.from(key, "hex"))) {
        throw new CallerError(
          `the key is not ${plugin}'s: call bindPlugin again`,
          "bad-key",
        );
      }
      // Checked on every call, so taking a plugin off the list takes effect
      // at once, also for a plugin that holds a key.
      await mustBeAllowed(plugin);
      return plugin;
    },
  };
}
