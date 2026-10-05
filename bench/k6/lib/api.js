// HTTP helpers of the bench scripts (k6). Every request carries a `route` tag (and name = route, so no per-URL
// series) and a 10 s timeout: a request that hangs during a fault ends as a status-0 error, not a stuck VU.
import http from 'k6/http';
import { BASE, USER_PASSWORD } from './config.js';
import { USERS, makeTokenCache, username } from './pure.js';

const JSON_HEADERS = { 'Content-Type': 'application/json' };

export function params(route, token, timeout = '10s') {
  const headers = token ? Object.assign({ Authorization: `Bearer ${token}` }, JSON_HEADERS) : JSON_HEADERS;
  return { headers, tags: { route, name: route }, timeout };
}

export function auth(token, route) {
  return params(route, token);
}

export function body(res) {
  try { return res.json(); } catch (e) { return null; }
}

export function login(user, password) {
  const res = http.post(`${BASE}/api/v1/auth/login`, JSON.stringify({ username: user, password }), params('login', null, '30s'));
  const b = body(res);
  if (res.status !== 200 || !b || !b.data || !b.data.accessToken) throw new Error(`login ${user} failed: HTTP ${res.status}`);
  return b.data.accessToken;
}

// Logs every bench user in, 20 at a time: [{ username, token, mintedAt }] indexed like username(i).
export function loginAll() {
  const users = [];
  for (let start = 0; start < USERS; start += 20) {
    const names = [];
    for (let i = start; i < Math.min(start + 20, USERS); i++) names.push(username(i));
    const responses = http.batch(names.map((u) => ['POST', `${BASE}/api/v1/auth/login`,
      JSON.stringify({ username: u, password: USER_PASSWORD }), params('login', null, '30s')]));
    responses.forEach((res, k) => {
      const b = body(res);
      if (res.status !== 200 || !b || !b.data || !b.data.accessToken) throw new Error(`login ${names[k]} failed: HTTP ${res.status}`);
      users.push({ username: names[k], token: b.data.accessToken, mintedAt: Date.now() });
    });
  }
  return users;
}

const tokens = makeTokenCache((user) => login(user, USER_PASSWORD), () => Date.now());

// Calls call(token) as user i; a 401 re-mints that user's token once and retries.
export function authed(users, i, call) {
  const res = call(tokens.token(users, i));
  return res.status === 401 ? call(tokens.relogin(users, i)) : res;
}

export function read(users, i, userIds, route) {
  const urls = {
    problem_list: `${BASE}/api/v1/problems?page=0&size=10`,
    problem_detail: `${BASE}/api/v1/problems/bench-ab`,
    history: `${BASE}/api/v1/submissions/user/${userIds[users[i].username]}?page=0&size=10`,
  };
  return authed(users, i, (t) => http.get(urls[route], auth(t, route)));
}

export function submit(users, i, slug, lang, source) {
  const payload = JSON.stringify({ sourceCode: source, languageIdentifier: lang, problemSlug: slug });
  return authed(users, i, (t) => http.post(`${BASE}/api/v1/submissions`, payload, auth(t, 'submit')));
}

// Accepted = HTTP 200 with a submission id (the controller answers 200, not 201). The id feeds the invariant check.
export function recordSubmit(res) {
  const b = body(res);
  if (res.status === 200 && b && b.data && b.data.id) {
    console.log(JSON.stringify({ ev: 'accepted', id: b.data.id, t: Date.now() }));
    return true;
  }
  console.log(JSON.stringify({ ev: 'rejected', status: res.status, t: Date.now() }));
  return false;
}

// E4: one line per request, so the fault timings come from exact request times.
export function recordRequest(route, res) {
  console.log(JSON.stringify({ ev: 'req', route, status: res.status, t: Date.now() }));
}
