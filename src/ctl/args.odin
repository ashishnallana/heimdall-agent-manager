package main

import "core:strings"
import cfg_lib "odin_test:lib/config"

command_tokens :: proc(args: []string) -> [dynamic]string {
	cmd := make([dynamic]string)
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == cfg_lib.CONFIG_PATH_FLAG || arg == "--as" || arg == "--daemon-url" || arg == "--hub-url" || arg == "--bridge-endpoint" || arg == "--agent-token" || arg == "--wrapper-bin" || arg == "--agent" || arg == "--agent-id" || arg == "--instance-id" || arg == "--instance" || arg == "--bridge-id" || arg == "--provider" || arg == "--model" || arg == "--conversation-id" || arg == "--chat-id" || arg == "--initial-body" || arg == "--slug" || arg == "--instructions" || arg == "--message" || arg == "--coordinator-agent-id" || arg == "--token" || arg == "--user-token" || arg == "--to" || arg == "--body" || arg == "--limit" || arg == "--task-id" || arg == "--task" || arg == "--chain-id" || arg == "--chain" || arg == "--status" || arg == "--agent-instance-id" || arg == "--role" || arg == "--roles" || arg == "--use" || arg == "--final-summary" || arg == "--summary" || arg == "--user-id" || arg == "--client-instance-id" || arg == "--message-id" || arg == "--result" || arg == "--comment" || arg == "--title" || arg == "--description" || arg == "--goal" || arg == "--priority" || arg == "--assignee-agent-instance-id" || arg == "--assignee" || arg == "--reviewer-agent-instance-id" || arg == "--coordinator-agent-instance-id" || arg == "--coordinator" || arg == "--reviewer" || arg == "--comment-id" || arg == "--depends-on" || arg == "--subject-agent" || arg == "--subject-key" || arg == "--scope" || arg == "--type" || arg == "--memory-id" || arg == "--memory" || arg == "--proposal-id" || arg == "--decision" || arg == "--reason" || arg == "--evidence" || arg == "--source-task-id" || arg == "--source-task" || arg == "--expected-version" || arg == "--project-id" || arg == "--project" || arg == "--repo-url" || arg == "--repo" || arg == "--vcs-kind" || arg == "--default-path" || arg == "--path" || arg == "--content-type" || arg == "--name" || arg == "--anchor-type" || arg == "--anchor-value" || arg == "--anchor-note" || arg == "--cursor" || arg == "--since" || arg == "--target-project-id" || arg == "--target-role" || arg == "--target-team-kind" || arg == "--team" || arg == "--team-id" || arg == "--project-ids" || arg == "--role-key" || arg == "--role-keys" || arg == "--task-chain-type" || arg == "--task-chain-types" || arg == "--template-key" || arg == "--template" || arg == "--file" || arg == "--proposal-file" || arg == "--out" || arg == "--artifact-id" || arg == "--artifact" || arg == "--artifacts-file" || arg == "--artifacts" || arg == "--kind" || arg == "--mime" || arg == "--creator-id" || arg == "--origin-kind" || arg == "--origin-ref" || arg == "--data" || arg == "--version" || arg == "--change-reason" || arg == "--annotation-id" || arg == "--context-type" || arg == "--context-json" || arg == "--notify" || arg == "--persona" || arg == "--on" || arg == "--dir" || arg == "--content" || arg == "--last" || arg == "--agents" || arg == "--agent-ids" || arg == "--projects" || arg == "--bridge" || arg == "--bridges" || arg == "--bridge-ids" || arg == "--bridge-models" || arg == "--bridge-models-file" || arg == "--capacity" || arg == "--min-warm" || arg == "--idle-ttl" || arg == "--idle-ttl-seconds" || arg == "--template-id" || arg == "--templates" || arg == "--template-ids" || arg == "--exclude" || arg == "--task-ids" || arg == "--chain-ids" || arg == "--project-ids" || arg == "--conversation-ids" || arg == "--not-in-task-ids" || arg == "--not-in-chain-ids" || arg == "--not-in-project-ids" || arg == "--not-in-conversation-ids" || arg == "--card-id" || arg == "--card" || arg == "--confidence" || arg == "--source-refs" || arg == "--operations" || arg == "--guard" || arg == "--rationale" || arg == "--alternative" || arg == "--snooze-until" || arg == "--ttl-at" || arg == "--prompt" || arg == "--cron" || arg == "--timezone" || arg == "--interval" || arg == "--active-from" || arg == "--active-until" || arg == "--blackout-dates" || arg == "--target-run-at" || arg == "--action-id" || arg == "--action" || arg == "--target-instance-id" || arg == "--target-agent-id" || arg == "--target-bridge-id" || arg == "--instance-strategy" || arg == "--label" || arg == "--port" || arg == "--signal" || arg == "--cmd" || arg == "--cwd" || arg == "--grep" || arg == "--offset" || arg == "--rows" || arg == "--cols" || arg == "--issue-id" || arg == "--issue" || arg == "--scope-type" || arg == "--target-id" || arg == "--target" || arg == "--query" || arg == "-q" || arg == "--voter-id" || arg == "--voter" || arg == "--voter-name" || arg == "--author-id" || arg == "--author" || arg == "--author-name" || arg == "--created-by" || arg == "--events" || arg == "--event-type" || arg == "--verdict" || arg == "--on-behalf-of" || arg == "--findings-file" || arg == "--handoff-file" || arg == "--output-file" || arg == "--brief-file" || arg == "--waiting-on" || arg == "--ref" || arg == "--lease" || arg == "--note" || arg == "--vcs-base" || arg == "--verify" || arg == "--acceptance" || arg == "--input" || arg == "--inputs" || arg == "--review-role" || arg == "--review-roles" {
			i += 1
			continue
		}
		if arg == "--remote" {
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") do i += 1
			continue
		}
		if strings.has_prefix(arg, "--") do continue
		append(&cmd, arg)
	}
	return cmd
}

option_value :: proc(args: []string, name, fallback: string) -> string {
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] == name do return args[i + 1]
	}
	return fallback
}

has_flag :: proc(args: []string, name: string) -> bool {
	for arg in args {
		if arg == name do return true
	}
	return false
}
