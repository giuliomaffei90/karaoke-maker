#!/bin/bash
# Builds dist/Karaoke Maker.app
set -euo pipefail
cd "$(dirname "$0")"

# Oldest macOS supported; keep it equal to `platforms` in Package.swift. SpeechAnalyzer needs macOS 26.
MIN_MACOS=26.0
# SwiftPM's default build engine stamps the binary as built with the SDK of MIN_MACOS; tell the linker the
# real SDK so macOS draws the app with the current look.
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$(xcrun --show-sdk-version)"

APP="dist/Karaoke Maker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/KaraokeMaker "$APP/Contents/MacOS/"
cp Resources/align.py "$APP/Contents/Resources/"
# AppIcon.icon is an Icon Composer document. actool runs through a background service that resolves
# relative paths against its own working directory: always hand it absolute paths.
xcrun actool "$PWD/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon \
  --include-all-app-icons --platform macosx --target-device mac --minimum-deployment-target "$MIN_MACOS" \
  --output-partial-info-plist "$(mktemp)" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>KaraokeMaker</string>
    <key>CFBundleIdentifier</key><string>com.giuliomaffei.KaraokeMaker</string>
    <key>CFBundleName</key><string>Karaoke Maker</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Karaoke Maker recognises the lyrics of your songs on this Mac.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Karaoke Project</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.giuliomaffei.KaraokeMaker.song</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Audio or Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.giuliomaffei.KaraokeMaker.song</string>
            <key>UTTypeDescription</key><string>Karaoke Project</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>kr</string><string>karaoke</string></array></dict>
            <key>UTTypeIcons</key>
            <dict>
                <key>UTTypeIconBadgeName</key><string>AppIcon</string>
                <key>UTTypeIconText</key><string>karaoke</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
