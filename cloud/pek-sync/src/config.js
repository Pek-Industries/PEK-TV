export const MAX_BODY = 1024 * 1024;     // bytes per request
export const MAX_PUSH = 900;             // items per sync request (srv ordering needs < 1000)
export const PAGE = 2000;                // items returned per pull page
export const MAX_ITEMS = 50000;          // per account
export const MAX_DATA = 2000;            // chars of JSON per item
export const MAX_KEY = 200;
export const MAX_PROFILES = 5;           // live profiles per account (Netflix-style: each person has their own history and favorites)
export const MAX_PROFILE_ROWS = 40;      // profile rows incl. removal markers, per account
export const CLOCK_SLACK = 5 * 60 * 1000;

// Plugin backups (the plugin's own files, packed by the app into one text bundle and cut into chunks)
export const MAX_PLUGINS = 30;                    // per account
export const MAX_PLUGIN_RAW = 8 * 1024 * 1024;    // bytes of plugin files (same limit the app enforces when installing)
export const PLUGIN_CHUNK = 400000;               // chars per chunk (the app uses the same size)
export const MAX_PLUGIN_CHUNKS = 40;              // 40 x 400k chars is more than an 8 MB plugin needs
export const MAX_PLUGIN_TOTAL = 60 * 1024 * 1024; // all of an account's plugin backups together (raw bytes)
export const BUILTIN_PLUGINS = ['weather', 'sample_scraper', 'sample_counter', 'tmdb-discover'];

export const PBKDF2_ITERATIONS = 100000; // the most Cloudflare Workers allows. Stored per user, so it is safe to change later.
export const SESSION_TTL = 90 * 24 * 3600 * 1000;
// Lapsed plans (see cloud/BILLING-DEPLOY.md, "When a plan lapses"): a missed renewal keeps PEK Cloud on for GRACE_MS (the same number as in
// billing-worker.js); once that is over the account has DELETE_DAYS (Text variable on this worker, default 30) to subscribe again, then
// the account and everything stored in it is deleted for good by the daily job at the bottom of this file.
export const GRACE_MS = 14 * 24 * 3600 * 1000;
export const DAY_MS = 24 * 3600 * 1000;
// Lapsed accounts get one email every 3 days, from the missed renewal all the way to the deletion (the last email is the "deleted" one).
// The daily job runs at a fixed time, so a little slack keeps "every 3 days" from slipping to 4.
export const NOTICE_EVERY_MS = 3 * DAY_MS;
export const NOTICE_SLACK_MS = 2 * 3600 * 1000;
export function deleteMs(env) { const d = Number(env && env.DELETE_DAYS); return (d >= 1 && d <= 365 ? Math.floor(d) : 30) * DAY_MS; }
export const SESSION_REFRESH_BELOW = 60 * 24 * 3600 * 1000;
export const RESET_TTL = 15 * 60 * 1000;
export const RESET_MAX_TRIES = 5;
export const VERIFY_TTL = 30 * 60 * 1000;
export const RESEND_GAP = 30 * 1000;               // least time between two "send a new code" requests for one address
export const REJECT_TTL = 3 * 24 * 3600 * 1000;   // the "Wasn't you? Reject this login" link in an email works for 3 days
export const INVITE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';   // 31 characters, no 0 / O / 1 / I / L
export const INVITE_MAX_NEW = 20;          // codes made per request
export const INVITE_DEFAULT_DAYS = 14;     // an unused code stops working after this many days (0 = never)
export const DEVICE_TTL = 10 * 60 * 1000;   // a TV's link code works for 10 minutes
export const MIN_PASSWORD = 8;
export const MAX_PASSWORD = 200;

export const CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Max-Age': '86400'
};

export function json(obj, status = 200) {
    return new Response(JSON.stringify(obj), {
        status,
        headers: Object.assign({ 'Content-Type': 'application/json' }, CORS)
    });
}
