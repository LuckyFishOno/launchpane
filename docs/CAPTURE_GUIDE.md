# Capture guide

Use this when recording LaunchPane visuals for the README, release notes, Product Hunt, Hacker News, Reddit, or social posts.

## Main screenshot

Goal: show the full-screen grid clearly, with search, folders, and familiar Mac apps visible.

1. Close private windows and anything with personal names, chats, customer data, calendars, emails, or project titles.
2. Set a clean wallpaper, ideally a soft macOS default wallpaper.
3. Open LaunchPane.
4. Stay on the first page.
5. Make sure the grid includes a mix of:
   - one or two folders
   - common apps such as App Store, Calendar, Calculator, Books, Safari, or FaceTime
   - several third-party apps if available
6. Do not type in search for the main screenshot.
7. Capture the full screen with `Shift-Control-Command-3` if you want the image on the clipboard, or `Shift-Command-5` if you want to save a file.
8. Use PNG for the source capture.

Recommended final asset:

- `docs/assets/launchpane-preview.png`
- 16:10 or similar desktop aspect ratio
- 2200 px wide is enough for GitHub
- Keep text readable after GitHub scales it down

## Operation GIF

Goal: show the app in motion without requiring sound or narration.

Record 8 to 12 seconds. Keep the pointer movement slow and intentional.

Suggested sequence:

1. Open LaunchPane from the Dock.
2. Type two or three letters into search, then clear search.
3. Drag one app onto another app until the folder target highlights.
4. Release to create the folder.
5. Close the folder.
6. Drag near the page edge just enough to show paging, then stop.

Avoid:

- showing private app names or private folders
- recording ChatGPT, Slack, email, messages, calendars, or internal project windows
- moving too quickly; GIF viewers need obvious state changes
- making the recording longer than 12 seconds

Recommended raw recording:

- Use `Shift-Command-5`.
- Select only the LaunchPane area or full screen if the wallpaper is clean.
- Save as `.mov`.
- Name it `launchpane-demo.mov`.

Recommended final asset:

- `docs/assets/launchpane-demo.gif`
- 1200 to 1600 px wide
- 8 to 12 seconds
- under 10 MB if possible

## Quick review checklist

- No private data is visible.
- The first frame already looks like LaunchPane.
- The folder creation moment is clear.
- Search appears instant.
- The pointer is visible but not distracting.
- The file is small enough for GitHub to load quickly.
