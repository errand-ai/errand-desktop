# ErrandDesktop — Suggested Commands

## Build & Test (Swift Package Manager)
```bash
# Build (debug)
cd /Users/rob/github/errand-desktop && swift build

# Build (release)
cd /Users/rob/github/errand-desktop && swift build -c release

# Run tests
cd /Users/rob/github/errand-desktop && swift test

# Clean build artifacts
cd /Users/rob/github/errand-desktop && swift package clean
```

## Running the App
```bash
# Run directly (debug build)
cd /Users/rob/github/errand-desktop && swift run ErrandDesktop

# Run release build
cd /Users/rob/github/errand-desktop && .build/release/ErrandDesktop
```

## Distribution
```bash
# Create DMG (requires app bundle)
scripts/create-dmg.sh ErrandDesktop.app ErrandDesktop.dmg

# Code sign (requires Developer ID certificate)
codesign --deep --force --verify --verbose \
  --sign "Developer ID Application" \
  --options runtime \
  --entitlements ErrandDesktop.entitlements \
  "ErrandDesktop.app"
```

## Git
```bash
git status
git log --oneline -10
git diff
git checkout -b <branch-name>
git push -u origin <branch-name>
gh pr create --title "<title>" --body "<body>"
```

## System (macOS / Darwin)
```bash
# List files (macOS ls)
ls -la

# Find files
find . -name "*.swift"

# Search in files
grep -r "pattern" Sources/

# Check Swift version
swift --version
```
