import Foundation

public enum LauncherLayoutDraftState: Equatable, Sendable {
    case active
    case rolledBack
}

public enum LauncherLayoutMutationError: Error, Equatable, Sendable {
    case draftIsRolledBack
    case invalidRootIndex(Int)
    case layoutItemIsNotAtRoot(LauncherLayoutItemIdentifier)
    case invalidFolderInsertionIndex(Int)
    case applicationIsNotAtRoot(ApplicationIdentity)
    case folderNotFound(UUID)
    case duplicateFolder(UUID)
    case cannotMergeApplicationWithItself
}

/// A value-semantic working copy used to preview drag operations before one atomic commit.
public struct LauncherLayoutDraft: Equatable, Sendable {
    public let snapshot: LauncherLayoutDocument
    public private(set) var document: LauncherLayoutDocument
    public private(set) var state: LauncherLayoutDraftState

    public var hasChanges: Bool {
        document.items != snapshot.items
    }

    public init(document: LauncherLayoutDocument) throws {
        try LauncherLayoutValidator.validate(document)
        snapshot = document
        self.document = document
        state = .active
    }

    /// Restores the original snapshot and permanently closes this draft to further mutations.
    public mutating func rollback() {
        document = snapshot
        state = .rolledBack
    }

    /// Moves a root application or folder to its desired final root-array index.
    public mutating func moveRootItem(from sourceIndex: Int, to destinationIndex: Int) throws {
        try requireActive()
        guard document.items.indices.contains(sourceIndex) else {
            throw LauncherLayoutMutationError.invalidRootIndex(sourceIndex)
        }
        guard document.items.indices.contains(destinationIndex) else {
            throw LauncherLayoutMutationError.invalidRootIndex(destinationIndex)
        }
        guard sourceIndex != destinationIndex else { return }

        var candidate = document
        let item = candidate.items.remove(at: sourceIndex)
        candidate.items.insert(item, at: destinationIndex)
        try publish(candidate)
    }

    /// Moves a root item to the final position currently occupied by another root item.
    ///
    /// Stable identifiers keep UI projections from confusing their compacted visible indices
    /// with document indices when a partial catalog leaves unresolved references in the layout.
    public mutating func moveRootItem(
        _ sourceIdentifier: LauncherLayoutItemIdentifier,
        toPositionOf destinationIdentifier: LauncherLayoutItemIdentifier
    ) throws {
        try requireActive()
        let sourceIndex = try document.items.rootItemIndex(identifier: sourceIdentifier)
        let destinationIndex = try document.items.rootItemIndex(identifier: destinationIdentifier)
        try moveRootItem(from: sourceIndex, to: destinationIndex)
    }

    /// Replaces two root applications with a folder at the target application's position.
    public mutating func mergeApplications(
        source sourceIdentity: ApplicationIdentity,
        target targetIdentity: ApplicationIdentity,
        folderID: UUID = UUID(),
        customTitle: String? = nil
    ) throws {
        try requireActive()
        guard sourceIdentity != targetIdentity else {
            throw LauncherLayoutMutationError.cannotMergeApplicationWithItself
        }
        guard !document.items.containsFolder(id: folderID) else {
            throw LauncherLayoutMutationError.duplicateFolder(folderID)
        }

        var candidate = document
        let source = try candidate.items.removeRootApplication(identity: sourceIdentity)
        let targetIndex = try candidate.items.rootApplicationIndex(identity: targetIdentity)
        let target = candidate.items.remove(at: targetIndex).applicationReference
        let folder = LauncherFolder(
            id: folderID,
            customTitle: customTitle,
            applications: [target, source]
        )
        candidate.items.insert(.folder(folder), at: targetIndex)
        try publish(candidate)
    }

    /// Removes a root application and adds it to an existing root folder.
    public mutating func addApplication(
        _ applicationIdentity: ApplicationIdentity,
        toFolder folderID: UUID,
        at insertionIndex: Int? = nil
    ) throws {
        try requireActive()

        var candidate = document
        let application = try candidate.items.removeRootApplication(identity: applicationIdentity)
        guard let folderIndex = candidate.items.firstIndexOfFolder(id: folderID) else {
            throw LauncherLayoutMutationError.folderNotFound(folderID)
        }
        guard case var .folder(folder) = candidate.items[folderIndex] else {
            preconditionFailure("Folder lookup returned a non-folder layout item.")
        }
        let destination = insertionIndex ?? folder.applications.endIndex
        guard destination >= 0, destination <= folder.applications.endIndex else {
            throw LauncherLayoutMutationError.invalidFolderInsertionIndex(destination)
        }

        folder.applications.insert(application, at: destination)
        candidate.items[folderIndex] = .folder(folder)
        try publish(candidate)
    }

    private func requireActive() throws {
        guard state == .active else {
            throw LauncherLayoutMutationError.draftIsRolledBack
        }
    }

    private mutating func publish(_ candidate: LauncherLayoutDocument) throws {
        try LauncherLayoutValidator.validate(candidate)
        document = candidate
    }
}

private extension [LauncherLayoutItem] {
    func rootItemIndex(identifier: LauncherLayoutItemIdentifier) throws -> Int {
        guard let index = firstIndex(where: { $0.identifier == identifier }) else {
            throw LauncherLayoutMutationError.layoutItemIsNotAtRoot(identifier)
        }
        return index
    }

    func containsFolder(id: UUID) -> Bool {
        firstIndexOfFolder(id: id) != nil
    }

    func firstIndexOfFolder(id: UUID) -> Int? {
        firstIndex {
            guard case let .folder(folder) = $0 else { return false }
            return folder.id == id
        }
    }

    func rootApplicationIndex(identity: ApplicationIdentity) throws -> Int {
        guard let index = firstIndex(where: {
            guard case let .application(application) = $0 else { return false }
            return application.identity == identity
        }) else {
            throw LauncherLayoutMutationError.applicationIsNotAtRoot(identity)
        }
        return index
    }

    mutating func removeRootApplication(
        identity: ApplicationIdentity
    ) throws -> LauncherApplicationReference {
        let index = try rootApplicationIndex(identity: identity)
        return remove(at: index).applicationReference
    }
}

private extension LauncherLayoutItem {
    var identifier: LauncherLayoutItemIdentifier {
        switch self {
        case let .application(application):
            .application(application.identity)
        case let .folder(folder):
            .folder(folder.id)
        }
    }

    var applicationReference: LauncherApplicationReference {
        guard case let .application(application) = self else {
            preconditionFailure("Expected an application layout item.")
        }
        return application
    }
}
