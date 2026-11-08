/**
 * Error-only logging with full tracebacks.
 *
 * Every caught failure is written here — and ONLY failures. Nothing is logged
 * on the success path, so the file stays small and greppable. The sink is
 * `/data/logs/` (the pod's persistent PVC), so an error stays diagnosable even
 * after the process restarts.
 *
 * The filename is `error-YYYYMMDD.log`, appended, rotated daily: the path is
 * recomputed from the current UTC date on every write.
 */

import fs from 'node:fs';
import path from 'node:path';

export interface ErrorLogContext {
  /** file:line or function where the catch lives */
  location: string;
  /** what was being attempted (e.g. 'smtp.send', 'imap.fetch', 'oauth.refresh') */
  operation: string;
  account?: string;
  mailbox?: string;
  recipient?: string;
  /** what the code did after catching (reconnected, retried, returned error, …) */
  handled: string;
}

const ERROR_LOG_DIR = process.env.EMAIL_MCP_ERROR_LOG_DIR ?? '/data/logs';

function errorLogPathFor(date: Date): string {
  const yyyy = date.getUTCFullYear();
  const mm = String(date.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(date.getUTCDate()).padStart(2, '0');
  return path.join(ERROR_LOG_DIR, `error-${yyyy}${mm}${dd}.log`);
}

function describeError(err: unknown): { message: string; stack: string } {
  if (err instanceof Error) {
    return { message: err.message, stack: err.stack ?? '' };
  }
  return { message: String(err), stack: '' };
}

/**
 * Log a caught failure with its full traceback.
 *
 * Fire-and-forget and never throws: the error logger must not turn a failing
 * operation into a crash. If the write itself fails, fall back to stderr.
 */
export function logError(err: unknown, context: ErrorLogContext): void {
  const { message, stack } = describeError(err);
  const entry: Record<string, string> = {
    timestamp: new Date().toISOString(),
    location: context.location,
    operation: context.operation,
    ...(context.account ? { account: context.account } : {}),
    ...(context.mailbox ? { mailbox: context.mailbox } : {}),
    ...(context.recipient ? { recipient: context.recipient } : {}),
    error: message,
    stack,
    handled: context.handled,
  };

  const line = `${JSON.stringify(entry)}\n`;

  try {
    fs.mkdirSync(ERROR_LOG_DIR, { recursive: true });
    fs.appendFileSync(errorLogPathFor(new Date()), line, 'utf-8');
  } catch (writeErr) {
    process.stderr.write(`[email-mcp] error log write failed: ${String(writeErr)}\n`);
    process.stderr.write(`[email-mcp] ${line}`);
  }
}
