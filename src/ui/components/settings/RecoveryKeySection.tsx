// Settings → Devices: the opt-in recovery key (plan P4). "Create recovery key" shows
// 12 words ONCE and requires the user to re-enter 3 randomly chosen ones before the
// key is created; "Replace recovery key" creates a new one and then revokes the old.

import React, { useState } from 'react';
import { Alert, Button, Input } from '@ui';
import { generate12RecoveryWords, hexToBytes } from '../../utils/vaultCrypto';
import { createRecoveryKey, replaceRecoveryKey } from '../../services/deviceVault';

/** Three distinct word positions (0-based, ascending) to confirm. */
export function pickConfirmPositions(random: () => number = Math.random): number[] {
  const picked = new Set<number>();
  while (picked.size < 3) picked.add(Math.floor(random() * 12) % 12);
  return [...picked].sort((a, b) => a - b);
}

/** Whether the typed words match the written-down words at `positions`. */
export function confirmationMatches(words: string[], positions: number[], typed: string[]): boolean {
  return positions.length === 3 && positions.every((p, i) => String(typed[i] ?? '').trim().toLowerCase() === words[p]);
}

type Step = { kind: 'idle' } | { kind: 'show'; words: string[]; entropyHex: string } | { kind: 'confirm'; words: string[]; entropyHex: string; positions: number[] };

export function RecoveryKeySection({ hasRecoveryKey, onChanged }: { hasRecoveryKey: boolean; onChanged: () => void }) {
  const [step, setStep] = useState<Step>({ kind: 'idle' });
  const [typed, setTyped] = useState<string[]>(['', '', '']);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const start = () => {
    const { words, entropyHex } = generate12RecoveryWords();
    setStep({ kind: 'show', words, entropyHex });
    setTyped(['', '', '']);
    setError('');
    setNotice('');
  };
  const cancel = () => { setStep({ kind: 'idle' }); setTyped(['', '', '']); };

  const finish = async () => {
    if (step.kind !== 'confirm') return;
    if (!confirmationMatches(step.words, step.positions, typed)) {
      setError('Those words do not match. Check what you wrote down.');
      return;
    }
    setBusy(true);
    setError('');
    const entropy = hexToBytes(step.entropyHex);
    try {
      if (hasRecoveryKey) await replaceRecoveryKey(entropy);
      else await createRecoveryKey(entropy);
      setNotice(hasRecoveryKey ? 'Recovery key replaced. The old words no longer work.' : 'Recovery key created. Keep the words somewhere safe and offline.');
      setStep({ kind: 'idle' });
      onChanged();
    } catch (err) {
      setError(String((err as Error)?.message || err));
    } finally {
      entropy.fill(0);
      setBusy(false);
      setTyped(['', '', '']);
    }
  };

  return (
    <section data-debug-id="settings-recovery-key">
      <h2 className="text-base font-semibold text-primary">Recovery key</h2>
      <p data-debug-id="settings-recovery-key-status" className="text-xs text-muted">
        {hasRecoveryKey
          ? 'A recovery key is set. With its 12 words a new browser can restore access if every device is lost.'
          : 'No recovery key. If you lose every device, the only way back is a vault reset (all history unreadable).'}
      </p>
      {step.kind === 'idle' ? (
        <Button size="sm" className="mt-2" data-debug-id={hasRecoveryKey ? 'settings-recovery-key-replace-btn' : 'settings-recovery-key-create-btn'} onClick={start}>
          {hasRecoveryKey ? 'Replace recovery key' : 'Create recovery key'}
        </Button>
      ) : null}
      {step.kind === 'show' ? (
        <div data-debug-id="settings-recovery-key-words" className="mt-2 flex flex-col gap-2 rounded-lg border border-subtle p-3">
          <p className="text-xs text-primary">Write these 12 words down, in order. They are shown once and never stored; anyone with them can restore your vault.</p>
          <ol className="grid grid-cols-3 gap-1 font-mono text-sm text-primary">
            {step.words.map((w, i) => <li key={i} data-debug-id={`settings-recovery-key-word-${i + 1}`}>{i + 1}. {w}</li>)}
          </ol>
          <div className="flex gap-2">
            <Button size="sm" variant="primary" data-debug-id="settings-recovery-key-written-btn" onClick={() => setStep({ kind: 'confirm', words: step.words, entropyHex: step.entropyHex, positions: pickConfirmPositions() })}>I wrote them down</Button>
            <Button size="sm" variant="ghost" data-debug-id="settings-recovery-key-cancel-btn" onClick={cancel}>Cancel</Button>
          </div>
        </div>
      ) : null}
      {step.kind === 'confirm' ? (
        <div data-debug-id="settings-recovery-key-confirm" className="mt-2 flex flex-col gap-2 rounded-lg border border-subtle p-3">
          <p className="text-xs text-primary">Enter these words from your list to confirm.</p>
          {step.positions.map((p, i) => (
            <label key={p} className="flex items-center gap-2 text-xs text-muted">
              Word {p + 1}
              <Input id={`settings-recovery-key-confirm-${i}`} data-debug-id={`settings-recovery-key-confirm-input-${i}`} value={typed[i]} onChange={(v: string) => setTyped((t) => t.map((x, j) => (j === i ? v : x)))} />
            </label>
          ))}
          <div className="flex gap-2">
            <Button size="sm" variant="primary" data-debug-id="settings-recovery-key-confirm-btn" loading={busy} onClick={() => void finish()}>{hasRecoveryKey ? 'Replace recovery key' : 'Create recovery key'}</Button>
            <Button size="sm" variant="ghost" data-debug-id="settings-recovery-key-confirm-cancel-btn" onClick={cancel}>Cancel</Button>
          </div>
        </div>
      ) : null}
      {notice ? <div data-debug-id="settings-recovery-key-notice" className="mt-2"><Alert tone="success">{notice}</Alert></div> : null}
      {error ? <div data-debug-id="settings-recovery-key-error" className="mt-2"><Alert tone="danger">{error}</Alert></div> : null}
    </section>
  );
}
