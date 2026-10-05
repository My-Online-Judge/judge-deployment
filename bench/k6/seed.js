// Seeds a fresh oj-bench stack (spec §4.3) as the root admin: 200 users, the two bench problems, and one ACCEPTED
// reference submission per problem and language (C++, Python 3). HISTORY=1 adds two judged bench-ab submissions
// per user (E1's history route). Writes /gen/users.json (username → id) and /gen/seed-report.json.
import http from 'k6/http';
import { sleep } from 'k6';
import { ADMIN_PASSWORD, ADMIN_USER, BASE, PROM, USER_PASSWORD, USER_ROLE_ID } from './lib/config.js';
import { auth, body, login } from './lib/api.js';
import { COOLDOWN_S, USERS, isTerminal, username } from './lib/pure.js';

const PROBLEMS = JSON.parse(open('/data/problems.json'));
const ZIPS = { 'bench-ab': open('/gen/data/bench-ab.zip', 'b'), 'bench-sum': open('/gen/data/bench-sum.zip', 'b') };
const SOLUTIONS = {
  'bench-ab': { cpp: open('/data/solutions/ab.cpp'), python3: open('/data/solutions/ab.py') },
  'bench-sum': { cpp: open('/data/solutions/sum.cpp'), python3: open('/data/solutions/sum.py') },
};
const HISTORY = __ENV.HISTORY === '1';

export const options = { setupTimeout: '40m', scenarios: { seed: { executor: 'shared-iterations', vus: 1, iterations: 1 } } };

function must(res, what) {
  const b = body(res);
  if (res.status >= 200 && res.status < 300) return b;
  throw new Error(`${what}: HTTP ${res.status} ${b && b.message ? b.message : ''}`);
}

// Re-running the seed on a seeded stack is harmless: "already exists" counts as done.
function created(res, what) {
  const b = body(res);
  if (res.status >= 200 && res.status < 300) return;
  if (res.status === 400 && b && /exist/i.test(b.message || '')) return;
  must(res, what);
}

function submitAs(token, slug, lang) {
  const payload = JSON.stringify({ sourceCode: SOLUTIONS[slug][lang], languageIdentifier: lang, problemSlug: slug });
  return must(http.post(`${BASE}/api/v1/submissions`, payload, auth(token, 'seed')), `submit ${slug}/${lang}`).data.id;
}

function waitVerdict(token, id, timeoutS) {
  const deadline = Date.now() + timeoutS * 1000;
  while (Date.now() < deadline) {
    const b = body(http.get(`${BASE}/api/v1/submissions/${id}`, auth(token, 'seed')));
    if (b && b.data && isTerminal(b.data.status)) return b.data.status;
    sleep(2);
  }
  throw new Error(`submission ${id} was not judged within ${timeoutS} s`);
}

function waitQueueEmpty(timeoutS) {
  const deadline = Date.now() + timeoutS * 1000;
  while (Date.now() < deadline) {
    const b = body(http.get(`${PROM}/api/v1/query?query=${encodeURIComponent('max(oj_queue_depth)')}`));
    const r = b && b.data && b.data.result && b.data.result[0];
    if (r && Number(r.value[1]) === 0) return;
    sleep(5);
  }
  throw new Error(`the judge queue did not empty within ${timeoutS} s`);
}

export function setup() {
  const admin = login(ADMIN_USER, ADMIN_PASSWORD);
  for (let i = 0; i < USERS; i++) {
    const u = username(i);
    const user = { username: u, name: `Bench user ${i + 1}`, email: `${u}@bench.local`, password: USER_PASSWORD, status: 1, roleIds: [USER_ROLE_ID] };
    created(http.post(`${BASE}/api/v1/users`, JSON.stringify(user), auth(admin, 'seed')), `create ${u}`);
  }
  for (const p of PROBLEMS) {
    created(http.post(`${BASE}/api/v1/problems`, {
      data: http.file(JSON.stringify(p), 'data.json', 'application/json'),
      file: http.file(ZIPS[p.problemSlug], `${p.problemSlug}.zip`, 'application/zip'),
    }, { headers: { Authorization: `Bearer ${admin}` }, tags: { route: 'seed', name: 'seed' }, timeout: '60s' }), `create ${p.problemSlug}`);
  }
  const ids = {};
  const tokens = [];
  for (let i = 0; i < USERS; i++) {
    tokens.push(login(username(i), USER_PASSWORD));
    ids[username(i)] = must(http.get(`${BASE}/api/v1/auth/me`, auth(tokens[i], 'seed')), `me ${username(i)}`).data.id;
  }
  // One reference submission per problem and language, each by a different user (the cooldown is per user).
  const verdicts = {};
  let k = 0;
  for (const slug of ['bench-ab', 'bench-sum']) {
    for (const lang of ['cpp', 'python3']) {
      verdicts[`${slug}/${lang}`] = waitVerdict(tokens[k], submitAs(tokens[k], slug, lang), 300);
      k += 1;
    }
  }
  const wrong = Object.keys(verdicts).filter((key) => verdicts[key] !== 0);
  if (wrong.length) throw new Error(`reference solutions not ACCEPTED: ${wrong.map((key) => `${key}=${verdicts[key]}`).join(', ')}`);
  if (HISTORY) {
    sleep(COOLDOWN_S + 1);
    for (let pass = 0; pass < 2; pass++) {
      const t0 = Date.now();
      for (let i = 0; i < USERS; i++) submitAs(tokens[i], 'bench-ab', 'python3');
      if (pass === 0) sleep(Math.max(0, COOLDOWN_S + 1 - (Date.now() - t0) / 1000));
    }
    waitQueueEmpty(1800);
  }
  return { ids, verdicts, history: HISTORY };
}

export default function () {}

export function handleSummary(data) {
  const s = data.setup_data;
  return {
    '/gen/users.json': JSON.stringify(s.ids, null, 1),
    '/gen/seed-report.json': JSON.stringify({ verdicts: s.verdicts, history: s.history }, null, 1),
  };
}
