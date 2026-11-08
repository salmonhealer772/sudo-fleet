/**
 * Refresh-token health check.
 *
 * The single PERMANENT failure mode for an always-on OAuth2 email system is a
 * dead refresh token (user revoked access, password change on a Gmail-scoped
 * token, or exceeding the per-user live-token limit). Access-token expiry is
 * NOT a problem — it is refreshed automatically from the refresh token. A dead
 * refresh token, however, cannot be auto-healed: it needs a human re-auth.
 * This check's entire job is earliest-possible detection of exactly that.
 *
 * It force-refreshes each account's refresh token (bypassing the in-memory
 * access-token cache) and logs every failure loudly with a full traceback.
 */

import { logError } from '../error-log.js';
import { mcpLog } from '../logging.js';
import OAuthService from '../services/oauth.service.js';
import type { AccountConfig } from '../types/index.js';
import type { AccountHealthResult, HealthReport } from './status.js';

export default class TokenHealthService {
  async checkAccount(account: AccountConfig): Promise<AccountHealthResult> {
    const base = { account: account.name, email: account.email };
    if (!account.oauth2) {
      // Password-authenticated accounts have no refresh token to check.
      return { ...base, ok: true, detail: { auth: 'password' } };
    }
    try {
      const { expiresIn } = await OAuthService.refreshAccessToken(account.oauth2);
      return {
        ...base,
        ok: true,
        detail: {
          auth: 'oauth2',
          provider: account.oauth2.provider,
          expires_in_s: expiresIn,
        },
      };
    } catch (err) {
      logError(err, {
        location: 'health/token-health.ts:checkAccount',
        operation: 'health.token_check',
        account: account.name,
        handled: 'surfaced (refresh token dead or refresh failed — needs operator re-auth)',
      });
      await mcpLog(
        'critical',
        'token-health',
        `refresh token check FAILED for "${account.name}"`,
      );
      return {
        ...base,
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }

  async checkAll(accounts: AccountConfig[]): Promise<HealthReport> {
    const results = await Promise.all(accounts.map((a) => this.checkAccount(a)));
    return {
      kind: 'token',
      at: new Date().toISOString(),
      ok: results.every((r) => r.ok),
      accounts: results,
    };
  }
}
