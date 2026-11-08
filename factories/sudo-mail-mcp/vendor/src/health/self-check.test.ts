import type ConnectionManager from '../connections/manager.js';
import type ImapService from '../services/imap.service.js';
import { logError } from '../error-log.js';
import SelfCheckService from './self-check.js';
import type { AccountConfig } from '../types/index.js';

vi.mock('../error-log.js', () => ({ logError: vi.fn() }));

const account: AccountConfig = {
  name: 'a', email: 'a@x.com', username: 'a@x.com',
  imap: { host: 'imap.x', port: 993, tls: true, starttls: false, verifySsl: true },
  smtp: { host: 'smtp.x', port: 587, tls: false, starttls: true, verifySsl: true },
};

describe('SelfCheckService', () => {
  it('reports ok when both IMAP and SMTP connect', async () => {
    const conn = {
      getImapClient: vi.fn().mockResolvedValue({}),
      verifySmtpTransport: vi.fn().mockResolvedValue(undefined),
    } as unknown as ConnectionManager;
    const svc = new SelfCheckService(conn, { getCapabilities: vi.fn().mockResolvedValue(['IMAP4rev1', 'AUTH=XOAUTH2']) } as unknown as ImapService);
    const r = await svc.checkAccount(account);
    expect(r.ok).toBe(true);
    expect(r.detail?.imap).toMatchObject({ connected: true });
    expect(r.detail?.smtp).toMatchObject({ connected: true });
  });

  it('reports failure and logs when SMTP verify fails', async () => {
    const conn = {
      getImapClient: vi.fn().mockResolvedValue({}),
      verifySmtpTransport: vi.fn().mockRejectedValue(new Error('535 auth failed')),
    } as unknown as ConnectionManager;
    const svc = new SelfCheckService(conn, { getCapabilities: vi.fn().mockResolvedValue(['IMAP4rev1', 'AUTH=XOAUTH2']) } as unknown as ImapService);
    const r = await svc.checkAccount(account);
    expect(r.ok).toBe(false);
    expect(r.detail?.smtp).toMatchObject({ connected: false });
    expect(logError).toHaveBeenCalled();
  });

  it('still reports IMAP ok when only SMTP fails', async () => {
    const conn = {
      getImapClient: vi.fn().mockResolvedValue({}),
      verifySmtpTransport: vi.fn().mockRejectedValue(new Error('timeout')),
    } as unknown as ConnectionManager;
    const svc = new SelfCheckService(conn, { getCapabilities: vi.fn().mockResolvedValue(['IMAP4rev1', 'AUTH=XOAUTH2']) } as unknown as ImapService);
    const r = await svc.checkAccount(account);
    expect(r.ok).toBe(false);
    expect(r.detail?.imap).toMatchObject({ connected: true });
    expect(r.error).toContain('timeout');
  });
});
