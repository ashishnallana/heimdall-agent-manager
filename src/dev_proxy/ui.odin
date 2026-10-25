package main

// DP-3 / DP-4 / DP-7: self-contained management UI for ham-dev-proxy.
//
// Serves a single HTML document at /_dev/ (and /_dev/ui) with inline <style>
// and <script> — no external dependencies, no build step, no <script src> /
// <link> tags. The JS drives the task-2 management API (/_dev/api/*) with
// fetch: list users, render active highlight, [Use] sets active (POST
// /_dev/api/active -> sets ham_dev_user cookie + persists active), [Delete]
// removes (DELETE /_dev/api/users/<name>), and the create form posts a new
// user. The list re-renders after every mutation.
//
// XSS safety: user-controlled fields (username/display_name/email) are rendered
// with textContent / setAttribute, NEVER via innerHTML interpolation, so a
// crafted username cannot inject markup or script.
//
// The UI is served ONLY when management_enabled is true (loopback bind); the
// dispatcher in main.odin gates the entire /_dev/* surface on loopback (DP-7),
// and the footer restates that this is a local-development-only tool.

import "core:net"

// handle_dev_ui_request serves the management HTML document for /_dev/ and
// /_dev/ui. Returns true if the path matched (response written); false to let
// the caller continue /_dev/ dispatch. The loopback gate is applied by the
// caller (handle_dev_proxy_client) before this runs, so the UI is unreachable
// on a non-loopback bind (DP-7).
handle_dev_ui_request :: proc(client: net.TCP_Socket, path: string) -> bool {
	if path != "/_dev/" && path != "/_dev" && path != "/_dev/ui" do return false
	write_response(client, 200, "OK", "text/html; charset=utf-8", DEV_UI_HTML)
	return true
}

// DEV_UI_HTML is the single self-contained management page. Inline CSS/JS only.
// The fetch targets are same-origin relative paths (/_dev/api/*), so it works
// regardless of which port the proxy listens on.
DEV_UI_HTML :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Heimdall Dev Proxy — Identity Manager</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, Segoe UI, sans-serif; max-width: 680px;
         margin: 32px auto; padding: 0 16px; line-height: 1.5; color: #1f2937; background: #f8fafc; }
  @media (prefers-color-scheme: dark) { body { color: #e5e7eb; background: #0f172a; } }
  h1 { font-size: 1.25rem; margin: 0 0 4px; }
  p.sub { margin: 0 0 20px; color: #6b7280; font-size: 0.9rem; }
  section { background: #ffffff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
  @media (prefers-color-scheme: dark) { section { background: #111827; border-color: #1f2937; } }
  ul { list-style: none; padding: 0; margin: 0; }
  li { display: flex; align-items: center; justify-content: space-between; gap: 8px;
       padding: 10px 12px; border: 1px solid #e5e7eb; border-radius: 6px; margin-bottom: 8px; }
  li.active { border-color: #2563eb; background: #eff6ff; }
  @media (prefers-color-scheme: dark) { li { border-color: #1f2937; } li.active { background: #1e3a8a; border-color: #3b82f6; } }
  .who { display: flex; flex-direction: column; min-width: 0; }
  .who .uname { font-weight: 600; word-break: break-all; }
  .who .meta { font-size: 0.8rem; color: #6b7280; word-break: break-all; }
  .badge { font-size: 0.7rem; font-weight: 700; color: #2563eb; border: 1px solid #2563eb;
           border-radius: 999px; padding: 1px 8px; margin-left: 8px; }
  .actions { display: flex; gap: 6px; flex-shrink: 0; }
  button { font: inherit; cursor: pointer; border-radius: 6px; padding: 6px 12px; border: 1px solid #d1d5db;
           background: #ffffff; color: inherit; }
  @media (prefers-color-scheme: dark) { button { background: #1f2937; border-color: #374151; } }
  button.primary { background: #2563eb; color: #ffffff; border-color: #2563eb; }
  button.danger { color: #b91c1c; border-color: #fecaca; }
  @media (prefers-color-scheme: dark) { button.danger { border-color: #7f1d1d; } }
  button:disabled { opacity: 0.5; cursor: default; }
  form { display: grid; grid-template-columns: 1fr 1fr 2fr auto; gap: 8px; }
  @media (max-width: 560px) { form { grid-template-columns: 1fr; } }
  label { font-size: 0.75rem; color: #6b7280; display: block; margin-bottom: 2px; }
  input { font: inherit; padding: 6px 8px; border: 1px solid #d1d5db; border-radius: 6px; background: #ffffff; color: inherit; }
  @media (prefers-color-scheme: dark) { input { background: #0b1220; border-color: #374151; } }
  .err { color: #b91c1c; font-size: 0.85rem; min-height: 1em; }
  footer { margin-top: 8px; font-size: 0.75rem; color: #9ca3af; text-align: center; }
</style>
</head>
<body>
<h1>Heimdall Dev Proxy</h1>
<p class="sub">Local identity manager. The selected dev user is sent to the mock OIDC
provider as <code>login_hint</code> when you sign in (<code>/api/v1/auth/login</code>);
after switching, sign out and sign in again.</p>

<section>
  <h2 style="font-size:1rem;margin:0 0 10px;">Dev users</h2>
  <ul id="users"><li><span class="who"><span class="uname">Loading…</span></span></li></ul>
  <p class="err" id="err"></p>
</section>

<section>
  <h2 style="font-size:1rem;margin:0 0 10px;">Create dev user</h2>
  <form id="createForm">
    <div><label for="username">Username *</label><input id="username" name="username" required autocomplete="off"></div>
    <div><label for="display_name">Display name</label><input id="display_name" name="display_name" autocomplete="off"></div>
    <div><label for="email">Email</label><input id="email" name="email" type="email" autocomplete="off"></div>
    <div style="display:flex;align-items:flex-end;"><button type="submit" class="primary">Create</button></div>
  </form>
</section>

<footer>Local-development-only tool · served on loopback ·
<code>ham-dev-proxy</code></footer>

<script>
"use strict";
const errEl = document.getElementById("err");
const usersEl = document.getElementById("users");
const form = document.getElementById("createForm");

function clearErr() { errEl.textContent = ""; }
function showErr(msg) { errEl.textContent = msg || ""; }

// Render one user row. All user-controlled text uses textContent (XSS-safe);
// no innerHTML interpolation anywhere.
function renderRow(u, active) {
  const li = document.createElement("li");
  if (active === u.username) li.classList.add("active");

  const who = document.createElement("div");
  who.className = "who";

  const nameWrap = document.createElement("div");
  const uname = document.createElement("span");
  uname.className = "uname";
  uname.textContent = u.username;
  nameWrap.appendChild(uname);
  if (active === u.username) {
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "active";
    nameWrap.appendChild(badge);
  }
  who.appendChild(nameWrap);

  const meta = document.createElement("span");
  meta.className = "meta";
  const parts = [];
  if (u.display_name) parts.push(u.display_name);
  if (u.email) parts.push(u.email);
  meta.textContent = parts.join(" · ");
  who.appendChild(meta);

  const actions = document.createElement("div");
  actions.className = "actions";

  const useBtn = document.createElement("button");
  useBtn.type = "button";
  useBtn.textContent = active === u.username ? "Current" : "Use";
  useBtn.disabled = active === u.username;
  if (active === u.username) useBtn.classList.add("primary");
  useBtn.addEventListener("click", () => useUser(u.username));
  actions.appendChild(useBtn);

  const delBtn = document.createElement("button");
  delBtn.type = "button";
  delBtn.className = "danger";
  delBtn.textContent = "Delete";
  delBtn.addEventListener("click", () => deleteUser(u.username));
  actions.appendChild(delBtn);

  li.appendChild(who);
  li.appendChild(actions);
  return li;
}

async function loadUsers() {
  clearErr();
  try {
    const res = await fetch("/_dev/api/users", { credentials: "same-origin" });
    if (!res.ok) { showErr("Failed to load users (" + res.status + ")"); return; }
    const data = await res.json();
    usersEl.textContent = "";
    const users = (data && data.users) || [];
    const active = (data && data.active) || null;
    if (users.length === 0) {
      const li = document.createElement("li");
      const span = document.createElement("span");
      span.className = "who";
      span.textContent = "No dev users yet — create one below.";
      li.appendChild(span);
      usersEl.appendChild(li);
      return;
    }
    for (const u of users) usersEl.appendChild(renderRow(u, active));
  } catch (e) {
    showErr("Network error loading users: " + e);
  }
}

async function useUser(username) {
  clearErr();
  try {
    const res = await fetch("/_dev/api/active", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username }),
    });
    if (!res.ok) {
      const body = await res.text();
      showErr("Set active failed (" + res.status + "): " + body);
      return;
    }
    await loadUsers();
  } catch (e) {
    showErr("Network error: " + e);
  }
}

async function deleteUser(username) {
  if (!confirm('Delete dev user "' + username + '"?')) return;
  clearErr();
  try {
    const res = await fetch("/_dev/api/users/" + encodeURIComponent(username), {
      method: "DELETE", credentials: "same-origin",
    });
    if (!res.ok && res.status !== 204) {
      const body = await res.text();
      showErr("Delete failed (" + res.status + "): " + body);
      return;
    }
    await loadUsers();
  } catch (e) {
    showErr("Network error: " + e);
  }
}

form.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  clearErr();
  const username = document.getElementById("username").value.trim();
  if (!username) { showErr("Username is required."); return; }
  const display_name = document.getElementById("display_name").value.trim();
  const email = document.getElementById("email").value.trim();
  try {
    const res = await fetch("/_dev/api/users", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, display_name, email }),
    });
    if (!res.ok) {
      const body = await res.text();
      showErr("Create failed (" + res.status + "): " + body);
      return;
    }
    form.reset();
    await loadUsers();
  } catch (e) {
    showErr("Network error: " + e);
  }
});

loadUsers();
</script>
</body>
</html>`
