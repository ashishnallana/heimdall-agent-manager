import React, { useState } from 'react';
import { useUpdateTaskChainFleetMutation, TaskChainFleet } from '../../api/endpoints/taskChains';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';

export interface FleetPlacementSectionProps {
  chainId: string;
  chainFleets: TaskChainFleet[];
  onOpenDrawer?: () => void;
  className?: string;
}

export const FleetPlacementSection: React.FC<FleetPlacementSectionProps> = ({
  chainId,
  chainFleets = [],
  onOpenDrawer,
  className = '',
}) => {
  const [collapsed, setCollapsed] = useState(false);
  const [updateFleet] = useUpdateTaskChainFleetMutation();
  const { data: bridgesData } = useListBridgesQuery();
  const bridges: any[] = bridgesData?.bridges || [];

  const onlineBridges = bridges.filter((b) => b.status === 'online' || b.connected);

  const handleFieldChange = async (
    agentId: string,
    field: 'bridge_id' | 'provider' | 'model' | 'capacity',
    value: string | number
  ) => {
    try {
      const current = chainFleets.find((f) => f.agent_id === agentId);
      if (!current) return;
      await updateFleet({
        chainId,
        agentId,
        capacity: field === 'capacity' ? Number(value) : current.capacity || 1,
        [field]: field === 'capacity' ? Number(value) : value,
      }).unwrap();
    } catch (err) {
      console.error('Failed to update fleet row placement', err);
    }
  };

  return (
    <div
      data-debug-id="fleet-placement-section"
      className={`rounded-2xl border border-subtle bg-surface text-left transition-all ${className}`}
    >
      <header
        role="button"
        tabIndex={0}
        onClick={() => setCollapsed(!collapsed)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            setCollapsed(!collapsed);
          }
        }}
        className="flex items-center justify-between px-4 py-3 cursor-pointer select-none border-b border-subtle/50 hover:bg-neutral-soft/50 rounded-t-2xl transition-colors"
      >
        <div className="flex items-center gap-2">
          <span className="h-2 w-2 rounded-full bg-accent shrink-0" />
          <span className="text-xs font-bold uppercase tracking-wider text-primary">
            Fleet Placement
          </span>
          <span className="font-mono text-[11px] text-muted">
            {chainFleets.length} {chainFleets.length === 1 ? 'row' : 'rows'} ·{' '}
            {onlineBridges.length}/{bridges.length || 1} bridges online
          </span>
        </div>
        <div className="flex items-center gap-2">
          {onOpenDrawer && (
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                onOpenDrawer();
              }}
              className="rounded bg-neutral-soft px-2 py-0.5 text-[11px] font-semibold text-primary hover:bg-surface-raised transition-colors"
            >
              Manage Fleet
            </button>
          )}
          <span className="text-muted text-xs font-mono">{collapsed ? '▸' : '▾'}</span>
        </div>
      </header>

      {!collapsed && (
        <div className="p-4 space-y-3">
          {chainFleets.length === 0 ? (
            <div className="rounded-xl border border-dashed border-subtle p-4 text-center text-xs text-muted">
              No fleet rows configured. Agents will run on the chain's default coordinator placement.
            </div>
          ) : (
            chainFleets.map((f) => {
              const roles = f.roles || ['worker'];
              const isBridgeOffline = Boolean(
                f.bridge_id &&
                  bridges.length > 0 &&
                  !bridges.some((b) => b.id === f.bridge_id && (b.status === 'online' || b.connected))
              );

              return (
                <article
                  key={f.agent_id}
                  data-debug-id={`fleet-row-${f.agent_id}`}
                  className="rounded-xl border border-subtle bg-surface-raised p-3 flex flex-col gap-2.5"
                >
                  {/* Top line: agent_id, roles badges, capacity */}
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <span className="font-mono text-xs font-semibold text-primary">
                        {f.agent_id}
                      </span>
                      {roles.map((r) => (
                        <span
                          key={r}
                          className={`rounded px-1.5 py-0.5 text-[10px] font-mono font-medium ${
                            r === 'worker'
                              ? 'bg-accent-soft text-accent border border-accent/20'
                              : 'bg-info-soft text-info border border-info/20'
                          }`}
                        >
                          {r}
                        </span>
                      ))}
                    </div>

                    <span
                      className={`font-mono text-[10px] px-1.5 py-0.5 rounded ${
                        (f.active_count || 0) > 0
                          ? 'bg-success-soft text-success'
                          : 'bg-neutral-soft text-muted'
                      }`}
                    >
                      {f.active_count || 0}/{f.capacity || 1} live
                    </span>
                  </div>

                  {/* Inline quick placement controls */}
                  <div className="grid grid-cols-2 gap-2 sm:grid-cols-4 text-[11px]">
                    <label className="flex flex-col gap-1 text-muted">
                      <span>bridge</span>
                      <select
                        value={f.bridge_id || ''}
                        onChange={(e) => handleFieldChange(f.agent_id, 'bridge_id', e.target.value)}
                        className="rounded border border-subtle bg-surface px-2 py-1 text-primary text-xs outline-none focus:border-accent"
                      >
                        <option value="">— default —</option>
                        {bridges.map((b) => (
                          <option key={b.id} value={b.id}>
                            {b.name || b.id} {b.status === 'online' || b.connected ? '' : '(offline)'}
                          </option>
                        ))}
                      </select>
                    </label>

                    <label className="flex flex-col gap-1 text-muted">
                      <span>provider</span>
                      <input
                        type="text"
                        value={f.provider || ''}
                        placeholder="default"
                        onChange={(e) => handleFieldChange(f.agent_id, 'provider', e.target.value)}
                        className="rounded border border-subtle bg-surface px-2 py-1 text-primary text-xs outline-none focus:border-accent"
                      />
                    </label>

                    <label className="flex flex-col gap-1 text-muted">
                      <span>model</span>
                      <input
                        type="text"
                        value={f.model || ''}
                        placeholder="default"
                        onChange={(e) => handleFieldChange(f.agent_id, 'model', e.target.value)}
                        className="rounded border border-subtle bg-surface px-2 py-1 text-primary text-xs outline-none focus:border-accent"
                      />
                    </label>

                    <label className="flex flex-col gap-1 text-muted">
                      <span>capacity</span>
                      <select
                        value={f.capacity || 1}
                        onChange={(e) => handleFieldChange(f.agent_id, 'capacity', Number(e.target.value))}
                        className="rounded border border-subtle bg-surface px-2 py-1 text-primary text-xs outline-none focus:border-accent"
                      >
                        <option value={1}>1</option>
                        <option value={2}>2</option>
                        <option value={3}>3</option>
                        <option value={5}>5</option>
                      </select>
                    </label>
                  </div>

                  {/* Summary note */}
                  <div className="text-[11px] font-mono">
                    {isBridgeOffline ? (
                      <span className="text-danger font-semibold">
                        ⚠ bridge {f.bridge_id} is offline — grants to this fleet row will be held
                      </span>
                    ) : (
                      <span className="text-faint">
                        next grant runs on {f.bridge_id || 'fleet default'} ·{' '}
                        {f.provider || 'default'}/{f.model || 'default'}
                      </span>
                    )}
                  </div>
                </article>
              );
            })
          )}
        </div>
      )}
    </div>
  );
};

export default FleetPlacementSection;
