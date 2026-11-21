# OpenNook

**OpenNook** is a free, native, and open-source Dynamic Island for macOS. It transforms the MacBook camera notch and menu bar into an interactive command center.

## Features

- **Live Media Scrubber**: Controls and now-playing metadata for Apple Music, Spotify, and web media.
- **Instant Camera Mirror**: Fast live mirror preview directly under your notch.
- **Schedule & Meeting Join**: Upcoming calendar events with one-click video meeting joins.
- **Scratchpad Notes**: Quick note taking accessible right from your notch.
- **Focus Timer**: Clean countdown timer with quick interval controls.
- **File Shelf**: Drag and drop shelf for staging files and AirDrop sharing.
- **Tahoe Control Center**: System metrics and quick toggles.

## Tech Stack

- **macOS Native**: Swift & SwiftUI (macOS 14 Sonoma / macOS 15 Sequoia)
- **Architecture**: Swift Package Manager (`swift build`), AppKit window integration (`NotchPanelController`), SystemKit / EventKit / AVFoundation.
- **Showcase Website**: HTML5, CSS3, Vanilla JavaScript interactive simulator.

## Getting Started

### Prerequisites

- macOS 14.0 or later
- Xcode 15+ / Swift 5.9+

### Building from Source

```bash
# Clone the repository
git clone https://github.com/thrithick5/OpenNook.git
cd OpenNook

# Build the release app bundle and installer
bash scripts/build-app.sh
```

### Running Tests

```bash
swift test
```

## License

MIT License.
