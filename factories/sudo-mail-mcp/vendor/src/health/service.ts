/**
 * Mercury health orchestrator.
 *
 * Runs the three checks on independent intervals and feeds the shared
 * HealthStatus store. Started once per process from startBackgroundServices().
 *
 *   - full check   (IMAP+SMTP connectivity)   — every fullMs  (default 5 min)
 *   - token check  (refresh-token validity)   — every tokenMs (default 15 min)
 *   - canary       (send+receive end-to-end)  — every canaryMs(default 60 min)
 *
 * The first canary is delayed by a short bootstrap so a crash-looping pod does
 * not spray canary mail while it is being restarted.
 */

import { logError } from '../error-log.js';
import type ConnectionManager from '../connections/manager.js';
import type ImapService from '../services/imap.service.js';
import type SmtpService from '../services/smtp.service.js';
import type { AccountConfig } from '../types/index.js';
import SelfCheckService from './self-check.js';
import SelfTestService from './self-test.js';
import TokenHealthService from './token-health.js';
import { HealthStatus, type StatusSnapshot } from './status.js';

export interface HealthIntervals {
  fullMs: number;
  tokenMs: number;
  canaryMs: number;
}

const DEFAULT_INTERVALS: HealthIntervals = {
  fullMs: 300_000,
  tokenMs: 900_000,
  canaryMs: 3_600_000,
};

const CANARY_BOOTSTRAP_DELAY_MS = 60_000;

function envMs(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

export interface MercuryHealthDeps {
  connections: ConnectionManager;
  imapService: ImapService;
  smtpService: SmtpService;
  accounts: AccountConfig[];
}

export default class MercuryHealthService {
  private readonly status = new HealthStatus();
  private readonly full: SelfCheckService;
  private readonly token: TokenHealthService;
  private readonly canary: SelfTestService;
  private readonly accounts: AccountConfig[];
  private readonly intervals: HealthIntervals;
  private timers: ReturnType<typeof setInterval>[] = [];
  private started = false;

  constructor(deps: MercuryHealthDeps) {
    this.accounts = deps.accounts;
    this.full = new SelfCheckService(deps.connections, deps.imapService);
    this.token = new TokenHealthService();
    this.canary = new SelfTestService(deps.connections, deps.imapService, deps.smtpService);
    this.intervals = {
      fullMs: envMs('MERCURY_HEALTH_INTERVAL_MS', DEFAULT_INTERVALS.fullMs),
      tokenMs: envMs('MERCURY_TOKEN_INTERVAL_MS', DEFAULT_INTERVALS.tokenMs),
      canaryMs: envMs('MERCURY_CANARY_INTERVAL_MS', DEFAULT_INTERVALS.canaryMs),
    };
  }

  getStatus(): HealthStatus {
    return this.status;
  }

  start(): void {
    if (this.started) return;
    this.started = true;

    void this.runFull();
    void this.runToken();
    this.timers.push(setTimeout(() => void this.runCanary(), CANARY_BOOTSTRAP_DELAY_MS));

    this.timers.push(setInterval(() => void this.runFull(), this.intervals.fullMs));
    this.timers.push(setInterval(() => void this.runToken(), this.intervals.tokenMs));
    this.timers.push(setInterval(() => void this.runCanary(), this.intervals.canaryMs));
  }

  stop(): void {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
  }

  /** Run all three checks once and return the snapshot (manual/CLI use). */
  async runOnce(): Promise<StatusSnapshot> {
    const [full, token, canary] = await Promise.all([
      this.full.checkAll(this.accounts),
      this.token.checkAll(this.accounts),
      this.canary.runAll(this.accounts),
    ]);
    this.status.record(full);
    this.status.record(token);
    this.status.record(canary);
    return this.status.getSnapshot();
  }

  private async runFull(): Promise<void> {
    try {
      this.status.record(await this.full.checkAll(this.accounts));
    } catch (err) {
      logError(err, {
        location: 'health/service.ts:runFull',
        operation: 'health.full_check',
        handled: 'surfaced (check loop crashed)',
      });
    }
  }

  private async runToken(): Promise<void> {
    try {
      this.status.record(await this.token.checkAll(this.accounts));
    } catch (err) {
      logError(err, {
        location: 'health/service.ts:runToken',
        operation: 'health.token_check',
        handled: 'surfaced (check loop crashed)',
      });
    }
  }

  private async runCanary(): Promise<void> {
    try {
      this.status.record(await this.canary.runAll(this.accounts));
    } catch (err) {
      logError(err, {
        location: 'health/service.ts:runCanary',
        operation: 'health.canary',
        handled: 'surfaced (check loop crashed)',
      });
    }
  }
}
