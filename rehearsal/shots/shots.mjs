// Screenshots of the HAW tab in the throwaway Termix. Runs in a Playwright
// container that shares Termix's network namespace (no published port):
//   docker run --rm --network container:haw-reh-termix \
//     -e CHROME=/ms-playwright/chromium-<n>/chrome-linux/chrome \
//     -v <dir with playwright-core + this file>:/pw:ro -v <state dir>:/in:ro \
//     -v <out dir>:/out -w /pw mcr.microsoft.com/playwright:v1.49.1-noble node shots.mjs
// /in/state.json is the driver's state (the people's passwords); /out gets PNGs.
import { chromium } from "playwright-core";
import { readFileSync } from "node:fs";

const state = JSON.parse(readFileSync("/in/state.json", "utf8"));
const BASE = "http://127.0.0.1:8080";
const browser = await chromium.launch({
  executablePath: process.env.CHROME,
  args: ["--no-sandbox"],
});
const log = (...a) => console.log("shots:", ...a);
const shot = async (page, name) => {
  await page.waitForTimeout(600);
  await page.screenshot({ path: `/out/${name}.png` });
  log("saved", name);
};

async function signIn(viewport, username, password) {
  const ctx = await browser.newContext({ viewport, colorScheme: "dark" });
  const page = await ctx.newPage();
  await page.goto(BASE + "/", { waitUntil: "networkidle" });
  await page.locator("#login-user").fill(username);
  await page.locator("#login-pass").fill(password);
  await page.getByRole("button", { name: "Login" }).last().click();
  await page.waitForTimeout(3000);
  // A new person's first sign-in opens onboarding: keep every plugin on and
  // go through it.
  for (let i = 0; i < 10; i++) {
    const step = await page
      .getByText(/Step \d+ of \d+/)
      .first()
      .isVisible()
      .catch(() => false);
    if (!step) break;
    const all = page.getByRole("button", { name: "Turn all on" });
    if (await all.count()) await all.click();
    for (const name of ["Skip", "Next", "Finish", "Done", "Get started"]) {
      const b = page.getByRole("button", { name, exact: true });
      if (await b.count()) {
        await b.last().click();
        break;
      }
    }
    await page.waitForTimeout(1200);
  }
  return { ctx, page };
}

/** Opens the VMs tab as a full tab and waits for the VM list. */
async function openHaw(page, { phone = false } = {}) {
  if (phone) {
    // The phone layout hides the rail behind a menu.
    const vms = page.getByRole("button", { name: "VMs" });
    if (
      !(await vms
        .first()
        .isVisible()
        .catch(() => false))
    ) {
      for (const name of [
        "Open menu",
        "Menu",
        "More",
        "Open sidebar",
        "Toggle sidebar",
      ]) {
        const b = page.getByRole("button", { name });
        if (
          await b
            .first()
            .isVisible()
            .catch(() => false)
        ) {
          await b.first().click();
          await page.waitForTimeout(800);
          if (
            await vms
              .first()
              .isVisible()
              .catch(() => false)
          )
            break;
        }
      }
    }
  }
  await page.getByRole("button", { name: "VMs" }).first().click();
  await page.waitForTimeout(1500);
  // The rail opens VMs as a tab; fold the hosts sidebar away for room.
  const fold = page.getByRole("button", { name: "Collapse sidebar" });
  if (
    !phone &&
    (await fold
      .first()
      .isVisible()
      .catch(() => false))
  ) {
    await fold.first().click();
    await page.waitForTimeout(800);
  }
  await vis(page, "vm-web-1")
    .waitFor({ timeout: 20000 })
    .catch(async (e) => {
      await page.screenshot({ path: "/out/debug-open.png" });
      throw e;
    });
}

/** The visible copy of a test id (the side panel keeps a hidden one). */
const vis = (page, id) => page.locator(`[data-testid="${id}"]:visible`).first();

const desktop = { width: 1280, height: 800 };
const phone = { width: 390, height: 844 };

// Owner, desktop.
{
  const { ctx, page } = await signIn(
    desktop,
    state.admin.username,
    state.admin.password,
  );
  await openHaw(page);
  await shot(page, "01-hosts-desktop");

  await vis(page, "vm-web-1").getByRole("button", { name: "Turn off" }).click();
  await page
    .getByRole("dialog")
    .waitFor({ timeout: 5000 })
    .catch(() => {});
  await shot(page, "03-confirm-turnoff");
  await page.getByRole("button", { name: "Cancel" }).last().click();
  await page.waitForTimeout(500);

  await vis(page, "vm-web-1").getByRole("button", { name: "Console" }).click();
  await page.waitForTimeout(1500);
  await shot(page, "04-console-linked");
  await page
    .getByRole("button", { name: "Close" })
    .last()
    .click()
    .catch(() => page.keyboard.press("Escape"));
  await page.waitForTimeout(500);

  await vis(page, "vm-test-vm1")
    .getByRole("button", { name: "Console" })
    .click();
  await page.waitForTimeout(1500);
  await shot(page, "05-console-not-linked");
  await page
    .getByRole("button", { name: "Close" })
    .last()
    .click()
    .catch(() => page.keyboard.press("Escape"));
  await page.waitForTimeout(500);

  await page.getByRole("button", { name: "Record" }).first().click();
  await page.waitForTimeout(1500);
  await shot(page, "06-record");
  await page
    .getByRole("button", { name: /back/i })
    .first()
    .click()
    .catch(() => {});
  await page.waitForTimeout(800);

  await page.getByRole("button", { name: "Add VM host" }).first().click();
  await page.waitForTimeout(1200);
  await page.getByRole("combobox").first().click();
  await page.getByRole("option", { name: /fakehv \(no vmctl\)/ }).click();
  await page.getByRole("button", { name: "Check", exact: true }).click();
  await vis(page, "setup").waitFor({ timeout: 20000 });
  await page
    .locator("details summary")
    .first()
    .click()
    .catch(() => {});
  await shot(page, "07-add-host-setup");
  await vis(page, "setup").scrollIntoViewIfNeeded();
  await shot(page, "07b-add-host-setup-steps");
  await ctx.close();
}

// Owner, phone.
{
  const { ctx, page } = await signIn(
    phone,
    state.admin.username,
    state.admin.password,
  );
  await openHaw(page, { phone: true });
  await shot(page, "02-hosts-phone");
  await ctx.close();
}

// Viewer: no power buttons.
{
  const viewer = state.people?.["haw-viewer"];
  const { ctx, page } = await signIn(desktop, "haw-viewer", viewer.password);
  await openHaw(page);
  await shot(page, "08-viewer");
  await ctx.close();
}

await browser.close();
