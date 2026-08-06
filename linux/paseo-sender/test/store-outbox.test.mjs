import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { DurableStore } from "../src/store.mjs";
import { agentKey, eventFingerprint } from "../src/privacy.mjs";

function tempDir() {
  return mkdtempSync(join(tmpdir(), "paseo-sender-store-"));
}

function finishedInput(agentId = "agent-1") {
  return {
    serverId: "server-1",
    agentId,
    workspaceId: "ws-1",
    kind: "finished",
    eventTimestamp: "2026-08-06T12:00:00.000Z",
    eventMs: Date.parse("2026-08-06T12:00:00.000Z"),
    status: "pending",
  };
}

test("transaction persists 0600 matching generations and restarts", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    assert.equal((await store.load()).ok, true);
    await store.transaction(() => {
      store.markInitialized("server-1");
      store.setWatermark("server-1", "agent-1", "2026-08-06T12:00:00.000Z");
      store.upsertItem(finishedInput());
    });
    assert.equal(statSync(join(dir, "state.json")).mode & 0o777, 0o600);
    assert.equal(statSync(join(dir, "outbox.json")).mode & 0o777, 0o600);
    assert.equal(existsSync(join(dir, "transaction.json")), false);
    const stateDisk = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    const outboxDisk = JSON.parse(readFileSync(join(dir, "outbox.json"), "utf8"));
    assert.equal(stateDisk.generation, outboxDisk.generation);

    const recovered = new DurableStore(dir);
    assert.equal((await recovered.load()).ok, true);
    assert.equal(recovered.state.initialized, true);
    assert.equal(recovered.listItems().length, 1);
    assert.match(recovered.listItems()[0].notificationId, /^[0-9a-f-]{36}$/iu);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("valid WAL recovers every interrupted write boundary", async () => {
  for (const crashPoint of ["after-wal", "after-outbox", "after-state"]) {
    const dir = tempDir();
    try {
      const baseline = new DurableStore(dir);
      await baseline.load();
      await baseline.transaction(() => baseline.markInitialized("server-1"));
      const beforeGeneration = baseline.state.generation;

      const crashing = new DurableStore(dir, {
        faultInjector(point) {
          if (point === crashPoint) throw new Error(`crash-${point}`);
        },
      });
      await crashing.load();
      await assert.rejects(
        crashing.transaction(() => crashing.upsertItem(finishedInput(`agent-${crashPoint}`))),
        /crash-/,
      );
      assert.equal(crashing.isLiveDeliveryBlocked(), true);
      assert.equal(crashing.listItems().length, 0, "in-memory state rolled back");
      assert.equal(existsSync(join(dir, "transaction.json")), true);

      const recovered = new DurableStore(dir);
      const loaded = await recovered.load();
      assert.equal(loaded.ok, true);
      assert.equal(loaded.recovered, true);
      assert.equal(recovered.state.generation, beforeGeneration + 1);
      assert.equal(recovered.outbox.generation, beforeGeneration + 1);
      assert.equal(recovered.listItems().length, 1);
      assert.equal(existsSync(join(dir, "transaction.json")), false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("corrupt WAL, missing pairs, and impossible WAL generations block recovery", async () => {
  for (const scenario of ["invalid-wal", "missing-pair", "generation-ahead", "generation-gap"]) {
    const dir = tempDir();
    try {
      const baseline = new DurableStore(dir);
      await baseline.load();
      await baseline.transaction(() => baseline.markInitialized("server-1"));

      if (scenario === "invalid-wal") {
        writeFileSync(join(dir, "transaction.json"), "{bad-json", { mode: 0o600 });
      } else if (scenario === "missing-pair") {
        rmSync(join(dir, "outbox.json"));
      } else {
        if (scenario === "generation-gap") {
          await baseline.transaction(() => baseline.upsertItem(finishedInput("gap-agent")));
        }
        const crashing = new DurableStore(dir, {
          faultInjector(point) {
            if (point === "after-wal") throw new Error("crash-after-wal");
          },
        });
        await crashing.load();
        await assert.rejects(
          crashing.transaction(() => crashing.setWatermark(
            "server-1",
            "agent-1",
            "2026-08-06T12:01:00.000Z",
          )),
          /crash-after-wal/u,
        );
        if (scenario === "generation-ahead") {
          for (const file of ["state.json", "outbox.json"]) {
            const value = JSON.parse(readFileSync(join(dir, file), "utf8"));
            value.generation += 2;
            writeFileSync(join(dir, file), JSON.stringify(value), { mode: 0o600 });
          }
        } else {
          rmSync(join(dir, "state.json"));
          rmSync(join(dir, "outbox.json"));
        }
      }

      const store = new DurableStore(dir);
      const loaded = await store.load();
      assert.equal(loaded.ok, false, scenario);
      assert.equal(store.isLiveDeliveryBlocked(), true, scenario);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("permission dominates finished, same authoritative set preserves UUID and delivered state", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    let permissionId;
    await store.transaction(() => {
      store.upsertItem(finishedInput("agent-a"));
      const permission = store.syncPermissionSet("server-1", "agent-a", "ws-1", ["p1", "p2"], {
        eventTimestamp: "2026-08-06T12:01:00.000Z",
        eventMs: Date.parse("2026-08-06T12:01:00.000Z"),
      });
      permission.status = "delivered";
      permission.desktopShownAt = Date.parse("2026-08-06T12:02:00.000Z");
      permissionId = permission.notificationId;
    });
    await store.transaction(() => {
      const same = store.syncPermissionSet("server-1", "agent-a", "ws-1", ["p2", "p1"]);
      assert.equal(same.notificationId, permissionId);
      assert.equal(same.status, "delivered");
      store.upsertItem({ ...finishedInput("agent-a"), eventTimestamp: "2026-08-06T12:03:00.000Z" });
    });
    assert.equal(store.listItems()[0].kind, "permission");
    assert.equal(store.listItems()[0].notificationId, permissionId);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("partial resolve keeps shown item; final resolve durably closes exact UUID", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    let notificationId;
    await store.transaction(() => {
      const item = store.syncPermissionSet("s", "a", "w", ["p1", "p2"]);
      item.status = "delivered";
      item.desktopShownAt = Date.now();
      notificationId = item.notificationId;
    });
    await store.transaction(() => {
      const result = store.resolvePermissionId("s", "a", "p1");
      assert.equal(result.allResolved, false);
      assert.deepEqual(result.item.permissionRequestIds, ["p2"]);
    });
    await store.transaction(() => {
      const result = store.resolvePermissionId("s", "a", "p2");
      assert.equal(result.allResolved, true);
      assert.equal(result.item.status, "closing");
      assert.equal(result.item.notificationId, notificationId);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("new permission arriving during close gets a new UUID and retains old close identity", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    let oldId;
    await store.transaction(() => {
      const item = store.syncPermissionSet("s", "a", "w", ["old"]);
      item.status = "delivered";
      item.desktopShownAt = Date.now();
      oldId = item.notificationId;
      store.resolvePermissionId("s", "a", "old");
      const next = store.syncPermissionSet("s", "a", "w", ["new"]);
      assert.notEqual(next.notificationId, oldId);
      assert.equal(next.supersededNotificationId, oldId);
      assert.equal(next.status, "pending");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("added permission ID starts new episode; subset partial resolve preserves UUID", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    let originalId;
    await store.transaction(() => {
      const item = store.syncPermissionSet("s", "a", "w", ["p1", "p2"]);
      item.status = "delivered";
      item.desktopShownAt = Date.now();
      originalId = item.notificationId;
    });
    await store.transaction(() => {
      // Subset caused only by partial resolution preserves UUID/card.
      const subset = store.syncPermissionSet("s", "a", "w", ["p1"]);
      assert.equal(subset.notificationId, originalId);
      assert.equal(subset.status, "delivered");
      assert.deepEqual(subset.permissionRequestIds, ["p1"]);
    });
    await store.transaction(() => {
      // Newly added request must start a new episode with superseded old UUID.
      const next = store.syncPermissionSet("s", "a", "w", ["p1", "p3"]);
      assert.notEqual(next.notificationId, originalId);
      assert.equal(next.status, "pending");
      assert.equal(next.supersededNotificationId, originalId);
      assert.deepEqual(next.permissionRequestIds.sort(), ["p1", "p3"]);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("disjoint permission set also starts a new episode", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    let oldId;
    await store.transaction(() => {
      const item = store.syncPermissionSet("s", "a", "w", ["old-a", "old-b"]);
      item.status = "delivered";
      item.desktopShownAt = Date.now();
      oldId = item.notificationId;
    });
    await store.transaction(() => {
      const next = store.syncPermissionSet("s", "a", "w", ["new-x"]);
      assert.notEqual(next.notificationId, oldId);
      assert.equal(next.supersededNotificationId, oldId);
      assert.equal(next.status, "pending");
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("pending never-shown permission is removed without close", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    await store.transaction(() => store.syncPermissionSet("s", "a", "w", ["p1"]));
    await store.transaction(() => store.resolvePermissionId("s", "a", "p1"));
    assert.equal(store.listItems().length, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("parseable schema corruption and generation mismatch quarantine/block", async () => {
  const scenarios = process.platform === "win32" ? ["item", "generation"] : ["item", "generation", "mode"];
  for (const kind of scenarios) {
    const dir = tempDir();
    try {
      const store = new DurableStore(dir);
      await store.load();
      await store.transaction(() => store.upsertItem(finishedInput()));
      if (kind === "item") {
        const outbox = JSON.parse(readFileSync(join(dir, "outbox.json"), "utf8"));
        Object.values(outbox.items)[0].notificationId = "not-a-uuid";
        writeFileSync(join(dir, "outbox.json"), JSON.stringify(outbox), { mode: 0o600 });
      } else if (kind === "generation") {
        const state = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
        state.generation += 1;
        writeFileSync(join(dir, "state.json"), JSON.stringify(state), { mode: 0o600 });
      } else if (process.platform !== "win32") {
        chmodSync(join(dir, "outbox.json"), 0o644);
      }
      const invalid = new DurableStore(dir);
      const loaded = await invalid.load();
      assert.equal(loaded.ok, false);
      assert.equal(invalid.isLiveDeliveryBlocked(), true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("invalid JSON is quarantined and blocks live delivery", async () => {
  const dir = tempDir();
  try {
    writeFileSync(join(dir, "state.json"), "{not-json", { mode: 0o600 });
    chmodSync(join(dir, "state.json"), 0o600);
    const store = new DurableStore(dir);
    assert.equal((await store.load()).ok, false);
    assert.equal(store.isLiveDeliveryBlocked(), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("processed fingerprints persist and display text never enters state/outbox/WAL", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    const fp = eventFingerprint({
      serverId: "s",
      agentId: "a",
      reason: "finished",
      timestamp: "2026-08-06T12:00:00.000Z",
    });
    await store.transaction(() => {
      store.markProcessedEvent(fp);
      store.upsertItem({
        ...finishedInput("private-display-name"),
        agentDisplayName: "TOP SECRET DISPLAY",
        title: "TOP SECRET TITLE",
        body: "TOP SECRET BODY",
      });
    });
    const raw = ["state.json", "outbox.json"]
      .map((file) => readFileSync(join(dir, file), "utf8"))
      .join("\n");
    assert.equal(raw.includes("TOP SECRET"), false);
    assert.equal(/agentDisplayName|"title"|"body"|token|password/u.test(raw), false);
    const restarted = new DurableStore(dir);
    await restarted.load();
    assert.equal(restarted.hasProcessedEvent(fp), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("agent deletion closes shown permission but removes pending item", async () => {
  const dir = tempDir();
  try {
    const store = new DurableStore(dir);
    await store.load();
    await store.transaction(() => {
      const shown = store.syncPermissionSet("s", "shown", "w", ["r1"]);
      shown.status = "delivered";
      shown.desktopShownAt = Date.now();
      store.syncPermissionSet("s", "pending", "w", ["r2"]);
    });
    await store.transaction(() => {
      store.markAgentMissing("s", "shown");
      store.markAgentMissing("s", "pending");
    });
    assert.equal(store.getItem(agentKey({ serverId: "s", agentId: "shown" })).status, "closing");
    assert.equal(store.getItem(agentKey({ serverId: "s", agentId: "pending" })), undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
