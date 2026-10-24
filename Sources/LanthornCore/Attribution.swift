// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// The one place the attribution strings live. The About screen, the web
/// footer and the GDTF/CITP server names read from here; a test asserts it.
public enum Attribution {
    public static let projectName = "Lanthorn"
    public static let author = "Tim de Bruijn"
    public static let repositoryURL = "https://github.com/timdebruijn/lanthorn"
    /// Required by LICENSE-ADDITIONAL-TERMS.md §1 (GPLv3 §7(b)).
    public static let text = "Based on Lanthorn by Tim de Bruijn — https://github.com/timdebruijn/lanthorn"
    /// Required by Artistic Licence's Art-Net conditions.
    public static let artNetCredit = "Art-Net™ Designed by and Copyright Artistic Licence Engineering Ltd"
}

public enum LanthornVersion {
    public static let string = "1.0.0-rc.1"
}
