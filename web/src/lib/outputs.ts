// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Pure helpers of the Outputs & Mapping screen: the output model as the engine stores it (OutputModel.swift),
// geometry for the mapper overlay, blend curve points and display naming.

export interface MapPoint {
  x: number;
  y: number;
}

export interface BlendEdge {
  overlap: number;
  power: number;
  gamma: number;
}

export interface BlendSettings {
  left: BlendEdge;
  right: BlendEdge;
  top: BlendEdge;
  bottom: BlendEdge;
  lift: number;
  liftFeather: number;
}

export interface MeshWarp {
  cols: number;
  rows: number;
  points: MapPoint[];
}

export interface WarpSettings {
  cornerPin: MapPoint[];
  mesh: MeshWarp | null;
}

export interface MaskSettings {
  path: MapPoint[];
  feather: number;
}

export interface SliceConfig {
  id: number;
  canvas: number;
  source: { x: number; y: number; w: number; h: number };
  dest: MapPoint[];
  mask: MaskSettings | null;
  opacity: number;
}

export interface OutputConfig {
  id: number;
  name: string;
  display: { uuid: string; name: string } | null;
  region: { x: number; y: number; w: number; h: number } | null;
  mode: { width: number; height: number; hz: number } | null;
  intensity: number;
  blend: BlendSettings;
  warp: WarpSettings;
  slices: SliceConfig[];
  testPattern: number;
}

export interface CanvasConfig {
  id: number;
  name: string;
  width: number;
  height: number;
  clockMaster: number | null;
}

export interface DisplayDoc {
  uuid: string;
  name: string;
  width: number;
  height: number;
  hz: number;
  main: boolean;
  builtin: boolean;
  modes: { width: number; height: number; hz: number }[];
}

export interface OutputStatusDoc {
  id: number;
  state: 'unassigned' | 'bound' | 'lost';
  display: string | null;
  width: number;
  height: number;
  hz: number;
  master: boolean;
}

export const TEST_PATTERNS = ['Off', 'Grid', 'Colour bars', 'Blend check', 'Output ID', 'Crosshair', 'Grey steps', 'Checkerboard'] as const;
export const EDGES = ['left', 'right', 'top', 'bottom'] as const;
export type Edge = (typeof EDGES)[number];
export type MapperMode = 'cornerPin' | 'mesh' | 'slices' | 'mask';

export const UNIT_QUAD: MapPoint[] = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 1 }];

export function meshIdentity(cols: number, rows: number): MeshWarp {
  const points: MapPoint[] = [];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) points.push({ x: c / (cols - 1), y: r / (rows - 1) });
  return { cols, rows, points };
}

export function clamp01(v: number): number {
  return Math.min(1, Math.max(0, v));
}

/** Pixel size of an output: its region, else its display's size, else 1920×1080. */
export function outputSize(output: OutputConfig, displays: DisplayDoc[]): { w: number; h: number } {
  if (output.region) return { w: output.region.w, h: output.region.h };
  const display = displays.find((d) => d.uuid === output.display?.uuid);
  return display ? { w: display.width, h: display.height } : { w: 1920, h: 1080 };
}

/** "3840 × 2160 @ 60" */
export function modeText(mode: { width: number; height: number; hz: number } | null | undefined): string {
  return mode ? `${mode.width} × ${mode.height} @ ${Number(mode.hz.toFixed(2))}` : '—';
}

export function statusText(status: OutputStatusDoc | undefined, output: OutputConfig): { text: string; tone: 'green' | 'red' | 'faint' } {
  if (!status || status.state === 'unassigned') return { text: output.display ? 'binding…' : 'not assigned to a display', tone: 'faint' };
  if (status.state === 'lost') return { text: `display missing: ${output.display?.name ?? '?'}`, tone: 'red' };
  return { text: `${status.display} · ${status.width} × ${status.height} @ ${Number(status.hz.toFixed(0))}${status.master ? ' · clock master' : ''}`, tone: 'green' };
}

/** The S-curve of DESIGN §9.2 as SVG path points (t from 0 to 1 across the overlap), gamma applied. */
export function blendCurvePath(edge: BlendEdge, width: number, height: number, samples = 48): string {
  const parts: string[] = [];
  for (let i = 0; i <= samples; i++) {
    const t = i / samples;
    const s = t < 0.5 ? 0.5 * Math.pow(2 * t, edge.power) : 1 - 0.5 * Math.pow(2 * (1 - t), edge.power);
    const f = Math.pow(s, 1 / Math.max(0.1, edge.gamma));
    parts.push(`${i === 0 ? 'M' : 'L'}${(t * width).toFixed(1)} ${((1 - f) * height).toFixed(1)}`);
  }
  return parts.join(' ');
}

/** Points of the overlay for a mapper mode, with the JSON pointer each one writes to. */
export function handles(output: OutputConfig, mode: MapperMode, sliceIndex: number): { path: string; point: MapPoint; group: number }[] {
  switch (mode) {
    case 'cornerPin':
      return output.warp.cornerPin.map((point, i) => ({ path: `/warp/cornerPin/${i}`, point, group: 0 }));
    case 'mesh':
      return (output.warp.mesh?.points ?? []).map((point, i) => ({ path: `/warp/mesh/points/${i}`, point, group: 0 }));
    case 'slices':
      return output.slices.flatMap((slice, s) => slice.dest.map((point, i) => ({ path: `/slices/${s}/dest/${i}`, point, group: s })));
    case 'mask': {
      const slice = output.slices[sliceIndex];
      return (slice?.mask?.path ?? []).map((point, i) => ({ path: `/slices/${sliceIndex}/mask/path/${i}`, point, group: sliceIndex }));
    }
  }
}

/** Closed outlines to draw under the handles. */
export function outlines(output: OutputConfig, mode: MapperMode, sliceIndex: number): { points: MapPoint[]; group: number }[] {
  switch (mode) {
    case 'cornerPin':
      return [{ points: output.warp.cornerPin, group: 0 }];
    case 'mesh': {
      const mesh = output.warp.mesh;
      if (!mesh) return [];
      const lines: { points: MapPoint[]; group: number }[] = [];
      for (let r = 0; r < mesh.rows; r++) lines.push({ points: mesh.points.slice(r * mesh.cols, (r + 1) * mesh.cols), group: 0 });
      for (let c = 0; c < mesh.cols; c++) lines.push({ points: Array.from({ length: mesh.rows }, (_, r) => mesh.points[r * mesh.cols + c]!), group: 0 });
      return lines;
    }
    case 'slices':
      return output.slices.map((slice, s) => ({ points: slice.dest, group: s }));
    case 'mask': {
      const slice = output.slices[sliceIndex];
      return slice?.mask ? [{ points: slice.mask.path, group: sliceIndex }] : [];
    }
  }
}

/** A mask inset 10 % on every side, the starting point for a new mask. */
export function defaultMask(): MaskSettings {
  return { path: [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.1 }, { x: 0.9, y: 0.9 }, { x: 0.1, y: 0.9 }], feather: 0 };
}

/** Inserts a point halfway between `index` and the next one (wrapping). */
export function insertPoint(path: MapPoint[], index: number): MapPoint[] {
  const a = path[index] ?? path[0]!;
  const b = path[(index + 1) % path.length]!;
  const next = [...path];
  next.splice(index + 1, 0, { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
  return next;
}

export function nextSliceId(output: OutputConfig): number {
  return Math.max(0, ...output.slices.map((s) => s.id)) + 1;
}

/** Nudge in pixels of the output, as a normalized delta. */
export function nudge(point: MapPoint, dx: number, dy: number, size: { w: number; h: number }): MapPoint {
  return { x: clamp01(point.x + dx / size.w), y: clamp01(point.y + dy / size.h) };
}
