/**
 * Real-capability connectivity check (IMAP + SMTP) for every account.
 *
 * Unlike a TCP probe — which only proves the kernel answered the SYN — this
 * verifies the server can actually authenticate to each account's IMAP and
 * SMTP endpoints. It never sends a message (sending is covered separately by
 * the canary in self-test.ts), so it is safe to run frequently without
 * touching anyone's inbox.
 */

import { logError } from '../error-log.js';
import { mcpLog } from '../logging.js';
import type ConnectionManager from '../connections/manager.js';
import type ImapService from '../services/imap.service.js';
import type { AccountConfig } from '../types/index.js';
import type { AccountHealthResult, HealthReport } from './status.js';

export default class SelfCheckService {
  constructor(
    private connections: ConnectionManager,
    private imapService: ImapService,
  ) {}

  async checkAccount(account: AccountConfig): Promise<AccountHealthResult> {
    const base = { account: account.name, email: account.email };
    const detail: Record<string, unknown> = {};
    let ok = true;
    let firstError: string | undefined;

    try {
      const start = Date.now();
      await this.connections.getImapClient(account.name);
      const capabilities = await this.imapService.getCapabilities(account.name);
      detail.imap = {
        connected: true,
        latency_ms: Date.now() - start,
        capabilities: capabilities.length,
      };
    } catch (err) {
      ok = false;
      const message = err instanceof Error ? err.message : String(err);
      firstError = message;
      detail.imap = { connected: false, error: message };
      logError(err, {
        location: 'health/self-check.ts:checkAccount',
        operation: 'health.full_check.imap',
        account: account.name,
        handled: 'surfaced (IMAP connection failed)',
      });
    }

    try {
      const start = Date.now();
      await this.connections.verifySmtpTransport(account.name);
      detail.smtp = { connected: true, latency_ms: Date.now() - start };
    } catch (err) {
      ok = false;
      const message = err instanceof Error ? err.message : String(err);
      firstError = firstError ?? message;
      detail.smtp = { connected: false, error: message };
      logError(err, {
        location: 'health/self-check.ts:checkAccount',
        operation: 'health.full_check.smtp',
        account: account.name,
        handled: 'surfaced (SMTP verify failed)',
      });
    }

    if (!ok) {
      await mcpLog('error', 'self-check', `connectivity check failed for "${account.name}"`);
    }

    return { ...base, ok, ...(firstError ? { error: firstError } : {}), detail };
  }

  async checkAll(accounts: AccountConfig[]): Promise<HealthReport> {
    const results = await Promise.all(accounts.map((a) => this.checkAccount(a)));
    return {
      kind: 'full',
      at: new Date().toISOString(),
      ok: results.every((r) => r.ok),
      accounts: results,
    };
  }
}
