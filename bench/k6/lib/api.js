// HTTP helpers of the bench scripts (k6). Every request carries a `route` tag (and name = route, so no per-URL
// series) and a 10 s timeout: a request that hangs during a fault ends as a status-0 error, not a stuck VU.
import http from 'k6/http';
import { BASE, USER_PASSWORD } from './config.js';
import { USERS, accessTokenFrom, makeTokenCache, username } from './pure.js';

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

// Login sets the token as an HttpOnly cookie; it is read off the response and sent as a Bearer header (which the
// services and the gateway check first). A throwaway jar keeps the cookie out of the VU's own jar.
function loginParams() {
  return Object.assign(params('login', null, '30s'), { jar: new http.CookieJar() });
}

function tokenOf(res, user) {
  const token = res.status === 200 ? accessTokenFrom(res.cookies) : null;
  if (!token) throw new Error(`login ${user} failed: HTTP ${res.status}${res.status === 200 ? ' without an accessToken cookie' : ''}`);
  return token;
}

export function login(user, password) {
  return tokenOf(http.post(`${BASE}/api/v1/auth/login`, JSON.stringify({ username: user, password }), loginParams()), user);
}

// Logs every bench user in, 20 at a time: [{ username, token, mintedAt }] indexed like username(i).
export function loginAll() {
  const users = [];
  for (let start = 0; start < USERS; start += 20) {
    const names = [];
    for (let i = start; i < Math.min(start + 20, USERS); i++) names.push(username(i));
    const responses = http.batch(names.map((u) => ['POST', `${BASE}/api/v1/auth/login`,
      JSON.stringify({ username: u, password: USER_PASSWORD }), loginParams()]));
    responses.forEach((res, k) => {
      users.push({ username: names[k], token: tokenOf(res, names[k]), mintedAt: Date.now() });
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

// E3/E4: one line per request — exact times for the fault timings, and durations for client latency over time
// (k6's remote-written trend stats are cumulative since the start of the run).
export function recordRequest(route, res) {
  console.log(JSON.stringify({ ev: 'req', route, status: res.status, t: Date.now(), ms: Math.round(res.timings.duration * 10) / 10 }));
}
