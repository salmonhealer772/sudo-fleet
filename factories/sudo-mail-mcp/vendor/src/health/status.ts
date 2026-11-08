/**
 * In-memory health status for the Mercury reliability layer.
 *
 * The readiness endpoint (/readyz) and the status endpoint (/health) read
 * from this store; the background health loop (MercuryHealthService) writes
 * to it. Nothing in this file talks to a mail server: a k8s probe must be
 * cheap and must never be able to hang the HTTP request path.
 *
 * A JSON snapshot is also persisted to /data/logs/health-status.json (the
 * pod's PVC) so the last-known state survives a restart and is readable
 * without a live HTTP call.
 */

import fs from 'node:fs';
import path from 'node:path';

export interface AccountHealthResult {
  account: string;
  email: string;
  ok: boolean;
  error?: string;
  detail?: Record<string, unknown>;
}

export interface HealthReport {
  kind: 'full' | 'token' | 'canary';
  at: string;
  ok: boolean;
  accounts: AccountHealthResult[];
}

export interface StatusSnapshot {
  full?: HealthReport;
  token?: HealthReport;
  canary?: HealthReport;
}

const STATUS_DIR = process.env.EMAIL_MCP_STATUS_DIR ?? '/data/logs';
const STATUS_FILE = path.join(STATUS_DIR, 'health-status.json');

export class HealthStatus {
  private snapshot: StatusSnapshot = {};

  record(report: HealthReport): void {
    this.snapshot[report.kind] = report;
    void HealthStatus.persist(this.snapshot);
  }

  getSnapshot(): StatusSnapshot {
    return { ...this.snapshot };
  }

  /**
   * True when a full (IMAP+SMTP) check has succeeded within `freshnessMs`.
   * This is the readiness signal: "recently verified real mail capability".
   */
  isReady(freshnessMs: number): boolean {
    const full = this.snapshot.full;
    if (!full?.ok) return false;
    const age = Date.now() - Date.parse(full.at);
    return age >= 0 && age <= freshnessMs;
  }

  /** Compact summary for /health — no secrets, no error stacks. */
  toPublic(): Record<string, unknown> {
    return {
      full: HealthStatus.publicReport(this.snapshot.full),
      token: HealthStatus.publicReport(this.snapshot.token),
      canary: HealthStatus.publicReport(this.snapshot.canary),
      ready: this.isReady(5 * 60 * 1000),
    };
  }

  private static publicReport(report: HealthReport | undefined): Record<string, unknown> | null {
    if (!report) return null;
    return {
      at: report.at,
      ok: report.ok,
      accounts: report.accounts.map((a) => ({
        account: a.account,
        ok: a.ok,
        ...(a.error ? { error: a.error } : {}),
      })),
    };
  }

  /** Fire-and-forget write of the snapshot to the PVC. Never throws. */
  private static persist(snapshot: StatusSnapshot): void {
    try {
      fs.mkdirSync(STATUS_DIR, { recursive: true });
      fs.writeFileSync(STATUS_FILE, `${JSON.stringify(snapshot, null, 2)}\n`, 'utf-8');
    } catch {
      // A failed status write must not disturb the health loop.
    }
  }
}
