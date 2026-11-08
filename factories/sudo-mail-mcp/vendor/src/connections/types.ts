import type { ImapFlow } from 'imapflow';
import type { Transporter } from 'nodemailer';
import type { AccountConfig } from '../types/index.js';

export interface IConnectionManager {
  getAccount: (name: string) => AccountConfig;
  getAccountNames: () => string[];
  getImapClient: (accountName: string) => Promise<ImapFlow>;
  getSmtpTransport: (accountName: string, options?: { verify?: boolean }) => Promise<Transporter>;
  /** Discard a cached SMTP transport so the next send builds a fresh one. */
  invalidateSmtpTransport: (accountName: string) => Promise<void>;
  /** Discard a cached IMAP client so the next operation reconnects. */
  invalidateImapClient: (accountName: string) => void;
  closeAll: () => Promise<void>;
}
