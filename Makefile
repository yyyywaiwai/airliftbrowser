APP := dist/Airlift Browser.app

.PHONY: all open clean strings

all:
	./Scripts/build.sh

open: all
	open "$(APP)"

# Add new UI strings to the catalog; translate the new entries afterwards.
strings:
	rm -rf .build/loc && mkdir -p .build/loc
	swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$(CURDIR)/.build/loc"
	xcrun xcstringstool sync Localization/Localizable.xcstrings --stringsdata .build/loc/*.stringsdata

clean:
	rm -rf .build dist
