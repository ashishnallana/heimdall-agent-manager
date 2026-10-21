// REQ-IMPL-5 / REQ-ENROLL-5, REQ-ENROLL-6, REQ-ENROLL-14:
// the untrusted-input handling behind the bridge-enrollment approval screen.
//
// Two jobs, both about one thing: the operator is making a trust
// decision from what this screen shows them, so everything the screen shows has
// to be either verifiable or visibly marked as unverifiable.
//
//  1. `sanitizeForDisplay` — host-asserted strings are untrusted input EVEN FOR
//     DISPLAY. React escapes markup, so there is no XSS here; what React cannot
//     stop is display SPOOFING. A hostname carrying U+202E reverses everything
//     after it (Trojan Source), and a Cyrillic U+0430 renders identically to a
//     Latin "a". Neither is caught by escaping, and both defeat exactly the
//     visual check this screen exists to enable.
//
//  2. `bridgeApprovalBlocked` — bridge approval fails closed unless the Hub
//     returned canonical key material and the operator explicitly confirmed
//     that its fingerprint matches the independently computed terminal value.
//
// These live in their own module rather than inside the component because they
// are where the security properties are, and that is what the tests need to be
// able to reach directly (tests/ui_device_approval_safety_test.ts).

/** Result of sanitising one host-asserted string for display. */
export interface SanitizedDisplay {
  /** The string that is safe to render. */
  text: string;
  /** True when the value was absent or sanitised away to nothing. */
  empty: boolean;
  /** Bidi/invisible/control characters were present and have been removed. */
  removedControls: boolean;
  /** The value was longer than the cap and has been clipped. */
  truncated: boolean;
  /** Which scripts the surviving text draws letters from. */
  scripts: string[];
  /** More than one script is present — the homoglyph signal. */
  mixedScript: boolean;
  /** Any non-printable-ASCII character survives in `text`. */
  nonAscii: boolean;
  /** `text` with every non-ASCII char as an explicit \uXXXX escape. */
  escaped: string;
  /** Worth warning the operator about: something was removed, or scripts are mixed. */
  suspicious: boolean;
}

/**
 * Bidi controls, invisible formatting characters, and C0/C1 controls.
 *
 * U+202A..U+202E and U+2066..U+2069 are the Trojan-Source family: they reorder
 * the characters AFTER them, so a visual check of the rendered string means
 * nothing while they are present. The zero-width and soft-hyphen range lets two
 * different strings render identically. Line/paragraph separators would let one
 * field occupy several lines of the layout.
 */
const DISPLAY_HOSTILE_RE = new RegExp(
  '[' +
    '\\u0000-\\u001F\\u007F-\\u009F' + // C0 and C1 controls (incl. tab/newline)
    '\\u00AD' + //                       soft hyphen (invisible)
    '\\u061C' + //                       Arabic letter mark
    '\\u180E' + //                       Mongolian vowel separator
    '\\u200B-\\u200F' + //               zero-width space .. RLM
    '\\u202A-\\u202E' + //               LRE RLE PDF LRO RLO  <- Trojan Source
    '\\u2028\\u2029' + //                line / paragraph separator
    '\\u2060-\\u2064' + //               word joiner, invisible operators
    '\\u2066-\\u206F' + //               LRI RLI FSI PDI, deprecated formats
    '\\uFEFF' + //                       zero-width no-break space / BOM
    '\\uFFF9-\\uFFFB' + //               interlinear annotation marks
    ']',
  'g',
);

/**
 * Scripts whose letters contain well-known homoglyphs for one another.
 *
 * This is MIXED-SCRIPT detection rather than a confusable lookup table. A table
 * would be large, would need maintaining, and would still miss pairs; whereas
 * "this one short identifier is written in two different alphabets at once" is
 * cheap to check and almost never true of a real hostname.
 */
const SCRIPT_PROBES: ReadonlyArray<readonly [string, RegExp]> = [
  ['Latin', /[A-Za-zÀ-ɏḀ-ỿ]/],
  ['Cyrillic', /[Ѐ-ԯⷠ-ⷿꙀ-ꚟ]/],
  ['Greek', /[Ͱ-Ͽἀ-῿]/],
  ['Armenian', /[԰-֏]/],
  ['Hebrew', /[֐-׿]/],
  ['Arabic', /[؀-ۿݐ-ݿ]/],
  ['Han', /[㐀-䶿一-鿿]/],
  ['Kana', /[぀-ヿ]/],
  ['Hangul', /[ᄀ-ᇿ가-힯]/],
  ['Thai', /[฀-๿]/],
];

/** Display cap for a host-asserted string, in code points. */
export const DISPLAY_MAX_CHARS = 96;

/**
 * The bridge emits 32 bytes of entropy as unpadded base64url, so a real `state`
 * is 43 characters from that alphabet (`bridge_enroll_random_token` /
 * `BRIDGE_ENROLL_SECRET_BYTES` in src/bridge/enroll_device_flow.odin).
 *
 * The floor is 22 characters — about 128 bits — rather than the exact 43, so a
 * future change to that constant cannot silently break the callback, while a
 * nonce too short to be a nonce is still refused.
 */
const STATE_RE = /^[A-Za-z0-9_-]{22,128}$/;

/** 65-byte uncompressed P-256 point as 130 lowercase hex chars. */
const BPK_RE = /^04[0-9a-f]{128}$/;

/** The lowest port a user-space bridge could have bound a loopback listener on. */
const MIN_CALLBACK_PORT = 1024;
const MAX_CALLBACK_PORT = 65535;

/**
 * Renders a string with every non-ASCII character as an explicit `\uXXXX`
 * escape, so a value flagged as suspicious can also be shown in a form that
 * cannot itself spoof anything. This is what the operator actually compares.
 */
export function escapeNonAscii(s: unknown): string {
  let out = '';
  for (const ch of String(s ?? '')) {
    const cp = ch.codePointAt(0)!;
    if (cp >= 0x20 && cp <= 0x7e) {
      out += ch;
      continue;
    }
    out += '\\u' + cp.toString(16).toUpperCase().padStart(4, '0');
  }
  return out;
}

function scriptsIn(s: string): string[] {
  const found: string[] = [];
  for (const [name, probe] of SCRIPT_PROBES) {
    if (probe.test(s)) found.push(name);
  }
  return found;
}

/**
 * The single sanitiser for every host-asserted string that reaches the screen.
 *
 * Order matters: hostile characters are removed BEFORE normalising, so nothing
 * can be reintroduced by composition, and truncation happens last so the
 * reported length is the length actually displayed.
 *
 * Removal is REPORTED rather than silent. Quietly turning
 * `evil<U+202E>moc.elpmaxe` into `evilmoc.elpmaxe` would trade one misleading
 * display for another; the caller is expected to render the flags.
 */
export function sanitizeForDisplay(raw: unknown, maxChars: number = DISPLAY_MAX_CHARS): SanitizedDisplay {
  const limit = Number.isFinite(maxChars) && maxChars > 0 ? Math.floor(maxChars) : DISPLAY_MAX_CHARS;
  const input = raw === null || raw === undefined ? '' : String(raw);

  const stripped = input.replace(DISPLAY_HOSTILE_RE, '');
  const removedControls = stripped.length !== input.length;

  let normalized = stripped;
  try {
    normalized = stripped.normalize('NFC');
  } catch {
    normalized = stripped;
  }
  // Normalisation cannot introduce a bidi control, but it is cheaper to be sure
  // than to argue about it.
  normalized = normalized.replace(DISPLAY_HOSTILE_RE, '');

  // Code points, not UTF-16 units: slicing by `.length` would cut an astral
  // character in half and render a replacement glyph.
  const chars = Array.from(normalized);
  const truncated = chars.length > limit;
  const text = truncated ? chars.slice(0, limit).join('') + '…' : normalized;

  const scripts = scriptsIn(text);
  return {
    text,
    empty: text.length === 0,
    removedControls,
    truncated,
    scripts,
    mixedScript: scripts.length > 1,
    nonAscii: /[^\x20-\x7E]/.test(text),
    escaped: escapeNonAscii(text),
    // Being non-ASCII is NOT itself suspicious. Flagging every accented
    // hostname would train the operator to click through the warning, which is
    // worse than not warning at all.
    suspicious: removedControls || scripts.length > 1,
  };
}


/** True only for the Hub's canonical enrollment key and fingerprint shapes. */
export function bridgeFingerprintConfirmationReady(publicKey: unknown, fingerprint: unknown): boolean {
  const key = String(publicKey ?? '').trim().toLowerCase();
  const fp = String(fingerprint ?? '').trim().toLowerCase();
  return /^04[0-9a-f]{128}$/.test(key) && /^[0-9a-f]{4}( [0-9a-f]{4}){3}$/.test(fp);
}

/** Bridge approval fails closed until the terminal fingerprint is confirmed. */
export function bridgeApprovalBlocked(
  isBridgeGrant: boolean,
  publicKey: unknown,
  fingerprint: unknown,
  fingerprintConfirmed: boolean,
): boolean {
  if (!isBridgeGrant) return false;
  return !bridgeFingerprintConfirmationReady(publicKey, fingerprint) || !fingerprintConfirmed;
}

/** Normalises human-entered device codes to their eight Base32 symbols. */
export function normalizeDeviceCodeSymbols(raw: unknown): string {
  return String(raw ?? '')
    .toUpperCase()
    .replace(/[\s-]+/g, '')
    .replace(/[^A-Z2-7]/g, '')
    .slice(0, 8);
}

/** Formats normalised symbols as the Hub's XXXX-XXXX lookup key. */
export function formatDeviceCode(raw: unknown): string {
  const symbols = normalizeDeviceCodeSymbols(raw);
  if (symbols.length <= 4) return symbols;
  return `${symbols.slice(0, 4)}-${symbols.slice(4)}`;
}

/** Reads a complete code from the hash-router query in `#/device/add?code=…`. */
export function deviceCodeFromHash(rawHash: unknown): string {
  const raw = String(rawHash ?? '').replace(/^#/, '');
  const queryAt = raw.indexOf('?');
  if (queryAt < 0) return '';
  const value = new URLSearchParams(raw.slice(queryAt + 1)).get('code');
  if (normalizeDeviceCodeSymbols(value).length !== 8) return '';
  return formatDeviceCode(value);
}

//
// Review finding, 2026-10-07T21:02:37Z: the approval screen rendered
// `Date.now()` — the OPERATOR BROWSER's clock — in the group headed "Verified
// by Heimdall", whose copy promises "The Hub measured these itself". That was a
// false provenance claim in the one group on the screen whose whole job is to be
// trustworthy.
//
// It was also a behavioural defect, which is the part that justifies a wire
// change over a relabel. The only reason to show a "now" beside "Request
// received" is to let the operator judge HOW STALE the request is — the check
// that catches an approval screen opened from an old phishing link. With a local
// "now" that comparison was Hub-clock versus operator-clock, so any skew on the
// operator's machine silently shifted the apparent age of the request in either
// direction, with nothing on screen to say so.
//
// `hub_observed.server_time` now carries the Hub's own reading, in unix seconds,
// from the same `now` that decided the grant had not expired.
//
// THE RULE THESE FUNCTIONS EXIST TO ENFORCE: when the Hub's time is missing or
// implausible, the row renders as UNAVAILABLE. It does NOT fall back to the
// local clock. A silent fallback would reintroduce exactly the defect above
// while still passing any test that only exercised the happy path.

/** Lower bound for a plausible unix-seconds timestamp: 2020-01-01. */
const MIN_PLAUSIBLE_UNIX = 1577836800;
/** Upper bound: 2100-01-01. Catches milliseconds passed as seconds. */
const MAX_PLAUSIBLE_UNIX = 4102444800;

/**
 * Reads a Hub-measured unix-seconds timestamp, or reports it unavailable.
 *
 * Rejects non-integers, zero, negatives, and values outside a plausible range —
 * the last of which is what catches a milliseconds value handed over as
 * seconds, since that would render as a date in the year 56000 rather than as
 * an obvious error.
 */
export function hubMeasuredTime(raw: unknown): { seconds: number; available: boolean } {
  const n = typeof raw === 'number' ? raw : Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return { seconds: 0, available: false };
  if (n < MIN_PLAUSIBLE_UNIX || n > MAX_PLAUSIBLE_UNIX) return { seconds: 0, available: false };
  return { seconds: n, available: true };
}

/**
 * How old the request is, computed from TWO Hub-measured values so that
 * operator clock skew cannot shift it.
 *
 * Unavailable unless both sides are plausible Hub values. A negative age (the
 * Hub's "now" earlier than its own `requested_at`) is reported as unavailable
 * rather than clamped to zero: it means the two values did not come from the
 * clock this function assumes, and inventing "0 seconds old" would hide that.
 */
export function requestAgeSeconds(
  requestedAt: unknown,
  serverTime: unknown,
): { seconds: number; available: boolean } {
  const req = hubMeasuredTime(requestedAt);
  const now = hubMeasuredTime(serverTime);
  if (!req.available || !now.available) return { seconds: 0, available: false };
  const age = now.seconds - req.seconds;
  if (age < 0) return { seconds: 0, available: false };
  return { seconds: age, available: true };
}

/** Renders an age in whole units, for a row the operator reads at a glance. */
export function formatAge(age: { seconds: number; available: boolean }): string {
  if (!age.available) return '';
  const s = age.seconds;
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}
