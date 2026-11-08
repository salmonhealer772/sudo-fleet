import SmtpService from './smtp.service.js';
import type { IConnectionManager } from '../connections/types.js';
import type RateLimiter from '../safety/rate-limiter.js';
import type ImapService from './imap.service.js';
import { logError } from '../error-log.js';

vi.mock('../error-log.js', () => ({ logError: vi.fn() }));

describe('SmtpService — anti-double-send guarantee', () => {
  it('attempts the send exactly once and does not re-submit on failure', async () => {
    const transport = {
      sendMail: vi.fn().mockRejectedValue(new Error('Connection closed unexpectedly')),
    };
    const connections = {
      getAccount: vi.fn().mockReturnValue({
        name: 't', email: 't@e.c', fullName: 'T', username: 't@e.c',
        imap: { host: 'i', port: 993, tls: true, starttls: false, verifySsl: true },
        smtp: { host: 's', port: 587, tls: false, starttls: true, verifySsl: true },
      }),
      getSmtpTransport: vi.fn().mockResolvedValue(transport),
      invalidateSmtpTransport: vi.fn().mockResolvedValue(undefined),
    } as unknown as IConnectionManager;

    const service = new SmtpService(
      connections,
      { tryConsume: vi.fn().mockReturnValue(true) } as unknown as RateLimiter,
      {} as ImapService,
    );

    await expect(
      service.sendEmail('t', { to: ['a@b.c'], subject: 's', body: 'b' }),
    ).rejects.toThrow('Connection closed unexpectedly');

    // The whole point: one send attempt, and the stale transport is discarded
    // so the NEXT message starts from a fresh connection.
    expect(transport.sendMail).toHaveBeenCalledTimes(1);
    expect(connections.invalidateSmtpTransport).toHaveBeenCalledTimes(1);
    expect(logError).toHaveBeenCalled();
  });

  it('sends exactly once on the success path', async () => {
    const transport = {
      sendMail: vi.fn().mockResolvedValue({ messageId: '<ok>' }),
    };
    const connections = {
      getAccount: vi.fn().mockReturnValue({
        name: 't', email: 't@e.c', fullName: 'T', username: 't@e.c',
        imap: { host: 'i', port: 993, tls: true, starttls: false, verifySsl: true },
        smtp: { host: 's', port: 587, tls: false, starttls: true, verifySsl: true },
      }),
      getSmtpTransport: vi.fn().mockResolvedValue(transport),
      invalidateSmtpTransport: vi.fn().mockResolvedValue(undefined),
    } as unknown as IConnectionManager;

    const service = new SmtpService(
      connections,
      { tryConsume: vi.fn().mockReturnValue(true) } as unknown as RateLimiter,
      {} as ImapService,
    );

    const result = await service.sendEmail('t', { to: ['a@b.c'], subject: 's', body: 'b' });
    expect(result.status).toBe('sent');
    expect(transport.sendMail).toHaveBeenCalledTimes(1);
    expect(connections.invalidateSmtpTransport).not.toHaveBeenCalled();
  });
});
