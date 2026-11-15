import type { TermixApp } from "@termix-ssh/plugin-sdk/frontend";
import { createHawTab, HawIcon } from "./tab";

const TAB_ID = "haw";

export function activate(app: TermixApp): void {
  app.registerRailItem({
    id: TAB_ID,
    icon: HawIcon,
    titleKey: "tab.title",
    kind: "tab",
    permission: "view",
  });
  app.registerTab(TAB_ID, createHawTab(app), {
    icon: HawIcon,
    titleKey: "tab.title",
    singleton: true,
    hostless: true,
  });
}
