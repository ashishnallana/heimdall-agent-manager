import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';
import './helpers/vaultEndpointHarness.ts';

test('AgentPaneComposerPanel module, polling intervals, and xterm terminal contracts', async () => {
  const { AgentPaneComposerPanel, computeFittedFontSize } = await import('../src/ui/components/chat/AgentPaneComposerPanel.tsx');
  const { computeAgentPanePollingInterval } = await import('../src/ui/hooks/useAgentPaneSubscription.ts');
  const { agentsApi, useSendAgentPaneInputMutation, useSendAgentPaneResizeMutation } = await import('../src/ui/api/endpoints/agents.ts');

  assert.equal(typeof AgentPaneComposerPanel, 'function', 'AgentPaneComposerPanel must be a React function component');

  const element = React.createElement(AgentPaneComposerPanel, {
    agentInstanceId: 'inst_test_123',
    isExpanded: true,
    isActiveTab: true,
    runtimeStatus: 'running',
    onClose: () => {},
    onToggleExpand: () => {},
    className: 'custom-class',
  });

  assert.ok(element, 'React.createElement with AgentPaneComposerPanel must succeed');
  assert.equal(element.props.agentInstanceId, 'inst_test_123');
  assert.equal(element.props.isExpanded, true);
  assert.equal(element.props.isActiveTab, true);
  assert.equal(element.props.runtimeStatus, 'running');

  assert.equal(
    computeAgentPanePollingInterval({
      agentInstanceId: 'inst_test_123',
      isExpanded: true,
      isActiveTab: true,
      runtimeStatus: 'running',
      isDocumentHidden: false,
    }),
    500,
    'Composer panel expanded polling interval must be 500ms continuous'
  );

  assert.equal(
    computeAgentPanePollingInterval({
      agentInstanceId: 'inst_test_123',
      isExpanded: false,
      isActiveTab: true,
      runtimeStatus: 'running',
      isDocumentHidden: false,
    }),
    300000,
    'Composer panel collapsed polling interval must be 5m (300000ms)'
  );

  assert.equal(
    computeAgentPanePollingInterval({
      agentInstanceId: 'inst_test_123',
      isExpanded: true,
      isActiveTab: false,
      runtimeStatus: 'running',
    }),
    0,
    'Inactive tab must pause polling (0ms)'
  );

  assert.equal(
    computeAgentPanePollingInterval({
      agentInstanceId: 'inst_test_123',
      isExpanded: true,
      isActiveTab: true,
      runtimeStatus: 'stopped',
    }),
    0,
    'Stopped agent runtime must pause polling (0ms)'
  );

  assert.equal(typeof useSendAgentPaneInputMutation, 'function', 'useSendAgentPaneInputMutation hook must be exported');
  assert.ok(agentsApi.endpoints.sendAgentPaneInput, 'sendAgentPaneInput endpoint must exist on agentsApi');

  assert.equal(typeof useSendAgentPaneResizeMutation, 'function', 'useSendAgentPaneResizeMutation hook must be exported');
  assert.ok(agentsApi.endpoints.sendAgentPaneResize, 'sendAgentPaneResize endpoint must exist on agentsApi');
  assert.equal(typeof agentsApi.endpoints.sendAgentPaneResize.initiate, 'function', 'sendAgentPaneResize must have initiate function');

  const TerminalClass = (xtermModule.Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default);
  const FitAddonClass = (fitAddonModule.FitAddon || (fitAddonModule as any).default?.FitAddon || (fitAddonModule as any).default);

  assert.equal(typeof TerminalClass, 'function', 'Terminal must be available from @xterm/xterm');
  assert.equal(typeof FitAddonClass, 'function', 'FitAddon must be available from @xterm/addon-fit');

  const testTerminal = new TerminalClass({
    convertEol: true,
    cursorBlink: false,
    cursorInactiveStyle: 'none',
  });
  const testFit = new FitAddonClass();
  testTerminal.loadAddon(testFit);

  assert.equal(testTerminal.options.cursorBlink, false, 'Terminal cursorBlink must be disabled');
  assert.equal(testTerminal.options.cursorInactiveStyle, 'none', 'Terminal cursorInactiveStyle must be none');

  const ansiColorString = '\x1b[31mRed\x1b[0m \x1b[32mGreen\x1b[0m \x1b[1;34mBold Blue\x1b[0m \x1b[38;2;255;100;50mRGB\x1b[0m\n';
  testTerminal.write(ansiColorString);

  let capturedInput = '';
  const disposable = testTerminal.onData((data: string) => {
    capturedInput = data;
  });

  testTerminal.input('ls -la\r');
  assert.equal(capturedInput, 'ls -la\r', 'Terminal onData must capture input keystrokes');
  disposable.dispose();

  let capturedResize: { cols: number; rows: number } | null = null;
  const resizeDisposable = testTerminal.onResize((e: { cols: number; rows: number }) => {
    capturedResize = { cols: e.cols, rows: e.rows };
  });

  testTerminal.resize(110, 25);
  assert.deepEqual(capturedResize, { cols: 110, rows: 25 }, 'Terminal onResize must fire with new cols and rows');
  assert.equal(testTerminal.cols, 110, 'Terminal cols must update to 110');
  assert.equal(testTerminal.rows, 25, 'Terminal rows must update to 25');
  resizeDisposable.dispose();

  assert.equal(typeof testTerminal.scrollToBottom, 'function', 'Terminal must support scrollToBottom');
  testTerminal.scrollToBottom();
  testTerminal.dispose();

  assert.equal(typeof computeFittedFontSize, 'function', 'computeFittedFontSize must be exported');
  assert.equal(computeFittedFontSize(600), 12, 'Desktop width (600px) must retain default 12px font');
  assert.equal(computeFittedFontSize(500), 12, '500px boundary must retain default 12px font');

  const font360 = computeFittedFontSize(360);
  const font390 = computeFittedFontSize(390);
  const font480 = computeFittedFontSize(480);

  assert.ok(font360 >= 6 && font360 <= 12, '360px font size must be within 6-12');
  assert.ok(font390 >= 6 && font390 <= 12, '390px font size must be within 6-12');
  assert.ok(font480 >= 6 && font480 <= 12, '480px font size must be within 6-12');

  assert.ok(80 * (font360 * 0.6) <= 360 - 16, '80 columns must fit within 360px container');
  assert.ok(80 * (font390 * 0.6) <= 390 - 16, '80 columns must fit within 390px container');
  assert.ok(80 * (font480 * 0.6) <= 480 - 16, '80 columns must fit within 480px container');
});
