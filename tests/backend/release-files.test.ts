import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { RELEASE_FILES } from "../../src/shared/release-files";
import { hypervInstallScript } from "../../src/shared/interfaces";

const sha = (path: string) =>
  createHash("sha256")
    .update(readFileSync(new URL(`../../${path}`, import.meta.url)))
    .digest("hex")
    .toUpperCase();

describe("the files a host's setup downloads", () => {
  it("have the SHA-256 the setup checks (run node tools/release-files.mjs)", () => {
    expect(RELEASE_FILES["hyper-v"]["vmctl.ps1"]).toBe(
      sha("vmctl/hyperv/vmctl.ps1"),
    );
    expect(RELEASE_FILES["hyper-v"]["vmctl-worker.ps1"]).toBe(
      sha("vmctl/hyperv/vmctl-worker.ps1"),
    );
    expect(RELEASE_FILES["hyper-v"]["install.ps1"]).toBe(
      sha("vmctl/hyperv/install.ps1"),
    );
  });

  it("are LF only, so a checkout and a download hash the same", () => {
    for (const file of [
      "vmctl/hyperv/vmctl.ps1",
      "vmctl/hyperv/vmctl-worker.ps1",
      "vmctl/hyperv/install.ps1",
    ]) {
      expect(
        readFileSync(new URL(`../../${file}`, import.meta.url), "utf8"),
      ).not.toContain("\r");
    }
  });

  it("are fetched from this version's tag and checked before they run", () => {
    const script = hypervInstallScript("1.0.0");
    expect(script).toContain("/v1.0.0/vmctl/hyperv");
    expect(script).toContain(RELEASE_FILES["hyper-v"]["install.ps1"]);
    expect(script).toContain(
      `-Sha256 '${RELEASE_FILES["hyper-v"]["vmctl.ps1"]}'`,
    );
    expect(script).toContain(
      `-WorkerSha256 '${RELEASE_FILES["hyper-v"]["vmctl-worker.ps1"]}'`,
    );
    expect(script.indexOf("Get-FileHash")).toBeLessThan(
      script.indexOf("& (Join-Path"),
    );
  });
});
