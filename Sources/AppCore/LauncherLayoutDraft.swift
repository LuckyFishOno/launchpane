import Foundation

public enum LauncherLayoutDraftState: Equatable, Sendable {
    case active
    case rolledBack
}

public enum LauncherLayoutMutationError: Error, Equatable, Sendable {
    case draftIsRolledBack
    case invalidRootIndex(Int)
    case invalidPageIndex(Int)
    case invalidPageInsertionIndex(Int)
    case invalidPageCapacity(Int)
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
        document.pages != snapshot.pages
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

        let source = document.items[sourceIndex].identifier
        let destination = document.items[destinationIndex].identifier
        try moveRootItem(source, toPositionOf: destination)
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
        let source = try document.rootLocation(identifier: sourceIdentifier)
        let destination = try document.rootLocation(identifier: destinationIdentifier)
        var candidate = document
        let item = candidate.pages[source.page].remove(at: source.index)
        candidate.pages[destination.page].insert(item, at: destination.index)
        try publish(candidate)
    }

    /// Moves to a final, page-local position, optionally creating the next page.
    /// Only overflow moves forward; a vacancy on the source page stays there.
    /// `index` is evaluated after removing the source, including same-page moves.
    public mutating func moveRootItem(
        _ sourceIdentifier: LauncherLayoutItemIdentifier,
        toPage page: Int,
        at index: Int,
        pageCapacity: Int
    ) throws {
        try requireActive()
        guard pageCapacity > 0 else {
            throw LauncherLayoutMutationError.invalidPageCapacity(pageCapacity)
        }
        guard page >= 0, page <= document.pages.count else {
            throw LauncherLayoutMutationError.invalidPageIndex(page)
        }
        let source = try document.rootLocation(identifier: sourceIdentifier)
        var candidate = document
        if page == candidate.pages.count { candidate.pages.append([]) }
        let item = candidate.pages[source.page].remove(at: source.index)
        guard index >= 0, index <= candidate.pages[page].count else {
            throw LauncherLayoutMutationError.invalidPageInsertionIndex(index)
        }
        candidate.pages[page].insert(item, at: index)
        try publish(candidate.normalizedForPageCapacity(pageCapacity))
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
        let source = try candidate.removeRootApplication(identity: sourceIdentity)
        let targetLocation = try candidate.rootApplicationLocation(identity: targetIdentity)
        let target = candidate.pages[targetLocation.page][targetLocation.index].applicationReference
        let folder = LauncherFolder(
            id: folderID,
            customTitle: customTitle,
            applications: [target, source]
        )
        candidate.pages[targetLocation.page][targetLocation.index] = .folder(folder)
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
        let application = try candidate.removeRootApplication(identity: applicationIdentity)
        let folderLocation: (page: Int, index: Int)
        do {
            folderLocation = try candidate.rootLocation(identifier: .folder(folderID))
        } catch {
            throw LauncherLayoutMutationError.folderNotFound(folderID)
        }
        guard case var .folder(folder) = candidate.pages[folderLocation.page][folderLocation.index] else {
            preconditionFailure("Folder lookup returned a non-folder layout item.")
        }
        let destination = insertionIndex ?? folder.applications.endIndex
        guard destination >= 0, destination <= folder.applications.endIndex else {
            throw LauncherLayoutMutationError.invalidFolderInsertionIndex(destination)
        }

        folder.applications.insert(application, at: destination)
        candidate.pages[folderLocation.page][folderLocation.index] = .folder(folder)
        try publish(candidate)
    }

    private func requireActive() throws {
        guard state == .active else {
            throw LauncherLayoutMutationError.draftIsRolledBack
        }
    }

    private mutating func publish(_ proposed: LauncherLayoutDocument) throws {
        var candidate = proposed
        while candidate.pages.count > 1, candidate.pages.last?.isEmpty == true {
            candidate.pages.removeLast()
        }
        try LauncherLayoutValidator.validate(candidate)
        document = candidate
    }
}

private extension LauncherLayoutDocument {
    func rootLocation(identifier: LauncherLayoutItemIdentifier) throws -> (page: Int, index: Int) {
        for (pageIndex, page) in pages.enumerated() {
            if let index = page.firstIndex(where: { $0.identifier == identifier }) {
                return (pageIndex, index)
            }
        }
        throw LauncherLayoutMutationError.layoutItemIsNotAtRoot(identifier)
    }

    func rootApplicationLocation(identity: ApplicationIdentity) throws -> (page: Int, index: Int) {
        do {
            return try rootLocation(identifier: .application(identity))
        } catch {
            throw LauncherLayoutMutationError.applicationIsNotAtRoot(identity)
        }
    }

    mutating func removeRootApplication(
        identity: ApplicationIdentity
    ) throws -> LauncherApplicationReference {
        let location = try rootApplicationLocation(identity: identity)
        return pages[location.page].remove(at: location.index).applicationReference
    }
}

private extension [LauncherLayoutItem] {
    func containsFolder(id: UUID) -> Bool {
        contains {
            guard case let .folder(folder) = $0 else { return false }
            return folder.id == id
        }
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
