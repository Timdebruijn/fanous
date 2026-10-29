// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// What the projector-wall wizard and the wall panels have open, kept outside the components so it survives a visit to
// Warp & Slices or another screen (the Grid step of the seam check sends the user there). The test patterns they put
// on the outputs go back to each output's own when the wizard or the seam check ends.
import { app, cmd, toastUndo } from './state.svelte';
import { PATTERN, SEAM_STEPS, editDraft, freeOutputs, newDraft, patternChange, patternRestore, wallArgs, type Control, type WallConfig, type WizardDraft } from './walls';

export type Pick = { wall: number } & ({ kind: 'seam'; a: number; b: number } | { kind: 'projector'; output: number } | { kind: 'geometry' });

export const wallUI = $state({
  wizard: null as WizardDraft | null,
  /** what a wall panel shows below its mini-map */
  pick: null as Pick | null,
  /** the control a seam-check hint opened: drawn highlighted */
  focus: null as Control | null,
  /** a hint of the current seam-check step (its index) waiting for the user to tap a seam or projector on the mini-map */
  hint: null as number | null,
  check: null as { wall: number; step: number } | null,
  /** each output's test pattern from before the wizard or the seam check put one on it */
  saved: {} as Record<number, number>,
});

const walls = () => app.project.walls ?? [];

async function send(set: { id: number; pattern: number }[]): Promise<void> {
  await Promise.all(set.map(({ id, pattern }) => cmd('output.set', { id, path: '/testPattern', value: pattern })));
}

async function show(ids: number[], pattern: number): Promise<void> {
  const change = patternChange(app.project.outputs, ids, pattern, wallUI.saved);
  wallUI.saved = change.saved;
  await send(change.set);
}

/** Every saved output gets its own pattern back, except those in `keep`. */
async function restore(keep: number[] = []): Promise<void> {
  const back = patternRestore(app.project.outputs, wallUI.saved, keep);
  wallUI.saved = back.saved;
  await send(back.set);
}

/** Step 1 of the wizard: every free output that is on a display shows its Output ID. */
async function showIDs(draft: WizardDraft): Promise<void> {
  const bound = new Set(app.live.outputs.filter((s) => s.state === 'bound').map((s) => s.id));
  await show(freeOutputs(app.project.outputs, walls(), draft.edit ?? undefined).map((o) => o.id).filter((id) => bound.has(id)), PATTERN.outputID);
}

/** New projector wall, or Edit layout… of `wall`. */
export async function startWizard(wall?: WallConfig): Promise<void> {
  await endCheck();
  wallUI.pick = null;
  const draft = wall ? editDraft(wall) : newDraft(app.project.canvases[0]?.id ?? 1);
  wallUI.wizard = draft;
  await showIDs(draft);
}

export async function wizardBack(): Promise<void> {
  if (!wallUI.wizard) return;
  wallUI.wizard.step = 1;
  await showIDs(wallUI.wizard);
}

export async function cancelWizard(): Promise<void> {
  wallUI.wizard = null;
  await restore();
}

/** Step 3: Blend check on the wall's outputs, then wall.add (or wall.set), so one Undo takes the wall back; the panel
 * opens on the seam check. A refusal keeps the wizard open (the banner says why). */
export async function applyWizard(): Promise<void> {
  const draft = wallUI.wizard;
  if (!draft?.grid) return;
  const args = wallArgs({ ...draft, grid: draft.grid });
  await restore(draft.order);
  await show(draft.order, PATTERN.blendCheck);
  const result = draft.edit !== null ? await cmd('wall.set', { ...args, id: draft.edit }) : await cmd('wall.add', { ...args, overlap: args.overlap! });
  if (result === undefined) return;
  const id = draft.edit ?? Number(result);
  wallUI.wizard = null;
  wallUI.check = { wall: id, step: SEAM_STEPS.findIndex((s) => s.pattern === PATTERN.blendCheck) };
}

export async function startCheck(wall: WallConfig): Promise<void> {
  if (wallUI.check && wallUI.check.wall !== wall.id) await endCheck();
  await stepCheck(wall, 0);
}

export async function stepCheck(wall: WallConfig, step: number): Promise<void> {
  const s = SEAM_STEPS[step];
  if (!s) return;
  wallUI.check = { wall: wall.id, step };
  wallUI.hint = null;
  await show(wall.outputs, s.pattern);
}

export async function endCheck(): Promise<void> {
  if (!wallUI.check) return;
  wallUI.check = null;
  wallUI.hint = null;
  await restore();
}

/** Selects a seam, a projector or the geometry on a wall's panel (null: closes it). */
export function pick(next: Pick | null, focus: Control | null = null): void {
  wallUI.pick = next;
  wallUI.focus = focus;
  wallUI.hint = null;
}

/** Remove wall: the outputs keep their slices and blend edges as they are now; Undo brings the wall back. */
export async function removeWall(wall: WallConfig): Promise<void> {
  if (wallUI.check?.wall === wall.id) await endCheck();
  if (wallUI.pick?.wall === wall.id) pick(null);
  if ((await cmd('wall.remove', { id: wall.id })) !== undefined) toastUndo(`${wall.name} removed. Its outputs keep their slices and blend edges.`);
}
