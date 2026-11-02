// The activity row above the composer shows an agent action like a tool call: a
// short verb ("Commenting on task") and, when the hub's summary carries more than
// the verb, the rest of it ("Signed key verification is in"). The verbs follow the
// hub's agent_action kinds (publish_agent_action in src/hub). Unit-tested in
// tests/ui_agent_action_labels_test.ts.

const VERBS: Record<string, string> = {
  agents_live: 'Listing live agents',
  artifact_content: 'Reading an artifact',
  artifact_create: 'Creating artifact',
  artifact_list: 'Listing artifacts',
  artifact_show: 'Opening an artifact',
  card_accept: 'Accepting card',
  card_create: 'Creating card',
  card_discard: 'Discarding card',
  card_list: 'Listing cards',
  card_show: 'Opening card',
  chain_desc: 'Updating chain description',
  chain_propose: 'Proposing a plan',
  chain_show: 'Viewing the chain',
  chain_status: 'Changing chain status',
  chain_summary: 'Updating chain summary',
  chain_title: 'Renaming the chain',
  chat_fetch: 'Reading messages',
  chat_read: 'Reading messages',
  chat_send: 'Sending a message',
  chat_send_agent: 'Messaging an agent',
  context: 'Refreshing context',
  conversation_title: 'Renaming the conversation',
  lease_block: 'Blocking task',
  lease_handoff: 'Handing off task',
  lease_submit: 'Submitting task',
  lease_switch: 'Switching task',
  memory_content: 'Reading memory',
  memory_list: 'Listing memories',
  memory_propose: 'Proposing memory',
  memory_show: 'Opening memory',
  review_post: 'Reviewing',
  search: 'Searching',
  task_comment: 'Commenting on task',
  task_comments: 'Reading task comments',
  task_create: 'Creating task',
  task_depend: 'Linking a dependency',
  task_list: 'Viewing tasks',
  task_show: 'Reading task',
  task_update: 'Updating task',
  workflow_define: 'Defining workflow',
};

/** The part of a hub summary that adds to the verb: text after ": ", or a quoted name. */
function detailOf(summary: string): string {
  const colon = summary.indexOf(': ');
  if (colon >= 0) return summary.slice(colon + 2).trim();
  const quoted = /["“]([^"”]+)["”]/.exec(summary);
  return quoted ? quoted[1].trim() : '';
}

export function agentActionLine(action: string, summary: string): { verb: string; detail: string } {
  const text = String(summary || '').trim();
  const verb = VERBS[String(action || '')];
  if (!verb) return { verb: text || 'Working', detail: '' };
  return { verb, detail: detailOf(text) };
}
