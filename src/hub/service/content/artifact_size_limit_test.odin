package content

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// REQ-ART-1: one store for the create -> get round trip.
Artifact_Size_Store :: struct {
	saved: domain.Artifact,
	saves: int,
}

fake_artifact_size_save :: proc(ctx: rawptr, a: domain.Artifact) -> (domain.Artifact, bool, domain.Domain_Error) {
	store := (^Artifact_Size_Store)(ctx)
	store.saved = a
	store.saves += 1
	return a, true, {}
}

fake_artifact_size_get :: proc(ctx: rawptr, id: string) -> (domain.Artifact, bool, domain.Domain_Error) {
	store := (^Artifact_Size_Store)(ctx)
	if store.saves == 0 || store.saved.artifact_id != id do return {}, false, domain.domain_error(.Not_Found, "artifact not found")
	return store.saved, true, {}
}

artifact_size_service :: proc(store: ^Artifact_Size_Store, repo: ^iface.Content_Repository) -> Content_Service {
	repo^ = iface.Content_Repository{ctx = rawptr(store), save_artifact = fake_artifact_size_save, get_artifact = fake_artifact_size_get}
	return new_content_service(repo, nil, nil, nil, nil, nil, nil)
}

@(test)
test_artifact_limit_is_exactly_15_mib_decoded :: proc(t: ^testing.T) {
	testing.expect_value(t, ARTIFACT_MAX_BYTES, 15 * 1024 * 1024)
	testing.expect_value(t, ARTIFACT_MAX_BYTES, 15_728_640)
	testing.expect_value(t, artifact_content_limit_bytes("plain"), 15_728_640)
	// The armored budget is derived from the same plaintext limit, not a second number.
	testing.expect_value(t, artifact_content_limit_bytes("vault:v2:x"), domain.vault_armored_max_bytes(contracts.ARTIFACT_MAX_CONTENT_BYTES))
	testing.expect(t, artifact_content_limit_bytes("vault:v2:x") > ARTIFACT_MAX_BYTES)
}

@(test)
test_create_artifact_accepts_exact_limit_and_rejects_one_more_byte :: proc(t: ^testing.T) {
	store: Artifact_Size_Store
	repo: iface.Content_Repository
	service := artifact_size_service(&store, &repo)
	auth := contracts.Auth_Context{user_id = "user_1"}

	exact := strings.repeat("a", ARTIFACT_MAX_BYTES, context.temp_allocator)
	a, ok, err := create_artifact(&service, auth, Artifact_Input{name = "exact.txt", content = exact})
	testing.expect(t, ok, "exactly 15,728,640 bytes must be accepted")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, a.size_bytes, 15_728_640)

	over := strings.repeat("a", ARTIFACT_MAX_BYTES + 1, context.temp_allocator)
	_, ok, err = create_artifact(&service, auth, Artifact_Input{name = "over.txt", content = over})
	testing.expect(t, !ok, "15,728,641 bytes must be rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(err.message, "15728641 bytes"), "error names the actual size")
	testing.expect(t, strings.contains(err.message, "15,728,640 bytes"), "error names the exact limit")
	testing.expect_value(t, store.saves, 1)
}

@(test)
test_create_artifact_vault_armored_budget_boundary :: proc(t: ^testing.T) {
	store: Artifact_Size_Store
	repo: iface.Content_Repository
	service := artifact_size_service(&store, &repo)
	auth := contracts.Auth_Context{user_id = "user_1"}
	limit := domain.vault_armored_max_bytes(ARTIFACT_MAX_BYTES)

	// A sealed 15 MiB plaintext is larger than 15 MiB on the wire; it must still fit.
	fits := strings.concatenate({"vault:v2:", strings.repeat("A", limit - len("vault:v2:"), context.temp_allocator)}, context.temp_allocator)
	_, ok, err := create_artifact(&service, auth, Artifact_Input{name = "sealed", content = fits})
	testing.expect(t, ok, "armored value at the armored budget must be accepted")
	testing.expect_value(t, err.code, domain.Error_Code.None)

	over := strings.concatenate({fits, "A"}, context.temp_allocator)
	_, ok, err = create_artifact(&service, auth, Artifact_Input{name = "sealed", content = over})
	testing.expect(t, !ok, "armored value one byte over the budget must be rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	testing.expect(t, strings.contains(err.message, "encrypted"), "error says the encrypted budget applied")
}

@(test)
test_create_artifact_binary_round_trip_is_byte_exact :: proc(t: ^testing.T) {
	store: Artifact_Size_Store
	repo: iface.Content_Repository
	service := artifact_size_service(&store, &repo)
	auth := contracts.Auth_Context{user_id = "user_1"}

	// Invalid UTF-8, NULs and every byte value; sized to the exact limit.
	payload := make([]byte, ARTIFACT_MAX_BYTES, context.temp_allocator)
	for i in 0 ..< len(payload) do payload[i] = byte((i * 7 + 3) % 256)
	payload[0] = 0xff; payload[1] = 0x00; payload[2] = 0xc3
	a, ok, err := create_artifact(&service, auth, Artifact_Input{name = "blob.bin", content = string(payload), mime = "application/octet-stream"})
	testing.expect(t, ok, "binary payload at the limit must be accepted")
	testing.expect_value(t, err.code, domain.Error_Code.None)

	got, found, gerr := get_artifact(&service, auth, a.artifact_id)
	testing.expect(t, found, "created artifact must be readable")
	testing.expect_value(t, gerr.code, domain.Error_Code.None)
	testing.expect_value(t, got.size_bytes, ARTIFACT_MAX_BYTES)
	testing.expect(t, got.content == string(payload), "binary content must round-trip byte-for-byte")
}
