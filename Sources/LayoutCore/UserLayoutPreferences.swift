import CoreGraphics

public struct UserLayoutPreferences: Equatable, Sendable {
    public var requestedRows: Int?
    public var requestedColumns: Int?
    public var requestedIconSize: CGFloat?
    public var isRightToLeft: Bool

    public init(
        requestedRows: Int? = nil,
        requestedColumns: Int? = nil,
        requestedIconSize: CGFloat? = nil,
        isRightToLeft: Bool = false
    ) {
        self.requestedRows = requestedRows
        self.requestedColumns = requestedColumns
        self.requestedIconSize = requestedIconSize
        self.isRightToLeft = isRightToLeft
    }

    public static let automatic = UserLayoutPreferences()
}
