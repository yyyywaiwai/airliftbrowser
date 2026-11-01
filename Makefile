APP := dist/Airlift Browser.app

.PHONY: all open clean strings test-discovery

all:
	./Scripts/build.sh

open: all
	open "$(APP)"

test-discovery:
	mkdir -p .build
	xcrun clang -fobjc-arc -Wall -Wextra -mmacosx-version-min=14.0 \
	  -framework Foundation -framework CoreFoundation \
	  /System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice \
	  Tests/BrowserBridge/DiscoveryTests.m -o .build/discovery-tests
	.build/discovery-tests

# Add new UI strings to the catalog; translate the new entries afterwards.
strings:
	rm -rf .build/loc && mkdir -p .build/loc
	swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$(CURDIR)/.build/loc"
	xcrun xcstringstool sync Localization/Localizable.xcstrings --stringsdata .build/loc/*.stringsdata

clean:
	rm -rf .build dist
