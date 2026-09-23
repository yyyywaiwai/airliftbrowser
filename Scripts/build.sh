#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/Airlift Browser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/"{MacOS,Helpers,Resources}
cp "$(swift build -c release --show-bin-path)/AirliftBrowser" "$APP/Contents/MacOS/AirliftBrowser"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0 \
  -framework Foundation -framework CoreFoundation \
  /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice \
  Sources/BrowserBridge/main.m -o "$APP/Contents/Helpers/browser_bridge"
mkdir -p .build/poc "$APP/Contents/Resources/AirliftPoC/Sources"
mkdir -p "$APP/Contents/Resources/DeviceFiles"
mkdir -p "$APP/Contents/Resources/AppManagement"
sed 's/if (!\[summary\[@"productType"\] hasPrefix:@"iPhone"\]) return NO;/if (!([summary[@"productType"] hasPrefix:@"iPhone"] || [summary[@"productType"] hasPrefix:@"iPad"])) return NO;/' \
  airlift/Sources/device_helper.m > .build/poc/device_helper.m
xcrun clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0 \
  -I airlift/Sources -framework Foundation -framework CoreFoundation \
  /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice \
  .build/poc/device_helper.m -o "$APP/Contents/Helpers/poc_device_helper"
sed 's/argc < 6/argc < 4/; s/pairCount > 4/pairCount > 6/' airlift/Sources/airtraffic_host.m > .build/poc/airtraffic_host.m
python3 - <<'PY'
from pathlib import Path
path = Path(".build/poc/airtraffic_host.m")
text = path.read_text()
text = text.replace("#include <unistd.h>\n", "#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\n", 1)
old = """        for (NSUInteger index = 0; index < assets.count; index++) {
            NSDictionary *asset = assets[index];
            ATHostConnectionSendAssetCompleted(
                connection,
                (__bridge CFStringRef)asset[@"identifier"],
                CFSTR("Book"),
                (__bridge CFStringRef)asset[@"destination"]);
            if (index + 1 < assets.count) usleep(900000);
        }
        sleep(2);"""
new = """        BOOL stepped = getenv("AIRLIFT_STEP") != NULL;
        for (NSUInteger index = 0; index < assets.count; index++) {
            NSDictionary *asset = assets[index];
            ATHostConnectionSendAssetCompleted(
                connection,
                (__bridge CFStringRef)asset[@"identifier"],
                CFSTR("Book"),
                (__bridge CFStringRef)asset[@"destination"]);
            if (stepped) {
                char message[48];
                int length = snprintf(message, sizeof message, "AIRLIFT_STEP %lu\\n", (unsigned long)index);
                if (length > 0) write(STDERR_FILENO, message, (size_t)length);
                char answer = 0;
                if (read(STDIN_FILENO, &answer, 1) != 1) break;
            } else if (index + 1 < assets.count) {
                usleep(900000);
            }
        }
        if (!stepped) sleep(2);"""
if old not in text:
    raise SystemExit("airtraffic_host patch point missing")
path.write_text(text.replace(old, new, 1))
PY
xcrun clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0 \
  -framework Foundation -framework CoreFoundation \
  /System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost \
  .build/poc/airtraffic_host.m -o "$APP/Contents/Helpers/airtraffic_host"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=14.0 \
  -framework AppKit -framework ImageIO -framework CoreGraphics \
  Sources/PoC/mask_image.m -o "$APP/Contents/Helpers/mask_image"
cp airlift/airlift.py Sources/PoC/runner.py Sources/PoC/write_file.py Sources/PoC/delete_file.py Sources/PoC/list_cards.py Sources/PoC/edit_card.py "$APP/Contents/Resources/AirliftPoC/"
cp Sources/DeviceFiles/container_files.py Sources/DeviceFiles/dvt_files.py "$APP/Contents/Resources/DeviceFiles/"
cp Sources/AppManagement/*.py "$APP/Contents/Resources/AppManagement/"
cp airlift/Sources/airlift_target.h "$APP/Contents/Resources/AirliftPoC/Sources/"
cp airlift/LICENSE "$APP/Contents/Resources/Airlift-LICENSE.txt"
ICON_OUT="$PWD/.build/icon"
rm -rf "$ICON_OUT"
mkdir -p "$ICON_OUT"
xcrun actool \
  --compile "$ICON_OUT" \
  --app-icon AirliftBrowser \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 14.0 \
  --platform macosx \
  --standalone-icon-behavior all \
  --output-partial-info-plist "$ICON_OUT/partial.plist" \
  "$PWD/AirliftBrowser.icon" >/dev/null
cp "$ICON_OUT/AirliftBrowser.icns" "$ICON_OUT/Assets.car" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Airlift Browser</string>
<key>CFBundleDisplayName</key><string>Airlift Browser</string>
<key>CFBundleIdentifier</key><string>local.airlift.browser</string>
<key>CFBundleExecutable</key><string>AirliftBrowser</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AirliftBrowser</string>
<key>CFBundleIconName</key><string>AirliftBrowser</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.airlift.app-backup</string>
<key>UTTypeDescription</key><string>Airlift App Backup</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.directory</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>airliftbackup</string></array></dict>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/browser_bridge"
codesign --force --sign - "$APP/Contents/Helpers/poc_device_helper"
codesign --force --sign - "$APP/Contents/Helpers/airtraffic_host"
codesign --force --sign - "$APP/Contents/Helpers/mask_image"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '\n%s\n' "$APP"
