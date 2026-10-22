import { useEffect, useRef, useState } from 'react';
import type { VaultKeyring } from '../../utils/vaultKeyring';
import { apiErrorText } from '../../api/cookieFetch';
import { buildQuestionSubmission, decryptQuestionGroup, readQuestionDraft, type QuestionDraft, type QuestionGroup, type QuestionSubmission } from './multiQuestion';

/** One source owns one draft and retry key. The parent keys this by conversation/source. */
export default function MultiQuestionForm({ group, eligible, answered, vaultKey, debugPrefix, onSubmit }: {
  group: QuestionGroup;
  eligible: boolean;
  answered?: boolean;
  vaultKey: VaultKeyring | null;
  debugPrefix: string;
  onSubmit: (submission: QuestionSubmission) => Promise<unknown>;
}) {
  const [resolved, setResolved] = useState<{ source: QuestionGroup; key: VaultKeyring | null; group: QuestionGroup } | null>(null);
  const [draft, setDraft] = useState<QuestionDraft>({});
  const [error, setError] = useState('');
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [stale, setStale] = useState(false);
  const inFlight = useRef(false);
  const pending = useRef<QuestionSubmission | null>(null);
  const retryKey = useRef(crypto.randomUUID());
  useEffect(() => {
    let current = true;
    decryptQuestionGroup(group, vaultKey).then((value) => {
      if (current) setResolved({ source: group, key: vaultKey, group: value });
    }).catch(() => { if (current) setResolved(null); });
    return () => { current = false; };
  }, [group, vaultKey]);
  // Never render a previous key's plaintext during a lock or source replacement.
  const plain = resolved?.source === group && resolved.key === vaultKey ? resolved.group : null;
  const complete = answered || sent;
  const interactive = eligible && !complete && !stale && Boolean(vaultKey);
  const frozen = sending || Boolean(pending.current);

  if (!plain) return <div role="status" data-debug-id={`${debugPrefix}-locked`} className="mt-3 text-sm text-muted">🔒 Unlock Vault to read these questions.</div>;
  const change = (id: string, value: QuestionDraft[string]) => { setDraft((prev) => ({ ...prev, [id]: value })); setError(''); };
  const submit = async () => {
    if (!interactive || inFlight.current) return;
    try {
      pending.current ||= buildQuestionSubmission(plain, draft, retryKey.current);
    } catch (err) { setError(apiErrorText(err)); return; }
    inFlight.current = true;
    setSending(true);
    setError('');
    try {
      await onSubmit(pending.current);
      setSent(true);
    } catch (err: any) {
      if (err?.code === 'question_stale' || err?.code === 'question_answered') setStale(true);
      setError(apiErrorText(err, 'Could not send answers. Retry to send the same answers.'));
    } finally { inFlight.current = false; setSending(false); }
  };
  return <form data-debug-id={`${debugPrefix}-form`} className="mt-3 min-w-0 space-y-4 rounded-xl border border-subtle bg-surface p-3 sm:p-4" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
    {plain.questions.map((q) => {
      const value = readQuestionDraft(draft, q.id);
      return <fieldset key={q.id} disabled={!interactive || frozen} className="min-w-0 space-y-2">
        <legend className="mb-2 whitespace-pre-wrap font-medium">{q.text}</legend>
        {interactive ? <>
          {q.options.map((o) => <label key={o.id} data-debug-id={`${debugPrefix}-question-${q.id}-choice-${o.id}`} className="flex min-h-11 cursor-pointer items-center gap-3 rounded-lg border border-subtle px-3 py-2 has-[:checked]:border-accent has-[:checked]:bg-accent/10">
            <input type={q.selection_mode === 'multiple' ? 'checkbox' : 'radio'} name={`${debugPrefix}-${q.id}`} value={o.id}
              data-debug-id={`${debugPrefix}-question-${q.id}-option-${o.id}`} checked={value.optionIds.includes(o.id)}
              onChange={() => change(q.id, { customText: '', optionIds: q.selection_mode === 'multiple' ? (value.optionIds.includes(o.id) ? value.optionIds.filter((id) => id !== o.id) : [...value.optionIds, o.id]) : [o.id] })} />
            <span className="min-w-0 whitespace-pre-wrap break-words">{o.label}</span>
          </label>)}
          <label className="block space-y-1 text-sm text-muted">
            <span>Or write a custom answer</span>
            <textarea data-debug-id={`${debugPrefix}-question-${q.id}-custom`} value={value.customText} rows={2} maxLength={8192}
              onChange={(event) => change(q.id, { optionIds: [], customText: event.target.value })}
              className="min-h-11 w-full rounded-lg border border-subtle bg-canvas px-3 py-2 text-primary focus-visible:shadow-focus" />
          </label>
        </> : <div className="space-y-1 text-muted">
          <ul className="list-inside list-disc">{q.options.map((o) => <li key={o.id} className="whitespace-pre-wrap">{o.label}</li>)}</ul>
          {value.customText || value.optionIds.length ? <p className="whitespace-pre-wrap text-primary">Your answer: {value.customText || q.options.filter((o) => value.optionIds.includes(o.id)).map((o) => o.label).join(', ')}</p> : null}
        </div>}
      </fieldset>;
    })}
    {complete ? <p role="status" data-debug-id={`${debugPrefix}-answered`} className="text-sm text-muted">Answers submitted.</p> : !interactive ? <p role="status" className="text-sm text-muted">{!vaultKey ? 'Unlock Vault to answer.' : 'This question is no longer accepting answers.'}</p> : <button type="submit" disabled={sending} data-debug-id={`${debugPrefix}-submit`} className="min-h-11 w-full rounded-lg bg-accent px-4 py-2 font-medium text-accent-fg disabled:opacity-50 sm:w-auto">{sending ? 'Sending answers…' : pending.current ? 'Retry answers' : 'Submit all answers'}</button>}
    {error ? <p role="alert" data-debug-id={`${debugPrefix}-error`} className="text-sm text-danger">{error}{pending.current && !stale ? ' Your draft is preserved; retry sends the same answers.' : ''}</p> : null}
  </form>;
}
