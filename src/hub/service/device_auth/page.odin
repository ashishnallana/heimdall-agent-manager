// Browser confirm page for the device-authorization flow (ELDA-2).
//
// GET /api/v1/device serves this single self-contained HTML document (inline
// CSS/JS, no external dependencies, no build step). It is NOT the Heimdall SPA
// shell — it is a tiny dedicated surface for entering a user_code, reviewing
// the requesting device's info, and approving or denying the grant.
//
// XSS safety: every server-controlled field rendered into the DOM
// (device_label, os, app_version, client, request_ip) is inserted via
// textContent / createElement, NEVER via innerHTML interpolation, so a crafted
// device_label cannot inject markup or script. The user_code typed by the user
// is likewise only ever read from the input and sent in the body, never
// rendered unsanitized.

package device_auth

// DEVICE_PAGE_HTML is served by GET /api/v1/device. The JS flow:
//   1. user enters the user_code shown by the device,
//   2. POST /api/v1/device/verify {user_code} -> show device info,
//   3. [Approve] / [Deny] -> POST /api/v1/device/approve {user_code, approve}.
// All fetches are same-origin, so the Hub session cookie rides on every request
// (and the POSTs carry the same-origin metadata the CSRF check requires).
DEVICE_PAGE_HTML :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Heimdall — Authorize device</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, Segoe UI, sans-serif; max-width: 520px;
         margin: 40px auto; padding: 0 16px; line-height: 1.5; color: #1f2937; background: #f8fafc; }
  @media (prefers-color-scheme: dark) { body { color: #e5e7eb; background: #0f172a; } }
  h1 { font-size: 1.25rem; margin: 0 0 4px; }
  p.sub { margin: 0 0 20px; color: #6b7280; font-size: 0.9rem; }
  section { background: #ffffff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
  @media (prefers-color-scheme: dark) { section { background: #111827; border-color: #1f2937; } }
  label { font-size: 0.8rem; color: #6b7280; display: block; margin-bottom: 4px; }
  input { font: inherit; padding: 8px 10px; border: 1px solid #d1d5db; border-radius: 6px; width: 100%;
          box-sizing: border-box; background: #ffffff; color: inherit; letter-spacing: 0.1em; }
  @media (prefers-color-scheme: dark) { input { background: #0b1220; border-color: #374151; } }
  button { font: inherit; cursor: pointer; border-radius: 6px; padding: 8px 16px; border: 1px solid #d1d5db;
           background: #ffffff; color: inherit; margin-top: 12px; }
  @media (prefers-color-scheme: dark) { button { background: #1f2937; border-color: #374151; } }
  button.primary { background: #2563eb; color: #ffffff; border-color: #2563eb; }
  button.danger { color: #b91c1c; border-color: #fecaca; }
  button:disabled { opacity: 0.5; cursor: default; }
  dl { margin: 0; display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; }
  dt { color: #6b7280; font-size: 0.8rem; }
  dd { margin: 0; word-break: break-all; font-weight: 500; }
  .err { color: #b91c1c; font-size: 0.85rem; min-height: 1em; }
  .ok { color: #047857; font-size: 0.85rem; }
  .warn { color: #b45309; font-size: 0.85rem; margin: 6px 0 0; }
  select { font: inherit; padding: 8px 10px; border: 1px solid #d1d5db; border-radius: 6px; width: 100%;
           box-sizing: border-box; background: #ffffff; color: inherit; margin-top: 2px; }
  @media (prefers-color-scheme: dark) { select { background: #0b1220; border-color: #374151; } }
  .hidden { display: none; }
</style>
</head>
<body>
<h1>Authorize a device</h1>
<p class="sub">Enter the code shown by the Ninjy app on your new device.</p>

<section>
  <label for="user_code">Device code</label>
  <input id="user_code" inputmode="text" autocomplete="off" placeholder="ABCD-2345" maxlength="9">
  <button id="verifyBtn" type="button" class="primary">Continue</button>
  <p class="err" id="err"></p>
</section>

<section id="deviceSection" class="hidden">
  <h2 style="font-size:1rem;margin:0 0 10px;">Confirm it's you signing in</h2>
  <dl>
    <dt>App</dt><dd id="d_client"></dd>
    <dt>Device</dt><dd id="d_device_label"></dd>
    <dt>OS</dt><dd id="d_os"></dd>
    <dt>Version</dt><dd id="d_app_version"></dd>
    <dt>From IP</dt><dd id="d_request_ip"></dd>
  </dl>
  <div id="bridgeTargetWrap" class="hidden">
    <label for="targetBridge">Bridge identity</label>
    <select id="targetBridge">
      <option value="">Create a new bridge</option>
    </select>
    <div id="newBridgeNameWrap">
      <label for="newBridgeName">Bridge name</label>
      <input id="newBridgeName" maxlength="128">
    </div>
    <p class="warn hidden" id="bridgeTargetWarning"></p>
  </div>
  <button id="approveBtn" type="button" class="primary">Approve</button>
  <button id="denyBtn" type="button" class="danger">Deny</button>
  <p class="ok" id="result"></p>
</section>

<script>
"use strict";
const errEl = document.getElementById("err");
const resultEl = document.getElementById("result");
const deviceSection = document.getElementById("deviceSection");
const verifyBtn = document.getElementById("verifyBtn");
const approveBtn = document.getElementById("approveBtn");
const denyBtn = document.getElementById("denyBtn");
const codeInput = document.getElementById("user_code");
const bridgeTargetWrap = document.getElementById("bridgeTargetWrap");
const targetBridgeSelect = document.getElementById("targetBridge");
const newBridgeNameWrap = document.getElementById("newBridgeNameWrap");
const newBridgeName = document.getElementById("newBridgeName");
const bridgeTargetWarning = document.getElementById("bridgeTargetWarning");

function showErr(msg) { errEl.textContent = msg || ""; resultEl.textContent = ""; }
function clearErr() { errEl.textContent = ""; }

// Render one <dd> by id using textContent (XSS-safe; never innerHTML).
function setDD(id, value) {
  const el = document.getElementById(id);
  el.textContent = value || "—";
}

// Offers "attach to an existing bridge" only for a bridge-enrollment grant
// (a plain user/Electron device grant has no bridge_id to attach to). Every
// option label is built with createElement + textContent, never innerHTML --
// a bridge's own label/machine_hostname is host-asserted, not something this
// page may trust as markup.
async function loadBridgeTargets(hostname) {
  while (targetBridgeSelect.options.length > 1) targetBridgeSelect.remove(1);
  bridgeTargetWarning.classList.add("hidden");
  bridgeTargetWarning.textContent = "";
  targetBridgeSelect.value = "";
  newBridgeNameWrap.classList.remove("hidden");
  newBridgeName.value = String(hostname || "").trim() || "bridge";
  try {
    const res = await fetch("/api/v1/bridges", { method: "GET", credentials: "same-origin" });
    if (!res.ok) return; // non-fatal: the picker just stays "create a new bridge" only
    const payload = await res.json();
    const bridges = (payload && payload.data) || [];
    const labels = new Set(bridges.map((br) => String((br && br.label) || "").trim().toLowerCase()));
    const base = String(hostname || "").trim() || "bridge";
    let candidate = base;
    let count = 2;
    while (labels.has(candidate.toLowerCase())) candidate = base + "-" + count++;
    newBridgeName.value = candidate;
    for (const br of bridges) {
      if (!br || br.status === "revoked") continue; // a dead bridge has nothing to attach to
      if (br.enrollment_state === "pending") continue; // not enrolled yet (REQ-EA-1); the hub refuses it as a target
      const opt = document.createElement("option");
      opt.value = br.bridge_id || "";
      opt.textContent = (br.label || br.bridge_id || "bridge") + " (" + (br.machine_hostname || "unknown host") + ")";
      targetBridgeSelect.appendChild(opt);
    }
  } catch (e) {
    // Network error here is non-fatal for the same reason as !res.ok above.
  }
}

targetBridgeSelect.addEventListener("change", () => {
  if (targetBridgeSelect.value) {
    newBridgeNameWrap.classList.add("hidden");
    bridgeTargetWarning.textContent =
      "This replaces that bridge's credential and disconnects it, ending any of its running sessions.";
    bridgeTargetWarning.classList.remove("hidden");
  } else {
    newBridgeNameWrap.classList.remove("hidden");
    bridgeTargetWarning.classList.add("hidden");
    bridgeTargetWarning.textContent = "";
  }
});

verifyBtn.addEventListener("click", async () => {
  clearErr();
  const user_code = codeInput.value.trim();
  if (!user_code) { showErr("Enter the code from your device."); return; }
  try {
    const res = await fetch("/api/v1/device/verify", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_code }),
    });
    if (res.status === 410) { showErr("This code was already used."); return; }
    if (!res.ok) { showErr("Invalid or expired code."); return; }
    const payload = await res.json();
    const d = (payload && payload.data) || payload || {};
    setDD("d_client", d.client);
    setDD("d_device_label", d.device_label);
    setDD("d_os", d.os);
    setDD("d_app_version", d.app_version);
    setDD("d_request_ip", d.request_ip);
    deviceSection.classList.remove("hidden");
    if (d.is_bridge_enrollment) {
      bridgeTargetWrap.classList.remove("hidden");
      await loadBridgeTargets(d.device_label);
    } else {
      bridgeTargetWrap.classList.add("hidden");
    }
  } catch (e) {
    showErr("Network error: " + e);
  }
});

async function decide(approve) {
  clearErr();
  const user_code = codeInput.value.trim();
  // Only meaningful on approval of a bridge-enrollment grant; the Hub ignores
  // it for every other case (approve() reads target_bridge_id only inside its
  // own "approve a Bridge_Enrollment grant" branch), so sending it harmlessly
  // on a deny or a non-bridge grant is fine.
  const target_bridge_id = bridgeTargetWrap.classList.contains("hidden") ? "" : targetBridgeSelect.value;
  const new_bridge_label = target_bridge_id ? "" : newBridgeName.value.trim();
  try {
    const res = await fetch("/api/v1/device/approve", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_code, approve, target_bridge_id, new_bridge_label }),
    });
    if (res.status === 409) { showErr("This code was already used."); return; }
    if (!res.ok) { showErr("Invalid or expired code."); return; }
    resultEl.textContent = approve ? "Approved — check your device." : "Denied.";
    approveBtn.disabled = true;
    denyBtn.disabled = true;
  } catch (e) {
    showErr("Network error: " + e);
  }
}

approveBtn.addEventListener("click", () => decide(true));
denyBtn.addEventListener("click", () => decide(false));
codeInput.addEventListener("keydown", (ev) => { if (ev.key === "Enter") verifyBtn.click(); });
</script>
</body>
</html>`
