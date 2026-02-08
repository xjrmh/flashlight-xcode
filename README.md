# Flashlight - iOS Morse Code Flashlight App

A modern iOS flashlight app with Liquid Glass design, featuring morse code communication via torch and camera.

## Features

- **Flashlight Control** - Brightness and beam width adjustment with real-time torch control
- **Morse Code Sender** - Type a message, convert to morse code, and transmit via torch flashes
- **Morse Code Receiver** - Detect and decode morse code from other devices using the camera
- **Liquid Glass UI** - Frosted glass design with translucent materials and smooth animations
- **Universal** - Adaptive layouts for both iPhone and iPad

## Requirements

- iOS 17.0+
- Xcode 16.0+
- Physical device required for torch and camera features

## Architecture

```
Flashlight/
├── FlashlightApp.swift          # App entry point
├── ContentView.swift            # Tab navigation
├── Models/
│   └── MorseCode.swift          # Morse encoding/decoding/timing
├── Services/
│   ├── FlashlightService.swift  # Torch hardware control
│   ├── MorseCodeEngine.swift    # Send/receive state machine
│   └── CameraLightDetector.swift # Camera-based light detection
├── Views/
│   ├── FlashlightView.swift     # Main flashlight screen
│   ├── MorseSendView.swift      # Morse code sender
│   └── MorseReceiveView.swift   # Morse code receiver
└── Components/
    ├── LiquidGlassView.swift    # Reusable glass UI components
    └── MorseReferenceSheet.swift # Morse code alphabet reference
```

## How Morse Code Works

- **Sending**: Enter text, tap Send, and the app flashes your torch in morse code patterns
- **Receiving**: Point your camera at a flashing light source and the app decodes the morse pattern in real-time
- **Speed**: Adjustable from 5-30 words per minute (WPM)
- **Detection**: Configurable brightness threshold for different lighting conditions
