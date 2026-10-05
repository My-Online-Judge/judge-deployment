// E2 — judging capacity (spec §3.3): bench-sum submissions, alternating C++ / Python 3: WARMUP_S at the first rate
// (not measured, spec §3.1), then ramping through STEPS (per second), each held STEP_S seconds. The measured step
// windows go to /out/schedule.json for the analysis.
import exec from 'k6/execution';
import { SUMMARY_TREND_STATS, SYSTEM_TAGS } from './lib/config.js';
import { loginAll, recordSubmit, submit } from './lib/api.js';
import { SUBMIT_PROBLEM, checkSubmitRate, languageForIteration, num, parseRates, publicSummary, stepStages, stepWindows, userIndexForIteration } from './lib/pure.js';

const RATES = parseRates(__ENV.STEPS);
RATES.forEach(checkSubmitRate);
const STEP_S = num(__ENV.STEP_S, 180);
const WARMUP_S = num(__ENV.WARMUP_S, 60);
const SOURCES = { cpp: open('/data/solutions/sum.cpp'), python3: open('/data/solutions/sum.py') };

export const options = {
  setupTimeout: '5m', summaryTrendStats: SUMMARY_TREND_STATS, systemTags: SYSTEM_TAGS,
  scenarios: {
    submit: { executor: 'ramping-arrival-rate', startRate: 0, timeUnit: '1m', preAllocatedVUs: 20, maxVUs: 100, stages: stepStages(RATES, STEP_S, WARMUP_S) },
  },
  thresholds: { 'http_req_duration{route:submit}': [], 'http_req_failed{route:submit}': [] },
};

export function setup() {
  const users = loginAll();
  const startMs = Date.now();
  console.log(JSON.stringify({ ev: 'setup-done', t: startMs }));
  return { users, startMs };
}

export default function (data) {
  const i = exec.scenario.iterationInTest;
  const lang = languageForIteration(i);
  recordSubmit(submit(data.users, userIndexForIteration(i), SUBMIT_PROBLEM, lang, SOURCES[lang]));
}

export function handleSummary(data) {
  return {
    '/out/summary.json': JSON.stringify(publicSummary(data)),
    '/out/schedule.json': JSON.stringify({ startMs: data.setup_data.startMs, stepS: STEP_S, warmupS: WARMUP_S, windows: stepWindows(RATES, STEP_S, WARMUP_S) }),
  };
}
