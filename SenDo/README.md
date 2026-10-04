# SenDo

A native macOS application for transferring games to Nintendo Switch via USB using Sphaira.

## Features

- **USB Connection**: Automatically detects Nintendo Switch connected via USB
- **File Support**: NSP, XCI, NSZ (compressed NSP), XCZ (compressed XCI)
- **Install Queue**: Manage multiple files with drag & drop reordering
- **Progress Tracking**: Real-time transfer progress and status
- **Native macOS**: Built with SwiftUI for a native Mac experience

## Requirements

- macOS 14.0 (Sonoma) or later
- Nintendo Switch with Atmosphere CFW and Sphaira installed
- USB-C cable

## Setup

1. Install Sphaira on your Nintendo Switch
2. Connect your Switch to your Mac via USB-C
3. Open Sphaira on your Switch
4. Navigate to Network > USB Install
5. Launch SenDo on your Mac

## Architecture

```
SenDo/
├── Sources/
│   ├── USB/                    # USB discovery and communication
│   │   ├── USBDiscovery.swift  # IOKit-based device detection
│   │   └── USBTransfer.swift   # Low-level packet handling
│   ├── Protocol/               # NUT protocol implementation
│   │   └── NUTClient.swift     # API client for Switch communication
│   ├── FileFormats/            # File parsing and decompression
│   │   ├── NSPParser.swift     # NSP/XCI file parsing
│   │   └── NSZDecompressor.swift # NSZ/XCZ decompression
│   ├── ViewModels/             # Business logic
│   │   └── SenDoViewModel.swift
│   └── Views/                  # SwiftUI interface
│       ├── ContentView.swift
│       ├── SidebarView.swift
│       ├── FileBrowserView.swift
│       ├── QueueView.swift
│       └── ...
└── Package.swift
```

## Protocol

SenDo uses the NUT (Nintendo USB Transfer) protocol, which is the same protocol used by:
- Tinfoil
- Awoo-Installer
- Sphaira
- ns-usbloader
- Fluffy

The protocol wraps HTTP-like requests in USB packets, allowing the Switch to request files from the PC.

## Building

```bash
# Clone the repository
git clone https://github.com/yourusername/SenDo.git
cd SenDo

# Build with Swift Package Manager
swift build

# Or open in Xcode
open Package.swift
```

## License

MIT License
