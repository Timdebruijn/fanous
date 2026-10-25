# Attribution term (GPLv3 section 7(b))

Status: DRAFT — wording to be confirmed by a lawyer before the first public
release. This file is referenced from `LICENSE-ADDITIONAL-TERMS.md` and from
the header of every source file.

## Additional term

In accordance with section 7(b) of the GNU General Public License, version 3,
the copyright holder of Fanous (Tim de Bruijn) adds the following term to
the license of the Program:

> Any work containing the Program or a covered work based on it that presents
> an "About" screen, window or dialog, and any web-based user interface it
> serves, must preserve, legibly and in the same place and prominence as its
> other Appropriate Legal Notices, the following attribution notice:
>
> **"Based on Fanous by Tim de Bruijn — https://github.com/timdebruijn/fanous"**
>
> The notice may be translated, and may be accompanied by additional
> attributions for the modified work, but must not be removed, obscured or
> altered in meaning. This term does not grant any right to use the name
> "Fanous" or its logo as the name or mark of a modified work (see
> `TRADEMARKS.md`).

Per section 7, this term is non-permissive and may not be removed by
downstream recipients. It is intentionally limited to the Appropriate Legal
Notices (About screen, web footer) so that it is a "reasonable" requirement
in the sense of section 7(b).

## Where the notice appears in Fanous itself

- Shell app: About window (also shows the engine version, license, the
  third-party notices and the Art-Net credit required by Artistic Licence).
- Web UI: footer of every screen, rendered from `Attribution.text` in
  `FanousCore`; a UI test asserts it is present.
- The exact string lives in exactly one place in the code
  (`Sources/FanousCore/Attribution.swift`) and is covered by this term.
