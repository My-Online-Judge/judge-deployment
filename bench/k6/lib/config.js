// Where the bench talks to and who it is (k6 only: reads __ENV, opens files in the init context).
export const BASE = __ENV.BASE_URL || 'http://api-gateway:8000';
export const PROM = __ENV.PROM_URL || 'http://prometheus:9090';
export const ADMIN_USER = 'admin';
// The root admin a fresh identity-db seeds (identity V2 migration). The bench stack is throwaway.
export const ADMIN_PASSWORD = __ENV.BENCH_ADMIN_PASSWORD || 'Admin@12345';
export const USER_PASSWORD = 'BenchPass2026';                          // bench users only
export const USER_ROLE_ID = 'b461277c-a4cb-44a4-92db-9185a1bade5e';    // USER (identity V2 seed)
export const SUMMARY_TREND_STATS = ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)', 'count'];
// No 'url' tag: the history route carries a user id, and one series per user would flood Prometheus.
export const SYSTEM_TAGS = ['status', 'method', 'name', 'scenario', 'expected_response', 'error_code'];

// username → user id, written by seed.js. Call it at the top level of a script (init context).
export function loadUserIds() {
  return JSON.parse(open('/gen/users.json'));
}
