#!/usr/bin/env node
import { loadSenderConfig, publicConfigStatus } from "./config.mjs";
import { DurableStore } from "./store.mjs";
import { HealthLeaseOwner } from "./lease.mjs";
import { PaseoSenderService } from "./service.mjs";
import { createLogger } from "./privacy.mjs";
import { WindowsDelivery } from "./delivery.mjs";

const USAGE = `paseo-sender — provider-independent Paseo → Windows notify bridge

Usage:
  paseo-sender run [--live] [--config <path>]
  paseo-sender check [--config <path>]
  paseo-sender dry-run [--config <path>]
  paseo-sender status [--config <path>]

Defaults to shadow mode (no Windows delivery). Pass --live or set
deliveryMode=live / PASEO_SENDER_DELIVERY_MODE=live for real POSTs.

Never put tokens/passwords on the command line; use config file or env.
`;

/**
 * @param {string[]} argv
 */
export async function main(argv = process.argv.slice(2)) {
  const logger = createLogger();
  const command = argv[0] || "help";
  const flags = parseFlags(argv.slice(1));

  if (command === "help" || command === "-h" || command === "--help") {
    process.stdout.write(USAGE);
    return 0;
  }

  if (flags.live) {
    process.env.PASEO_SENDER_DELIVERY_MODE = "live";
  }

  let config;
  try {
    config = await loadSenderConfig({ configPath: flags.config });
  } catch (error) {
    logger.error("config_error", {
      reason: error instanceof Error ? error.message : "unknown",
    });
    return 2;
  }

  if (command === "status") {
    const store = new DurableStore(config.stateDir, { logger });
    await store.load();
    const lease = new HealthLeaseOwner({ stateDir: config.stateDir, staleMs: config.leaseStaleMs });
    await lease.load();
    const status = {
      config: publicConfigStatus(config),
      store: {
        corrupt: store.corrupt,
        corruptReason: store.corruptReason || undefined,
        initialized: store.state.initialized,
        outboxCount: store.listItems().length,
      },
      lease: {
        healthy: lease.isHealthy(),
        lastHealthyAt: lease.lease?.lastHealthyAt,
        status: lease.lease?.status,
      },
    };
    process.stdout.write(`${JSON.stringify(status, null, 2)}\n`);
    return store.corrupt ? 1 : 0;
  }

  if (command === "check") {
    const store = new DurableStore(config.stateDir, { logger });
    const loaded = await store.load();
    const lease = new HealthLeaseOwner({ stateDir: config.stateDir, staleMs: config.leaseStaleMs });
    await lease.load();
    const delivery = new WindowsDelivery({
      notifyUrl: config.windowsEndpoint,
      token: config.windowsToken,
      timeoutMs: config.timeoutMs,
      deliveryMode: config.deliveryMode,
      logger,
    });

    /** @type {Record<string, unknown>} */
    const report = {
      ok: true,
      config: publicConfigStatus(config),
      storeOk: loaded.ok,
      storeCorrupt: store.corrupt,
      deliveryMode: config.deliveryMode,
      endpointPolicy: config.enabled,
    };

    if (config.windowsToken && config.deliveryMode === "live") {
      const health = await delivery.probeHealth();
      report.windowsHealth = {
        ok: health.ok,
        ready: health.ready,
        reason: health.reason,
        elapsedMs: health.elapsedMs,
      };
      if (!health.ok || !health.ready) report.ok = false;
    } else {
      report.windowsHealth = { skipped: true, reason: "shadow-or-no-token" };
    }

    if (!loaded.ok) report.ok = false;
    if (!config.enabled) report.ok = false;

    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    return report.ok ? 0 : 1;
  }

  if (command === "dry-run") {
    // Force shadow for dry-run
    config = { ...config, deliveryMode: "shadow" };
    process.stdout.write(
      `${JSON.stringify(
        {
          mode: "dry-run",
          config: publicConfigStatus(config),
          note: "Would start service in shadow mode; no daemon connect in dry-run CLI.",
        },
        null,
        2,
      )}\n`,
    );
    return 0;
  }

  if (command === "run") {
    const service = new PaseoSenderService({ config, logger });
    const shutdown = async (signal) => {
      logger.info("signal", { signal });
      try {
        await service.stop();
      } finally {
        process.exit(0);
      }
    };
    process.on("SIGINT", () => void shutdown("SIGINT"));
    process.on("SIGTERM", () => void shutdown("SIGTERM"));
    try {
      const started = await service.start();
      if (!started.started) return started.reason === "disabled" ? 0 : 1;
    } catch (error) {
      logger.error("start_failed", {
        reason: error instanceof Error ? error.message : "unknown",
      });
      return 1;
    }
    // Keep alive
    await new Promise(() => {});
    return 0;
  }

  process.stderr.write(`unknown command: ${command}\n`);
  process.stderr.write(USAGE);
  return 2;
}

/**
 * @param {string[]} args
 */
function parseFlags(args) {
  /** @type {{ config?: string, live?: boolean }} */
  const flags = {};
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (a === "--live") flags.live = true;
    else if (a === "--config") {
      flags.config = args[i + 1];
      i += 1;
    } else if (a.startsWith("--config=")) {
      flags.config = a.slice("--config=".length);
    }
  }
  return flags;
}

const isDirect = process.argv[1] &&
  (process.argv[1].endsWith("/cli.mjs") || process.argv[1].endsWith("paseo-sender"));

if (isDirect) {
  main().then(
    (code) => {
      if (typeof code === "number" && code !== 0) process.exitCode = code;
    },
    (error) => {
      console.error(error);
      process.exitCode = 1;
    },
  );
}
