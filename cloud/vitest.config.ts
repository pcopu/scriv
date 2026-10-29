import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';
export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: './wrangler.jsonc' },
    miniflare: { bindings: { ENVIRONMENT: 'test', PUBLIC_URL: 'https://scriv.test', STRIPE_SECRET_KEY: 'sk_test_scriv', STRIPE_WEBHOOK_SECRET: 'whsec_test', STRIPE_TEAM_PRICE_ID: 'price_scriv_team' } }
  })],
  test: { include: ['tests/**/*.test.ts'], testTimeout: 20000, hookTimeout: 30000, fileParallelism: false }
});
