// E4 background load (spec §3.5): reads at READ_RATE and bench-sum submissions at SUBMIT_RATE for
// STEADY_S + FAULT_S + RECOVER_S. Every request is logged ({ev:'req'}), so the fault timings use exact times.
import exec from 'k6/execution';
import { SUMMARY_TREND_STATS, SYSTEM_TAGS, loadUserIds } from './lib/config.js';
import { loginAll, read, recordRequest, recordSubmit, submit } from './lib/api.js';
import { SUBMIT_PROBLEM, USERS, checkSubmitRate, faultTimeline, languageForIteration, num, perMinute, publicSummary, readRouteForIteration, userIndexForIteration } from './lib/pure.js';

const READ_RATE = num(__ENV.READ_RATE, 10);
const SUBMIT_RATE = checkSubmitRate(num(__ENV.SUBMIT_RATE, 0));
if (SUBMIT_RATE <= 0) throw new Error('SUBMIT_RATE is required (half the 1-worker capacity measured by E2)');
const T = faultTimeline(num(__ENV.STEADY_S, 120), num(__ENV.FAULT_S, 60), num(__ENV.RECOVER_S, 180));
const USER_IDS = loadUserIds();
const SOURCES = { cpp: open('/data/solutions/sum.cpp'), python3: open('/data/solutions/sum.py') };

export const options = {
  setupTimeout: '5m', summaryTrendStats: SUMMARY_TREND_STATS, systemTags: SYSTEM_TAGS,
  scenarios: {
    reads: { executor: 'constant-arrival-rate', exec: 'readOne', rate: READ_RATE, timeUnit: '1s', duration: `${T.totalS}s`, preAllocatedVUs: 20, maxVUs: 150 },
    submits: { executor: 'constant-arrival-rate', exec: 'submitOne', rate: perMinute(SUBMIT_RATE), timeUnit: '1m', duration: `${T.totalS}s`, preAllocatedVUs: 10, maxVUs: 100 },
  },
};

export function setup() {
  const users = loginAll();
  console.log(JSON.stringify({ ev: 'setup-done', t: Date.now() }));
  return { users };
}

export function readOne(data) {
  const route = readRouteForIteration(exec.scenario.iterationInTest);
  recordRequest(route, read(data.users, (exec.vu.idInTest - 1) % USERS, USER_IDS, route));
}

export function submitOne(data) {
  const i = exec.scenario.iterationInTest;
  const lang = languageForIteration(i);
  const res = submit(data.users, userIndexForIteration(i), SUBMIT_PROBLEM, lang, SOURCES[lang]);
  recordRequest('submit', res);
  recordSubmit(res);
}

export function handleSummary(data) {
  return { '/out/summary.json': JSON.stringify(publicSummary(data)) };
}
