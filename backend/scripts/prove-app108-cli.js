'use strict';

const assert = require('assert/strict');
const { displayNewGeneratedCredential } = require('../dist/cli/credentialDisplay.js');

const user = { id: '10000000-0000-4000-8000-000000000001', email: 'user@example.com', franchiseeId: '20000000-0000-4000-8000-000000000002', isActive: true, tokenVersion: 0 };
const displayed = [];
displayNewGeneratedCredential({ outcome: 'succeeded', reasonCode: 'APPLIED', user, generatedPassword: 'generated-only-once' }, (value) => displayed.push(value));
// Same-key replay has no generatedPassword; supplied credentials are absent by design.
displayNewGeneratedCredential({ outcome: 'succeeded', reasonCode: 'APPLIED', user }, (value) => displayed.push(value));
assert.deepEqual(displayed, ['generated-only-once']);
process.stdout.write('{"compiled_tty_generated_once_and_replay_silent":"passed"}\n');
