import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';
export default defineConfig(async () => ({
  plugins: [cloudflareTest({
    wrangler: { configPath: './wrangler.jsonc' },
    miniflare: { bindings: { TEST_MIGRATIONS: await readD1Migrations('./migrations'), RUN_LOAD_TEST: process.env.SCRIV_LOAD_TEST === '1', ENVIRONMENT: 'test', PUBLIC_URL: 'https://scriv.test', STRIPE_SECRET_KEY: 'sk_test_scriv', STRIPE_WEBHOOK_SECRET: 'whsec_test', STRIPE_TEAM_PRICE_ID: 'price_scriv_team' } }
  })],
  test: { include: ['tests/**/*.test.ts'], testTimeout: 20000, hookTimeout: 30000, fileParallelism: false }
}));
