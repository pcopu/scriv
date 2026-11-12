# Team entitlement grace and project visibility

Run `tracer app -- test services team-lifecycle` through the configured Scriv CLI.
The owned local Worker keeps all original 40 named callbacks, including 39 HTTP
requests and one synthetic entitlement fixture, unchanged. The appended chapter
adds 41 HTTP requests for 80 total, within the unchanged request cap.

The chapter rejoins two synthetic members through the real invitation route,
sets one viewer role, and creates a fresh team project through HTTP. Seven
fixture entitlement tuples vary only subscription_status, paid_until and
canceled_at: active/future, trialing/future, past_due/future, active/recent expiry,
recent cancellation with old payment, old cancellation with recent payment, and
old payment with no cancellation. Dates are safely one hour future, one day past
or 31 days past, without altering the real clock or waiting for expiry.

Each tuple drives owner/member/viewer project GETs and a member identity GET.
Premium metadata appears only for active/trialing with future payment. Grace
retains member/viewer reads with canWrite false; expired grace causes exact 402
and omits the project from member identity while retaining the team. Opposite
cancellation/payment dates distinguish canceled_at precedence over paid_until.
The owner retains existing-project visibility in all states. Returned canWrite
values are capability projections, not evidence that document writes occurred.

Fresh project-create requests from a member during recent expiry and from the
owner after old cancellation both fail 402 without business-state changes.
After grace, owner archive still works: only the new project archive/update
timestamps change, then owner listing and lookup omit/refuse it. Restoring the
three entitlement fixture fields and leaving both temporary memberships through
HTTP restores all original declared rows, retaining only the new archived
project. Original archived content is not overwritten or resurrected.

Read-only observations compare complete users, sessions, teams, team_members,
join_links and projects. Rate counters, other stores and notification transport
are excluded. All new memberships/projects and their removals/archiving use
public routes. Fixture entitlement input is not a provider/webhook test.

The original runtime report describes its 40 callbacks; a separate
team-entitlement-grace-evidence entry describes the 41 additional HTTP checks.
Semantic audit, manual mapping, service execution and native acceptance remain
separate. No production source, original team catalog/proposal, GitHub Actions
or native registry changes. No live provider/payment, actual content write,
export, socket delivery, exact time equality, forced race or native UI claim.
