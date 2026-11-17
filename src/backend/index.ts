import type { Router } from "express";
import type { PluginContext } from "@termix-ssh/plugin-sdk/backend";
import { createStore } from "./store.js";
import { createVmctl } from "./vmctl.js";
import { registerRoutes } from "./routes.js";
import { ALLOWED_SETTING, createCallers, parseAllowed } from "./callers.js";
import { createVmService, SERVICE } from "./service.js";

export async function activate(ctx: PluginContext) {
  const store = await createStore(ctx.db);
  const vmctl = createVmctl(ctx);
  ctx.settings.onValidate("admin", (values): Record<string, string> => {
    if (!(ALLOWED_SETTING in values)) return {};
    const { problem } = parseAllowed(values[ALLOWED_SETTING], ctx.manifest.id);
    return problem ? { [ALLOWED_SETTING]: problem } : {};
  });
  // VM actions for a person, for the plugins an admin allows (1.0.3).
  ctx.services.provide(
    SERVICE,
    createVmService(ctx, store, vmctl, createCallers(ctx)),
  );
  // No public routes: every request needs a Termix login.
  const router = ctx.http.router<Router>();
  registerRoutes(router, ctx, store, vmctl);
}

export async function deactivate() {
  // Core closes every SSH connection and route opened through ctx.
}
