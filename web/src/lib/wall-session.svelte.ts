// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// What the projector-wall wizard and the wall panels have open, kept outside the components so it is shared by them
// and survives a switch to Warp & Slices (the Grid step of the seam check sends the user there); leaving the Outputs
// screen ends the wizard and the seam check. The test patterns they put on the outputs go back to each output's own
// when the wizard or the check ends. Until the engine has taken every one of those, the output keeps its saved
// pattern here and in sessionStorage (so a reloaded page can still give it back), and the wizard or check stays open.
import { app, can, cmd, toastUndo } from './state.svelte';
import {
  PATTERN, SEAM_STEPS, editDraft, freeOutputs, newDraft, patternChange, patternRestore, savedFrom, unrestored, wallArgs,
  type Control, type WallConfig, type WizardDraft,
} from './walls';

export type Pick = { wall: number } & ({ kind: 'seam'; a: number; b: number } | { kind: 'projector'; output: number } | { kind: 'geometry' });

const STORE = 'fanous.wallPatterns';
function stored(): string | null {
  try {
    return sessionStorage.getItem(STORE);
  } catch {
    return null;
  }
}

export const wallUI = $state({
  wizard: null as WizardDraft | null,
  /** a wall.add or wall.set of the wizard is on its way */
  busy: false,
  /** what a wall panel shows below its mini-map */
  pick: null as Pick | null,
  /** the control a seam-check hint opened: drawn highlighted */
  focus: null as Control | null,
  /** a hint of the current seam-check step (its index) waiting for the user to tap a seam or projector on the mini-map */
  hint: null as number | null,
  check: null as { wall: number; step: number } | null,
  /** each output's test pattern from before the wizard or the seam check put one on it */
  saved: {} as Record<number, number>,
  /** saved patterns a reloaded page left behind (sessionStorage): the Outputs screen offers to give them back */
  leftover: savedFrom(stored()),
  /** the last give-back was not taken for every output: those keep their saved pattern */
  stuck: false,
});

function persist(): void {
  try {
    if (Object.keys(wallUI.saved).length === 0) sessionStorage.removeItem(STORE);
    else sessionStorage.setItem(STORE, JSON.stringify({ wall: wallUI.check?.wall ?? wallUI.wizard?.edit ?? null, saved: wallUI.saved }));
  } catch {
    // blocked storage: a reload then forgets the saved patterns
  }
}

/** A reloaded page's saved patterns join this page's: theirs are the outputs' own. */
function adoptLeftover(): void {
  if (!wallUI.leftover) return;
  wallUI.saved = { ...wallUI.saved, ...wallUI.leftover.saved };
  wallUI.leftover = null;
}

/** Why test patterns cannot be given back now (the engine would refuse), or null. */
function blocked(): string | null {
  if (!can('programmer')) return 'Only the programmer role can give the outputs their own test pattern back.';
  return app.project.showLock ? 'Unlock the show to give the outputs their own test pattern back.' : null;
}

/** The caption while some outputs still wait for their own test pattern, or null. */
export function stuckText(): string | null {
  return wallUI.stuck ? (blocked() ?? 'Some outputs did not get their own test pattern back. Try again.') : null;
}

/** The ids the engine took. */
async function send(set: { id: number; pattern: number }[]): Promise<number[]> {
  const done = await Promise.all(set.map(({ id, pattern }) => cmd('output.set', { id, path: '/testPattern', value: pattern }).then((r) => (r === undefined ? null : id))));
  return done.filter((id): id is number => id !== null);
}

async function show(ids: number[], pattern: number): Promise<void> {
  adoptLeftover();
  const change = patternChange(app.project.outputs, ids, pattern, wallUI.saved);
  wallUI.saved = change.saved;
  persist();
  if (!blocked()) await send(change.set);
}

/** Every saved output gets its own pattern back, except those in `keep`; false when the engine did not take them all. */
async function restore(keep: number[] = []): Promise<boolean> {
  adoptLeftover();
  const back = patternRestore(app.project.outputs, wallUI.saved, keep);
  const ok = blocked() ? [] : await send(back.set);
  wallUI.saved = unrestored(back.saved, back.set, ok);
  wallUI.stuck = ok.length < back.set.length;
  persist();
  return !wallUI.stuck;
}

/** Step 1 of the wizard: every free output on a display shows its Output ID (WallWizard runs it again when outputs are
 * bound or unbound meanwhile). */
export async function showIDs(draft: WizardDraft): Promise<void> {
  const bound = new Set(app.live.outputs.filter((s) => s.state === 'bound').map((s) => s.id));
  const ids = freeOutputs(app.project.outputs, app.project.walls, draft.edit ?? undefined).map((o) => o.id).filter((id) => bound.has(id));
  if (ids.length) await show(ids, PATTERN.outputID);
}

/** New projector wall, or Edit layout… of `wall`. */
export async function startWizard(wall?: WallConfig): Promise<void> {
  if (!(await endCheck())) return;
  wallUI.pick = null;
  wallUI.wizard = wall ? editDraft(wall) : newDraft(app.project.canvases[0]?.id ?? 1);
}

export function wizardBack(): void {
  if (wallUI.wizard) wallUI.wizard.step = 1;
}

export async function cancelWizard(): Promise<void> {
  if (await restore()) wallUI.wizard = null;
}

/** Blend check on the wall's outputs, then wall.add (or wall.set), so one Undo takes the wall back; the panel opens on
 * the seam check. A refusal keeps the wizard open (the banner says why). */
export async function applyWizard(): Promise<void> {
  const draft = wallUI.wizard;
  if (!draft?.grid || wallUI.busy) return;
  wallUI.busy = true;
  try {
    const args = wallArgs({ ...draft, grid: draft.grid });
    await restore(draft.order);
    await show(draft.order, PATTERN.blendCheck);
    const result = draft.edit !== null ? await cmd('wall.set', { ...args, id: draft.edit }) : await cmd('wall.add', { ...args, overlap: args.overlap! });
    if (result === undefined) return;
    wallUI.wizard = null;
    wallUI.check = { wall: draft.edit ?? Number(result), step: SEAM_STEPS.findIndex((s) => s.pattern === PATTERN.blendCheck) };
    persist();
  } finally {
    wallUI.busy = false;
  }
}

export async function startCheck(wall: WallConfig): Promise<void> {
  if (wallUI.check && wallUI.check.wall !== wall.id && !(await endCheck())) return;
  await stepCheck(wall, 0);
}

export async function stepCheck(wall: WallConfig, step: number): Promise<void> {
  const s = SEAM_STEPS[step];
  if (!s) return;
  wallUI.check = { wall: wall.id, step };
  wallUI.hint = null;
  await show(wall.outputs, s.pattern);
}

/** Ends the seam check; it stays open (false) while an output did not get its own pattern back. */
export async function endCheck(): Promise<boolean> {
  if (!wallUI.check) return true;
  wallUI.hint = null;
  if (!(await restore())) return false;
  wallUI.check = null;
  return true;
}

/** "Give the test patterns back" on the Outputs screen: a reloaded page's, or a check whose wall went. */
export async function giveBack(): Promise<void> {
  if (wallUI.check) await endCheck();
  else await restore();
}

export function keepLeftover(): void {
  wallUI.leftover = null;
  persist();
}

/** Selects a seam, a projector or the geometry on a wall's panel (null: closes it). */
export function pick(next: Pick | null, focus: Control | null = null): void {
  wallUI.pick = next;
  wallUI.focus = focus;
  wallUI.hint = null;
}

/** Remove wall: the outputs keep their slices and blend edges as they are now; Undo brings the wall back. */
export async function removeWall(wall: WallConfig): Promise<void> {
  if (wallUI.check?.wall === wall.id && !(await endCheck())) return;
  if (wallUI.pick?.wall === wall.id) pick(null);
  if ((await cmd('wall.remove', { id: wall.id })) !== undefined) toastUndo(`${wall.name} removed. Its outputs keep their slices and blend edges.`);
}
