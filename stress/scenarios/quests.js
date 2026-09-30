/**
 * The quest loop: report an event, read the quest list, claim the reward.
 *
 * Quest progress is server-owned -- no player-facing endpoint advances it -- so
 * the event arrives through `stress_hook`, exactly as a real game server would
 * send it. The three steps are timed apart because they cost wildly different
 * things: the event is an advisory lock around a read-modify-write of one
 * progress row, the list is a cached read of every visible quest, and the claim
 * is the heaviest path in the feature -- a second locked read-modify-write plus
 * a reward grant that writes the wallet and the ledger inside the same
 * transaction. `t_quest_claim` is where a quest regression shows up first.
 *
 * A fresh device user per iteration rather than this VU's cached session, which
 * is what every other scenario uses. Completing a quest sets a
 * per-(user, quest, period) "done" marker in the cache with a one-hour TTL, and
 * a `reset: "repeat"` quest re-arms its row on claim without dropping that
 * marker -- `period_key` for a repeat quest is the constant `"static"`, so the
 * marker never rolls over either. A reused player therefore claims exactly once
 * and then reports events that advance nothing for an hour, which would leave
 * this scenario timing a 403 `not_completed` and calling it a claim.
 *
 * That hour is also why the user has to be new to the *run*, not just to the
 * iteration: device ids are derived from RUN_TAG, VU and iteration, so a second
 * run with the same tag logs in as players who already claimed and are still
 * inside their marker's TTL. Hence the per-run nonce from `setup()`.
 *
 * Paying for a user per iteration also means this scenario is the first to see
 * the SQLite "database busy" 500 that `Gamend.Analytics.insert_day/2` raises
 * out of the login path under concurrent registration, so read a red run here
 * against `POST /login/device` before suspecting quests.
 */

import { sleep } from 'k6';
import { Trend } from 'k6/metrics';
import { constantVus, summaryHandler, RUN_TAG, THINK } from '../lib/config.js';
import { deviceLogin } from '../lib/auth.js';
import { myQuests, claimQuest } from '../lib/api.js';
import { callHook } from '../lib/hooks.js';
import { ok, bodyMatches } from '../lib/checks.js';

const QUEST = 'stress_play';

const tEvent = new Trend('t_quest_event', true);
const tList = new Trend('t_quest_list', true);
const tClaim = new Trend('t_quest_claim', true);

export const options = constantVus();
export const handleSummary = summaryHandler('quests');

export function setup() {
  return { run: Date.now().toString(36) };
}

export default function (ctx) {
  const session = deviceLogin({ fresh: true, id: `${RUN_TAG}-q${ctx.run}-${__VU}-${__ITER}` });
  if (!session) return;

  const event = callHook(session.token, 'stress_quest_event', [1], 'hook stress_quest_event');
  tEvent.add(event.timings.duration);
  if (!ok(event, 'quest event')) return;

  // `advanced` is the only thing that separates a quest engine that ran from
  // one that matched no objective and returned 200 anyway.
  bodyMatches(event, (d) => d.advanced > 0, 'event advances a quest');

  const list = myQuests(session.token);
  tList.add(list.timings.duration);
  ok(list, 'quests list');
  bodyMatches(
    list,
    (qs) => qs.some((q) => q.key === QUEST && q.progress && q.claimable),
    'stress quest is listed as claimable',
  );

  const claimed = claimQuest(session.token, QUEST);
  tClaim.add(claimed.timings.duration);
  ok(claimed, 'quest claim');
  bodyMatches(claimed, (c) => c.rewards && c.rewards.length > 0, 'claim pays a reward');

  sleep(THINK);
}
