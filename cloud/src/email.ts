import type { Env } from './types';
import { assert } from './http';

/** Uses Cloudflare's structured Email Sending binding; never accepts arbitrary content. */
export async function sendLoginEmail(env: Env, email: string, code: string): Promise<void> {
  assert(env.EMAIL && env.EMAIL_FROM, 503, 'auth_not_configured', 'Email sign-in is not configured on this server.');
  await env.EMAIL.send({
    to: email,
    from: { email: env.EMAIL_FROM, name: 'Scriv' },
    subject: 'Your Scriv sign-in code',
    text: `Your Scriv sign-in code is ${code}.\n\nEnter it in the Scriv window where you requested it. This code expires in 10 minutes and can only be used once. Never share this code. If you did not request it, ignore this email.`,
    html: `<p>Your Scriv sign-in code is:</p><p style="font-size:28px;font-weight:bold;letter-spacing:6px">${code}</p><p>Enter it in the Scriv window where you requested it. This code expires in 10 minutes and can only be used once.</p><p>Never share this code. If you did not request it, ignore this email.</p>`
  });
}
