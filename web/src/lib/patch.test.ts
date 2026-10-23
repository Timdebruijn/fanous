// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import { describe, expect, it } from 'vitest';
import { applyPatch, tokens } from './patch';

describe('applyPatch', () => {
  it('replaces, adds and removes object members in place', () => {
    const doc = { name: 'a', nested: { x: 1 } };
    const same = applyPatch(doc, [
      { op: 'replace', path: '/name', value: 'b' },
      { op: 'add', path: '/nested/y', value: [1, 2] },
      { op: 'remove', path: '/nested/x' },
    ]);
    expect(same).toBe(doc);
    expect(doc).toEqual({ name: 'b', nested: { y: [1, 2] } });
  });

  it('handles arrays, "-" and escaped pointers', () => {
    const doc: { list: number[]; 'a/b': number } = { list: [1, 3], 'a/b': 0 };
    applyPatch(doc, [
      { op: 'add', path: '/list/1', value: 2 },
      { op: 'add', path: '/list/-', value: 4 },
      { op: 'replace', path: '/a~1b', value: 9 },
      { op: 'remove', path: '/list/0' },
    ]);
    expect(doc).toEqual({ list: [2, 3, 4], 'a/b': 9 });
    expect(tokens('/m~0n/~1')).toEqual(['m~n', '/']);
  });

  it('refuses missing paths so a lagging client re-snapshots instead of diverging', () => {
    expect(() => applyPatch({ a: 1 }, [{ op: 'replace', path: '/b', value: 1 }])).toThrow(/missing/);
    expect(() => applyPatch({ a: 1 }, [{ op: 'remove', path: '/a/b', value: 1 }])).toThrow(/not a container/);
    expect(() => applyPatch([1], [{ op: 'replace', path: '/5', value: 1 }])).toThrow(/bad index/);
  });

  it('replaces the root', () => {
    expect(applyPatch({ a: 1 }, [{ op: 'replace', path: '', value: { b: 2 } }])).toEqual({ b: 2 });
  });
});
