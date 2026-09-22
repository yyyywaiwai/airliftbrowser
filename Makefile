APP := dist/Airlift Browser.app

.PHONY: all open clean

all:
	./Scripts/build.sh

open: all
	open "$(APP)"

clean:
	rm -rf .build dist
