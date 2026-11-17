import { afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import {
  renderWithApp,
  type RenderedPluginApp,
} from "@termix-ssh/plugin-sdk/testing";
import type { PluginManifest } from "@termix-ssh/plugin-sdk/manifest";
import * as plugin from "../../src/frontend/index";
import manifestJson from "../../manifest.json";
import locales from "../../locales/en.json";
import { INTERFACES } from "../../src/shared/interfaces";
import { powerActions } from "../../src/frontend/HostCard";
import type { MeAnswer, VmHostView, VmView } from "../../src/frontend/api";
import type { Role } from "../../src/shared/roles";

const manifest = manifestJson as unknown as PluginManifest;
let rendered: RenderedPluginApp | null = null;

// Radix Select reads these, which jsdom does not have.
Element.prototype.scrollIntoView ??= () => {};
Element.prototype.hasPointerCapture ??= () => false;
Element.prototype.releasePointerCapture ??= () => {};

afterEach(async () => {
  await rendered?.deactivate();
  rendered = null;
});

const vm = (name: string, extra: Partial<VmView> = {}): VmView => ({
  name,
  id: `id-${name}`,
  state: "running",
  cpus: 2,
  memoryMB: 4096,
  uptimeSeconds: 7200,
  addresses: ["192.0.2.5"],
  allowed: true,
  protected: false,
  consoleHostId: null,
  ...extra,
});

const detail = (name: string) => ({
  ...vm(name),
  generation: 2,
  disks: [{ sizeGB: 80, usedGB: 20 }],
  networks: [{ switch: "lab-net", mac: "00:15:5D:00:00:01", addresses: [] }],
  checkpoints: 3,
  notes: "the web server",
});

/** What a VM's details read: `show`, and its last recorded action. */
const DETAIL_GETS = {
  "/hosts/1/vms/web-1": { vm: detail("web-1") },
  "/actions": [
    {
      id: 9,
      at: "2026-11-14T10:00:00.000Z",
      userId: "4be1c2a0-0000",
      hostId: 1,
      hostName: "hv-1",
      action: "restart",
      vmName: "web-1",
      force: false,
      ok: true,
      code: null,
      message: null,
    },
  ],
};

const vmHost: VmHostView = {
  id: 1,
  hostId: 1,
  name: "hv-1",
  address: "192.0.2.1",
  interface: "hyper-v",
  info: {
    host: { name: "HV1" },
    backend: { kind: "hyper-v", version: "1.0.0" },
    protocol: { versions: [1] },
    capacity: { cpus: 16, memoryMB: 65536, freeMemoryMB: 20480, disks: [] },
    networks: [],
    verbs: [],
    limits: { namePattern: "^[a-z]", protected: ["build-*"], ceilings: {} },
    configProblem: null,
  },
  lastCheckedAt: "2026-11-14T10:00:00.000Z",
};

function me(role: Role | null): MeAnswer {
  return {
    role,
    version: "1.0.0",
    interfaces: [
      {
        id: "hyper-v",
        labelKey: INTERFACES["hyper-v"].labelKey,
        setup: INTERFACES["hyper-v"].setup("1.0.0"),
      },
    ],
  };
}

function fakeApi(options: {
  role: Role | null;
  vms?: VmView[];
  post?: (url: string, body?: unknown) => Promise<{ data: unknown }>;
  get?: Record<string, unknown>;
}) {
  return {
    get: vi.fn(async (url: string) => {
      if (url === "/me") return { data: me(options.role) };
      if (url === "/hosts") return { data: [vmHost] };
      if (url === "/hosts/1/vms") return { data: { vms: options.vms ?? [] } };
      if (options.get && url in options.get) return { data: options.get[url] };
      throw Object.assign(new Error("not found"), {
        response: { status: 404, data: { error: `no ${url}` } },
      });
    }),
    post: vi.fn(options.post ?? (async () => ({ data: {} }))),
    put: vi.fn(async () => ({ data: {} })),
    patch: vi.fn(),
    delete: vi.fn(async () => ({ data: {} })),
  };
}

async function render(
  api: ReturnType<typeof fakeApi>,
  hosts: Array<Record<string, unknown>> = [],
) {
  rendered = await renderWithApp(plugin, {
    manifest,
    locales,
    api: api as never,
    hosts,
  });
  rendered.renderTab("haw", { isVisible: true });
  return rendered;
}

describe("the HAW tab", () => {
  it("registers its rail item behind the view permission", async () => {
    const app = await render(fakeApi({ role: "viewer" }));
    expect(app.registered.tabs()).toEqual(["haw"]);
    expect(app.registered.railItems()[0].permission).toBe("haw.view");
  });

  it("tells a person with no role how to get one", async () => {
    await render(fakeApi({ role: null }));
    expect(await screen.findByText(locales.role.none)).toBeTruthy();
  });

  it("lists each VM with its state, size and badges", async () => {
    await render(
      fakeApi({
        role: "viewer",
        vms: [
          vm("build-1", { protected: true }),
          vm("old-box", { allowed: false, state: "off" }),
        ],
      }),
    );
    const build = await screen.findByTestId("vm-build-1");
    expect(within(build).getByText("Running")).toBeTruthy();
    expect(within(build).getByText("protected")).toBeTruthy();
    expect(within(build).getByText(/2 CPU · 4 GB · 192\.0\.2\.5/)).toBeTruthy();
    expect(within(build).getByText("Up 2h")).toBeTruthy();
    expect(
      within(screen.getByTestId("vm-old-box")).getByText("not managed"),
    ).toBeTruthy();
  });

  it("gives a viewer no power buttons and no Add VM host", async () => {
    await render(
      fakeApi({ role: "viewer", vms: [vm("web-1")], get: DETAIL_GETS }),
    );
    const row = await screen.findByTestId("vm-web-1");
    const powerOrConsole = /Start|Shut down|Turn off|Restart|Reset|Console/;
    expect(within(row).queryByRole("button", { name: powerOrConsole })).toBe(
      null,
    );
    fireEvent.click(within(row).getByRole("button", { expanded: false }));
    await within(row).findByTestId("vm-details");
    expect(within(row).queryByRole("button", { name: powerOrConsole })).toBe(
      null,
    );
    expect(screen.queryByText("Add VM host")).toBeNull();
  });

  it("asks before a power action, then sends it", async () => {
    const api = fakeApi({
      role: "operator",
      vms: [vm("web-1")],
      get: DETAIL_GETS,
      post: async () => ({ data: { vm: vm("web-1", { state: "off" }) } }),
    });
    await render(api);
    const row = await screen.findByTestId("vm-web-1");
    // Turn off is in the details, not on the row.
    expect(within(row).queryByText("Turn off")).toBeNull();
    fireEvent.click(within(row).getByRole("button", { expanded: false }));
    fireEvent.click(await within(row).findByText("Turn off"));
    expect(await screen.findByText("Turn off web-1?")).toBeTruthy();
    expect(api.post).not.toHaveBeenCalled();
    const confirm = screen.getAllByRole("button", { name: "Turn off" }).at(-1)!;
    fireEvent.click(confirm);
    await waitFor(() =>
      expect(api.post).toHaveBeenCalledWith("/hosts/1/vms/web-1/stop", {
        force: true,
      }),
    );
  });

  it("sends nothing when the question is cancelled", async () => {
    const api = fakeApi({ role: "operator", vms: [vm("web-1")] });
    await render(api);
    fireEvent.click(
      within(await screen.findByTestId("vm-web-1")).getByText("Restart"),
    );
    fireEvent.click(await screen.findByRole("button", { name: "Cancel" }));
    await waitFor(() =>
      expect(screen.queryByText("Restart web-1?")).toBeNull(),
    );
    expect(api.post).not.toHaveBeenCalled();
  });
});

describe("power buttons", () => {
  it("follow the state, the protect list and the name pattern", () => {
    expect(powerActions(vm("a"))).toEqual([
      "shutdown",
      "turnoff",
      "restart",
      "reset",
    ]);
    expect(powerActions(vm("a", { state: "off" }))).toEqual(["start"]);
    expect(powerActions(vm("a", { state: "saved" }))).toEqual(["start"]);
    expect(powerActions(vm("a", { protected: true }))).toEqual([]);
    expect(powerActions(vm("a", { protected: true, state: "off" }))).toEqual([
      "start",
    ]);
    expect(powerActions(vm("a", { allowed: false, state: "off" }))).toEqual([]);
    expect(powerActions(vm("a", { state: "stopping" }))).toEqual([]);
  });
});

describe("Add VM host", () => {
  const termixHosts = [
    {
      id: 1,
      name: "hv-1",
      address: "192.0.2.1",
      username: "vmctl",
      added: false,
    },
  ];

  async function openAdd(post: (url: string) => Promise<{ data: unknown }>) {
    const api = fakeApi({
      role: "owner",
      get: { "/termix-hosts": termixHosts },
      post,
    });
    await render(api);
    fireEvent.click(await screen.findByText("Add VM host"));
    await screen.findByText("Add a VM host");
    return api;
  }

  it("shows the interface's setup when vmctl does not answer", async () => {
    await openAdd(async (url) =>
      url === "/hosts/check"
        ? {
            data: {
              ok: false,
              code: "no-reply",
              error: "vmctl sent no reply (exit code 1)",
              detail: "-File parameter does not exist",
            },
          }
        : { data: {} },
    );
    const check = screen.getByRole("button", { name: "Check" });
    expect((check as HTMLButtonElement).disabled).toBe(true);
    // The first combobox is the host; Radix opens it from the keyboard.
    fireEvent.keyDown(screen.getAllByRole("combobox")[0], { key: "Enter" });
    fireEvent.click(await screen.findByRole("option", { name: /hv-1/ }));
    await waitFor(() =>
      expect(
        (screen.getByRole("button", { name: "Check" }) as HTMLButtonElement)
          .disabled,
      ).toBe(false),
    );
    fireEvent.click(screen.getByRole("button", { name: "Check" }));
    const setup = await screen.findByTestId("setup");
    expect(within(setup).getByText(/Generate Key Pair/)).toBeTruthy();
    expect(setup.textContent).toContain(
      "raw.githubusercontent.com/Coolroo/termix-plugin-haw/v1.0.0/vmctl/hyperv",
    );
    expect(screen.getByText(/vmctl sent no reply/)).toBeTruthy();
  });
});

describe("consoles", () => {
  it("opens the linked host in the Remote Desktop plugin", async () => {
    const api = fakeApi({
      role: "operator",
      vms: [vm("web-1", { consoleHostId: 7 })],
      get: {
        "/hosts/1/vms/web-1/console": {
          console: {
            kind: "vmconnect",
            host: "hv1.example.lan",
            port: 2179,
            vmId: "id-web-1",
          },
          consoleHost: { id: 7, name: "web-1 console" },
        },
      },
    });
    const app = await render(api, [
      { id: 7, name: "web-1 console", ip: "hv1.example.lan", port: 2179 },
    ]);
    fireEvent.click(
      within(await screen.findByTestId("vm-web-1")).getByText("Console"),
    );
    fireEvent.click(
      await screen.findByRole("button", { name: "Open console" }),
    );
    await waitFor(() =>
      expect(app.shellCalls.some((call) => call.method === "openTab")).toBe(
        true,
      ),
    );
    const call = app.shellCalls.find((entry) => entry.method === "openTab")!;
    expect(call.args[1]).toBe("rdp");
    expect(String((call.args[0] as { id: unknown }).id)).toBe("7");
  });

  it("says what the console host needs when none is linked", async () => {
    await render(
      fakeApi({
        role: "operator",
        vms: [vm("web-1")],
        get: {
          "/hosts/1/vms/web-1/console": {
            console: {
              kind: "vmconnect",
              host: "hv1.example.lan",
              port: 2179,
              vmId: "id-web-1",
            },
            consoleHost: null,
          },
        },
      }),
    );
    fireEvent.click(
      within(await screen.findByTestId("vm-web-1")).getByText("Console"),
    );
    const panel = await screen.findByTestId("console");
    expect(panel.textContent).toContain("security VMConnect");
    expect(panel.textContent).toContain("id-web-1");
    expect(screen.queryByRole("button", { name: "Open console" })).toBeNull();
    expect(screen.queryByText("Link a host")).toBeNull();
  });
});

describe("keeping up with the host", () => {
  it("reads the list again every 2 seconds while the tab is visible", async () => {
    const api = fakeApi({ role: "viewer", vms: [vm("web-1")] });
    await render(api);
    await screen.findByTestId("vm-web-1");
    const reads = () =>
      api.get.mock.calls.filter(([url]) => url === "/hosts/1/vms").length;
    const first = reads();
    await waitFor(() => expect(reads()).toBeGreaterThan(first), {
      timeout: 4000,
    });
  });

  it("shows a change on the host without a click", async () => {
    let state: VmView["state"] = "running";
    const api = fakeApi({ role: "viewer" });
    api.get.mockImplementation(async (url: string) => {
      if (url === "/me") return { data: me("viewer") };
      if (url === "/hosts") return { data: [vmHost] };
      return { data: { vms: [vm("web-1", { state })] } };
    });
    await render(api);
    const row = await screen.findByTestId("vm-web-1");
    expect(within(row).getByText("Running")).toBeTruthy();
    state = "off";
    await waitFor(
      () =>
        expect(
          within(screen.getByTestId("vm-web-1")).getByText("Off"),
        ).toBeTruthy(),
      { timeout: 4000 },
    );
  });
});

describe("the list", () => {
  it("opens a VM's details in place, with its disks and last action", async () => {
    const api = fakeApi({
      role: "operator",
      vms: [vm("web-1")],
      get: DETAIL_GETS,
    });
    await render(api);
    const row = await screen.findByTestId("vm-web-1");
    expect(within(row).queryByTestId("vm-details")).toBeNull();
    const toggle = within(row).getByRole("button", { expanded: false });
    fireEvent.click(toggle);
    const details = await within(row).findByTestId("vm-details");
    expect(within(details).getByText("Generation 2")).toBeTruthy();
    expect(within(details).getByText("20 of 80 GB")).toBeTruthy();
    expect(within(details).getByText("lab-net")).toBeTruthy();
    expect(within(details).getByText("3 checkpoints")).toBeTruthy();
    expect(within(details).getByText("the web server")).toBeTruthy();
    await waitFor(() =>
      expect(
        within(details).getByTestId("vm-last-action").textContent,
      ).toContain("user 4be1c2a0 · restart"),
    );
    expect(api.get).toHaveBeenCalledWith("/actions", {
      params: { hostId: 1, vmName: "web-1", limit: 1 },
    });
    fireEvent.click(toggle);
    expect(within(row).queryByTestId("vm-details")).toBeNull();
  });

  it("filters by name, address and state", async () => {
    await render(
      fakeApi({
        role: "viewer",
        vms: [
          vm("web-1"),
          vm("db-1", { state: "off", addresses: ["198.51.100.7"] }),
          vm("cache-1", { state: "paused", addresses: [] }),
        ],
      }),
    );
    await screen.findByTestId("vm-web-1");
    // The counts arrive one render after the rows.
    expect(await screen.findByText("3 VMs · 1 running · 1 hosts")).toBeTruthy();

    fireEvent.change(screen.getByPlaceholderText("Name or address"), {
      target: { value: "198.51" },
    });
    await waitFor(() => expect(screen.queryByTestId("vm-web-1")).toBeNull());
    expect(screen.getByTestId("vm-db-1")).toBeTruthy();

    fireEvent.change(screen.getByPlaceholderText("Name or address"), {
      target: { value: "" },
    });
    fireEvent.click(screen.getByText("Stopped"));
    await waitFor(() => expect(screen.queryByTestId("vm-web-1")).toBeNull());
    expect(screen.getByTestId("vm-db-1")).toBeTruthy();
    expect(screen.getByTestId("vm-cache-1")).toBeTruthy();

    fireEvent.change(screen.getByPlaceholderText("Name or address"), {
      target: { value: "nothing-like-this" },
    });
    expect(
      await screen.findByText("No VM on this host matches the filter."),
    ).toBeTruthy();
  });

  it("shows the host's memory use, and its limits on request", async () => {
    await render(fakeApi({ role: "viewer", vms: [vm("web-1")] }));
    const memory = await screen.findByTestId("host-memory");
    expect(memory.textContent).toContain("44 GB of 64 GB");
    expect(screen.queryByTestId("host-limits")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Limits" }));
    expect(screen.getByTestId("host-limits").textContent).toContain(
      "protected: build-*",
    );
  });

  describe("on a phone", () => {
    const width = window.innerWidth;
    afterEach(() => {
      Object.defineProperty(window, "innerWidth", {
        value: width,
        configurable: true,
      });
    });

    it("keeps the row free of buttons and puts large ones in the details", async () => {
      Object.defineProperty(window, "innerWidth", {
        value: 390,
        configurable: true,
      });
      window.matchMedia ??= ((query: string) => ({
        matches: false,
        media: query,
        addEventListener: () => {},
        removeEventListener: () => {},
      })) as unknown as typeof window.matchMedia;
      await render(
        fakeApi({ role: "operator", vms: [vm("web-1")], get: DETAIL_GETS }),
      );
      const row = await screen.findByTestId("vm-web-1");
      await waitFor(() =>
        expect(within(row).queryByText("Restart")).toBeNull(),
      );
      fireEvent.click(within(row).getByRole("button", { expanded: false }));
      const buttons = await within(row).findByTestId("vm-actions");
      for (const name of [
        "Shut down",
        "Turn off",
        "Restart",
        "Reset",
        "Console",
      ]) {
        expect(within(buttons).getByRole("button", { name })).toBeTruthy();
      }
    });
  });
});
