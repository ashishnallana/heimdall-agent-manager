package push

// REQ-IMPL-5 / REQ-ENROLL-14 item 6: the post-approval notification.
//
// Enrolling a machine as a bridge is the single most consequential thing an
// owner can approve, and the approval happens in one browser tab that may then
// be closed. If that approval was obtained by phishing the owner, the only way
// they find out is by being told on a device they did not just use. So an
// approval is an `attention` push, not a chat one.
//
// ── WHY THIS PAYLOAD CARRIES NO HOSTNAME ────────────────────────────────────
//
// It would be natural to put the machine's hostname in the body, and it is the
// wrong thing to do. `device_label`, `os` and `os_user` are HOST-ASSERTED: the
// machine requesting access chose them, so they can carry bidi overrides and
// homoglyphs (that is the whole reason the approval page sanitises them before
// display, REQ-ENROLL-6). A push notification is rendered by the operating
// system, outside any page we control, where none of that sanitising applies
// and where there is no provenance split to show the value as a mere claim.
// Pushing that text would hand an attacker a spoofing surface strictly better
// than the one we just closed.
//
// So the body carries only Hub-derived values: the fingerprint the Hub computed
// itself (hex quads, structurally incapable of spoofing anything) and fixed
// prose. "Which machine was it?" is answered by opening Heimdall, where the
// provenance split exists.

import "core:strings"

// build_enrollment_approval_notification builds the content for "a bridge was
// just approved on your account".
//
// `key_fingerprint` must be the HUB-COMPUTED fingerprint
// (bridge_key_fingerprint_for), never a host-supplied one. It is hex quads, so
// it is safe to render anywhere; an empty value simply omits the detail rather
// than rendering "fingerprint: " with nothing after it.
//
// Ownership matches build_chat_notification exactly: body, tag and route are
// heap-allocated (even the fallbacks) so a caller can unconditionally
// `defer free_notification_content(content)`; `title` is a literal, which is
// why free_notification_content does not touch it.
build_enrollment_approval_notification :: proc(key_fingerprint: string) -> Notification_Content {
	body: string
	if key_fingerprint != "" {
		body = strings.concatenate({
			"A machine was just approved to enroll as a bridge on your account. Key fingerprint ",
			key_fingerprint,
			". If this was not you, revoke it now.",
		})
	} else {
		body = strings.clone(
			"A machine was just approved to enroll as a bridge on your account. If this was not you, revoke it now.",
		)
	}

	return Notification_Content{
		title    = "Bridge enrollment approved",
		body     = body,
		// A fixed tag deliberately COALESCES repeated approvals into one
		// notification slot. The alternative — a per-bridge tag — would let an
		// attacker who has obtained one approval bury it under a burst of
		// others, which is the opposite of discoverable.
		tag      = strings.clone("heimdall:attention:bridge-enrollment"),
		route    = strings.clone("/settings/bridges"),
		category = .Attention,
	}
}

// build_vault_device_pending_notification: "a new device is waiting for approval".
// It deliberately carries NO user code (plan §3: a stolen cookie can register a
// pending device, but approving it needs the code shown on the NEW screen, so the
// code must never travel to the other devices) and no host-chosen label — only the
// hub-computed fingerprint, which the approver compares on the new device's screen.
build_vault_device_pending_notification :: proc(fingerprint: string) -> Notification_Content {
	body := strings.concatenate({
		"A new device asked to join your vault (fingerprint ",
		fingerprint,
		"). To approve it, enter the code shown on that device. If this was not you, ignore it.",
	})
	return Notification_Content{
		title    = "New device waiting for approval",
		body     = body,
		tag      = strings.clone("heimdall:attention:vault-device"),
		route    = strings.clone("/device/add"),
		category = .Attention,
	}
}
