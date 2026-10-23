// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
import type { JSONValue, PatchOp } from './protocol';

/** RFC 6901 pointer → tokens. */
export function tokens(path: string): string[] {
  if (path === '') return [];
  if (!path.startsWith('/')) throw new Error(`bad pointer ${path}`);
  return path
    .slice(1)
    .split('/')
    .map((t) => t.replace(/~1/g, '/').replace(/~0/g, '~'));
}

type Container = Record<string, JSONValue> | JSONValue[];

function child(container: Container, token: string): JSONValue | undefined {
  if (Array.isArray(container)) {
    const i = Number(token);
    return Number.isInteger(i) ? container[i] : undefined;
  }
  return container[token];
}

/**
 * Applies add/remove/replace in place (the engine never sends move/copy/test). Mutating in place is what
 * keeps Svelte's deep `$state` proxies fine-grained: only the touched paths re-render.
 * Returns the (possibly new) root: a replace of "" swaps the whole document.
 */
export function applyPatch(root: JSONValue, ops: PatchOp[]): JSONValue {
  for (const op of ops) {
    const path = tokens(op.path);
    if (path.length === 0) {
      if (op.op === 'remove') throw new Error('cannot remove the root');
      root = op.value as JSONValue;
      continue;
    }
    let node: JSONValue = root;
    for (const token of path.slice(0, -1)) {
      if (typeof node !== 'object' || node === null) throw new Error(`not a container at ${op.path}`);
      const next = child(node as Container, token);
      if (next === undefined) throw new Error(`missing ${op.path}`);
      node = next;
    }
    if (typeof node !== 'object' || node === null) throw new Error(`not a container at ${op.path}`);
    const last = path[path.length - 1]!;
    if (Array.isArray(node)) {
      const index = last === '-' ? node.length : Number(last);
      if (!Number.isInteger(index) || index < 0 || index > node.length) throw new Error(`bad index ${op.path}`);
      if (op.op === 'add') node.splice(index, 0, op.value as JSONValue);
      else if (index === node.length) throw new Error(`missing ${op.path}`);
      else if (op.op === 'remove') node.splice(index, 1);
      else node[index] = op.value as JSONValue;
    } else {
      const object = node as Record<string, JSONValue>;
      if (op.op === 'remove') {
        if (!(last in object)) throw new Error(`missing ${op.path}`);
        delete object[last];
      } else if (op.op === 'replace' && !(last in object)) {
        throw new Error(`missing ${op.path}`);
      } else {
        object[last] = op.value as JSONValue;
      }
    }
  }
  return root;
}
