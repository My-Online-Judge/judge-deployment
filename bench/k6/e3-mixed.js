// E3 — sustained mixed load (spec §3.4): reads at READ_RATE with E1's route mix plus bench-sum submissions at
// SUBMIT_RATE (half the 1-worker capacity from E2), WARMUP_S then MEASURE_S (15 minutes).
import exec from 'k6/execution';
import { SUMMARY_TREND_STATS, SYSTEM_TAGS, loadUserIds } from './lib/config.js';
import { loginAll, read, recordSubmit, submit } from './lib/api.js';
import { READ_ROUTES, SUBMIT_PROBLEM, USERS, checkSubmitRate, languageForIteration, measureThresholds, num, perMinute, readRouteForIteration, submitUserIndex } from './lib/pure.js';

const READ_RATE = num(__ENV.READ_RATE, 20);
const SUBMIT_RATE = checkSubmitRate(num(__ENV.SUBMIT_RATE, 0));
if (SUBMIT_RATE <= 0) throw new Error('SUBMIT_RATE is required (half the 1-worker capacity measured by E2)');
const WARMUP_S = num(__ENV.WARMUP_S, 60);
const MEASURE_S = num(__ENV.MEASURE_S, 900);
const USER_IDS = loadUserIds();
const SOURCES = { cpp: open('/data/solutions/sum.cpp'), python3: open('/data/solutions/sum.py') };
const WARMUP_SUBMITS = Math.round((perMinute(SUBMIT_RATE) * WARMUP_S) / 60);

const reads = (phase, startS, durationS) => ({
  executor: 'constant-arrival-rate', exec: 'readOne', rate: READ_RATE, timeUnit: '1s', startTime: `${startS}s`,
  duration: `${durationS}s`, preAllocatedVUs: 20, maxVUs: 100, tags: { phase },
});
// The measured submits continue the warm-up's round-robin (USER_OFFSET): no user is reused inside its cooldown.
const submits = (phase, startS, durationS, offset) => ({
  executor: 'constant-arrival-rate', exec: 'submitOne', rate: perMinute(SUBMIT_RATE), timeUnit: '1m', startTime: `${startS}s`,
  duration: `${durationS}s`, preAllocatedVUs: 10, maxVUs: 50, tags: { phase }, env: { USER_OFFSET: String(offset) },
});

export const options = {
  setupTimeout: '5m', summaryTrendStats: SUMMARY_TREND_STATS, systemTags: SYSTEM_TAGS,
  scenarios: {
    reads_warmup: reads('warmup', 0, WARMUP_S),
    reads: reads('measure', WARMUP_S, MEASURE_S),
    submits_warmup: submits('warmup', 0, WARMUP_S, 0),
    submits: submits('measure', WARMUP_S, MEASURE_S, WARMUP_SUBMITS),
  },
  thresholds: measureThresholds(READ_ROUTES.concat(['submit'])),
};

export function setup() {
  const users = loginAll();
  console.log(JSON.stringify({ ev: 'setup-done', t: Date.now() }));
  return { users };
}

export function readOne(data) {
  read(data.users, (exec.vu.idInTest - 1) % USERS, USER_IDS, readRouteForIteration(exec.scenario.iterationInTest));
}

export function submitOne(data) {
  const i = exec.scenario.iterationInTest;
  const lang = languageForIteration(i);
  recordSubmit(submit(data.users, submitUserIndex(i, num(__ENV.USER_OFFSET, 0)), SUBMIT_PROBLEM, lang, SOURCES[lang]));
}

export function handleSummary(data) {
  return { '/out/summary.json': JSON.stringify(data) };
}
