// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Port of WarpMath (Sources/FanousCore/Mapping/MappingMath.swift): the editor draws slice, mask and mesh handles
// where the engine puts them on screen, i.e. through the mesh and the corner-pin homography, and maps the
// pointer back through the inverse when a handle is dragged.
import type { MapPoint, MapperMode, MeshWarp, OutputConfig, WarpSettings } from './outputs';

export type Mat3 = number[];
const IDENTITY: Mat3 = [1, 0, 0, 0, 1, 0, 0, 0, 1];

/** Heckbert's square-to-quad homography (row-major 3×3); identity for a degenerate quad. */
export function homography(quad: MapPoint[]): Mat3 {
  if (quad.length !== 4) return IDENTITY;
  const [p0, p1, p2, p3] = quad as [MapPoint, MapPoint, MapPoint, MapPoint];
  const sx = p0.x - p1.x + p2.x - p3.x;
  const sy = p0.y - p1.y + p2.y - p3.y;
  let g = 0;
  let h = 0;
  if (Math.abs(sx) > 1e-12 || Math.abs(sy) > 1e-12) {
    const dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dy1 = p1.y - p2.y, dy2 = p3.y - p2.y;
    const det = dx1 * dy2 - dx2 * dy1;
    if (Math.abs(det) <= 1e-12) return IDENTITY;
    g = (sx * dy2 - dx2 * sy) / det;
    h = (dx1 * sy - sx * dy1) / det;
  }
  return [p1.x - p0.x + g * p1.x, p3.x - p0.x + h * p3.x, p0.x, p1.y - p0.y + g * p1.y, p3.y - p0.y + h * p3.y, p0.y, g, h, 1];
}

export function applyHomography(m: Mat3, u: number, v: number): MapPoint {
  const w = m[6]! * u + m[7]! * v + m[8]!;
  const s = Math.abs(w) < 1e-12 ? 1 : 1 / w;
  return { x: (m[0]! * u + m[1]! * v + m[2]!) * s, y: (m[3]! * u + m[4]! * v + m[5]!) * s };
}

/** Inverse of a 3×3 (adjugate); null when singular. */
export function invert(m: Mat3): Mat3 | null {
  const [a, b, c, d, e, f, g, h, i] = m as [number, number, number, number, number, number, number, number, number];
  const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (Math.abs(det) < 1e-12) return null;
  return [A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d].map((x) => x / det);
}

function catmullRom(values: number[], t: number): number {
  const n = values.length;
  if (n < 2) return values[0] ?? 0;
  const x = Math.min(Math.max(t, 0), 1) * (n - 1);
  const i = Math.min(n - 2, Math.floor(x));
  const f = x - i;
  const p1 = values[i]!, p2 = values[i + 1]!;
  const p0 = i > 0 ? values[i - 1]! : 2 * p1 - p2;
  const p3 = i + 2 < n ? values[i + 2]! : 2 * p2 - p1;
  return 0.5 * (2 * p1 + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f);
}

export function meshPoint(mesh: MeshWarp, u: number, v: number): MapPoint {
  if (mesh.cols < 2 || mesh.rows < 2 || mesh.points.length !== mesh.cols * mesh.rows) return { x: u, y: v };
  const xs: number[] = [];
  const ys: number[] = [];
  for (let r = 0; r < mesh.rows; r++) {
    const row = mesh.points.slice(r * mesh.cols, (r + 1) * mesh.cols);
    xs.push(catmullRom(row.map((p) => p.x), u));
    ys.push(catmullRom(row.map((p) => p.y), u));
  }
  return { x: catmullRom(xs, v), y: catmullRom(ys, v) };
}

/** A `cols × rows` mesh whose points lie on the surface of `mesh` (flat when there is none), so a density change
 *  keeps the shape. Points shared by both grids (3 → 5, 5 → 9 …) keep their exact position. */
export function resampleMesh(mesh: MeshWarp | null | undefined, cols: number, rows: number): MeshWarp {
  const points: MapPoint[] = [];
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const u = c / (cols - 1), v = r / (rows - 1);
      points.push(mesh ? meshPoint(mesh, u, v) : { x: u, y: v });
    }
  }
  return { cols, rows, points };
}

/** Where the undistorted point (u, v) lands on the output: mesh first (if any), then the corner pin. */
export function warped(warp: WarpSettings, u: number, v: number, h: Mat3 = homography(warp.cornerPin)): MapPoint {
  const p = warp.mesh ? meshPoint(warp.mesh, u, v) : { x: u, y: v };
  return applyHomography(h, p.x, p.y);
}

/** The (u, v) that `warped` sends to `target`: Newton steps with a finite-difference Jacobian, starting at the target. */
export function unwarp(warp: WarpSettings, target: MapPoint): MapPoint {
  const h = homography(warp.cornerPin);
  if (!warp.mesh) {
    const inv = invert(h);
    return inv ? applyHomography(inv, target.x, target.y) : target;
  }
  let u = target.x;
  let v = target.y;
  const eps = 1e-4;
  for (let k = 0; k < 8; k++) {
    const p = warped(warp, u, v, h);
    const ex = p.x - target.x, ey = p.y - target.y;
    if (Math.hypot(ex, ey) < 1e-7) break;
    const pu = warped(warp, u + eps, v, h), pv = warped(warp, u, v + eps, h);
    const a = (pu.x - p.x) / eps, c = (pu.y - p.y) / eps, b = (pv.x - p.x) / eps, d = (pv.y - p.y) / eps;
    const det = a * d - b * c;
    if (Math.abs(det) < 1e-9) break;
    u -= (d * ex - b * ey) / det;
    v -= (-c * ex + a * ey) / det;
  }
  return { x: u, y: v };
}

/** Handle position per mapper mode: corner pin handles are the warp itself; mesh nodes go through the pin; slices and masks through both. */
export function toScreen(output: OutputConfig, mode: MapperMode, p: MapPoint): MapPoint {
  if (mode === 'cornerPin') return p;
  if (mode === 'mesh') return applyHomography(homography(output.warp.cornerPin), p.x, p.y);
  return warped(output.warp, p.x, p.y);
}

/** Inverse of `toScreen`, for dragging. */
export function fromScreen(output: OutputConfig, mode: MapperMode, p: MapPoint): MapPoint {
  if (mode === 'cornerPin') return p;
  if (mode === 'mesh') {
    const inv = invert(homography(output.warp.cornerPin));
    return inv ? applyHomography(inv, p.x, p.y) : p;
  }
  return unwarp(output.warp, p);
}

/** An outline through the warp: each edge is cut into pieces because a straight line bends under a mesh or a pin. */
export function warpedOutline(output: OutputConfig, mode: MapperMode, points: MapPoint[], closed: boolean, pieces = 12): MapPoint[] {
  if (mode === 'cornerPin' || points.length === 0) return points;
  const out: MapPoint[] = [];
  const n = closed ? points.length : points.length - 1;
  for (let i = 0; i < n; i++) {
    const a = points[i]!, b = points[(i + 1) % points.length]!;
    for (let k = 0; k < pieces; k++) out.push(toScreen(output, mode, { x: a.x + ((b.x - a.x) * k) / pieces, y: a.y + ((b.y - a.y) * k) / pieces }));
  }
  if (!closed) out.push(toScreen(output, mode, points[points.length - 1]!));
  return out;
}

/** Moves a stored point by whole output pixels as seen on screen (through the warp), for arrow keys and the nudge pad. */
export function nudgeStored(output: OutputConfig, mode: MapperMode, point: MapPoint, dx: number, dy: number, size: { w: number; h: number }): MapPoint {
  const s = toScreen(output, mode, point);
  const p = fromScreen(output, mode, { x: Math.min(1, Math.max(0, s.x + dx / size.w)), y: Math.min(1, Math.max(0, s.y + dy / size.h)) });
  return { x: Math.min(1, Math.max(0, p.x)), y: Math.min(1, Math.max(0, p.y)) };
}
