PREFIX ?= /usr/local
SWIFTC ?= swiftc
SWIFTFLAGS ?= -O -swift-version 5
MODULE_CACHE ?= build/module-cache
SOURCES := $(wildcard Sources/hidpi/*.swift)
LIB_SOURCES := $(filter-out Sources/hidpi/main.swift,$(SOURCES))
APP := build/HiDPI.app

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Assets/Info.plist)
MIN_MACOS ?= 13.0
RELEASE := build/release

.PHONY: all clean install uninstall app test release

all: build/hidpi

build/hidpi: $(SOURCES)
	@mkdir -p build
	$(SWIFTC) $(SWIFTFLAGS) -module-cache-path "$(MODULE_CACHE)" -o $@ $(SOURCES)

install: build/hidpi
	install -d "$(PREFIX)/bin"
	install -m 755 build/hidpi "$(PREFIX)/bin/hidpi"

uninstall:
	rm -f "$(PREFIX)/bin/hidpi"
	@echo "Remove HiDPI.app separately after disabling Launch at Login in its settings."

build/HiDPI.icns: Assets/HiDPI.png Scripts/build-icon.sh
	sh Scripts/build-icon.sh

app: build/hidpi build/HiDPI.icns Assets/Info.plist
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@rm -f $(APP)/Contents/MacOS/launch
	cp build/hidpi $(APP)/Contents/MacOS/HiDPI
	cp build/HiDPI.icns $(APP)/Contents/Resources/HiDPI.icns
	cp Assets/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	codesign --verify --strict $(APP)
	@echo "Built $(APP)"

build/hidpi-tests: $(LIB_SOURCES) Tests/TestRunner.swift
	@mkdir -p build
	$(SWIFTC) -swift-version 5 -module-cache-path "$(MODULE_CACHE)" -o $@ $(LIB_SOURCES) Tests/TestRunner.swift

test: build/hidpi build/hidpi-tests
	build/hidpi-tests
	sh Tests/cli-smoke.sh build/hidpi

clean:
	rm -rf build

# Distribution build: a universal (Apple Silicon + Intel) binary that runs on macOS $(MIN_MACOS)+.
# The default `all`/`app` targets build only for this Mac and its macOS version.
$(RELEASE)/hidpi: $(SOURCES)
	@mkdir -p $(RELEASE)
	for arch in arm64 x86_64; do \
		$(SWIFTC) $(SWIFTFLAGS) -target $$arch-apple-macos$(MIN_MACOS) -module-cache-path "$(MODULE_CACHE)" \
			-o $(RELEASE)/hidpi-$$arch $(SOURCES) || exit 1; \
	done
	lipo -create -output $@ $(RELEASE)/hidpi-arm64 $(RELEASE)/hidpi-x86_64
	codesign --force --sign - $@

release: $(RELEASE)/hidpi build/HiDPI.icns Assets/Info.plist
	rm -rf $(RELEASE)/HiDPI.app
	mkdir -p $(RELEASE)/HiDPI.app/Contents/MacOS $(RELEASE)/HiDPI.app/Contents/Resources
	cp $(RELEASE)/hidpi $(RELEASE)/HiDPI.app/Contents/MacOS/HiDPI
	cp build/HiDPI.icns $(RELEASE)/HiDPI.app/Contents/Resources/HiDPI.icns
	cp Assets/Info.plist $(RELEASE)/HiDPI.app/Contents/Info.plist
	codesign --force --sign - $(RELEASE)/HiDPI.app
	codesign --verify --strict $(RELEASE)/HiDPI.app
	cd $(RELEASE) && rm -f *.zip SHA256SUMS.txt \
		&& ditto -c -k --keepParent HiDPI.app HiDPI-$(VERSION).zip \
		&& ditto -c -k hidpi hidpi-cli-$(VERSION).zip \
		&& shasum -a 256 *.zip > SHA256SUMS.txt
	@echo "Release files in $(RELEASE):" && ls -1 $(RELEASE)/*.zip $(RELEASE)/SHA256SUMS.txt

# Run only in an interactive macOS GUI session. Shows a one-second test dialog.
build/hidpi-preview-timer-test: $(LIB_SOURCES) Tests/PreviewTimer.swift
	@mkdir -p build
	$(SWIFTC) -swift-version 5 -module-cache-path "$(MODULE_CACHE)" -o $@ $(LIB_SOURCES) Tests/PreviewTimer.swift
