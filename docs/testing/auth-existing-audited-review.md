# Existing authentication and team assertion review

This November 13, 2026 author review adds a separate proposed catalog for the
existing email-auth, OAuth and team-lifecycle CLI journeys. It changes no test,
production source, fixture or global mapping. The production and migration
sources remain at `9d4f717`; the catalog pins exact source and assertion ranges.
The relationships still require the integration owner's review before promotion.

The catalog retains the three existing ordered workflows and their preceding
fixtures. Its 19 narrow associations select 52 currently unlinked included lines:

| Source | Included lines selected | Assertion contract |
| --- | ---: | --- |
| `cloud/src/email-auth.ts` | 5 | Exact expiry/resend constants, five-attempt ceiling, error text and six-digit returned-code format |
| `cloud/migrations/0001_identity_teams.sql` | 34 | Publicly produced user/session/OAuth fields, team/member/invite fields and project ownership/archive fields |
| `cloud/migrations/0003_email_auth.sql` | 13 | Exact verified-identity and challenge fields; same-email/same-proof upsert replacement |

The pre-integration report has 4,565 witnessed linked lines of 30,831 included
lines. If all 52 distinct additions pass independent review and are integrated,
the numerator would become 4,617 with the same denominator. These are manual
source-to-assertion associations, not measured execution. The separate proposal
contains only this increment and does not replace the whole-project proposal.

The already completed baseline logs report 40 email-auth HTTP requests, 40 OAuth
HTTP requests and 80 team-lifecycle HTTP requests passing. Email and team runs had
zero outbound attempts. OAuth used 14 exactly allowed local simulated provider
calls with zero denied calls. All reported zero native scenarios. No execution
was repeated for this catalog-only change. Catalog/proposal integrity, packet
generation, current mapping comparison and whitespace checks passed.

The schema associations are deliberately field-specific. Exact read-only D1
observations follow real HTTP issuance, verification, callback, exchange,
revocation and archive operations. The seeded unrelated user/session and the
synthetic entitlement changes provide context; they earn no write-behavior
credit. Composite conflict keys are associated only where the real production
`ON CONFLICT` path and duplicate membership or challenge replacement are observed.

The following gaps remain explicit:

- `randomEmailCode` allocation and rejection-sampling loop are not linked by this
  catalog. Six-digit output does not establish entropy, distribution, a sampled
  leading-zero case or the rare retry branch.
- OAuth and email rate-limit caps are not asserted by these workflows. A resend
  cooldown failure is not evidence of an address, IP or global quota rejection.
- A nonmanager team rename fails at the outer role guard, before the SQL manager
  predicate. Successful admin rename does not establish mutation-time authority
  rechecking under a race, so that predicate remains unlinked here.
- Persisted column checks do not establish every colocated SQL constraint.
  Invalid raw inserts, foreign-key cascades, arbitrary uniqueness collisions,
  nullability and out-of-range CHECK rejection, indexes and query performance
  remain unclaimed. In particular, the sixth verification refusal is the
  application attempt guard, not a database CHECK failure.
- The public invitation HTML route, alternative configuration values, native
  sign-in, real email/GitHub delivery and controlled internal transaction overlap
  are outside these associations. Fixture entitlement projections are not
  billing transitions or successful document writes.
