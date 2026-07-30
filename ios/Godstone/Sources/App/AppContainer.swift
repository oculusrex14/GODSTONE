import Foundation
import Combine
import GodstoneCore
import GodstoneMesh
import GodstoneLLM

/// Composition root. Everything is constructed here, once, and injected down.
/// No singletons, no service locators: dependencies are visible and testable.
@MainActor
final class AppContainer: ObservableObject {

    let tier: Tier
    let identity: MeshIdentity
    let meshNode: MeshNode
    let meshCoordinator: MeshCoordinator
    let ragPipeline: RagPipeline
    let oracleViewModel: OracleViewModel
    let archive: ArchiveRepository

    init() {
        self.tier = Tier.current

        // Identity is generated once and stored in the Secure Enclave-backed
        // Keychain with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
        self.identity = (try? MeshIdentity.loadFromKeychain())
            ?? MeshIdentity.generateAndStore()

        self.meshNode = MeshNode(identity: identity)
        self.meshCoordinator = MeshCoordinator(node: meshNode)

        self.archive = ArchiveRepository(
            databaseName: tier.archiveDatabaseName
        )

        self.ragPipeline = RagPipeline(
            models: ModelManager(
                modelName: tier.modelFileName,
                contextTokens: tier.contextTokens
            ),
            retriever: Retriever(archive: archive),
            topK: tier.retrievalChunks
        )

        self.oracleViewModel = OracleViewModel(pipeline: ragPipeline)
    }
}
