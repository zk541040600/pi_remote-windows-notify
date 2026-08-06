import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  buildClosePayload,
  buildNotifyPayload,
  extractPermissionRequestIds,
  normalizeAttentionEvent,
  validateRoute,
} from "../src/normalize.mjs";
import { eventFingerprint } from "../src/privacy.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const contract = JSON.parse(
  readFileSync(join(root, "../fixtures/windows-paseo-v1-contract.json"), "utf8"),
);

const PROVIDERS = ["pi", "codex", "grok-build"];

function attentionFixture(provider, reason = "finished") {
  // Provider only exists in comments/fixtures; handler must not branch on it.
  return {
    provider,
    agentId: "agent-1",
    reason,
    timestamp: "2026-08-06T12:00:00.000Z",
    shouldNotify: false,
    notification: {
      title: "secret-title",
      body: "secret-body",
      data: {
        serverId: "server-1",
        workspaceId: "workspace-1",
        agentId: "agent-1",
        reason,
      },
    },
  };
}

test("provider fixtures share identical normalize path", () => {
  const results = PROVIDERS.map((provider) =>
    normalizeAttentionEvent(attentionFixture(provider), {
      serverId: "server-1",
      now: Date.parse("2026-08-06T12:00:01.000Z"),
    }),
  );
  for (const result of results) {
    assert.equal(result.ok, true);
    assert.equal(result.reason, "finished");
    assert.equal(result.agentId, "agent-1");
  }
  assert.equal(results[0].eventFp, results[1].eventFp);
  assert.equal(results[1].eventFp, results[2].eventFp);
});

test("error is dropped; finished and permission accepted; shouldNotify ignored", () => {
  const now = Date.parse("2026-08-06T12:00:01.000Z");
  assert.equal(
    normalizeAttentionEvent(attentionFixture("pi", "error"), { serverId: "server-1", now }).ok,
    false,
  );
  assert.equal(
    normalizeAttentionEvent(attentionFixture("pi", "finished"), { serverId: "server-1", now }).ok,
    true,
  );
  assert.equal(
    normalizeAttentionEvent(attentionFixture("pi", "permission"), { serverId: "server-1", now }).ok,
    true,
  );
});

test("legacy/dedicated same fingerprint", () => {
  const a = eventFingerprint({
    serverId: "server-1",
    agentId: "agent-1",
    reason: "finished",
    timestamp: "2026-08-06T12:00:00.000Z",
  });
  const b = eventFingerprint({
    serverId: "server-1",
    agentId: "agent-1",
    reason: "finished",
    timestamp: "2026-08-06T12:00:00.000Z",
  });
  assert.equal(a, b);
  assert.notEqual(
    a,
    eventFingerprint({
      serverId: "server-1",
      agentId: "agent-1",
      reason: "permission",
      timestamp: "2026-08-06T12:00:00.000Z",
    }),
  );
});

test("future, missing, and non-RFC3339 timestamps drop; offsets canonicalize", () => {
  const now = Date.parse("2026-08-06T12:00:00.000Z");
  for (const timestamp of ["2026-08-06T13:00:00.000Z", "", "0", "2026-08-06"]) {
    assert.equal(
      normalizeAttentionEvent(
        { agentId: "a", reason: "finished", timestamp, shouldNotify: true },
        { serverId: "s", now },
      ).ok,
      false,
    );
  }

  const utc = normalizeAttentionEvent(
    { agentId: "a", reason: "finished", timestamp: "2026-08-06T11:00:00.000Z" },
    { serverId: "s", now },
  );
  const offset = normalizeAttentionEvent(
    { agentId: "a", reason: "finished", timestamp: "2026-08-06T12:00:00+01:00" },
    { serverId: "s", now },
  );
  assert.equal(utc.ok, true);
  assert.equal(offset.ok, true);
  assert.equal(offset.timestamp, "2026-08-06T11:00:00.000Z");
  assert.equal(offset.eventFp, utc.eventFp);
});

test("v1 notify payload matches parent contract fixture", () => {
  const payload = buildNotifyPayload({
    notificationId: contract.notify.payload.notificationId,
    kind: "finished",
    serverId: "server-1",
    workspaceId: "workspace-1",
    agentId: "agent-1",
    agentDisplayName: "Agent",
  });
  assert.equal(payload.originKind, "paseo");
  assert.equal(payload.notificationKind, "finished");
  assert.equal(payload.paseoRoute.version, 1);
  assert.deepEqual(Object.keys(payload.paseoRoute).sort(), ["agentId", "serverId", "version", "workspaceId"]);
  assert.equal(payload.body, "已完成");
  assert.ok([...payload.title].length <= contract.notify.titleMaxCodePoints);
  assert.ok([...payload.body].length <= contract.notify.bodyMaxCodePoints);
});

test("permission body is minimal waiting status", () => {
  const payload = buildNotifyPayload({
    notificationId: contract.notify.payload.notificationId,
    kind: "permission",
    serverId: "server-1",
    workspaceId: "workspace-1",
    agentId: "agent-1",
  });
  assert.equal(payload.notificationKind, "permission");
  assert.equal(payload.body, "等待授权");
});

test("close payload is exact three-field contract", () => {
  const close = buildClosePayload(contract.close.payload.notificationId);
  assert.deepEqual(Object.keys(close).sort(), contract.close.allowedFields.slice().sort());
  assert.equal(close.originKind, "paseo");
  assert.equal(close.version, 1);
});

test("control characters stripped and unicode truncated", () => {
  const payload = buildNotifyPayload({
    notificationId: contract.notify.payload.notificationId,
    kind: "finished",
    serverId: "server-1",
    workspaceId: "workspace-1",
    agentId: "agent-1",
    agentDisplayName: `A\u0000${"名".repeat(100)}`,
    titleMax: 10,
  });
  assert.equal(payload.title.includes("\u0000"), false);
  assert.ok([...payload.title].length <= 10);
});

test("permission IDs extracted as set without order guess", () => {
  const ids = extractPermissionRequestIds([
    { id: "b" },
    { id: "a" },
    { id: "b" },
    { noid: true },
  ]);
  assert.deepEqual(ids.sort(), ["a", "b"]);
});

test("route validation rejects controls and empty", () => {
  assert.equal(validateRoute({ serverId: "s", workspaceId: "w", agentId: "a" }).ok, true);
  assert.equal(validateRoute({ serverId: "s", workspaceId: "", agentId: "a" }).ok, false);
  assert.equal(validateRoute({ serverId: "s\u0000x", workspaceId: "w", agentId: "a" }).ok, false);
  assert.equal(validateRoute({ serverId: "s\u0007", workspaceId: "w", agentId: "a" }).ok, false);
});

test("source has no provider notification switch", () => {
  const src = readFileSync(join(root, "../src/normalize.mjs"), "utf8") +
    readFileSync(join(root, "../src/service.mjs"), "utf8") +
    readFileSync(join(root, "../src/reconcile.mjs"), "utf8");
  assert.equal(/switch\s*\(\s*provider/i.test(src), false);
  assert.equal(/if\s*\(\s*provider\s*===/.test(src), false);
  assert.equal(/provider\s*===\s*['"]pi['"]/.test(src), false);
  assert.equal(/provider\s*===\s*['"]codex['"]/.test(src), false);
});
