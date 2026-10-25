# Fanous Plugin Exception (additional permission under GPLv3 section 7)

**STATUS: DRAFT. NOT IN EFFECT. This text must be reviewed by a lawyer before
it is added to `LICENSE-ADDITIONAL-TERMS.md` and before any plugin that links
a proprietary SDK is distributed.**

Modelled on the structure of existing GPL additional permissions (GCC Runtime
Library Exception, Classpath Exception). Definitions refer to the interface in
`Sources/FanousPluginAPI/`.

## Definitions

- "Program" means Fanous as licensed under GPL-3.0-only with additional terms.
- "Plugin Interface" means the C header `fanous_plugin.h` and the Swift
  declarations in `Sources/FanousPluginAPI/`, as published in the Program's
  source repository, including their documentation comments.
- "Plugin" means a work that (a) is loaded by the Program at run time through
  the Plugin Interface, (b) interacts with the Program solely through the
  Plugin Interface, and (c) does not incorporate any source code of the
  Program other than the Plugin Interface itself.
- "Proprietary SDK" means a software development kit or library whose license
  is incompatible with the GNU GPL, such as the NDI® SDK or the Blackmagic
  DeckLink SDK.

## Additional permission

As a special exception to the GNU General Public License, version 3, the
copyright holder of the Program grants you the additional permission to:

1. compile, link and combine a Plugin with one or more Proprietary SDKs, and
2. convey the resulting Plugin, in source or object form, under license terms
   of your choice, including terms that do not comply with the GPL,

provided that:

- the Plugin Interface itself remains licensed under the GPL-3.0-only with
  the Program's additional terms, and you do not modify it in the conveyed
  Plugin except as the Program's maintainers publish it;
- the Program, and any modified version of it, remains licensed under the
  GPL-3.0-only with its additional terms; this exception does not extend to
  any part of the Program other than the Plugin Interface;
- you do not use this exception to convey the Program itself, or a work
  based on the Program, combined with a Proprietary SDK in a single
  executable or library;
- you include a copy of this exception with the Plugin, and clearly state
  that the Plugin is not part of the Program and is not covered by its
  warranty disclaimer or license.

This exception is an additional permission under section 7 of the GPL. You
may remove it from your copies of the Program, as section 7 allows, but it
then no longer applies to works you convey. It does not grant any right to
use the Fanous name or logo (see `TRADEMARKS.md`).

## Notes for legal review

- Whether "interacts solely through the Plugin Interface" is precise enough
  given in-process loading (`dlopen`); whether to require out-of-process
  plugins for the exception to apply.
- Whether distributing *this project's own* NDI/DeckLink plugins (built by
  the copyright holder) under this exception is consistent with the SDK
  vendors' license terms (NDI SDK license, Blackmagic SDK license).
- Interaction with the commercial license: the exception is granted under
  the GPL edition only; the commercial edition carries its own terms.
