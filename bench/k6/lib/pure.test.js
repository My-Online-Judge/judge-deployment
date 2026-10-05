import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as p from './pure.js';

test('bench users are bench_u001..bench_u200 (identity allows only [a-zA-Z0-9_])', () => {
  assert.equal(p.username(0), 'bench_u001');
  assert.equal(p.username(199), 'bench_u200');
  assert.throws(() => p.username(200));
  assert.match(p.username(57), /^[a-zA-Z0-9_]{3,32}$/);
});

test('submits go round-robin over the users, and a later scenario can continue the rotation', () => {
  assert.equal(p.userIndexForIteration(0), 0);
  assert.equal(p.userIndexForIteration(201), 1);
  assert.equal(p.submitUserIndex(5, 198), 3);
});

test('the highest submit rate keeps every user outside the 10 s cooldown, with a margin', () => {
  assert.equal(p.maxSubmitRate(), 18);
  assert.ok(p.USERS / p.maxSubmitRate() > p.COOLDOWN_S);
  assert.equal(p.checkSubmitRate(18), 18);
  assert.throws(() => p.checkSubmitRate(18.1), /above 18/);
});

test('a token is re-minted from 12 minutes on (they live 15)', () => {
  assert.equal(p.needsRelogin(0, 12 * 60 * 1000 - 1), false);
  assert.equal(p.needsRelogin(0, 12 * 60 * 1000), true);
});

test('the token cache keeps setup tokens, re-mints old ones once, and re-mints on demand after a 401', () => {
  let now = 0;
  const logins = [];
  const cache = p.makeTokenCache((u) => { logins.push(u); return `${u}-new${logins.length}`; }, () => now);
  const users = [{ username: 'bench_u001', token: 'setup-token', mintedAt: 0 }];
  assert.equal(cache.token(users, 0), 'setup-token');
  now = 12 * 60 * 1000;
  assert.equal(cache.token(users, 0), 'bench_u001-new1');
  assert.equal(cache.token(users, 0), 'bench_u001-new1');   // cached, no second login
  assert.equal(cache.relogin(users, 0), 'bench_u001-new2');  // the 401 path
  assert.deepEqual(logins, ['bench_u001', 'bench_u001']);
});

test('E2 alternates C++ and Python 3; reads cycle through the three routes', () => {
  assert.deepEqual([0, 1, 2, 3].map(p.languageForIteration), ['cpp', 'python3', 'cpp', 'python3']);
  assert.deepEqual([0, 1, 2, 3].map(p.readRouteForIteration), ['problem_list', 'problem_detail', 'history', 'problem_list']);
});

test('rates are given per second and run per minute (k6 rates are integers)', () => {
  assert.equal(p.perMinute(0.5), 30);
  assert.equal(p.perMinute(18), 1080);
});

test('env numbers fall back when unset and refuse garbage', () => {
  assert.equal(p.num(undefined, 5), 5);
  assert.equal(p.num('', 5), 5);
  assert.equal(p.num('7.5', 5), 7.5);
  assert.throws(() => p.num('x', 5));
  assert.throws(() => p.num('-1', 5));
});

test('a step list parses, and an empty or bad one is refused', () => {
  assert.deepEqual(p.parseRates('0.5, 1,2'), [0.5, 1, 2]);
  assert.throws(() => p.parseRates(''));
  assert.throws(() => p.parseRates('1,x'));
  assert.throws(() => p.parseRates('1,0'));
});

test('E2 stages hold each rate stepS seconds after a 5 s ramp, and the windows say when', () => {
  assert.deepEqual(p.stepStages([0.5, 1], 180), [
    { target: 30, duration: '5s' }, { target: 30, duration: '180s' },
    { target: 60, duration: '5s' }, { target: 60, duration: '180s' },
  ]);
  assert.deepEqual(p.stepWindows([0.5, 1], 180), [
    { rate: 0.5, startS: 5, endS: 185 }, { rate: 1, startS: 190, endS: 370 },
  ]);
});

test('an E2 warm-up holds the first rate before the first measured window (spec §3.1)', () => {
  assert.deepEqual(p.stepStages([0.5], 180, 60), [
    { target: 30, duration: '5s' }, { target: 30, duration: '60s' },
    { target: 30, duration: '5s' }, { target: 30, duration: '180s' },
  ]);
  assert.deepEqual(p.stepWindows([0.5], 180, 60), [{ rate: 0.5, startS: 70, endS: 250 }]);
});

test('the E4 timeline is 120 s steady, 60 s fault, 180 s recovery by default', () => {
  assert.deepEqual(p.faultTimeline(), { steadyS: 120, faultS: 60, recoverS: 180, totalS: 360 });
  assert.equal(p.faultTimeline(20, 10, 20).totalS, 50);
});

test('PENDING (6) and JUDGING (7) are the only non-terminal statuses', () => {
  assert.equal(p.isTerminal(6), false);
  assert.equal(p.isTerminal(7), false);
  assert.equal(p.isTerminal(0), true);
  assert.equal(p.isTerminal(-2), true);
});

test('measure thresholds name a duration and a failure sub-metric per route', () => {
  assert.deepEqual(Object.keys(p.measureThresholds(['history'])),
    ['http_req_duration{phase:measure,route:history}', 'http_req_failed{phase:measure,route:history}']);
});

test('the access token comes from the accessToken cookie of the login response (the body carries none)', () => {
  assert.equal(p.accessTokenFrom({ accessToken: [{ name: 'accessToken', value: 'abc' }], refreshToken: [{ value: 'r' }] }), 'abc');
  assert.equal(p.accessTokenFrom({ refreshToken: [{ value: 'r' }] }), null);
  assert.equal(p.accessTokenFrom({ accessToken: [] }), null);
  assert.equal(p.accessTokenFrom(undefined), null);
});
