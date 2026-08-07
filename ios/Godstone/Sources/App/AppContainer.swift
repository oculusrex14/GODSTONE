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
        archive = ArchiveRepository(databaseName: tier.archiveDatabaseName)
    }
}
