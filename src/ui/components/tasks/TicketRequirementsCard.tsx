import React from 'react';
import { Alert, Badge, Button, Icon, Tab, Tabs, TabsList, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { DecryptedMarkdown, VaultText } from '../vault';
import { normalizeTaskState } from './taskV2Types';
import { EditedText } from './RequirementsEditorModal';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import type { TaskNames } from './taskNames';
import { diffAcceptance, formatAgo, parseRequirementsHistory } from './ticketModel';

/* Requirements (REQ-T4) ---------------------------------------------- */

export function TicketRequirementsCard({
  task,
  history,
  names,
  now,
  view,
  onViewChange,
  highlight,
  canEdit,
  masked,
  onChange,
  onSeeChanges,
}: {
  task: TaskWire;
  history: ReturnType<typeof parseRequirementsHistory>;
  names: TaskNames;
  now: number;
  view: 'current' | 'changes';
  onViewChange: (v: 'current' | 'changes') => void;
  highlight: boolean;
  canEdit: boolean;
  masked: boolean;
  onChange: () => void;
  onSeeChanges: () => void;
}) {
  const req = task.requirements;
  const revision = Number(req?.revision) || 1;
  const latest = history && history.length ? history[0] : null;
  const acceptance = (task.brief?.acceptance || []).map(String);
  // Edited / New tags compare with the revision before the current one.
  const prev = latest && latest.revision === revision ? latest.before.acceptance : null;
  const diff = prev ? diffAcceptance(prev, acceptance) : { items: acceptance.map((text) => ({ text, tag: null as null })), removed: [] as string[] };
  const acks = req?.acknowledgements || [];
  const pending = acks.filter((a) => a.pending);
  const who = latest ? (latest.actorKind === 'user' ? 'You' : names.participant(latest.actorId) || names.instance(latest.actorId) || 'An agent') : '';
  const goal = String(task.brief?.goal || task.description || '');
  return (
    <section
      data-debug-id="ticket-view-requirements"
      className={`rounded-lg border bg-surface transition-colors duration-slow motion-reduce:transition-none ${highlight ? 'border-info bg-info-soft' : 'border-subtle'}`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2 px-4 pt-3">
        <span className="flex flex-wrap items-center gap-2">
          <Text as="h3" role="title" className="text-primary">Requirements</Text>
          <Badge tone="neutral" data-debug-id="task-requirements-status">Rev {revision}</Badge>
          {latest && latest.revision === revision && (
            <Text as="span" role="caption" tone="muted">by {who} · {formatAgo(latest.tsMs, now)}</Text>
          )}
        </span>
        <span className="flex items-center gap-2">
          {revision > 1 && (
            <Tabs value={view} onChange={(v) => onViewChange(v as 'current' | 'changes')} variant="segmented">
              <TabsList label="Requirements view">
                <Tab value="current" data-debug-id="ticket-view-requirements-current">Current</Tab>
                <Tab value="changes" data-debug-id="ticket-view-requirements-changes">Changes</Tab>
              </TabsList>
            </Tabs>
          )}
        </span>
      </div>
      <div className="flex flex-col gap-3 p-4 pt-3">
        {pending.length > 0 && (
          <Alert tone="info" icon="info">
            {pending.map((a) => names.instance(a.holder_instance_id) || 'The worker').join(', ')} {pending.length === 1 ? 'was' : 'were'} notified and read{pending.length === 1 ? 's' : ''} rev {revision} before {pending.length === 1 ? 'its' : 'their'} next step.
          </Alert>
        )}
        {view === 'changes' && latest ? (
          <div className="flex flex-col gap-2 text-body-sm" data-debug-id="ticket-view-requirements-diff">
            <Text as="p" role="caption" tone="muted">Since rev {latest.revision - 1}</Text>
            {latest.before.goal !== latest.after.goal && (
              <div className="flex flex-col gap-1">
                <span className="text-faint line-through"><VaultText value={latest.before.goal} /></span>
                <span className="text-primary"><VaultText value={latest.after.goal} /></span>
              </div>
            )}
            {diffAcceptance(latest.before.acceptance, latest.after.acceptance).items.filter((i) => i.tag).map((i, n) => (
              <div key={n} className="flex gap-2">
                <Badge tone={i.tag === 'new' ? 'success' : 'info'}>{i.tag === 'new' ? 'Add' : 'Edit'}</Badge>
                <span className="min-w-0 break-words text-primary"><EditedText previous={i.previous} text={i.text} /></span>
              </div>
            ))}
            {diffAcceptance(latest.before.acceptance, latest.after.acceptance).removed.map((r, n) => (
              <div key={`r${n}`} className="flex gap-2">
                <Badge tone="danger">Remove</Badge>
                <span className="min-w-0 break-words text-faint line-through"><VaultText value={r} /></span>
              </div>
            ))}
            <div>
              <Button size="sm" variant="ghost" onClick={onSeeChanges} data-debug-id="ticket-view-see-what-changed">
                See every change
              </Button>
            </div>
          </div>
        ) : (
          <>
            {goal ? (
              <div className="font-[family-name:var(--font-display)] text-body text-primary">
                <DecryptedMarkdown source={goal} compact copyAll={false} data-debug-id="task-details-goal" />
              </div>
            ) : (
              <Text role="caption" tone="faint">No goal yet.</Text>
            )}
            {diff.items.length > 0 && (
              <ul className="divide-y divide-subtle" data-debug-id="ticket-view-acceptance">
                {diff.items.map((i, n) => (
                  <li key={n} className="flex items-start gap-2 py-2 text-body-sm">
                    <span aria-hidden="true" className="mt-0.5 inline-flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-pill border border-strong text-success">
                      {normalizeTaskState(task.state) === 'done' && <Icon name="check" size={10} />}
                    </span>
                    <span className="min-w-0 flex-1 break-words text-primary">
                      {i.tag === 'edited' ? <EditedText previous={'previous' in i ? i.previous : undefined} text={i.text} /> : <VaultText value={i.text} />}
                    </span>
                    {i.tag === 'edited' && <Badge tone="info">Edited</Badge>}
                    {i.tag === 'new' && <Badge tone="success">New</Badge>}
                  </li>
                ))}
              </ul>
            )}
          </>
        )}
        {acks.length > 0 && revision > 1 && (
          <div className="flex flex-col gap-1" data-debug-id="ticket-view-requirements-readers">
            <Text as="span" role="overline" tone="faint">Who has read rev {revision}</Text>
            <ul className="flex flex-wrap gap-x-4 gap-y-1">
              {acks.map((a) => (
                <li key={a.lease_id} className="inline-flex items-center gap-1.5 text-body-sm">
                  <TicketAgentAvatar name={names.instance(a.holder_instance_id) || 'Agent'} state={a.pending ? 'working' : 'idle'} />
                  <span className="text-primary">{names.instance(a.holder_instance_id) || 'Agent'}</span>
                  <Badge tone={a.pending ? 'info' : 'success'}>{a.pending ? 'Notified · reads at next step' : 'Read'}</Badge>
                </li>
              ))}
            </ul>
          </div>
        )}
        {canEdit && (
          <div>
            <Button size="sm" variant="secondary" leading={<Icon name="pencil" size="sm" />} disabled={masked} title={masked ? 'Unlock your vault to edit' : undefined} onClick={onChange} data-debug-id="ticket-view-requirements-change-btn">
              Change requirements
            </Button>
          </div>
        )}
      </div>
    </section>
  );
}
