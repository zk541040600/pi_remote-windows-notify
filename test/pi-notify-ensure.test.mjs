import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import {
  ensureInstallation,
  inspectInstallation,
} from "../windows/pi-notify-ensure.mjs";

const PACKAGE_RELATIVE = join("git", "github.com", "zk541040600", "pi_remote-windows-notify");
const PACKAGE_SOURCE_RELATIVES = [
  join("linux", "extensions", "remote-windows-notify.ts"),
  join("windows", "remote-windows-notify.ts"),
];

function createFixture(t, nestedName) {
  const temporaryRoot = mkdtempSync(join(tmpdir(), "pi-notify-ensure-test-"));
  const root = nestedName ? join(temporaryRoot, nestedName) : temporaryRoot;
  const homeDir = join(root, "home");
  const piDir = join(root, "pi", "agent");
  const managedDir = join(root, "managed");
  mkdirSync(root, { recursive: true });
  mkdirSync(homeDir, { recursive: true });
  mkdirSync(managedDir, { recursive: true });
  writeFileSync(join(managedDir, "remote-windows-notify.ts"), "canonical-source\n", "utf8");
  writeFileSync(join(managedDir, "remote-windows-notify.json"), '{"enabled":true,"token":"secret"}\n', {
    encoding: "utf8",
    mode: 0o600,
  });
  t.after(() => rmSync(temporaryRoot, { recursive: true, force: true }));
  return { root, homeDir, piDir, managedDir };
}

function createPackageRoot(baseDir, initial = "old-source\n") {
  const packageRoot = join(baseDir, PACKAGE_RELATIVE);
  for (const relative of PACKAGE_SOURCE_RELATIVES) {
    const path = join(packageRoot, relative);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, initial, "utf8");
  }
  return packageRoot;
}

test("standalone mode installs one global entry and is idempotent", (t) => {
  const fixture = createFixture(t);
  const result = ensureInstallation(fixture);
  const globalEntry = join(fixture.piDir, "extensions", "remote-windows-notify.ts");
  const config = join(fixture.piDir, "remote-windows-notify.json");

  assert.equal(result.mode, "standalone");
  assert.equal(result.activePath, globalEntry);
  assert.equal(readFileSync(globalEntry, "utf8"), "canonical-source\n");
  assert.equal(readFileSync(config, "utf8"), '{"enabled":true,"token":"secret"}\n');
  if (process.platform !== "win32") {
    assert.equal(statSync(config).mode & 0o777, 0o600);
  }

  const second = ensureInstallation({ managedDir: fixture.managedDir, homeDir: fixture.homeDir });
  assert.equal(second.mode, "standalone");
  assert.deepEqual(inspectInstallation({ managedDir: fixture.managedDir, homeDir: fixture.homeDir }).errors, []);
  assert.equal(
    existsSync(join(fixture.managedDir, "pi-notify-install-state.json")),
    true,
    "first run must persist the custom Pi directory for boot-time repair",
  );
});

test("package mode updates package copies and removes an identical legacy global entry", (t) => {
  const fixture = createFixture(t);
  const packageRoot = createPackageRoot(fixture.piDir);
  const globalEntry = join(fixture.piDir, "extensions", "remote-windows-notify.ts");
  mkdirSync(join(globalEntry, ".."), { recursive: true });
  writeFileSync(globalEntry, "canonical-source\n", "utf8");

  const result = ensureInstallation(fixture);
  assert.equal(result.mode, "package");
  assert.equal(existsSync(globalEntry), false);
  for (const relative of PACKAGE_SOURCE_RELATIVES) {
    assert.equal(readFileSync(join(packageRoot, relative), "utf8"), "canonical-source\n");
  }
  assert.deepEqual(result.errors, []);
});

test("package mode rejects a customized legacy entry before mutating package files", (t) => {
  const fixture = createFixture(t);
  const packageRoot = createPackageRoot(fixture.piDir);
  const globalEntry = join(fixture.piDir, "extensions", "remote-windows-notify.ts");
  mkdirSync(join(globalEntry, ".."), { recursive: true });
  writeFileSync(globalEntry, "user-customized-source\n", "utf8");

  assert.throws(() => ensureInstallation(fixture), /conflicting legacy extension/i);
  assert.equal(readFileSync(join(packageRoot, PACKAGE_SOURCE_RELATIVES[0]), "utf8"), "old-source\n");
  assert.equal(existsSync(join(fixture.piDir, "remote-windows-notify.json")), false);
});

test("a package under another Pi directory does not suppress the selected standalone entry", (t) => {
  const fixture = createFixture(t);
  const otherPiDir = join(fixture.homeDir, ".pi", "agent");
  const otherPackageRoot = createPackageRoot(otherPiDir);

  const result = ensureInstallation(fixture);
  assert.equal(result.mode, "standalone");
  assert.equal(existsSync(join(fixture.piDir, "extensions", "remote-windows-notify.ts")), true);
  assert.equal(readFileSync(join(otherPackageRoot, PACKAGE_SOURCE_RELATIVES[0]), "utf8"), "old-source\n");
});

test("inspection detects source drift without modifying it", (t) => {
  const fixture = createFixture(t);
  const packageRoot = createPackageRoot(fixture.piDir);
  ensureInstallation(fixture);
  const driftedPath = join(packageRoot, PACKAGE_SOURCE_RELATIVES[0]);
  writeFileSync(driftedPath, "drifted\n", "utf8");

  const result = inspectInstallation({ managedDir: fixture.managedDir, homeDir: fixture.homeDir });
  assert.ok(result.errors.some((error) => error.includes("differs from managed source")));
  assert.equal(readFileSync(driftedPath, "utf8"), "drifted\n");
});

test("invalid managed config fails before any active entry is written", (t) => {
  const fixture = createFixture(t);
  writeFileSync(join(fixture.managedDir, "remote-windows-notify.json"), "{bad-json", "utf8");
  assert.throws(() => ensureInstallation(fixture), /managed config is not valid JSON/i);
  assert.equal(existsSync(join(fixture.piDir, "extensions", "remote-windows-notify.ts")), false);
});

test("managed and Pi directories support spaces and Unicode", (t) => {
  const fixture = createFixture(t, "notify 路径 with spaces");
  const result = ensureInstallation(fixture);
  assert.equal(result.mode, "standalone");
  assert.deepEqual(inspectInstallation({ managedDir: fixture.managedDir }).errors, []);
});
