import { runScriptJourney } from './support/script-authoring-steps.mjs';
import { runIdentityReview } from './support/text-identity-review-steps.mjs';
import { identityReviewCatalog } from './support/text-identity-review-fixtures.mjs';

await runScriptJourney({ journey: 'AUT-J06', workflows: { 'review-and-edit': runIdentityReview },
  cases: identityReviewCatalog,
  companions: ['Confirm/Cancel repeated with full before/after equality',
    'exact-word occurrence Keep unlinked then no-match wording and Cancel',
    'native selected emoji-prefix deletion preserves the confirmed link',
    'saved explicit unlink survives suffix edit without reproposal (partial only, not frozen correction case)', 'full native browser reopen'],
  excluded: ['in-memory draft observation while review sheet is open', 'character picker menus/correction',
    'fully reviewed row reopening through a menu', 'duplicate-name deletion and no-edit fallback',
    'bootstrap/rename/alias-removal/name-reuse', 'CloudCodec/local codec equivalence',
    'lease denial/stale-account transitions', 'pagination', 'rendered foreground/background visual parity',
    'legacy test retirement; all native evidence pending'],
});
