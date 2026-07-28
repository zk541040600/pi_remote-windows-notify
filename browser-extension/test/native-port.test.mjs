import './setup.mjs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { NativePortClient, ReconnectPolicy } from '../core/native-port.mjs';
import { MessageTypes } from '../core/protocol.mjs';

/**
 * @returns {{ runtime: any, ports: any[], triggerDisconnect: () => void, deliver: (msg: unknown) => void }}
 */
function mockRuntime() {
  /** @type {any[]} */
  const ports = [];
  let lastPort = null;

  const runtime = {
    lastError: null,
    connectNative(name) {
      /** @type {Set<Function>} */
      const msgListeners = new Set();
      /** @type {Set<Function>} */
      const discListeners = new Set();
      const port = {
        name,
        posted: [],
        postMessage(msg) {
          this.posted.push(msg);
        },
        disconnect() {
          for (const fn of discListeners) fn();
        },
        onMessage: {
          addListener(fn) {
            msgListeners.add(fn);
          },
        },
        onDisconnect: {
          addListener(fn) {
            discListeners.add(fn);
          },
        },
        _deliver(msg) {
          for (const fn of msgListeners) fn(msg);
        },
        _disconnect() {
          for (const fn of discListeners) fn();
        },
      };
      lastPort = port;
      ports.push(port);
      return port;
    },
  };

  return {
    runtime,
    ports,
    triggerDisconnect: () => lastPort?._disconnect(),
    deliver: (msg) => lastPort?._deliver(msg),
  };
}

describe('native port reconnect + messaging', () => {
  it('connects and resolves request/response by requestId', async () => {
    const { runtime, ports, deliver } = mockRuntime();
    /** @type {Array<() => void>} */
    const timers = [];
    const client = new NativePortClient({
      runtime,
      hostName: 'io.pi.notify.route',
      schedule: (fn) => {
        timers.push(fn);
        return timers.length;
      },
      clearSchedule: () => {},
    });
    client.start();
    assert.equal(client.isConnected, true);
    assert.equal(ports.length, 1);

    const sendPromise = client.send({
      type: MessageTypes.Health,
      requestId: 'reqhealth0001',
      protocolVersion: 1,
    });
    assert.equal(ports[0].posted.length, 1);
    deliver({ type: 'result', requestId: 'reqhealth0001', result: 'ok' });
    const res = await sendPromise;
    assert.equal(res.result, 'ok');
    client.stop();
  });

  it('reconnects after disconnect with backoff policy', async () => {
    const { runtime, ports, triggerDisconnect } = mockRuntime();
    /** @type {Array<{ fn: Function, ms: number }>} */
    const scheduled = [];
    const client = new NativePortClient({
      runtime,
      reconnectBaseMs: 100,
      reconnectMaxMs: 800,
      schedule: (fn, ms) => {
        scheduled.push({ fn, ms });
        return scheduled.length;
      },
      clearSchedule: () => {},
    });
    client.start();
    assert.equal(ports.length, 1);
    triggerDisconnect();
    assert.equal(client.isConnected, false);
    assert.ok(scheduled.length >= 1);
    assert.ok(scheduled[0].ms >= 80);

    // Fire reconnect timer
    scheduled[0].fn();
    assert.equal(ports.length, 2);
    assert.equal(client.isConnected, true);
    client.stop();
  });

  it('ReconnectPolicy doubles delay up to max', () => {
    const p = new ReconnectPolicy({ baseMs: 500, maxMs: 15_000 });
    assert.equal(p.nextDelayMs(), 500);
    assert.equal(p.nextDelayMs(), 1000);
    assert.equal(p.nextDelayMs(), 2000);
    for (let i = 0; i < 10; i++) p.nextDelayMs();
    assert.equal(p.nextDelayMs(), 15_000);
    p.reset();
    assert.equal(p.nextDelayMs(), 500);
  });

  it('rejects send while disconnected', async () => {
    const { runtime } = mockRuntime();
    const client = new NativePortClient({
      runtime,
      schedule: (fn) => setTimeout(fn, 0),
      clearSchedule: (id) => clearTimeout(id),
    });
    // not started
    await assert.rejects(() => client.send({ type: 'ping', requestId: 'x'.repeat(12) }));
  });
});
