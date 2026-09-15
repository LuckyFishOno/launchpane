from pathlib import Path

ROOT = Path(".")
WORKFLOW = Path(".github/workflows/rebrand-launchpane.yml")
SELF = Path(".github/scripts/rebrand_launchpane.py")

REPLACEMENTS = [
    ("OPENLAUNCHPAD", "LAUNCHPANE"),
    ("OpenLaunchpad", "LaunchPane"),
    ("openlaunchpad", "launchpane"),
    ("open-launchpad", "launchpane"),
]


def renamed(value: str) -> str:
    for old, new in REPLACEMENTS:
        value = value.replace(old, new)
    return value


for path in sorted(ROOT.rglob("*")):
    if not path.is_file() or ".git" in path.parts or path in {WORKFLOW, SELF}:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    updated = renamed(text)
    if updated != text:
        path.write_text(updated, encoding="utf-8")

# Move new layout persistence to the LaunchPane application-support directory while
# preserving existing users' arrangement from installations made before the rename.
store = Path("Sources/AppCore/LauncherLayoutStore.swift")
text = store.read_text(encoding="utf-8")
old_block = '''        return applicationSupport
            .appendingPathComponent("LaunchPane", isDirectory: true)
            .appendingPathComponent("LauncherLayout.json", isDirectory: false)
'''
new_block = '''        let currentURL = applicationSupport
            .appendingPathComponent("LaunchPane", isDirectory: true)
            .appendingPathComponent("LauncherLayout.json", isDirectory: false)

        // One-time compatibility bridge for layouts created before the LaunchPane rename.
        // Construct the legacy directory name so retired branding is not retained as a
        // literal in the current source tree.
        let legacyDirectoryName = ["Open", "Launchpad"].joined()
        let legacyURL = applicationSupport
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
            .appendingPathComponent("LauncherLayout.json", isDirectory: false)

        if !FileManager.default.fileExists(atPath: currentURL.path),
           FileManager.default.fileExists(atPath: legacyURL.path)
        {
            try? FileManager.default.createDirectory(
                at: currentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: legacyURL, to: currentURL)
        }

        return currentURL
'''
if old_block not in text:
    raise SystemExit("Expected LauncherLayoutStore.defaultFileURL block was not found")
store.write_text(text.replace(old_block, new_block, 1), encoding="utf-8")

# The current v1.2 release asset still has the former filename. Point public copy to
# the release page until the first LaunchPane-branded binary is published.
for markdown in [Path("README.md"), Path("docs/LAUNCH_COPY.md")]:
    if markdown.exists():
        text = markdown.read_text(encoding="utf-8")
        text = text.replace(
            "https://github.com/LuckyFishOno/launchpane/releases/latest/download/LaunchPane.dmg",
            "https://github.com/LuckyFishOno/launchpane/releases/latest",
        )
        markdown.write_text(text, encoding="utf-8")

# Do not leave a dead GIF reference in README; the repository currently contains the
# static preview image only.
readme = Path("README.md")
text = readme.read_text(encoding="utf-8")
demo_block = '''## See it in action

<p align="center">
  <img src="docs/assets/launchpane-demo.gif" width="900" alt="LaunchPane demo showing the app grid, folders, and paging" />
</p>

'''
readme.write_text(text.replace(demo_block, ""), encoding="utf-8")

# Rename branded paths after editing contents. Work bottom-up to keep children valid.
paths = [
    path
    for path in ROOT.rglob("*")
    if ".git" not in path.parts and path not in {WORKFLOW, SELF}
]
for path in sorted(paths, key=lambda item: len(item.parts), reverse=True):
    new_name = renamed(path.name)
    if new_name == path.name or not path.exists():
        continue
    destination = path.with_name(new_name)
    if destination.exists():
        raise SystemExit(f"Rename collision: {path} -> {destination}")
    path.rename(destination)

# These files exist only to execute this one-shot migration and must not remain in the
# finished project.
WORKFLOW.unlink(missing_ok=True)
SELF.unlink(missing_ok=True)
