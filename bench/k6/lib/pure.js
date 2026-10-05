// Pure helpers of the bench k6 scripts (sub-project 5). No k6 import, so `node --test` runs them (pure.test.js).
export const USERS = 200;
export const COOLDOWN_S = 10;                     // SUBMISSION_COOLDOWN_SECONDS, unchanged for the bench
export const RELOGIN_AFTER_MS = 12 * 60 * 1000;   // access tokens live 15 minutes (spec §4.4)
export const RAMP_S = 5;                          // E2: seconds between two steps
export const READ_ROUTES = ['problem_list', 'problem_detail', 'history'];
export const SUBMIT_PROBLEM = 'bench-sum';

export function username(i) {
  if (!Number.isInteger(i) || i < 0 || i >= USERS) throw new Error(`user index out of range: ${i}`);
  return `bench_u${String(i + 1).padStart(3, '0')}`;
}

// Round-robin: at r arrivals/s each user submits every USERS / r seconds.
export function userIndexForIteration(iteration, users = USERS) {
  return iteration % users;
}

// A scenario that follows another (E3's measure after its warm-up) continues the rotation instead of restarting it.
export function submitUserIndex(iteration, offset) {
  return userIndexForIteration(iteration + offset);
}

export function maxSubmitRate(users = USERS, cooldownS = COOLDOWN_S) {
  return Math.floor((users / cooldownS) * 0.9 * 10) / 10;
}

export function checkSubmitRate(rate) {
  if (rate > maxSubmitRate()) {
    throw new Error(`submit rate ${rate}/s is above ${maxSubmitRate()}/s: ${USERS} users with a ${COOLDOWN_S} s cooldown would hit 429`);
  }
  return rate;
}

export function needsRelogin(mintedAtMs, nowMs) {
  return nowMs - mintedAtMs >= RELOGIN_AFTER_MS;
}

// Per-VU tokens over the setup() tokens: an old token is replaced once before use; relogin() replaces it on demand
// (after a 401). loginFn(username) → token; nowFn() → ms.
export function makeTokenCache(loginFn, nowFn) {
  const fresh = {};
  function relogin(users, i) {
    fresh[i] = { token: loginFn(users[i].username), mintedAt: nowFn() };
    return fresh[i].token;
  }
  function token(users, i) {
    const t = fresh[i] || users[i];
    return needsRelogin(t.mintedAt, nowFn()) ? relogin(users, i) : t.token;
  }
  return { token, relogin };
}

export function languageForIteration(iteration) {
  return iteration % 2 === 0 ? 'cpp' : 'python3';
}

export function readRouteForIteration(iteration) {
  return READ_ROUTES[iteration % READ_ROUTES.length];
}

export function perMinute(ratePerSecond) {
  return Math.round(ratePerSecond * 60);
}

export function num(value, fallback) {
  if (value === undefined || value === '') return fallback;
  const n = Number(value);
  if (!Number.isFinite(n) || n < 0) throw new Error(`not a non-negative number: ${value}`);
  return n;
}

export function parseRates(text) {
  const rates = String(text || '').split(',').map((s) => s.trim()).filter((s) => s !== '').map(Number);
  if (rates.length === 0 || rates.some((r) => !Number.isFinite(r) || r <= 0)) throw new Error(`bad rate list: '${text}'`);
  return rates;
}

// warmupS > 0 holds the first rate that long first (spec §3.1: the first minute is not measured).
export function stepStages(rates, stepS, warmupS = 0) {
  const stages = [];
  if (warmupS > 0) {
    stages.push({ target: perMinute(rates[0]), duration: `${RAMP_S}s` });
    stages.push({ target: perMinute(rates[0]), duration: `${warmupS}s` });
  }
  for (const r of rates) {
    stages.push({ target: perMinute(r), duration: `${RAMP_S}s` });
    stages.push({ target: perMinute(r), duration: `${stepS}s` });
  }
  return stages;
}

export function stepWindows(rates, stepS, warmupS = 0) {
  const offset = warmupS > 0 ? RAMP_S + warmupS : 0;
  return rates.map((rate, k) => {
    const startS = offset + RAMP_S + k * (stepS + RAMP_S);
    return { rate, startS, endS: startS + stepS };
  });
}

export function faultTimeline(steadyS = 120, faultS = 60, recoverS = 180) {
  return { steadyS, faultS, recoverS, totalS: steadyS + faultS + recoverS };
}

export function isTerminal(status) {
  return status !== 6 && status !== 7;
}

export function measureThresholds(routes, phase = 'measure') {
  const t = {};
  for (const r of routes) {
    t[`http_req_duration{phase:${phase},route:${r}}`] = [];
    t[`http_req_failed{phase:${phase},route:${r}}`] = [];
  }
  return t;
}
