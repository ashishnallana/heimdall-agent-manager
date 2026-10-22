#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mq_test_dir="${HOME}/.cache/heimdall-tests"
mkdir -p "$mq_test_dir"
mq_test_prefix="${mq_test_dir}/multi-question-$$"

nix develop -c odin check src/hub -collection:odin_test=src
nix develop -c odin check src/ctl -collection:odin_test=src

nix develop -c odin build src/contracts -build-mode:test -collection:odin_test=src -out:"${mq_test_prefix}-contracts"
"${mq_test_prefix}-contracts" -tests:test_multi_question_schema_validation,test_multi_question_answer_validation

nix develop -c odin build src/ctl -build-mode:test -collection:odin_test=src -out:"${mq_test_prefix}-ctl"
"${mq_test_prefix}-ctl" -tests:test_chat_multi_question_encrypted_roundtrip,test_chat_multi_question_file_and_flags,test_chat_multi_question_rejects_invalid_input,test_chat_send_encryption_with_vault_key,test_chat_send_with_comma_separated_options,test_chat_send_with_repeated_option_flags,test_chat_send_with_expected_answers_and_choices_aliases,test_chat_send_without_options_omits_options_key,test_chat_send_with_comma_separated_actions,test_chat_send_with_repeated_action_flags,test_chat_read_transparent_decryption,test_chat_read_fallback_when_vault_locked,test_chat_read_wrong_key_fallback,test_chat_read_unarmored_legacy_messages_pass_through

nix develop -c odin build src/hub/repository/sqlite -build-mode:test -collection:odin_test=src -out:"${mq_test_prefix}-sqlite"
"${mq_test_prefix}-sqlite" -tests:test_multi_question_answer_survives_reopen

nix develop -c odin build src/hub/transport/http -build-mode:test -collection:odin_test=src -out:"${mq_test_prefix}-http"
"${mq_test_prefix}-http" -tests:test_multi_question_http_roundtrip_and_replay,test_multi_question_http_latest_only_and_ownership,test_multi_question_http_invalid_answers,test_multi_question_http_parallel_duplicates,test_multi_question_http_legacy_metadata_and_types
