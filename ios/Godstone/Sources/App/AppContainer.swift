import Foundation
import Combine
import GodstoneCore

/// Archive-only production composition root.
@MainActor
final class AppContainer: ObservableObject {
    let tier: Tier
    let archive: ArchiveRepository

    init() {
        tier = Tier.current
        // T48 (s17): the pairing is sealed at the composition root -- the
        // repository will refuse the file that is not its tier's own.
        archive = ArchiveRepository(databaseName: tier.archiveDatabaseName, expectedTier: tier)
    }
}
