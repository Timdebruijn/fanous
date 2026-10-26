// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
// Content template: what of the canvas ends up visible on an output, drawn at canvas resolution for a designer.
import type { MapPoint, OutputConfig, SliceConfig } from './outputs';

/** Bilinear position in a slice's destination quad (TL, TR, BR, BL), as the engine's slice mesh interpolates it. */
export function bilinear(dest: MapPoint[], u: number, v: number): MapPoint {
  const [tl, tr, br, bl] = dest as [MapPoint, MapPoint, MapPoint, MapPoint];
  const top = { x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u };
  const bottom = { x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u };
  return { x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v };
}

/** Inverse of `bilinear` by Newton steps: (u, v) inside the quad for an output point, or null when it does not converge. */
export function inverseBilinear(dest: MapPoint[], p: MapPoint): { u: number; v: number } | null {
  let u = 0.5, v = 0.5;
  for (let i = 0; i < 30; i++) {
    const q = bilinear(dest, u, v);
    const ex = q.x - p.x, ey = q.y - p.y;
    if (ex * ex + ey * ey < 1e-14) return { u, v };
    const h = 1e-5;
    const du = bilinear(dest, u + h, v), dv = bilinear(dest, u, v + h);
    const a = (du.x - q.x) / h, b = (dv.x - q.x) / h, c = (du.y - q.y) / h, d = (dv.y - q.y) / h;
    const det = a * d - b * c;
    if (Math.abs(det) < 1e-12) return null;
    u -= (d * ex - b * ey) / det;
    v -= (-c * ex + a * ey) / det;
  }
  return { u, v };
}

/** An output-space point of a slice's mask, in canvas pixels. */
export function maskPointOnCanvas(slice: SliceConfig, p: MapPoint, canvas: { width: number; height: number }): MapPoint | null {
  const uv = inverseBilinear(slice.dest, p);
  if (!uv) return null;
  const u = Math.max(0, Math.min(1, uv.u)), v = Math.max(0, Math.min(1, uv.v));
  return { x: (slice.source.x + slice.source.w * u) * canvas.width, y: (slice.source.y + slice.source.h * v) * canvas.height };
}

const COLOURS = ['#4C9EFF', '#35D07F', '#FFC532', '#FF5A5F', '#B78CFF'];

function escape(text: string): string {
  return text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
}

/**
 * SVG at canvas size: a 10 % grid, per slice the canvas rectangle it takes (outline + label) and its mask shape mapped
 * back onto the canvas (filled: that part is visible on the output). A mask edge is cut into pieces so it follows the
 * slice's bilinear mapping.
 */
export function templateSVG(output: OutputConfig, canvas: { width: number; height: number }, name = output.name): string {
  const { width: W, height: H } = canvas;
  const line = Math.max(2, Math.round(H / 540));
  const font = Math.max(14, Math.round(H / 40));
  const parts: string[] = [];
  parts.push(`<rect width="${W}" height="${H}" fill="#101215"/>`);
  for (let i = 1; i < 10; i++) {
    parts.push(`<line x1="${(W * i) / 10}" y1="0" x2="${(W * i) / 10}" y2="${H}" stroke="#2a2f36" stroke-width="${line / 2}"/>`);
    parts.push(`<line x1="0" y1="${(H * i) / 10}" x2="${W}" y2="${(H * i) / 10}" stroke="#2a2f36" stroke-width="${line / 2}"/>`);
  }
  output.slices.forEach((slice, i) => {
    const colour = COLOURS[i % COLOURS.length]!;
    const x = slice.source.x * W, y = slice.source.y * H, w = slice.source.w * W, h = slice.source.h * H;
    if (slice.mask && slice.mask.path.length >= 3) {
      const path = slice.mask.path;
      const pts: MapPoint[] = [];
      for (let k = 0; k < path.length; k++) {
        const a = path[k]!, b = path[(k + 1) % path.length]!;
        for (let s = 0; s < 16; s++) {
          const q = maskPointOnCanvas(slice, { x: a.x + ((b.x - a.x) * s) / 16, y: a.y + ((b.y - a.y) * s) / 16 }, canvas);
          if (q) pts.push(q);
        }
      }
      parts.push(`<polygon points="${pts.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ')}" fill="${colour}" fill-opacity="0.28" stroke="${colour}" stroke-width="${line}"/>`);
    } else {
      parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${colour}" fill-opacity="0.18"/>`);
    }
    parts.push(`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="none" stroke="${colour}" stroke-width="${line}" stroke-dasharray="${line * 4} ${line * 3}"/>`);
    const label = `Slice ${slice.id} · ${Math.round(x)},${Math.round(y)} · ${Math.round(w)}×${Math.round(h)} px${slice.mask ? ' · masked' : ''}`;
    parts.push(`<text x="${x + font * 0.6}" y="${y + font * 1.4}" fill="${colour}" font-family="Helvetica, Arial, sans-serif" font-size="${font}" font-weight="700">${escape(label)}</text>`);
  });
  parts.push(
    `<text x="${font * 0.6}" y="${H - font * 0.8}" fill="#A3AAB4" font-family="Helvetica, Arial, sans-serif" font-size="${font}">${escape(`Fanous content template · ${name} · canvas ${W}×${H} px · filled = visible on this output`)}</text>`,
  );
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${parts.join('')}</svg>`;
}

/** Renders the SVG to a PNG and offers it as a download. */
export async function downloadTemplatePNG(svg: string, width: number, height: number, filename: string): Promise<void> {
  const image = new Image();
  const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }));
  try {
    await new Promise<void>((resolve, reject) => {
      image.onload = () => resolve();
      image.onerror = () => reject(new Error('template render failed'));
      image.src = url;
    });
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    canvas.getContext('2d')!.drawImage(image, 0, 0, width, height);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/png'));
    if (!blob) throw new Error('template encode failed');
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(link.href), 10_000);
  } finally {
    URL.revokeObjectURL(url);
  }
}
