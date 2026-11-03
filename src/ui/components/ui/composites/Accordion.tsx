/**
 * Accordion — role-correct disclosure sections.
 * ------------------------------------------------------------------
 * Purpose: one collapsible-section dialect (EL-062) with the disclosure a11y that
 * the app's hand-rolled toggles were missing — a header `<button>` with
 * `aria-expanded` + `aria-controls`, and a labelled region. Fixes the "toggles
 * without aria-expanded" defect.
 *
 * NOT for: tabbed content (use `Tabs`), a menu (`Menu`), or a modal.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › Accordion.
 *
 * API (composition): `<Accordion type>` wrapping `<Accordion.Item value title>`
 * sections. `type="single"` (default) keeps one open; `type="multiple"` lets any
 * number open. Uncontrolled via `defaultValue` or controlled via `value`/`onChange`.
 *
 * Accessibility (built in): each header is a `<button aria-expanded aria-controls>`
 * with a focus-visible ring; each panel is a labelled region, `hidden` when
 * collapsed. A rotating chevron reflects state (aria-hidden).
 *
 * Tokens only: border/radius/type/motion via tokens. No raw values.
 */
import React, { createContext, useContext, useId, useMemo, useState } from 'react';
import { Icon } from '../primitives/Icon';
import type { RootClassNameProps } from '../types';

type AccordionType = 'single' | 'multiple';

interface AccordionCtx {
  openValues: string[];
  toggle: (value: string) => void;
  baseId: string;
}
const AccordionContext = createContext<AccordionCtx | null>(null);
const useAccordion = () => {
  const ctx = useContext(AccordionContext);
  if (!ctx) throw new Error('Accordion.Item must be used inside <Accordion>');
  return ctx;
};

export interface AccordionProps extends RootClassNameProps {
  /** `single` (default) keeps one section open; `multiple` allows many. */
  type?: AccordionType;
  /** Uncontrolled initial open value(s). */
  defaultValue?: string | string[];
  /** Controlled open value(s). */
  value?: string | string[];
  /** Fired with the next open value(s). */
  onChange?: (value: string[]) => void;
  children?: React.ReactNode;
}

interface AccordionComponent extends React.FC<AccordionProps> {
  Item: typeof AccordionItem;
}

const toArray = (v: string | string[] | undefined): string[] =>
  v == null ? [] : Array.isArray(v) ? v : [v];

const AccordionRoot: React.FC<AccordionProps> = ({
  type = 'single',
  defaultValue,
  value: valueProp,
  onChange,
  className,
  children,
}) => {
  const isControlled = valueProp !== undefined;
  const [openState, setOpenState] = useState<string[]>(toArray(defaultValue));
  const openValues = isControlled ? toArray(valueProp) : openState;
  const baseId = useId();

  const toggle = (value: string) => {
    const isOpen = openValues.includes(value);
    let next: string[];
    if (type === 'single') next = isOpen ? [] : [value];
    else next = isOpen ? openValues.filter((v) => v !== value) : [...openValues, value];
    if (!isControlled) setOpenState(next);
    onChange?.(next);
  };

  const ctx = useMemo(() => ({ openValues, toggle, baseId }), [openValues, baseId]);

  return (
    <AccordionContext.Provider value={ctx}>
      <div className={['divide-y divide-subtle border-y border-subtle', className].filter(Boolean).join(' ')}>
        {children}
      </div>
    </AccordionContext.Provider>
  );
};

export interface AccordionItemProps extends RootClassNameProps {
  /** Stable value identifying this section. */
  value: string;
  /** The header content. */
  title: React.ReactNode;
  children?: React.ReactNode;
  /** `data-debug-id` of the header button. */
  debugId?: string;
}

/** A single collapsible section. */
export const AccordionItem: React.FC<AccordionItemProps> = ({ value, title, className, children, debugId }) => {
  const { openValues, toggle, baseId } = useAccordion();
  const open = openValues.includes(value);
  const headerId = `${baseId}-h-${value}`;
  const panelId = `${baseId}-p-${value}`;

  return (
    <div className={className}>
      <h3 className="m-0">
        <button
          type="button"
          data-debug-id={debugId}
          id={headerId}
          aria-expanded={open}
          aria-controls={panelId}
          onClick={() => toggle(value)}
          className="flex w-full items-center justify-between gap-3 py-3 text-left text-[length:var(--text-body-size)] font-medium text-primary outline-none focus-visible:shadow-focus focus-visible:outline-none"
        >
          <span className="min-w-0">{title}</span>
          <Icon
            name="chevron-down"
            size="sm"
            className={['shrink-0 text-muted transition-transform duration-fast', open ? 'rotate-180' : ''].join(' ')}
          />
        </button>
      </h3>
      <div id={panelId} role="region" aria-labelledby={headerId} hidden={!open} className="pb-3">
        {open ? children : null}
      </div>
    </div>
  );
};

export const Accordion = AccordionRoot as AccordionComponent;
Accordion.Item = AccordionItem;

export default Accordion;
