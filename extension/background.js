// WhatsApp Notifier - MV3 background service worker.
//
// Replaces the always-open tab. Wakes on an alarm, polls the local wa-notifier
// service, buffers inbound messages per chat, and raises ONE notification per
// chat once that chat goes quiet.
//
// VERIFIED: Aside's inbox captures self.registration.showNotification() from an
// extension service worker, but NOT chrome.notifications.create(). Tested by
// firing both; only the showNotification one reached Aside's inbox.
// Do not switch to chrome.notifications - it is silently dropped, with no error.
//
// The "notifications" manifest permission IS required even though we only use
// showNotification(). Removing it (on the assumption that service-worker
// notifications don't need it, which holds for web pages but NOT extensions)
// silently broke delivery: the call throws and nothing reaches the inbox.
//
// WHY DEBOUNCE: an Aside cron event routine creates a NEW task per notification.
// Undebounced, ten WhatsApp messages create ten Aside sessions. Grouping the
// burst into one notification makes it one session.

// If you change this port you MUST also change "host_permissions" in
// manifest.json and WA_NOTIFIER_PORT in the installed env.sh. All three have to
// agree or the extension silently fails every fetch with a CORS/permission error.
const BASE = 'http://127.0.0.1:8011';
const ALARM = 'wa-poll';
const CURSOR_KEY = 'lastRowId';
const PENDING_KEY = 'pending';
const POLL_MINUTES = 0.5; // 30s is the MV3 minimum

// Flush a chat once it has been silent this long. Because polls are 30s apart,
// anything under 30000 effectively means "flush on the next poll that brings
// nothing new". Raise to ~55000 to require two quiet polls: tighter grouping,
// but adds roughly 30s of latency.
const QUIET_MS = 25000;

// Safety valve. A chat that never goes quiet would otherwise buffer forever,
// so force a flush once the oldest held message reaches this age.
const MAX_HOLD_MS = 5 * 60 * 1000;

// Never put more than this many message lines in one notification body.
const MAX_LINES = 8;

async function getCursor() {
  const o = await chrome.storage.local.get(CURSOR_KEY);
  return typeof o[CURSOR_KEY] === 'number' ? o[CURSOR_KEY] : null;
}

async function setCursor(id) {
  await chrome.storage.local.set({ [CURSOR_KEY]: id });
}

// pending = { [chat_jid]: { title, firstAt, lastAt, messages: [{rowid, sender, content, media_type}] } }
// Held in chrome.storage.local, not memory, because MV3 tears the worker down
// between alarms.
async function getPending() {
  const o = await chrome.storage.local.get(PENDING_KEY);
  return o[PENDING_KEY] && typeof o[PENDING_KEY] === 'object' ? o[PENDING_KEY] : {};
}

async function setPending(p) {
  await chrome.storage.local.set({ [PENDING_KEY]: p });
}

// Every title starts with the exact prefix "WhatsApp: " so an Aside event
// routine can match on titleIncludes. We cannot filter on eventFilter.from,
// because normalizeEventFilter runs new URL(from).origin and chrome-extension://
// is not a special scheme, so it collapses to the string "null" and never matches.
function titleFor(m) {
  const isGroup = (m.chat_jid || '').endsWith('@g.us');
  const who = m.chat_name || m.sender || 'unknown';
  return isGroup ? `WhatsApp: ${who} (group)` : `WhatsApp: ${who}`;
}

function textFor(m) {
  return m.content || `[${m.media_type || 'media'}]`;
}

// The body doubles as the routine's instruction sheet. The trailing [rows a-b]
// marker lets a wake read the exact range back through MCP without guessing,
// and is a cheap cross-check against the cursor the routine keeps in memory.
function bodyFor(entry) {
  const msgs = entry.messages;
  if (msgs.length === 1) {
    return `${textFor(msgs[0])}\n[rows ${msgs[0].rowid}-${msgs[0].rowid}]`;
  }

  const first = msgs[0].rowid;
  const last = msgs[msgs.length - 1].rowid;
  const shown = msgs.slice(0, MAX_LINES);
  const lines = shown.map((m) => `\u2022 ${m.sender || '?'}: ${textFor(m)}`);
  if (msgs.length > shown.length) {
    lines.push(`\u2022 ...and ${msgs.length - shown.length} more`);
  }

  return `${msgs.length} new messages\n${lines.join('\n')}\n[rows ${first}-${last}]`;
}

async function fire(chatJid, entry) {
  try {
    // tag becomes part of Aside's threadKey, so a routine can filter to one
    // specific chat/group without reading message text.
    await self.registration.showNotification(entry.title, {
      body: bodyFor(entry),
      tag: chatJid,
    });
    console.log('wa-notifier ext: notified', entry.title, `(${entry.messages.length} msg)`);
    return true;
  } catch (e) {
    // Loud on purpose. A silent failure here looks identical to "no messages".
    console.error('wa-notifier ext: showNotification FAILED', e && e.message, e);
    return false;
  }
}

// Collect new messages into per-chat buckets and advance the cursor. The cursor
// moves as soon as a message is buffered, so a message is only ever read once;
// durability from that point on is the pending buffer's job.
async function collect() {
  let cursor = await getCursor();

  if (cursor === null) {
    // First run: start from now so we don't replay all history.
    const head = await (await fetch(`${BASE}/api/head`)).json();
    await setCursor(head.maxRowId);
    console.log('wa-notifier ext: initialised cursor at', head.maxRowId);
    return;
  }

  const res = await fetch(`${BASE}/api/new?since=${cursor}`);
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const data = await res.json();

  // The server delivers every inbound message, but still reports the high-water
  // mark it scanned separately, because its LIMIT can truncate a large burst.
  // Advance to head so nothing is rescanned on every poll.
  const head = typeof data.head === 'number' ? data.head : cursor;

  if (!data.messages.length) {
    if (head > cursor) await setCursor(head);
    return;
  }

  const pending = await getPending();
  const now = Date.now();

  for (const m of data.messages) {
    const jid = m.chat_jid;
    if (!pending[jid]) {
      pending[jid] = { title: titleFor(m), firstAt: now, messages: [] };
    }
    // Refresh the title each time: a group can be renamed, and chat_name is
    // null until the bridge has seen metadata for it.
    pending[jid].title = titleFor(m);
    pending[jid].lastAt = now;
    pending[jid].messages.push({
      rowid: m.rowid,
      sender: m.sender,
      content: m.content,
      media_type: m.media_type,
    });
    cursor = Math.max(cursor, m.rowid);
  }

  cursor = Math.max(cursor, head);
  await setPending(pending);
  await setCursor(cursor);
  console.log('wa-notifier ext: buffered', data.messages.length, '-> cursor', cursor);
}

// Fire notifications for any chat that has gone quiet, or that has been held
// too long. A chat that fails to notify stays buffered and retries next poll.
async function flushDue() {
  const pending = await getPending();
  const jids = Object.keys(pending);
  if (!jids.length) return;

  const now = Date.now();
  let changed = false;

  for (const jid of jids) {
    const entry = pending[jid];
    if (!entry || !entry.messages || !entry.messages.length) {
      delete pending[jid];
      changed = true;
      continue;
    }

    const quiet = now - (entry.lastAt || 0) >= QUIET_MS;
    const stale = now - (entry.firstAt || 0) >= MAX_HOLD_MS;
    if (!quiet && !stale) continue;

    if (await fire(jid, entry)) {
      delete pending[jid];
      changed = true;
    }
  }

  if (changed) await setPending(pending);
}

async function poll() {
  try {
    await collect();
    await flushDue();
  } catch (e) {
    console.error('wa-notifier ext poll failed', e);
  }
}

function arm() {
  chrome.alarms.create(ALARM, { periodInMinutes: POLL_MINUTES });
  poll();
}

chrome.runtime.onInstalled.addListener(arm);
chrome.runtime.onStartup.addListener(arm);

chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === ALARM) poll();
});
