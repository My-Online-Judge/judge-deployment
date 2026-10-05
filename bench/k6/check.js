// The no-lost-submission check (spec §5): lists every bench user's submissions with that user's own token;
// /out/found.json feeds `oj_analyze invariant`.
import http from 'k6/http';
import { BASE, loadUserIds } from './lib/config.js';
import { auth, body, loginAll } from './lib/api.js';
import { USERS, username } from './lib/pure.js';

const USER_IDS = loadUserIds();

export const options = { setupTimeout: '15m', scenarios: { check: { executor: 'shared-iterations', vus: 1, iterations: 1 } } };

export function setup() {
  const users = loginAll();
  const found = [];
  for (let i = 0; i < USERS; i++) {
    const id = USER_IDS[username(i)];
    for (let page = 0; ; page++) {
      const res = http.get(`${BASE}/api/v1/submissions/user/${id}?page=${page}&size=200`, auth(users[i].token, 'check'));
      const b = body(res);
      if (res.status !== 200 || !b) throw new Error(`listing ${username(i)} failed: HTTP ${res.status}`);
      for (const s of b.data || []) found.push({ id: s.id, status: s.status });
      if (!b.pagination || !b.pagination.hasNext) break;
    }
  }
  return { found };
}

export default function () {}

export function handleSummary(data) {
  return { '/out/found.json': JSON.stringify(data.setup_data) };
}
