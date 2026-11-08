import SelfTestService from '../health/self-test.js';
import { buildTestAccount, createTestServices } from './helpers/index.js';

describe('self-test canary (integration)', () => {
  it('sends account-to-self and confirms arrival end-to-end', async () => {
    const account = buildTestAccount();
    const svc = createTestServices(account);
    try {
      const canary = new SelfTestService(svc.connections, svc.imapService, svc.smtpService, {
        arrivalTimeoutMs: 30_000,
        arrivalPollMs: 2_000,
      });
      const report = await canary.runAll([account]);
      expect(report.ok).toBe(true);
      expect(report.accounts[0]?.ok).toBe(true);
    } finally {
      await svc.connections.closeAll();
    }
  });
});
