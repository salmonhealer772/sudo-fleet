/**
 * `email-mcp selftest` — run the three reliability checks once and print a
 * JSON report. Exits 0 when every check passed, 1 when any account failed.
 *
 * This is the manual/ops trigger for the same checks the background loop runs
 * on its own schedule; it is also the hook for external (cron/CI) heartbeat
 * runs against a live cluster.
 */

import { buildServices } from '../app.js';
import type { HealthReport } from '../health/status.js';

export default async function runSelfTest(): Promise<void> {
  const services = await buildServices();
  const snapshot = await services.health.runOnce();
  const reports = [snapshot.full, snapshot.token, snapshot.canary].filter(
    (r): r is HealthReport => r !== undefined,
  );
  const allOk = reports.every((r) => r.ok);
  process.stdout.write(`${JSON.stringify(snapshot, null, 2)}\n`);

  // Best-effort graceful close, capped: IMAP logout can block on a pooled
  // connection mid-command, and a one-shot CLI must not hang after it has
  // already reported its result. The cap also gives the stdout write above
  // time to flush before the explicit exit.
  await Promise.race([
    services.connections.closeAll(),
    new Promise<void>((resolve) => setTimeout(resolve, 3_000)),
  ]);
  process.exit(allOk ? 0 : 1);
}
