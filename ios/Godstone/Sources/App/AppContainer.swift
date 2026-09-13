import Foundation
import Combine
import GodstoneCore

/// Archive-only production composition root.
@MainActor
final class AppContainer: ObservableObject {
    let tier: Tier
    // T48 (s17): the pairing is sealed at the composition root -- the
    // repository will refuse the file that is not its tier's own.
    let archive: ArchiveRepository

    // T50 (s17): the reader model, seated at the root as the card
    // commandeth. One open serveth the road through the library; the scene
    // is the journey's state owner (the isle twin of the sealed android
    // BrowseViewModel); the provenance face readeth the same frozen columns
    // the android projection enriched. The archive handle abideth for the
    // provenance road alone -- both handles open the same read-only bytes,
    // which no road here wrieteth.
    let archiveLibrary: ArchiveLibrary
    let archiveModel: ArchiveReaderModel
    let scene: ArchiveSceneModel

    init() {
        tier = Tier.current
        archive = ArchiveRepository(databaseName: tier.archiveDatabaseName, expectedTier: tier)
        archiveLibrary = ArchiveLibrary(databaseName: tier.archiveDatabaseName, tier: tier)
        archiveModel = ArchiveReaderModel(library: archiveLibrary)
        scene = ArchiveSceneModel(reading: archiveLibrary, model: archiveModel)
    }
}
