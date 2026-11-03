/**
 * EmptyState — the "nothing here" placeholder.
 * ------------------------------------------------------------------
 * Purpose: one dashed-card empty/placeholder dialect (EL-065/066), merging the
 * `Empty` helpers and the bare centered-text variants into a single block for
 * "nothing yet" / "no matches" / "no results" surfaces.
 *
 * NOT for: a loading state (use `Spinner`), an error banner (use `Alert`), or a
 * populated list.
 *
 * Layer: composite. Spec: `docs/ui-audit/04-component-catalogue.md` › EmptyState.
 *
 * API: `icon?` · `title?` · `description?` · `action?` (a Button/Link) ·
 * `children?` (free body when a title/description doesn't fit). Give at least a
 * `title` or `description`/`children`. Native attrs (`data-*`, …) pass through.
 *
 * Accessibility: a plain container; the icon is decorative (`aria-hidden`). Any
 * action is a real focusable control the caller supplies.
 *
 * Tokens only: border/radius/type/color via tokens. No raw values.
 *
 * Variant `page` (opt-in; default `card` is unchanged): a whole-page blocked
 * state such as "No bridge is online" — no dashed card, centred column capped at
 * 560px, 24px rhythm, `media` (e.g. a 56px `IconWell`) in place of the glyph,
 * and `children` laid out as full-width blocks (panels, action rows, notes)
 * rather than a muted text run. Pass a heading element as `title` (e.g.
 * `<Text as="h1" role="headline">`).
 *
 * Escape hatch: `className` merges onto the root.
 */
import React from 'react';
import { Icon, type IconName } from '../primitives/Icon';
import type { RootClassNameProps } from '../types';

export interface EmptyStateProps
  extends Omit<React.HTMLAttributes<HTMLDivElement>, 'title' | 'className'>,
    RootClassNameProps {
  /** Decorative glyph shown above the title. */
  icon?: IconName;
  /** Primary line. */
  title?: React.ReactNode;
  /** Secondary line. */
  description?: React.ReactNode;
  /** A call to action (e.g. a Button/Link). */
  action?: React.ReactNode;
  /** Free body when title/description are not enough (the bare-text variant). */
  children?: React.ReactNode;
  /** `card` (default): the dashed placeholder card. `page`: a full-page blocked state. */
  variant?: 'card' | 'page';
  /** Decorative lead element (e.g. an `IconWell`); replaces `icon`. */
  media?: React.ReactNode;
}

export const EmptyState: React.FC<EmptyStateProps> = ({
  icon,
  title,
  description,
  action,
  className,
  children,
  variant = 'card',
  media,
  ...rest
}) => {
  if (variant === 'page') {
    const pageClassName = ['mx-auto flex w-full max-w-[560px] flex-col items-center gap-6 text-center', className ?? '']
      .filter(Boolean)
      .join(' ')
      .trim();
    return (
      <div {...rest} data-empty-state="page" className={pageClassName}>
        {media ?? (icon ? <Icon name={icon} size="xl" className="text-faint" /> : null)}
        {title || description ? (
          <div className="flex flex-col items-center gap-2">
            {title ? <div className="text-primary">{title}</div> : null}
            {description ? (
              <div className="max-w-[460px] text-[length:var(--text-body-sm-size)] text-muted">{description}</div>
            ) : null}
          </div>
        ) : null}
        {children ? <div className="flex w-full flex-col items-center gap-6">{children}</div> : null}
        {action ? <div className="flex w-full justify-center">{action}</div> : null}
      </div>
    );
  }
  const rootClassName = [
    'flex flex-col items-center justify-center gap-2 rounded-[var(--radius-lg)] border border-dashed',
    'border-subtle bg-neutral-soft px-6 py-12 text-center',
    className ?? '',
  ]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  return (
    <div {...rest} className={rootClassName}>
      {media ?? (icon ? <Icon name={icon} size="lg" className="text-faint" /> : null)}
      {title ? <div className="text-title text-primary">{title}</div> : null}
      {description ? (
        <div className="text-[length:var(--text-body-sm-size)] text-muted">{description}</div>
      ) : null}
      {children ? (
        <div className="text-[length:var(--text-body-sm-size)] text-muted">{children}</div>
      ) : null}
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  );
};

export default EmptyState;
