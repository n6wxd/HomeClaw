---
description: Create xcarchive for TestFlight
allowed-tools: Bash(scripts/*), Bash(open *)
---

Create an Xcode archive for TestFlight / App Store distribution.

1. Run `scripts/archive.sh`
2. Report the archive location and version
3. Ask if the user wants to open in Xcode Organizer: `open .build/archives/HomeClaw.xcarchive`
