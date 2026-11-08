import { HealthStatus } from './status.js';

describe('HealthStatus', () => {
  it('is not ready before any full check', () => {
    const s = new HealthStatus();
    expect(s.isReady(300_000)).toBe(false);
  });

  it('is ready after a successful full check within the freshness window', () => {
    const s = new HealthStatus();
    s.record({ kind: 'full', at: new Date().toISOString(), ok: true, accounts: [] });
    expect(s.isReady(300_000)).toBe(true);
  });

  it('is not ready when the last full check failed', () => {
    const s = new HealthStatus();
    s.record({ kind: 'full', at: new Date().toISOString(), ok: false, accounts: [] });
    expect(s.isReady(300_000)).toBe(false);
  });

  it('is not ready when the full check is stale', () => {
    const s = new HealthStatus();
    const stale = new Date(Date.now() - 400_000).toISOString();
    s.record({ kind: 'full', at: stale, ok: true, accounts: [] });
    expect(s.isReady(300_000)).toBe(false);
  });

  it('exposes a public summary without error stacks', () => {
    const s = new HealthStatus();
    s.record({
      kind: 'token',
      at: new Date().toISOString(),
      ok: false,
      accounts: [{ account: 'a', email: 'a@b.c', ok: false, error: 'boom' }],
    });
    const pub = s.toPublic() as {
      token: { accounts: Array<{ account: string; ok: boolean; error?: string }> };
    };
    expect(pub.token.accounts[0]?.error).toBe('boom');
  });
});
