import React from 'react';
import { Icon } from '@ui';
import type { ReviewVerdict } from './taskActions';

/** A reviewer's verdict: ✓ approved, ✗ changes requested, a clock while still waiting. */
export function ReviewVoteMark({ verdict, waiting = true }: { verdict?: ReviewVerdict; waiting?: boolean }) {
  if (verdict === 'approve') return <Icon name="check" size={12} className="text-success" title="Approved" />;
  if (verdict === 'request_changes') return <Icon name="close" size={12} className="text-danger" title="Requested changes" />;
  return waiting ? <Icon name="clock" size={12} className="text-faint" title="Waiting for review" /> : null;
}
