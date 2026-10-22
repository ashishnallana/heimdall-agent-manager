import { decryptVaultText, containsVaultArmored, isVaultArmored } from '../../utils/vaultContent.ts';
import type { VaultKeyring } from '../../utils/vaultKeyring.ts';
import { VAULT_LOCKED_MARKER, VAULT_OTHER_VAULT_MARKER } from '../../utils/vaultCrypto.ts';

export type Question = {
  id: string;
  text: string;
  selection_mode?: 'single' | 'multiple';
  options: { id: string; label: string }[];
};
export type QuestionGroup = { version: 1; questions: Question[] };
export type QuestionAnswer = { question_id: string; option_ids?: string[]; custom_text?: string };
export type QuestionSubmission = { version: 1; idempotency_key: string; body: string; answers: QuestionAnswer[] };
const validId = (id: unknown): id is string => typeof id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(id);

export function parseQuestionGroup(metadata: any): QuestionGroup | null {
  const group = metadata?.multi_question;
  if (group?.version !== 1 || !Array.isArray(group.questions) || !group.questions.length || group.questions.length > 12) return null;
  const ids = new Set<string>();
  for (const q of group.questions) {
    if (!q || !validId(q.id) || ids.has(q.id) || typeof q.text !== 'string' || !q.text.trim()) return null;
    ids.add(q.id);
    if (q.selection_mode !== undefined && q.selection_mode !== 'single' && q.selection_mode !== 'multiple') return null;
    if (!Array.isArray(q.options) || !q.options.length || q.options.length > 12) return null;
    const options = new Set<string>();
    for (const o of q.options) {
      if (!o || !validId(o.id) || options.has(o.id) || typeof o.label !== 'string' || !o.label.trim()) return null;
      options.add(o.id);
    }
  }
  return group;
}

/** Authenticate every private label before exposing any of this form. */
export async function decryptQuestionGroup(group: QuestionGroup, key: VaultKeyring | null): Promise<QuestionGroup> {
  const text = async (value: string) => {
    if (!containsVaultArmored(value)) return value;
    if (!key || !isVaultArmored(value)) throw new Error('Unlock Vault to read these questions.');
    const plain = await decryptVaultText(value, key);
    if (plain === VAULT_LOCKED_MARKER || plain === VAULT_OTHER_VAULT_MARKER) throw new Error('Question key is unavailable.');
    return plain;
  };
  return { version: 1, questions: await Promise.all(group.questions.map(async (q) => ({
    ...q, text: await text(q.text),
    options: await Promise.all(q.options.map(async (o) => ({ ...o, label: await text(o.label) }))),
  }))) };
}

export type QuestionDraft = Record<string, { optionIds: string[]; customText: string }>;
export function buildQuestionSubmission(group: QuestionGroup, draft: QuestionDraft, key: string): QuestionSubmission {
  const answers: QuestionAnswer[] = [];
  const summary: string[] = [];
  for (const q of group.questions) {
    const value = draft[q.id];
    const custom = value?.customText.trim() || '';
    const selected = value?.optionIds || [];
    if (!custom && (!selected.length || (q.selection_mode !== 'multiple' && selected.length !== 1))) throw new Error('Answer every question before submitting.');
    if (new TextEncoder().encode(custom).length > 8192) throw new Error('Custom answers must be at most 8192 bytes.');
    if (!custom && (new Set(selected).size !== selected.length || selected.some((id) => !q.options.some((o) => o.id === id)))) throw new Error('Choose a valid answer.');
    answers.push(custom ? { question_id: q.id, custom_text: custom } : { question_id: q.id, option_ids: selected });
    summary.push(`${q.text}\n${custom || q.options.filter((o) => selected.includes(o.id)).map((o) => o.label).join(', ')}`);
  }
  const body = summary.join('\n\n');
  if (new TextEncoder().encode(body).length > 65536) throw new Error('The answer summary is too long.');
  return { version: 1, idempotency_key: key, body, answers };
}
