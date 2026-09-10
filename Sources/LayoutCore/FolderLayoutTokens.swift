import CoreGraphics

/// Typed visual and interaction constraints for the folder overlay.
public struct FolderLayoutTokens: Equatable, Sendable {
    public var preferredIconSize: CGFloat
    public var minimumIconSize: CGFloat
    public var maximumIconSize: CGFloat
    public var preferredCellWidth: CGFloat
    public var preferredCellHeight: CGFloat
    public var minimumHorizontalGap: CGFloat
    public var minimumVerticalGap: CGFloat
    public var minimumInteractionTarget: CGFloat
    public var labelHeight: CGFloat
    public var titleHeight: CGFloat
    public var titleToGridSpacing: CGFloat
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat
    public var displayMargin: CGFloat
    public var maximumPanelWidth: CGFloat
    public var maximumPanelHeight: CGFloat
    public var defaultRows: Int
    public var defaultColumns: Int
    public var maximumRows: Int
    public var maximumColumns: Int

    public init(
        preferredIconSize: CGFloat = 84,
        minimumIconSize: CGFloat = 40,
        maximumIconSize: CGFloat = 96,
        preferredCellWidth: CGFloat = 144,
        preferredCellHeight: CGFloat = 132,
        minimumHorizontalGap: CGFloat = 16,
        minimumVerticalGap: CGFloat = 14,
        minimumInteractionTarget: CGFloat = 56,
        labelHeight: CGFloat = 30,
        titleHeight: CGFloat = 40,
        titleToGridSpacing: CGFloat = 16,
        horizontalPadding: CGFloat = 40,
        verticalPadding: CGFloat = 32,
        displayMargin: CGFloat = 24,
        maximumPanelWidth: CGFloat = 800,
        maximumPanelHeight: CGFloat = 560,
        defaultRows: Int = 3,
        defaultColumns: Int = 5,
        maximumRows: Int = 3,
        maximumColumns: Int = 5
    ) {
        self.preferredIconSize = preferredIconSize
        self.minimumIconSize = minimumIconSize
        self.maximumIconSize = maximumIconSize
        self.preferredCellWidth = preferredCellWidth
        self.preferredCellHeight = preferredCellHeight
        self.minimumHorizontalGap = minimumHorizontalGap
        self.minimumVerticalGap = minimumVerticalGap
        self.minimumInteractionTarget = minimumInteractionTarget
        self.labelHeight = labelHeight
        self.titleHeight = titleHeight
        self.titleToGridSpacing = titleToGridSpacing
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.displayMargin = displayMargin
        self.maximumPanelWidth = maximumPanelWidth
        self.maximumPanelHeight = maximumPanelHeight
        self.defaultRows = defaultRows
        self.defaultColumns = defaultColumns
        self.maximumRows = maximumRows
        self.maximumColumns = maximumColumns
    }

    public static let standard = FolderLayoutTokens()
}
