APP        := build/Kuroko.app
BUNDLE_ID  := com.neveroddoreven.kuroko
IDENTITY   := Kuroko Dev
BIN_DIR     = $(shell swift build -c release --show-bin-path)

.PHONY: build test app sign run install cert clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$(BIN_DIR)/Kuroko" $(APP)/Contents/MacOS/Kuroko
	cp Resources/Info.plist $(APP)/Contents/Info.plist

# Signs with the stable dev identity when present (see `make cert`), else ad-hoc.
sign: app
	@if security find-identity -v -p codesigning | grep -q '"$(IDENTITY)"'; then \
		codesign --force --options runtime --sign "$(IDENTITY)" --identifier $(BUNDLE_ID) $(APP); \
	else \
		echo "warning: '$(IDENTITY)' not found; signing ad-hoc. Screen Recording must be re-granted after each build. Run 'make cert'."; \
		codesign --force --options runtime --sign - --identifier $(BUNDLE_ID) $(APP); \
	fi

run: sign
	-pkill -x Kuroko
	open $(APP)

install: sign
	-pkill -x Kuroko
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/Kuroko.app"
	ditto $(APP) "$(HOME)/Applications/Kuroko.app"
	open "$(HOME)/Applications/Kuroko.app"

cert:
	scripts/make-dev-cert.sh "$(IDENTITY)"

clean:
	rm -rf .build build
