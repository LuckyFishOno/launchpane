import AppKit
import QuartzCore

enum DragProxyMetrics {
    static let labelLayerName = "LaunchPaneDragProxyLabel"
    static let labelAnimationKey = "folderMergeSourceLabelFade"
}

enum FolderMergeVisualMetrics {
    // The merge-ready surface should feel like a closed folder preview:
    // smaller than the old selection ring, but much more legible.
    static let appTargetFrameScale: CGFloat = 0.82
    // Existing folders grow more assertively when an app is held over them.
    // The requested merge-ready state is 30% larger than the normal folder tile.
    static let folderTargetScale: CGFloat = 1.30
    static let transitionDuration: CFTimeInterval = 0.14
    // Names intentionally trail the geometry so the merge intent reads first.
    static let labelFadeDuration: CFTimeInterval = 0.30
    // Merge landing stays fully visible while it travels toward the folder,
    // then disappears only after it has visibly shrunk into the target.
    // Keep the source visible until it is close to the miniature size;
    // the final scale itself comes from AppTilePresentationFactory so it
    // always matches the closed-folder 3x3 geometry exactly.
    static let mergeFadeStartProgress: Double = 0.90
    // When all nine miniature slots are already occupied, the incoming
    // app is absorbed by the folder itself rather than by a visible slot.
    // Shrink almost to a point and defer fading until the final instant.
    static let fullFolderAbsorbScale: CGFloat = 0.03
    static let fullFolderFadeStartProgress: Double = 0.97
    // Keep the page completely still until the source app has finished
    // shrinking into the folder. One extra display frame makes the visual
    // ownership handoff unambiguous before the surrounding grid reflows.
    static let postLandingReflowDelay: CFTimeInterval = 0.02
    static let folderBackgroundOpacity: CGFloat = 0.42
    static let folderBorderOpacity: CGFloat = 0.52
    static let folderBorderWidth: CGFloat = 0.75
    static let normalSelectionBackgroundOpacity: CGFloat = 0.12
    static let normalSelectionBorderOpacity: CGFloat = 0.18
    static let normalSelectionBorderWidth: CGFloat = 0.7
}
