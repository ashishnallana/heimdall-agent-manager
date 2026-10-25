import React from 'react';

/** One grey bar; widths are fixed so the placeholder does not jump. */
function Bar({ className }: { className: string }) {
  return <span aria-hidden="true" className={`block rounded bg-neutral-soft ${className}`} />;
}

/**
 * The board's shape while a chain loads: header row, progress bar and a few
 * cards, so the layout is in place before the data arrives. The pulse is off
 * under prefers-reduced-motion.
 */
export function TaskBoardSkeleton({ cards = 3, stepper = false }: { cards?: number; stepper?: boolean }) {
  return (
    <div data-debug-id="task-board-skeleton" role="status" aria-label="Loading tickets" className="flex flex-col gap-5 p-4 motion-safe:animate-pulse sm:p-5">
      <div className="space-y-3">
        <div className="flex items-center gap-2">
          <Bar className="h-7 w-32 rounded-full" />
          <span className="flex-1" />
          <Bar className="h-7 w-7 rounded-md" />
          <Bar className="h-7 w-24 rounded-full" />
        </div>
        <Bar className="h-1.5 w-full rounded-full" />
        <Bar className="h-3 w-2/3" />
      </div>
      <Bar className="h-3 w-24" />
      <div className="flex flex-col gap-2">
        {Array.from({ length: cards }, (_, i) => (
          <div key={i} className="flex gap-3">
            {stepper && <Bar className="mt-1 h-6 w-6 shrink-0 rounded-full" />}
            <div className="relative flex-1 space-y-2.5 rounded-lg border border-subtle bg-surface py-3 pl-5 pr-3">
              <span aria-hidden="true" className="absolute inset-y-0 left-0 w-[3px] rounded-l-lg bg-neutral-soft" />
              <Bar className={`h-4 ${i % 2 ? 'w-1/2' : 'w-3/4'}`} />
              <Bar className="h-4 w-20 rounded-full" />
              <Bar className="h-3 w-5/6" />
              <div className="flex gap-3">
                <Bar className="h-5 w-24 rounded-full" />
                <Bar className="h-5 w-16 rounded-full" />
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export default TaskBoardSkeleton;
