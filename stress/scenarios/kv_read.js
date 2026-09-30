/**
 * GET /api/v1/kv/:key — the cached read with no plugin layer.
 *
 * The other half of the subtraction hooks_rpc.js sets up: `stress_kv_read`
 * reads the same value through the plugin RPC, so the gap between that Trend
 * and this one is what the hook path costs on top of an ordinary cached read.
 * Against me.js it says something else again — both resolve a JWT and return a
 * cached row, so a large gap is the KV cache, not authentication.
 *
 * The value is asserted, not just the status: a cache that has been invalidated
 * into returning an empty body still answers 200 in 2ms.
 */

import { sleep } from 'k6';
import { Trend } from 'k6/metrics';
import { constantVus, summaryHandler, RUN_TAG, THINK } from '../lib/config.js';
import { deviceLogin } from '../lib/auth.js';
import { kvGet } from '../lib/api.js';
import { ensureSeed } from '../lib/hooks.js';
import { ok, bodyMatches } from '../lib/checks.js';

// A key of this scenario's own: hooks_rpc.js restamps `<tag>_bench_key` every
// iteration, and a read benchmark should not be racing a writer for the cache.
const KEY = `${RUN_TAG}_kv_read_key`;

const tRead = new Trend('t_kv_read', true);

export const options = constantVus();
export const handleSummary = summaryHandler('kv_read');

export function setup() {
  const session = deviceLogin({ fresh: true, id: `${RUN_TAG}-setup-kv` });
  if (session) ensureSeed(session.token, KEY);
  return { key: KEY };
}

export default function (ctx) {
  const session = deviceLogin();
  if (!session) return;

  const res = kvGet(session.token, ctx.key);
  tRead.add(res.timings.duration);

  ok(res, 'kv read');
  // `stress_setup` writes `{"seeded": true}`, and the controller answers the
  // entry under `data` — so the stored value is the unwrapped body's `data`.
  bodyMatches(res, (e) => e.data && e.data.seeded === true, 'kv read returns the seeded value');

  sleep(THINK);
}
