// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

@Suite struct AttributionTests {
    @Test func attributionNamesAuthorAndRepository() {
        #expect(Attribution.text.contains(Attribution.author))
        #expect(Attribution.text.contains(Attribution.repositoryURL))
        #expect(Attribution.artNetCredit.contains("Artistic Licence"))
    }
}
