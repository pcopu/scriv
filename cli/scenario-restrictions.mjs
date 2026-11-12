// Known native route restrictions are enforced before scenario/app launch.
// Removing one requires new authorized evidence, not a test-only bypass flag.
export const scenarioRestrictions = Object.freeze({
  'character-aliases': Object.freeze({
    status: 'blocked',
    reason: 'native-alert-route-library-validation-blocked',
    detail: 'Alias Add/Cancel has no verified UIKit action route. The AppKit fallback was denied by Library Validation and must not be retried.',
  }),
});
