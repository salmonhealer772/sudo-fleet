/**
 * End-to-end canary: send a tagged test message from an account to itself and
 * confirm it actually lands in the recipient's inbox.
 *
 * This is the strongest "email works" signal — it proves SMTP accept AND IMAP
 * delivery. Success is reported only when the message actually arrives (the
 * Healthchecks.io heartbeat model); a send that is accepted but never
 * delivered is a failure here.
 *
 * Hard constraint: the recipient is always the account's own address, never an
 * external one. The operator's other accounts are never touched by this class.
 */

import { logError } from '../error-log.js';
import { mcpLog } from '../logging.js';
import type ConnectionManager from '../connections/manager.js';
import type ImapService from '../services/imap.service.js';
import type SmtpService from '../services/smtp.service.js';
import type { AccountConfig } from '../types/index.js';
import type { AccountHealthResult, HealthReport } from './status.js';

const CANARY_PREFIX = 'mercury-canary';
const ARRIVAL_TIMEOUT_MS = 120_000;
const ARRIVAL_POLL_MS = 5_000;

export interface SelfTestOptions {
  arrivalTimeoutMs?: number;
  arrivalPollMs?: number;
}

function makeToken(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

export default class SelfTestService {
  private readonly arrivalTimeoutMs: number;
  private readonly arrivalPollMs: number;

  constructor(
    private connections: ConnectionManager,
    private imapService: ImapService,
    private smtpService: SmtpService,
    options: SelfTestOptions = {},
  ) {
    this.arrivalTimeoutMs = options.arrivalTimeoutMs ?? ARRIVAL_TIMEOUT_MS;
    this.arrivalPollMs = options.arrivalPollMs ?? ARRIVAL_POLL_MS;
  }

  /** Sends account -> itself only (never external). */
  async runCanary(account: AccountConfig): Promise<AccountHealthResult> {
    const base = { account: account.name, email: account.email };
    const token = makeToken();
    const subject = `${CANARY_PREFIX} ${token}`;
    const body = `Mercury self-test canary ${token}`;

    try {
      const result = await this.smtpService.sendEmail(account.name, {
        to: [account.email],
        subject,
        body,
      });
      const arrived = await this.waitForArrival(account.name, token);
      if (!arrived) {
        throw new Error(
          `canary sent (${result.messageId || 'no messageId'}) but never arrived in ` +
            `${account.email} within ${this.arrivalTimeoutMs}ms`,
        );
      }
      return { ...base, ok: true, detail: { messageId: result.messageId, subject } };
    } catch (err) {
      logError(err, {
        location: 'health/self-test.ts:runCanary',
        operation: 'health.canary',
        account: account.name,
        recipient: account.email,
        handled: 'surfaced (canary send or arrival failed)',
      });
      await mcpLog('error', 'self-test', `canary failed for "${account.name}"`);
      return {
        ...base,
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }

  private async waitForArrival(accountName: string, token: string): Promise<boolean> {
    const deadline = Date.now() + this.arrivalTimeoutMs;
    // Poll silently; a transient read error just means "keep waiting". The
    // definitive failure (never arrived) is surfaced by runCanary above, and
    // an IMAP outage is already caught by the full connectivity check.
    while (Date.now() < deadline) {
      // Force a fresh connection each poll: Gmail's IMAP SEARCH on a long-lived
      // connection can lag a just-SMTP-delivered message (search-index lag), so
      // the in-process background canary — which shares the pooled connection —
      // reported false "never arrived". A freshly-opened connection sees the
      // delivered message immediately (this is why the standalone `selftest`
      // CLI, which always uses fresh connections, is reliably green).
      this.connections.invalidateImapClient(accountName);
      try {
        const page = await this.imapService.listEmails(accountName, {
          mailbox: 'INBOX',
          subject: token,
          pageSize: 20,
        });
        if (page.items.some((m) => m.subject.includes(token))) {
          return true;
        }
      } catch {
        // keep polling
      }
      await new Promise((resolve) => setTimeout(resolve, this.arrivalPollMs));
    }
    return false;
  }

  async runAll(accounts: AccountConfig[]): Promise<HealthReport> {
    const results = await Promise.all(accounts.map((a) => this.runCanary(a)));
    return {
      kind: 'canary',
      at: new Date().toISOString(),
      ok: results.every((r) => r.ok),
      accounts: results,
    };
  }
}
