import OAuthService from '../services/oauth.service.js';
import { logError } from '../error-log.js';
import TokenHealthService from './token-health.js';
import type { AccountConfig } from '../types/index.js';

vi.mock('../error-log.js', () => ({ logError: vi.fn() }));

const imap = { host: 'imap.x', port: 993, tls: true, starttls: false, verifySsl: true };
const smtp = { host: 'smtp.x', port: 587, tls: false, starttls: true, verifySsl: true };

function oauthAccount(): AccountConfig {
  return {
    name: 'aidan',
    email: 'aidan@x.com',
    username: 'aidan@x.com',
    oauth2: { provider: 'google', clientId: 'c', clientSecret: 's', refreshToken: 'rt' },
    imap,
    smtp,
  } as AccountConfig;
}

describe('TokenHealthService', () => {
  it('reports ok for password accounts without checking a token', async () => {
    const svc = new TokenHealthService();
    const account = {
      name: 'p', email: 'p@x.com', username: 'p@x.com', password: 'pw', imap, smtp,
    } as AccountConfig;
    const result = await svc.checkAccount(account);
    expect(result.ok).toBe(true);
    expect(result.detail?.auth).toBe('password');
  });

  it('reports ok when the refresh succeeds', async () => {
    vi.spyOn(OAuthService, 'refreshAccessToken').mockResolvedValue({
      accessToken: 'at', expiresIn: 3600,
    });
    const svc = new TokenHealthService();
    const result = await svc.checkAccount(oauthAccount());
    expect(result.ok).toBe(true);
    expect(result.detail?.expires_in_s).toBe(3600);
    vi.restoreAllMocks();
  });

  it('reports failure and logs loudly when the refresh token is dead', async () => {
    vi.spyOn(OAuthService, 'refreshAccessToken').mockRejectedValue(
      new Error('invalid_grant: Token has been expired or revoked'),
    );
    const svc = new TokenHealthService();
    const result = await svc.checkAccount(oauthAccount());
    expect(result.ok).toBe(false);
    expect(result.error).toContain('invalid_grant');
    expect(logError).toHaveBeenCalled();
    vi.restoreAllMocks();
  });
});
