/*
 * Drives Authentik's flow executor and renders each stage as the approved Heimdall design.
 *
 * Protocol, captured from auth.brolabs.ai on 2025.12.4 (see the task notes):
 *   GET  /api/v3/flows/executor/<slug>/?query=<urlencoded original query>  -> challenge JSON
 *   POST  same URL with the stage response                                 -> 302 back to it
 *   then GET again for the next challenge. Terminal challenge is xak-flow-redirect.
 * No CSRF token is involved; the session rides on the authentik_session cookie, which is why
 * this page must be served from the same origin as Authentik.
 */

// ---- Element helpers ---------------------------------------------------------
// Text always goes in via textContent: labels, placeholders and error strings come from
// the server and from blueprints, and must never be interpolated into markup.
function el(tag, props = {}, kids = []) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'text') n.textContent = v;
    else if (k === 'cls') n.className = v;
    else if (k === 'html') throw new Error('refusing to set innerHTML');
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else if (k in n && k !== 'list') n[k] = v;
    else n.setAttribute(k, v);
  }
  for (const kid of [].concat(kids)) if (kid) n.append(kid);
  return n;
}
const card = () => document.getElementById('card');

// ---- Flow endpoint -----------------------------------------------------------
const params = new URLSearchParams(location.search);
const SLUG = params.get('flow') || document.body.dataset.flow || 'default-authentication-flow';

// Everything except our own `flow` marker is the flow's original query, which Authentik
// needs verbatim — it carries `?next=` for forward-auth and `?itoken=` for invites.
const passthrough = new URLSearchParams(location.search);
passthrough.delete('flow');
const EXECUTOR = `api/v3/flows/executor/${encodeURIComponent(SLUG)}/`
  + `?query=${encodeURIComponent(passthrough.toString())}`;

/**
 * The stock Authentik UI for this flow — the escape hatch if we cannot render something.
 *
 * `stock=1` is load-bearing: without it nginx redirects /if/flow/<slug>/ straight back here,
 * so the "use the standard page" link would bounce to this page instead of escaping to
 * Authentik. Our own `flow` marker is dropped too — left in, it would be re-prepended on
 * every bounce and the query string would grow a `flow=` per click.
 */
const STOCK_URL = (() => {
  const q = new URLSearchParams(passthrough);
  q.set('stock', '1');
  return `/if/flow/${encodeURIComponent(SLUG)}/?${q}`;
})();

async function getChallenge() {
  const r = await fetch(EXECUTOR, { headers: { Accept: 'application/json' }, credentials: 'same-origin' });
  if (!r.ok) throw new Error(`executor GET ${r.status}`);
  return r.json();
}

async function postChallenge(payload) {
  const r = await fetch(EXECUTOR, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify(payload),
  });
  // A POST answers 302 back to the executor; fetch follows it, so the body is usually the
  // next challenge already. Re-GET when it is not (or when the body is not JSON).
  if (!r.ok) throw new Error(`executor POST ${r.status}`);
  try {
    const j = await r.json();
    return j && j.component ? j : getChallenge();
  } catch { return getChallenge(); }
}

// ---- Shared pieces -----------------------------------------------------------
function flowHead(challenge, subtitle) {
  // flow_info.title is the blueprint's own flow title, so copy edits there flow through.
  const title = challenge.flow_info?.title || 'Heimdall';
  return el('div', { cls: 'flow-head' }, [
    el('h1', { cls: 'flow-title', text: title }),
    subtitle ? el('p', { cls: 'flow-sub', text: subtitle }) : null,
  ]);
}

/** The "Signing in as <user>" chip, using the avatar the challenge supplies. */
function identityChip(challenge) {
  if (!challenge.pending_user) return null;
  const who = el('span', { cls: 'ident-who' }, [
    challenge.pending_user_avatar
      ? el('img', { cls: 'uid-avatar', src: challenge.pending_user_avatar, alt: '', 'aria-hidden': 'true' })
      : null,
    el('span', { cls: 'uid-display', text: challenge.pending_user }),
  ]);
  return el('div', {}, [
    el('label', { text: 'Signing in as' }),
    el('div', { cls: 'ident-chip' }, [
      who,
      el('button', { type: 'button', text: 'Change', onclick: () => { location.href = changeUserUrl(challenge); } }),
    ]),
  ]);
}

/**
 * Where "Change" goes. Reloading is not enough: the pending user lives in the flow plan in
 * the Authentik session, so the executor would hand back the same password stage. The
 * cancel view (flow_info.cancel_url, what the stock UI's "Not you?" uses) drops the plan,
 * then honours a relative `next` — so it lands back here, with the original query
 * (`?next=`, `?itoken=`) intact, at a fresh identification stage.
 */
function changeUserUrl(challenge) {
  const url = new URL(challenge.flow_info?.cancel_url || '/flows/-/cancel/', location.origin);
  url.searchParams.set('next', location.pathname + location.search);
  return url.pathname + url.search;
}

/** Server-side validation messages for one field, e.g. "Invalid password". */
function fieldError(challenge, key) {
  const errs = challenge.response_errors?.[key];
  if (!errs?.length) return null;
  return el('p', { cls: 'error', text: errs.map((e) => e.string).join(' ') });
}

/** Errors not tied to a field we rendered — never silently swallow them. */
function otherErrors(challenge, handledKeys) {
  const all = challenge.response_errors || {};
  const rest = Object.keys(all).filter((k) => !handledKeys.includes(k));
  if (!rest.length) return null;
  return el('p', { cls: 'error', text: rest.map((k) => all[k].map((e) => e.string).join(' ')).join(' ') });
}

function submitButton(label) {
  return el('button', { cls: 'primary', type: 'submit', text: label });
}

function busy(form, on) {
  form.querySelectorAll('button, input').forEach((n) => { n.disabled = on; });
}

/** Wire a form so submit() runs, errors surface, and the next challenge renders. */
function onSubmit(form, build) {
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const payload = build();
    if (!payload) return;
    busy(form, true);
    try {
      render(await postChallenge(payload));
    } catch (err) {
      busy(form, false);
      form.append(el('p', { cls: 'error', text: `Something went wrong (${err.message}). ` }),
        el('p', { cls: 'hint center' }, [el('a', { href: STOCK_URL, text: 'Use the standard sign-in page' })]));
    }
  });
  return form;
}

// ---- Stage renderers ---------------------------------------------------------
const STAGES = {
  'ak-stage-identification': (c) => {
    const label = (c.user_fields || ['username']).map((f) => ({ email: 'Email', username: 'username' }[f] || f))
      .join(' or ').replace(/^./, (s) => s.toUpperCase());
    const input = el('input', { cls: 'field', id: 'uid', type: 'text', name: 'uid_field',
      autocomplete: 'username', placeholder: `Your ${label.toLowerCase()}`, autofocus: true });
    const form = el('form', { novalidate: true }, [
      el('label', { for: 'uid', text: label }),
      input,
      fieldError(c, 'uid_field'),
      otherErrors(c, ['uid_field']),
      submitButton('Continue'),
    ]);
    return [
      flowHead(c, 'Command your agent fleet'),
      ssoBlock(c),
      onSubmit(form, () => ({ component: c.component, uid_field: input.value.trim() })),
      signupLine(c),
    ];
  },

  'ak-stage-password': (c) => {
    const input = el('input', { cls: 'field', id: 'pw', type: 'password', name: 'password',
      autocomplete: 'current-password', placeholder: 'Your password', autofocus: true });
    const form = el('form', { novalidate: true }, [
      identityChip(c),
      el('div', { cls: 'label-row' }, [
        el('label', { for: 'pw', text: 'Password' }),
        // Shown disabled: this instance has no recovery flow, so the stock UI offers no
        // such link either. Becomes a real link once one is configured.
        el('span', { cls: 'disabled-link', 'aria-disabled': 'true',
          title: 'No recovery flow is configured yet', text: 'Forgot password?' }),
      ]),
      input,
      fieldError(c, 'password'),
      otherErrors(c, ['password']),
      submitButton('Continue'),
    ]);
    return [flowHead(c, 'Command your agent fleet'), onSubmit(form, () => ({ component: c.component, password: input.value }))];
  },

  // One challenge carries every enrolled factor. Picking "recovery code" is not another
  // endpoint — it is this same stage with a different selected_challenge.
  'ak-stage-authenticator-validate': (c, view) => {
    const devices = c.device_challenges || [];
    const pick = (cls) => devices.find((d) => d.device_class === cls);
    const useStatic = view === 'static' && pick('static');
    const device = useStatic ? pick('static') : (pick('totp') || devices[0]);
    if (!device) return [flowHead(c), el('p', { cls: 'hint', text: 'No usable second factor is configured.' }),
      el('p', { cls: 'hint center' }, [el('a', { href: STOCK_URL, text: 'Use the standard sign-in page' })])];

    const isTotp = device.device_class === 'totp';
    const input = isTotp
      ? el('input', { cls: 'field code', id: 'code', type: 'text', inputmode: 'numeric',
          autocomplete: 'one-time-code', maxLength: 6, placeholder: '000000', autofocus: true })
      : el('input', { cls: 'field', id: 'code', type: 'text', autocomplete: 'one-time-code',
          placeholder: 'xxxxxxxx', style: 'font-family:var(--font-mono);letter-spacing:.08em', autofocus: true });
    if (isTotp) input.addEventListener('input', () => { input.value = input.value.replace(/\D/g, '').slice(0, 6); });

    const other = isTotp ? pick('static') : pick('totp');
    const form = el('form', { novalidate: true }, [
      identityChip(c),
      el('label', { for: 'code', style: 'margin-top:16px', text: isTotp ? 'Authentication code' : 'Recovery code' }),
      el('p', { cls: 'hint', text: isTotp
        ? 'Enter the 6-digit code from your authenticator app.'
        : 'Enter one of the recovery codes you saved when you set up two-factor authentication. Each code works once.' }),
      input,
      fieldError(c, 'code'),
      otherErrors(c, ['code']),
      submitButton('Verify'),
      other ? el('p', { cls: 'hint center' }, [
        el('a', { href: '#', text: isTotp ? 'Use a recovery code instead' : 'Use your authenticator app instead',
          onclick: (e) => { e.preventDefault(); render(c, isTotp ? 'static' : 'totp'); } }),
      ]) : null,
    ]);
    return [flowHead(c, 'Command your agent fleet'),
      onSubmit(form, () => ({ component: c.component, selected_challenge: device, code: input.value.trim() }))];
  },

  // Generic: one renderer for every prompt stage, driven by the fields array.
  'ak-stage-prompt': (c) => {
    const fields = [...(c.fields || [])].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
    const inputs = new Map();
    const nodes = [];
    for (const f of fields) {
      if (f.type === 'static') {
        nodes.push(el('h2', { cls: 'step-title', style: nodes.length ? '' : 'margin-top:0', text: f.label }));
        if (f.placeholder) nodes.push(el('p', { cls: 'hint', text: f.placeholder }));
        continue;
      }
      if (f.type === 'checkbox') {
        const box = el('input', { type: 'checkbox', id: `f-${f.field_key}` });
        inputs.set(f.field_key, () => box.checked);
        nodes.push(el('label', { cls: 'check', for: `f-${f.field_key}` }, [box, el('span', { text: f.label })]));
      } else {
        const type = { password: 'password', email: 'email', number: 'number' }[f.type] || 'text';
        const auto = { password: 'new-password', email: 'email', username: 'username' }[f.type] || 'on';
        const input = el('input', { cls: 'field', id: `f-${f.field_key}`, type, autocomplete: auto,
          placeholder: f.placeholder || '', value: f.initial_value || '', autofocus: nodes.length === 0 });
        inputs.set(f.field_key, () => input.value);
        nodes.push(el('label', { for: `f-${f.field_key}`, style: nodes.length ? 'margin-top:16px' : '', text: f.label }));
        if (f.sub_text) nodes.push(el('p', { cls: 'hint', text: f.sub_text }));
        nodes.push(input);
      }
      const err = fieldError(c, f.field_key);
      if (err) nodes.push(err);
    }
    nodes.push(otherErrors(c, fields.map((f) => f.field_key)));
    nodes.push(submitButton('Continue'));
    const form = el('form', { novalidate: true }, nodes);
    return [flowHead(c, 'Create your Heimdall account.'),
      onSubmit(form, () => {
        const out = { component: c.component };
        for (const [k, read] of inputs) out[k] = read();
        return out;
      })];
  },

  'ak-stage-authenticator-totp': (c) => {
    const secret = new URL(c.config_url).searchParams.get('secret') || '';
    const input = el('input', { cls: 'field code', id: 'code', type: 'text', inputmode: 'numeric',
      autocomplete: 'one-time-code', maxLength: 6, placeholder: '000000', autofocus: true });
    input.addEventListener('input', () => { input.value = input.value.replace(/\D/g, '').slice(0, 6); });
    const form = el('form', { novalidate: true }, [
      el('h2', { cls: 'step-title', style: 'margin-top:0', text: 'Set up authenticator' }),
      el('p', { cls: 'hint', text: 'Scan the QR code with an authenticator app (1Password, Google Authenticator, Authy…), then enter the code it shows.' }),
      qrNode(c.config_url),
      el('p', { cls: 'hint center', style: 'margin:10px 0 0', text: "Can't scan? Enter this key manually:" }),
      el('code', { cls: 'secret', text: secret.replace(/(.{4})/g, '$1 ').trim() }),
      el('label', { for: 'code', style: 'margin-top:16px', text: 'Authentication code' }),
      input,
      fieldError(c, 'code'),
      otherErrors(c, ['code']),
      submitButton('Continue'),
    ]);
    return [flowHead(c, 'Create your Heimdall account.'),
      onSubmit(form, () => ({ component: c.component, code: input.value.trim() }))];
  },

  'ak-stage-authenticator-static': (c) => {
    const list = el('ul', { cls: 'codes' }, (c.codes || []).map((code) => el('li', { text: code })));
    const form = el('form', { novalidate: true }, [
      el('h2', { cls: 'step-title', style: 'margin-top:0', text: 'Save your recovery codes' }),
      el('p', { cls: 'hint', text: 'Use one of these if you lose access to your authenticator app. Each code works once.' }),
      list,
      el('p', { cls: 'warn', text: 'These are shown only once. Copy them somewhere safe before you continue.' }),
      submitButton('I have saved these codes'),
      otherErrors(c, []),
    ]);
    return [flowHead(c, 'Create your Heimdall account.'), onSubmit(form, () => ({ component: c.component }))];
  },

  'ak-stage-access-denied': (c) => [
    flowHead(c),
    el('h2', { cls: 'step-title', style: 'margin-top:0', text: 'Access denied' }),
    el('p', { cls: 'hint', text: c.error_message || 'This sign-in cannot continue.' }),
    el('p', { cls: 'hint center' }, [el('a', { href: STOCK_URL, text: 'Use the standard sign-in page' })]),
  ],
};

function ssoBlock(c) {
  // `sources` is empty on this instance, so there is nothing to drive yet. The buttons are
  // shown disabled deliberately rather than hidden; they light up when a source is configured.
  const sources = c.sources || [];
  const btn = (name, mark) => el('button', {
    type: 'button', disabled: !sources.length,
    title: sources.length ? `Continue with ${name}` : `${name} sign-in is coming soon`,
  }, [mark, document.createTextNode(name)]);
  return el('div', { id: 'sso-block' }, [
    el('div', { cls: 'sso' }, [btn('Google', brandMark('google')), btn('GitHub', brandMark('github'))]),
    sources.length ? null : el('p', { cls: 'soon', text: 'SSO coming soon' }),
    el('div', { cls: 'divider', text: 'or' }),
  ]);
}

function signupLine(c) {
  // Enrolment is invite-only on this instance, so there is no self-service sign-up to link to.
  return el('p', { cls: 'alt' }, [
    document.createTextNode("Don't have an account? "),
    el('span', { cls: 'disabled-link', 'aria-disabled': 'true', title: 'Sign-up is invite-only', text: 'Sign up' }),
  ]);
}

function brandMark(which) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  const paths = which === 'google'
    ? [['#4285F4', 'M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.27-4.74 3.27-8.1z'],
       ['#34A853', 'M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84A11 11 0 0 0 12 23z'],
       ['#FBBC05', 'M5.84 14.1A6.6 6.6 0 0 1 5.5 12c0-.73.13-1.43.34-2.1V7.06H2.18A11 11 0 0 0 1 12c0 1.77.43 3.45 1.18 4.94l3.66-2.84z'],
       ['#EA4335', 'M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.06l3.66 2.84C6.71 7.3 9.14 5.38 12 5.38z']]
    : [['currentColor', 'M12 .5C5.65.5.5 5.65.5 12a11.5 11.5 0 0 0 7.86 10.92c.58.1.79-.25.79-.56v-2c-3.2.7-3.87-1.37-3.87-1.37-.52-1.33-1.28-1.69-1.28-1.69-1.04-.71.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.76 2.7 1.25 3.36.96.1-.75.4-1.25.73-1.54-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.77 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.84 1.19 3.1 0 4.42-2.69 5.39-5.26 5.68.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z']];
  if (which === 'google') svg.classList.add('g-mark');
  for (const [fill, d] of paths) {
    const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('fill', fill); p.setAttribute('d', d);
    svg.append(p);
  }
  return svg;
}

/** Render the otpauth URI as a QR, drawn from the matrix our encoder produces. */
function qrNode(configUrl) {
  const box = el('div', { cls: 'qr', 'aria-label': 'Authenticator QR code' });
  try {
    const m = qrMatrix(configUrl);
    const n = m.length;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', `0 0 ${n} ${n}`);
    svg.setAttribute('shape-rendering', 'crispEdges');
    let d = '';
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (m[r][c]) d += `M${c} ${r}h1v1h-1z`;
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', d);
    path.setAttribute('fill', '#0e0d0b');
    svg.append(path);
    box.append(svg);
  } catch (err) {
    // The manual key below is a complete fallback, so a QR failure must not block setup.
    box.append(el('p', { cls: 'hint center', text: 'QR unavailable — use the key below.' }));
  }
  return box;
}

// ---- Dispatch ----------------------------------------------------------------
function render(challenge, view) {
  if (challenge.component === 'xak-flow-redirect') {
    location.href = challenge.to || '/';
    return;
  }
  const renderer = STAGES[challenge.component];
  const host = card();
  host.replaceChildren();
  if (!renderer) {
    // REQ-L3-6: never dead-end on a stage we do not know. Hand the user to the stock UI,
    // which can render every stage Authentik ships.
    host.append(
      flowHead(challenge),
      el('h2', { cls: 'step-title', style: 'margin-top:0', text: 'One more step' }),
      el('p', { cls: 'hint', text: 'This step needs the standard sign-in page.' }),
      el('p', { cls: 'hint center' }, [el('a', { href: STOCK_URL, text: 'Continue there' })]),
    );
    console.warn('unhandled flow stage', challenge.component, challenge);
    return;
  }
  for (const node of [].concat(renderer(challenge, view))) if (node) host.append(node);
  host.querySelector('[autofocus]')?.focus();
}

(async function start() {
  try {
    render(await getChallenge());
  } catch (err) {
    card().replaceChildren(
      el('h1', { cls: 'flow-title', text: 'Sign in' }),
      el('p', { cls: 'hint', style: 'margin-top:14px', text: `Could not reach the sign-in service (${err.message}).` }),
      el('p', { cls: 'hint center' }, [el('a', { href: STOCK_URL, text: 'Use the standard sign-in page' })]),
    );
  }
})();
