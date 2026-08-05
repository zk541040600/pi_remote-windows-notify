import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const programPath = new URL(
  "../windows/route-host/src/PiNotifyRouteHost/Program.cs",
  import.meta.url,
);

test("Route Host client wait budget is monotonic across wall-clock rollback", () => {
  const source = readFileSync(programPath, "utf8");
  const methodStart = source.indexOf(
    "private static async Task<RouteResponse> WaitForActivationAsync",
  );
  const methodEnd = source.indexOf(
    "private static async Task<int> RunSelfTestAsync",
    methodStart,
  );
  assert.ok(methodStart >= 0 && methodEnd > methodStart, "missing client wait method");

  const method = source.slice(methodStart, methodEnd);
  assert.match(method, /Stopwatch\s*\.\s*GetElapsedTime\(/);
  assert.match(method, /clientWaitStarted/);
  assert.doesNotMatch(method, /now\s*>\s*deadlineMs/);
  assert.doesNotMatch(method, /deadlineMs\s*-\s*now/);
});

test("Route Host client wait budget covers connect and the initial activate send", () => {
  const source = readFileSync(programPath, "utf8");
  const clientStart = source.indexOf(
    "private static async Task<int> RunClientAsync",
  );
  const clientEnd = source.indexOf(
    "private static async Task<RouteResponse> WaitForActivationAsync",
    clientStart,
  );
  assert.ok(clientStart >= 0 && clientEnd > clientStart, "missing client method");

  const method = source.slice(clientStart, clientEnd);
  const budgetStart = method.indexOf("Stopwatch.GetTimestamp()");
  const connect = method.indexOf(".ConnectAsync(");
  const initialSend = method.indexOf(".SendAsync(msg");
  assert.ok(budgetStart >= 0, "client must start one monotonic total budget");
  assert.ok(budgetStart < connect, "budget must start before pipe connect");
  assert.ok(budgetStart < initialSend, "budget must start before initial activate send");
  assert.match(method, /ConnectAsync\([^;]*clientWaitToken/s);
  assert.match(method, /SendAsync\(msg,\s*clientWaitToken\)/);
});

test("Route Host native and ordinary client exchanges use the bounded request API", () => {
  const source = readFileSync(programPath, "utf8");
  const nativeStart = source.indexOf(
    "private static async Task<int> RunNativeAsync",
  );
  const clientStart = source.indexOf(
    "private static async Task<int> RunClientAsync",
    nativeStart,
  );
  const waitStart = source.indexOf(
    "private static async Task<RouteResponse> WaitForActivationAsync",
    clientStart,
  );
  assert.ok(
    nativeStart >= 0 && clientStart > nativeStart && waitStart > clientStart,
    "missing native/client methods",
  );

  const nativeMethod = source.slice(nativeStart, clientStart);
  const clientMethod = source.slice(clientStart, waitStart);
  assert.match(nativeMethod, /\.SendRequestAsync\(/);
  assert.match(clientMethod, /\.SendRequestAsync\(/);
});
