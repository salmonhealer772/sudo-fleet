/**
 * Connection manager for lazy-persistent IMAP and SMTP connections.
 *
 * - Creates connections on first use per account
 * - Reuses open connections across tool calls
 * - Auto-reconnects on failure
 * - Graceful shutdown closes all connections
 */

import type { ImapFlow } from 'imapflow';
import type { TransportConfig, Transporter } from 'nodemailer';
import nodemailer from 'nodemailer';
import { mcpLog } from '../logging.js';
import { logError } from '../error-log.js';

import eventBus from '../services/event-bus.js';
import type OAuthService from '../services/oauth.service.js';
import type { AccountConfig } from '../types/index.js';
import { authFailureHint, withAuthGuidance } from '../utils/auth-error.js';
import { createImapClient } from '../utils/imap-client.js';
import type { IConnectionManager } from './types.js';

type SmtpAuth =
  | { user: string; pass?: string }
  | { type: string; user: string; accessToken: string };

/**
 * A `starttls = true` account demands an encrypted session on a plain port.
 * imapflow upgrades opportunistically when the server offers STARTTLS, but it
 * will also happily stay plaintext when the server does not — so the flag was
 * silently unenforced (proven E2E against a no-STARTTLS server 2026-10-10).
 * nodemailer's requireTLS covers SMTP; this is the IMAP counterpart.
 */
async function assertImapUpgraded(client: ImapFlow, account: AccountConfig): Promise<void> {
  if (!account.imap.starttls || account.imap.tls) return;
  const secured = (client as unknown as { secureConnection?: boolean }).secureConnection;
  if (secured) return;
  try {
    await client.logout();
  } catch {
    client.close();
  }
  throw new Error(
    `IMAP connection to ${account.imap.host}:${account.imap.port} stayed plaintext but ` +
      `starttls = true requires an upgraded session — the server likely does not support STARTTLS.`,
  );
}

export default class ConnectionManager implements IConnectionManager {
  private imapClients = new Map<string, ImapFlow>();

  private smtpTransports = new Map<string, Transporter>();

  private accounts = new Map<string, AccountConfig>();

  private oauthService?: OAuthService;

  constructor(accounts: AccountConfig[], oauthService?: OAuthService) {
    accounts.forEach((account) => {
      this.accounts.set(account.name, account);
    });
    this.oauthService = oauthService;
  }

  // -------------------------------------------------------------------------
  // Account lookup
  // -------------------------------------------------------------------------

  getAccount(name: string): AccountConfig {
    const account = this.accounts.get(name);
    if (!account) {
      throw new Error(
        `Account "${name}" not found. Available: ${[...this.accounts.keys()].join(', ')}`,
      );
    }
    return account;
  }

  getAccountNames(): string[] {
    return [...this.accounts.keys()];
  }

  // -------------------------------------------------------------------------
  // IMAP
  // -------------------------------------------------------------------------

  /**
   * ImapFlow is an EventEmitter; Node's default behaviour for an unhandled
   * 'error' is to throw, which on a cached, long-lived connection crashes the
   * whole process — an idle socket timeout or the server hanging up become
   * uncatchable. 'close' needs the same handling: a client that closes
   * cleanly is just as dead as one that errored, and the next caller must not
   * be handed the same stale object.
   *
   * `invalidateIfCurrent` guards the one race this introduces: an old
   * client's socket can keep tearing down after `getImapClient` has already
   * replaced it in the map, so a trailing event from the old object must not
   * evict the new one that took its place.
   */
  private registerImapLifecycle(accountName: string, client: ImapFlow): void {
    const invalidateIfCurrent = (): void => {
      if (this.imapClients.get(accountName) === client) {
        this.imapClients.delete(accountName);
        // Same signal the usable===false path sends: anything derived from
        // this connection — capability probes, cached UIDVALIDITY,
        // label-strategy memos — is now suspect.
        eventBus.emit('imap:reconnect', { account: accountName });
      }
    };

    client.on('error', (err: Error) => {
      invalidateIfCurrent();
      mcpLog('warning', 'imap', `IMAP connection lost for "${accountName}": ${err.message}`).catch(
        () => undefined,
      );
    });
    client.on('close', invalidateIfCurrent);
  }

  /**
   * Detect an IMAP client whose socket has already been destroyed but whose
   * `usable` flag has not flipped yet. imapflow sets `usable=false` only once
   * the close/error event is processed; in the gap a pooled client can still
   * report usable while its socket is dead, and the next fetch surfaces
   * "Connection not available" instead of reconnecting. Checking the socket
   * directly closes that gap for the common (already-torn-down) case.
   */
  private static isImapSocketDead(client: ImapFlow): boolean {
    const socket = (client as unknown as { socket?: { destroyed?: boolean } }).socket;
    return socket?.destroyed === true;
  }

  async getImapClient(accountName: string): Promise<ImapFlow> {
    const existing = this.imapClients.get(accountName);
    if (existing?.usable && !ConnectionManager.isImapSocketDead(existing)) {
      return existing;
    }

    // Clean up stale connection
    if (existing) {
      this.imapClients.delete(accountName);
      try {
        existing.close();
      } catch {
        /* ignore */
      }
      // Announce the replacement. A new connection may be talking to a
      // different server, or to a mailbox that has been recreated since —
      // so capability probes, per-account memos and any cached UIDVALIDITY
      // derived from the old connection must be revalidated.
      eventBus.emit('imap:reconnect', { account: accountName });
    }

    const account = this.getAccount(accountName);

    // Build auth config based on auth type
    let auth: { user: string; pass?: string; accessToken?: string };
    if (account.oauth2 && this.oauthService) {
      const accessToken = await this.oauthService.getAccessToken(account.oauth2);
      auth = { user: account.username, accessToken };
    } else {
      auth = { user: account.username, pass: account.password };
    }

    const client = createImapClient({
      host: account.imap.host,
      port: account.imap.port,
      secure: account.imap.tls,
      tls: {
        rejectUnauthorized: account.imap.verifySsl,
      },
      auth,
      logger: false,
    });

    this.registerImapLifecycle(accountName, client);
    await withAuthGuidance(account, 'IMAP', () => client.connect());
    await assertImapUpgraded(client, account);
    await mcpLog(
      'info',
      'imap',
      `Connected to ${account.imap.host}:${account.imap.port} for "${accountName}"`,
    );
    this.imapClients.set(accountName, client);
    return client;
  }

  // -------------------------------------------------------------------------
  // SMTP
  // -------------------------------------------------------------------------

  private static buildSmtpTransportOptions(
    account: AccountConfig,
    auth: SmtpAuth,
  ): TransportConfig {
    const pool = account.smtp.pool ?? {
      enabled: true,
      maxConnections: 1,
      maxMessages: 100,
    };

    return {
      host: account.smtp.host,
      port: account.smtp.port,
      secure: account.smtp.tls,
      requireTLS: account.smtp.starttls,
      ignoreTLS: !account.smtp.tls && !account.smtp.starttls,
      tls: {
        rejectUnauthorized: account.smtp.verifySsl,
      },
      auth,
      pool: pool.enabled,
      ...(pool.enabled
        ? {
            maxConnections: pool.maxConnections,
            maxMessages: pool.maxMessages,
          }
        : {}),
    } as TransportConfig;
  }

  /**
   * Drop any idle pooled SMTP connection on a transport.
   *
   * Gmail/Outlook close idle SMTP connections, but nodemailer's pool keeps
   * them marked "available" until a write fails — which is exactly the
   * "Connection closed unexpectedly" a send then surfaces. Dropping the idle
   * connection forces the pool to open a fresh one on the next send, so a
   * message is never handed to a dead socket. This re-establishes the
   * transport only: it never touches, and never re-submits, the message.
   */
  private static dropIdleSmtpConnections(transport: Transporter): void {
    const pool = (transport as { transporter?: unknown }).transporter as
      | { _connections?: Array<{ available?: boolean; close?: () => void }> }
      | undefined;
    const connections = pool?._connections;
    if (!Array.isArray(connections)) return;
    for (const connection of [...connections]) {
      if (connection.available && typeof connection.close === 'function') {
        try {
          connection.close();
        } catch {
          /* a dead socket just closes */
        }
      }
    }
  }

  async getSmtpTransport(
    accountName: string,
    options?: { verify?: boolean },
  ): Promise<Transporter> {
    const verify = options?.verify ?? false;
    const existing = this.smtpTransports.get(accountName);
    if (existing) {
      if (!verify) {
        // Drop any idle pooled connection before handing the transport to a
        // send, so the send always starts from a fresh connection.
        ConnectionManager.dropIdleSmtpConnections(existing);
        return existing;
      }
      try {
        await existing.verify();
        return existing;
      } catch (err) {
        logError(err, {
          location: 'connections/manager.ts:getSmtpTransport',
          operation: 'smtp.verify',
          account: accountName,
          handled: 'reconnect (discard stale transport, rebuild)',
        });
        this.smtpTransports.delete(accountName);
        try {
          existing.close();
        } catch {
          /* ignore */
        }
      }
    }

    const account = this.getAccount(accountName);

    // Build auth config based on auth type
    let auth: SmtpAuth;
    if (account.oauth2 && this.oauthService) {
      const accessToken = await this.oauthService.getAccessToken(account.oauth2);
      auth = { type: 'OAuth2', user: account.username, accessToken };
    } else {
      auth = { user: account.username, pass: account.password };
    }

    const transport = nodemailer.createTransport(
      ConnectionManager.buildSmtpTransportOptions(account, auth),
    );

    await withAuthGuidance(account, 'SMTP', () => transport.verify());
    await mcpLog(
      'info',
      'smtp',
      `Connected to ${account.smtp.host}:${account.smtp.port} for "${accountName}"`,
    );
    this.smtpTransports.set(accountName, transport);
    return transport;
  }

  async verifySmtpTransport(accountName: string): Promise<void> {
    await this.getSmtpTransport(accountName, { verify: true });
  }

  /**
   * Discard a cached SMTP transport so the next send builds a fresh one.
   * Called after a failed send: the message was NOT re-submitted, and the next
   * attempt starts from a clean (fresh) connection.
   */
  async invalidateSmtpTransport(accountName: string): Promise<void> {
    const transport = this.smtpTransports.get(accountName);
    if (!transport) return;
    this.smtpTransports.delete(accountName);
    try {
      transport.close();
    } catch {
      /* ignore */
    }
  }

  /**
   * Discard a cached IMAP client so the next operation reconnects. Called
   * when an on-demand operation hits a stale connection; a fresh client is
   * built on the next `getImapClient`.
   */
  invalidateImapClient(accountName: string): void {
    const client = this.imapClients.get(accountName);
    if (!client) return;
    this.imapClients.delete(accountName);
    try {
      client.close();
    } catch {
      /* ignore */
    }
    eventBus.emit('imap:reconnect', { account: accountName });
  }

  // -------------------------------------------------------------------------
  // Test connections (for setup wizard / test command)
  // -------------------------------------------------------------------------

  static async testImap(
    account: AccountConfig,
    oauthService?: OAuthService,
  ): Promise<{
    success: boolean;
    error?: string;
    /** What to do about a rejected credential, for the caller to render. */
    hint?: string;
    details?: { messages: number; folders: number };
  }> {
    let client: ImapFlow | undefined;
    try {
      let auth: { user: string; pass?: string; accessToken?: string };
      if (account.oauth2 && oauthService) {
        const accessToken = await oauthService.getAccessToken(account.oauth2);
        auth = { user: account.username, accessToken };
      } else {
        auth = { user: account.username, pass: account.password };
      }

      client = createImapClient({
        host: account.imap.host,
        port: account.imap.port,
        secure: account.imap.tls,
        tls: {
          rejectUnauthorized: account.imap.verifySsl,
        },
        auth,
        logger: false,
      });
      // This connection is short-lived (closed in the `finally` below), but
      // it is still an EventEmitter: a stray socket error between awaits
      // would otherwise crash the process running `email-mcp test` instead
      // of being reported as the probe failure it is.
      client.on('error', () => undefined);
      await client.connect();
      await assertImapUpgraded(client, account);

      const mailboxes = await client.list();
      let messageCount = 0;
      try {
        const inbox = await client.status('INBOX', {
          messages: true,
          unseen: true,
        });
        messageCount = inbox ? (inbox.messages ?? 0) : 0;
      } catch {
        // INBOX may not exist (e.g. Google Workspace uses "All Mail")
        const firstMailbox = mailboxes[0];
        if (firstMailbox) {
          try {
            const first = await client.status(firstMailbox.path, {
              messages: true,
            });
            messageCount = first ? (first.messages ?? 0) : 0;
          } catch {
            /* ignore — connection still works */
          }
        }
      }

      return {
        success: true,
        details: {
          messages: messageCount,
          folders: mailboxes.length,
        },
      };
    } catch (err) {
      return {
        success: false,
        error: err instanceof Error ? err.message : String(err),
        hint: authFailureHint(err, account),
      };
    } finally {
      if (client) {
        try {
          await client.logout();
        } catch {
          /* ignore */
        }
      }
    }
  }

  static async testSmtp(
    account: AccountConfig,
    oauthService?: OAuthService,
  ): Promise<{ success: boolean; error?: string; hint?: string }> {
    let transport: Transporter | undefined;
    try {
      let auth: SmtpAuth;
      if (account.oauth2 && oauthService) {
        const accessToken = await oauthService.getAccessToken(account.oauth2);
        auth = { type: 'OAuth2', user: account.username, accessToken };
      } else {
        auth = { user: account.username, pass: account.password };
      }

      transport = nodemailer.createTransport(
        ConnectionManager.buildSmtpTransportOptions(account, auth),
      );
      await transport.verify();
      return { success: true };
    } catch (err) {
      return {
        success: false,
        error: err instanceof Error ? err.message : String(err),
        hint: authFailureHint(err, account),
      };
    } finally {
      transport?.close();
    }
  }

  // -------------------------------------------------------------------------
  // Shutdown
  // -------------------------------------------------------------------------

  async closeAll(): Promise<void> {
    await mcpLog('info', 'connections', 'Closing all connections');
    const closeOps: Promise<void>[] = [];

    Array.from(this.imapClients.entries()).forEach(([name, client]) => {
      closeOps.push(
        client
          .logout()
          .catch(() => {})
          .then(() => {
            this.imapClients.delete(name);
          }),
      );
    });

    Array.from(this.smtpTransports.entries()).forEach(([name, transport]) => {
      transport.close();
      this.smtpTransports.delete(name);
    });

    await Promise.allSettled(closeOps);
  }
}
