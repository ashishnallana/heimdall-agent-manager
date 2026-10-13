import { test } from 'node:test';
import assert from 'node:assert/strict';

test('REQ-CLUB-RUN-COMMANDS-13: groupTranscriptMessages clubs consecutive shell_run messages (>= 2) and keeps single runs standalone', async () => {
  const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeRun = (id: string, sessionId: string, time: number): any => ({
    key: id,
    messageId: id,
    body: '',
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'shell_run',
    metadata: { session_id: sessionId },
  });

  const makeUser = (id: string, text: string): any => ({
    key: id,
    messageId: id,
    body: text,
    isUser: true,
    createdUnixMs: 1000,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: 'you',
    messageType: 'text',
  });

  // 3 consecutive runs -> 1 clubbed group
  const input1 = [
    makeRun('r1', 's1', 1000),
    makeRun('r2', 's2', 2000),
    makeRun('r3', 's3', 3000),
  ];
  const out1 = groupTranscriptMessages(input1);
  assert.equal(out1.length, 1);
  assert.equal(out1[0].messageType, 'shell_run_group');
  assert.equal(out1[0].metadata?.count, 3);
  assert.equal(out1[0].metadata?.clubbedRuns.length, 3);

  // Single isolated run -> stays 1 shell_run
  const input2 = [
    makeUser('u1', 'hello'),
    makeRun('r1', 's1', 1000),
    makeUser('u2', 'world'),
  ];
  const out2 = groupTranscriptMessages(input2);
  assert.equal(out2.length, 3);
  assert.equal(out2[1].messageType, 'shell_run');

  // Consecutive runs with pinned session filtered out
  const input3 = [
    makeRun('r1', 's1', 1000),
    makeRun('r2', 's2', 2000),
    makeRun('r3', 's3_pinned', 3000),
  ];
  const out3 = groupTranscriptMessages(input3, new Set(['s3_pinned']));
  assert.equal(out3.length, 1);
  assert.equal(out3[0].messageType, 'shell_run_group');
  assert.equal(out3[0].metadata?.count, 2);
});

test('REQ-SUBTLE-AGENT-START-14: groupTranscriptMessages clubs consecutive start messages', async () => {
  const { groupTranscriptMessages, isAgentStartMessage } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeSystem = (id: string, body: string, time: number): any => ({
    key: id,
    messageId: id,
    body,
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'system',
  });

  const msg1 = makeSystem('sys1', 'Agent has started and is ready.', 1000);
  const msg2 = makeSystem('sys2', 'Agent has started and is ready.', 2000);
  assert.ok(isAgentStartMessage(msg1), 'Must identify system start message');

  // Single start message -> isolated
  const single = groupTranscriptMessages([msg1]);
  assert.equal(single.length, 1);
  assert.equal(single[0].messageType, 'system');

  // Consecutive start messages -> clubbed into agent_start_clubbed
  const clubbed = groupTranscriptMessages([msg1, msg2]);
  assert.equal(clubbed.length, 1);
  assert.equal(clubbed[0].messageType, 'agent_start_clubbed');
  assert.equal(clubbed[0].metadata?.count, 2);
});

// ---------------------------------------------------------------------------
// REQ-TEST-VERIFICATION-17: Regression tests for command clubbing, start indicators,
// and auto-startup capture pane
// ---------------------------------------------------------------------------

test('REQ-TEST-VERIFICATION-17: Consecutive shell_run messages (>= 2) group with count and formatted start/end time range', async () => {
  const {
    groupTranscriptMessages,
    formatClubbedTimeRange,
    formatClubbedRunLabel,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeRun = (id: string, time: number): any => ({
    key: id,
    messageId: id,
    body: '',
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'shell_run',
    metadata: { session_id: `sess_${id}` },
  });

  const mockFormatTimestamp = (ms: number) => {
    const d = new Date(ms);
    const hours = d.getUTCHours();
    const minutes = String(d.getUTCMinutes()).padStart(2, '0');
    return { label: `${hours}:${minutes} UTC`, iso: d.toISOString() };
  };

  // 1. Grouping 2 consecutive runs
  const runs2 = [
    makeRun('run-1', 1700000000000),
    makeRun('run-2', 1700000300000),
  ];
  const grouped2 = groupTranscriptMessages(runs2);
  assert.equal(grouped2.length, 1);
  assert.equal(grouped2[0].messageType, 'shell_run_group');
  assert.equal(grouped2[0].metadata?.count, 2);
  assert.equal(grouped2[0].metadata?.startUnixMs, 1700000000000);
  assert.equal(grouped2[0].metadata?.endUnixMs, 1700000300000);
  assert.equal(formatClubbedRunLabel(grouped2[0].metadata?.count), 'Ran 2 commands');
  const timeRange2 = formatClubbedTimeRange(
    grouped2[0].metadata?.startUnixMs,
    grouped2[0].metadata?.endUnixMs,
    mockFormatTimestamp,
  );
  assert.equal(timeRange2, '22:13 UTC \u2013 22:18 UTC');

  // 2. Grouping 4 consecutive runs with multiple intervals
  const runs4 = [
    makeRun('run-a', 1700000000000),
    makeRun('run-b', 1700000100000),
    makeRun('run-c', 1700000200000),
    makeRun('run-d', 1700000600000),
  ];
  const grouped4 = groupTranscriptMessages(runs4);
  assert.equal(grouped4.length, 1);
  assert.equal(grouped4[0].messageType, 'shell_run_group');
  assert.equal(grouped4[0].metadata?.count, 4);
  assert.equal(grouped4[0].metadata?.clubbedRuns.length, 4);
  assert.equal(formatClubbedRunLabel(grouped4[0].metadata?.count), 'Ran 4 commands');
  const timeRange4 = formatClubbedTimeRange(
    grouped4[0].metadata?.startUnixMs,
    grouped4[0].metadata?.endUnixMs,
    mockFormatTimestamp,
  );
  assert.equal(timeRange4, '22:13 UTC \u2013 22:23 UTC');

  // 3. Same start and end timestamp returns single time formatted
  const sameTimeRange = formatClubbedTimeRange(
    1700000000000,
    1700000000000,
    mockFormatTimestamp,
  );
  assert.equal(sameTimeRange, '22:13 UTC');
});

test('REQ-TEST-VERIFICATION-17: Group toggle expands/collapses the full command list', async () => {
  const {
    createClubbedGroupState,
    toggleClubbedGroup,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  // Initial state is collapsed
  let state = createClubbedGroupState(false);
  assert.equal(state.isGroupExpanded, false, 'Group must default to collapsed');

  // Toggle opens
  state = toggleClubbedGroup(state);
  assert.equal(state.isGroupExpanded, true, 'First toggle must expand group');

  // Toggle closes
  state = toggleClubbedGroup(state);
  assert.equal(state.isGroupExpanded, false, 'Second toggle must collapse group');
});

test('REQ-TEST-VERIFICATION-17: Individual commands inside clubbed group can be toggled expanded/collapsed independently', async () => {
  const {
    createClubbedGroupState,
    toggleClubbedCommand,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  let state = createClubbedGroupState(true);
  assert.equal(state.expandedCommandIds.size, 0, 'Inner commands must default to collapsed');

  // Expand command 1
  state = toggleClubbedCommand(state, 'cmd_1');
  assert.ok(state.expandedCommandIds.has('cmd_1'), 'cmd_1 must be expanded');
  assert.equal(state.expandedCommandIds.size, 1);

  // Expand command 2 independently
  state = toggleClubbedCommand(state, 'cmd_2');
  assert.ok(state.expandedCommandIds.has('cmd_1'), 'cmd_1 must remain expanded');
  assert.ok(state.expandedCommandIds.has('cmd_2'), 'cmd_2 must be expanded');
  assert.equal(state.expandedCommandIds.size, 2);

  // Collapse command 1 while keeping command 2 expanded
  state = toggleClubbedCommand(state, 'cmd_1');
  assert.ok(!state.expandedCommandIds.has('cmd_1'), 'cmd_1 must be collapsed');
  assert.ok(state.expandedCommandIds.has('cmd_2'), 'cmd_2 must still be expanded');
  assert.equal(state.expandedCommandIds.size, 1);
});

test('REQ-TEST-VERIFICATION-17: Single isolated shell_run message renders as a single row', async () => {
  const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeMsg = (id: string, type: string, body = ''): any => ({
    key: id,
    messageId: id,
    body,
    isUser: type === 'user',
    createdUnixMs: 1000,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: type,
    metadata: type === 'shell_run' ? { session_id: `sess_${id}` } : {},
  });

  // Isolated run between user and assistant messages
  const input = [
    makeMsg('u1', 'user', 'Run a command'),
    makeMsg('r1', 'shell_run'),
    makeMsg('a1', 'assistant', 'Done!'),
  ];
  const output = groupTranscriptMessages(input);
  assert.equal(output.length, 3, 'Isolated run must not change message count');
  assert.equal(output[0].messageType, 'user');
  assert.equal(output[1].messageType, 'shell_run', 'Isolated run must remain shell_run type (not shell_run_group)');
  assert.equal(output[1].metadata?.clubbedRuns, undefined, 'Isolated run must not have clubbedRuns metadata');
  assert.equal(output[2].messageType, 'assistant');

  // Single run alone in thread
  const single = groupTranscriptMessages([makeMsg('r-solo', 'shell_run')]);
  assert.equal(single.length, 1);
  assert.equal(single[0].messageType, 'shell_run');
});

test('REQ-TEST-VERIFICATION-17: Agent start/restart system messages render as subtle divider indicators with time', async () => {
  const {
    isAgentStartMessage,
    formatAgentStartDividerText,
    groupTranscriptMessages,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeSystem = (id: string, body: string, time = 1700000000000, metadata: any = {}): any => ({
    key: id,
    messageId: id,
    body,
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'system',
    metadata,
  });

  // Verify various startup/restart phrases are recognized
  assert.ok(isAgentStartMessage(makeSystem('s1', 'Agent has started and is ready.')));
  assert.ok(isAgentStartMessage(makeSystem('s2', 'Agent restarted after crash.')));
  assert.ok(isAgentStartMessage(makeSystem('s3', 'system ready for commands')));
  assert.ok(isAgentStartMessage({ messageType: 'agent_start' } as any));
  assert.ok(isAgentStartMessage(makeSystem('s4', '', 0, { system_type: 'agent_start' })));
  assert.ok(isAgentStartMessage(makeSystem('s5', '', 0, { system_type: 'startup' })));

  // Single isolated start message preserves system message type
  const solo = groupTranscriptMessages([makeSystem('s1', 'Agent has started and is ready.', 1700000000000)]);
  assert.equal(solo.length, 1);
  assert.equal(solo[0].messageType, 'system');

  // Verify divider text formatting for single start
  const dividerText = formatAgentStartDividerText(1, '10:14 AM');
  assert.equal(dividerText, 'agent started (10:14 AM)');
});

test('REQ-TEST-VERIFICATION-17: Consecutive agent starts are clubbed with count and time range', async () => {
  const {
    groupTranscriptMessages,
    formatAgentStartDividerText,
    formatClubbedTimeRange,
  } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  const makeStart = (id: string, time: number): any => ({
    key: id,
    messageId: id,
    body: 'Agent has started and is ready.',
    isUser: false,
    createdUnixMs: time,
    deliveredUnixMs: 0,
    readUnixMs: 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: '',
    messageType: 'system',
    metadata: {},
  });

  const mockFormatTimestamp = (ms: number) => ({
    label: ms === 1000 ? '10:00 AM' : ms === 2000 ? '10:02 AM' : '10:05 AM',
    iso: new Date(ms).toISOString(),
  });

  // 3 consecutive agent starts
  const starts = [
    makeStart('st1', 1000),
    makeStart('st2', 2000),
    makeStart('st3', 3000),
  ];
  const clubbed = groupTranscriptMessages(starts);
  assert.equal(clubbed.length, 1);
  assert.equal(clubbed[0].messageType, 'agent_start_clubbed');
  assert.equal(clubbed[0].metadata?.count, 3);
  assert.equal(clubbed[0].metadata?.startUnixMs, 1000);
  assert.equal(clubbed[0].metadata?.endUnixMs, 3000);

  const timeRange = formatClubbedTimeRange(
    clubbed[0].metadata?.startUnixMs,
    clubbed[0].metadata?.endUnixMs,
    mockFormatTimestamp,
  );
  assert.equal(timeRange, '10:00 AM \u2013 10:05 AM');

  const dividerText = formatAgentStartDividerText(clubbed[0].metadata?.count, timeRange);
  assert.equal(dividerText, 'agent started 3 times (10:00 AM \u2013 10:05 AM)');
});

test('REQ-TEST-VERIFICATION-17: Startup phase triggers capture pane expansion and running state triggers auto-close with manual override preservation', async () => {
  const { computeAutoStartupPaneState } = await import('../src/ui/components/chat/transcriptGrouping.ts');

  // 1. Stopped -> Starting: auto-expands pane
  const step1 = computeAutoStartupPaneState({
    prevStatus: 'stopped',
    runtimeStatus: 'starting',
    userManuallyToggled: false,
    currentExpanded: false,
  });
  assert.equal(step1.isPaneExpanded, true, 'Transition into starting must auto-expand capture pane');
  assert.equal(step1.userManuallyToggled, false);

  // 2. Starting -> Running: auto-closes pane
  const step2 = computeAutoStartupPaneState({
    prevStatus: 'starting',
    runtimeStatus: 'running',
    userManuallyToggled: false,
    currentExpanded: true,
  });
  assert.equal(step2.isPaneExpanded, false, 'Transition into running must auto-collapse capture pane');
  assert.equal(step2.userManuallyToggled, false);

  // 3. User manual override during starting: user manually closes pane
  const step3 = computeAutoStartupPaneState({
    prevStatus: 'starting',
    runtimeStatus: 'starting',
    userManuallyToggled: true,
    currentExpanded: false,
  });
  assert.equal(step3.isPaneExpanded, false, 'Manual collapse during starting must be preserved');
  assert.equal(step3.userManuallyToggled, true);

  // 4. User manual override during running: user manually opens pane
  const step4 = computeAutoStartupPaneState({
    prevStatus: 'running',
    runtimeStatus: 'running',
    userManuallyToggled: true,
    currentExpanded: true,
  });
  assert.equal(step4.isPaneExpanded, true, 'Manual expand during running must be preserved');
  assert.equal(step4.userManuallyToggled, true);

  // 5. Subsequent new start cycle resets userManuallyToggled and auto-expands
  const step5 = computeAutoStartupPaneState({
    prevStatus: 'running',
    runtimeStatus: 'starting',
    userManuallyToggled: true,
    currentExpanded: false,
  });
  assert.equal(step5.isPaneExpanded, true, 'New start cycle must reset override and auto-expand');
  assert.equal(step5.userManuallyToggled, false);
});

test('REQ-CHAT-EXPECTED-ANSWERS-19: extractMessageOptions parses options from array, string metadata, and metadata_json', async () => {
  const { extractMessageOptions } = await import('../src/ui/components/chat/types.ts');

  // Object with array options
  assert.deepEqual(
    extractMessageOptions({ metadata: { options: ['Deploy', 'Rollback', 'Wait'] } }),
    ['Deploy', 'Rollback', 'Wait'],
    'Must parse string array from metadata.options'
  );

  // Stringified metadata
  assert.deepEqual(
    extractMessageOptions({ metadata: JSON.stringify({ options: ['Alpha', 'Beta'] }) }),
    ['Alpha', 'Beta'],
    'Must parse JSON string in metadata'
  );

  // Fallback to metadata_json
  assert.deepEqual(
    extractMessageOptions({ metadata_json: JSON.stringify({ options: ['Yes', 'No'] }) }),
    ['Yes', 'No'],
    'Must parse JSON string in metadata_json'
  );

  // Empty or missing metadata returns empty array (normal messages without options)
  assert.deepEqual(extractMessageOptions({ metadata: {} }), [], 'Empty metadata object returns empty array');
  assert.deepEqual(extractMessageOptions({}), [], 'Missing metadata returns empty array');
  assert.deepEqual(extractMessageOptions({ metadata: { options: [] } }), [], 'Empty options array returns empty array');
  assert.deepEqual(extractMessageOptions({ metadata: { options: ['', '   '] } }), [], 'Whitespace-only options are filtered out');
});

test('REQ-ACTION-FEEDBACK-LOOP-21: extractMessageActionIds parses action_ids from metadata, stringified metadata, and metadata_json', async () => {
  const { extractMessageActionIds } = await import('../src/ui/components/chat/types.ts');

  // Array of action_ids
  assert.deepEqual(
    extractMessageActionIds({ metadata: { action_ids: ['card_1', 'card_2'] } }),
    ['card_1', 'card_2'],
    'Must parse string array from metadata.action_ids'
  );

  // Stringified metadata
  assert.deepEqual(
    extractMessageActionIds({ metadata: JSON.stringify({ action_ids: ['card_3'] }) }),
    ['card_3'],
    'Must parse JSON string in metadata'
  );

  // Fallback to metadata_json
  assert.deepEqual(
    extractMessageActionIds({ metadata_json: JSON.stringify({ action_ids: ['card_4'] }) }),
    ['card_4'],
    'Must parse JSON string in metadata_json'
  );

  // Aliases: actions or action_id
  assert.deepEqual(
    extractMessageActionIds({ metadata: { actions: ['card_5'] } }),
    ['card_5'],
    'Must support actions alias'
  );
  assert.deepEqual(
    extractMessageActionIds({ metadata: { action_id: 'card_6' } }),
    ['card_6'],
    'Must support single action_id string'
  );

  // Normal messages without action_ids return empty array
  assert.deepEqual(extractMessageActionIds({ metadata: {} }), [], 'Empty metadata returns empty array');
  assert.deepEqual(extractMessageActionIds({}), [], 'Missing metadata returns empty array');
  assert.deepEqual(extractMessageActionIds({ metadata: { action_ids: [] } }), [], 'Empty array returns empty array');
});
