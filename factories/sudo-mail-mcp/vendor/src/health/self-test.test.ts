import type ConnectionManager from '../connections/manager.js';
import type ImapService from '../services/imap.service.js';
import type SmtpService from '../services/smtp.service.js';
import SelfTestService from './self-test.js';
import type { AccountConfig } from '../types/index.js';

vi.mock('../error-log.js', () => ({ logError: vi.fn() }));

const connections = {
  invalidateImapClient: vi.fn(),
} as unknown as ConnectionManager;

const account: AccountConfig = {
  name: 'a', email: 'a@x.com', username: 'a@x.com',
  imap: { host: 'imap.x', port: 993, tls: true, starttls: false, verifySsl: true },
  smtp: { host: 'smtp.x', port: 587, tls: false, starttls: true, verifySsl: true },
};

describe('SelfTestService', () => {
  it('sends account-to-self and reports ok when the canary arrives', async () => {
    const smtp = {
      sendEmail: vi.fn().mockResolvedValue({ messageId: '<m1>', status: 'sent' }),
    } as unknown as SmtpService;
    const imap = {
      listEmails: vi.fn().mockImplementation(
        (_acct: string, opts: { subject?: string }) => ({
          items: [{ subject: `mercury-canary ${opts.subject ?? ''}` }],
        }),
      ),
    } as unknown as ImapService;
    const svc = new SelfTestService(connections, imap, smtp, {
      arrivalTimeoutMs: 200, arrivalPollMs: 5,
    });

    const r = await svc.runCanary(account);
    expect(r.ok).toBe(true);
    // recipient is always the account's own address, never an external one
    expect(smtp.sendEmail).toHaveBeenCalledWith(
      'a',
      expect.objectContaining({ to: ['a@x.com'] }),
    );
  });

  it('reports failure when the canary never arrives', async () => {
    const smtp = {
      sendEmail: vi.fn().mockResolvedValue({ messageId: '<m1>', status: 'sent' }),
    } as unknown as SmtpService;
    const imap = {
      listEmails: vi.fn().mockResolvedValue({ items: [] }),
    } as unknown as ImapService;
    const svc = new SelfTestService(connections, imap, smtp, {
      arrivalTimeoutMs: 30, arrivalPollMs: 5,
    });

    const r = await svc.runCanary(account);
    expect(r.ok).toBe(false);
    expect(r.error).toContain('never arrived');
  });

  it('reports failure when the send itself fails', async () => {
    const smtp = {
      sendEmail: vi.fn().mockRejectedValue(new Error('Connection closed unexpectedly')),
    } as unknown as SmtpService;
    const imap = {
      listEmails: vi.fn().mockResolvedValue({ items: [] }),
    } as unknown as ImapService;
    const svc = new SelfTestService(connections, imap, smtp, {
      arrivalTimeoutMs: 30, arrivalPollMs: 5,
    });

    const r = await svc.runCanary(account);
    expect(r.ok).toBe(false);
    expect(r.error).toContain('Connection closed unexpectedly');
  });
});
