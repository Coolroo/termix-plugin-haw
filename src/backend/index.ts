import type { Router } from "express";
import type { PluginContext } from "@termix-ssh/plugin-sdk/backend";
import { createStore } from "./store.js";
import { createVmctl } from "./vmctl.js";
import { registerRoutes } from "./routes.js";

export async function activate(ctx: PluginContext) {
  const store = await createStore(ctx.db);
  // No public routes: every request needs a Termix login.
  const router = ctx.http.router<Router>();
  registerRoutes(router, ctx, store, createVmctl(ctx));
}

export async function deactivate() {
  // Core closes every SSH connection and route opened through ctx.
}
