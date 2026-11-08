/**
 * Recognise connection-lost errors from the transports this server uses, so a
 * caller can reconnect and retry once instead of surfacing a stale socket to
 * the user.
 *
 * imapflow stamps its own codes (`NoConnection`, `EConnectionClosed`, …);
 * Node's socket/TLS/DNS layer passes through its own (`ECONNRESET`, …).
 */

const IMAP_CONNECTION_CODES = new Set([
  'NoConnection',
  'EConnectionClosed',
  'StateLogout',
  'ClosedAfterConnectText',
  'ClosedAfterConnectTLS',
]);

const SOCKET_ERROR_CODES = new Set([
  'ECONNRESET',
  'ECONNREFUSED',
  'EPIPE',
  'ETIMEDOUT',
  'ECONNABORTED',
  'ENOTFOUND',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'ENETDOWN',
  'EAI_AGAIN',
]);

/**
 * True when the failure means "the connection is gone" and a fresh connection
 * could retry the operation safely. False for server rejections and logical
 * errors (bad mailbox, message not found), which a retry would not fix.
 */
export function isImapConnectionError(err: unknown): boolean {
  const code = (err as { code?: unknown } | null)?.code;
  if (typeof code !== 'string') return false;
  return IMAP_CONNECTION_CODES.has(code) || SOCKET_ERROR_CODES.has(code);
}
