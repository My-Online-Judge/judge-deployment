// E1 — read latency at a fixed arrival rate (spec §3.2): WARMUP_S warm-up, then MEASURE_S measured, through the
// gateway. Each VU reads as its own bench user (so a re-login after 12 minutes costs one login per VU).
import exec from 'k6/execution';
import { SUMMARY_TREND_STATS, SYSTEM_TAGS, loadUserIds } from './lib/config.js';
import { loginAll, read } from './lib/api.js';
import { READ_ROUTES, USERS, measureThresholds, num, publicSummary, readRouteForIteration } from './lib/pure.js';

const RATE = num(__ENV.RATE, 20);
const WARMUP_S = num(__ENV.WARMUP_S, 60);
const MEASURE_S = num(__ENV.MEASURE_S, 180);
const USER_IDS = loadUserIds();
const reads = (phase, startS, durationS) => ({
  executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', startTime: `${startS}s`, duration: `${durationS}s`,
  preAllocatedVUs: 50, maxVUs: 200, tags: { phase },
});

export const options = {
  setupTimeout: '5m', summaryTrendStats: SUMMARY_TREND_STATS, systemTags: SYSTEM_TAGS,
  scenarios: { warmup: reads('warmup', 0, WARMUP_S), measure: reads('measure', WARMUP_S, MEASURE_S) },
  thresholds: measureThresholds(READ_ROUTES),
};

export function setup() {
  const users = loginAll();
  console.log(JSON.stringify({ ev: 'setup-done', t: Date.now() }));
  return { users };
}

export default function (data) {
  read(data.users, (exec.vu.idInTest - 1) % USERS, USER_IDS, readRouteForIteration(exec.scenario.iterationInTest));
}

export function handleSummary(data) {
  return { '/out/summary.json': JSON.stringify(publicSummary(data)) };
}
