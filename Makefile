prefix ?= $(HOME)/.local
INSTALL_DIR = $(prefix)/bin
NOTARY_PROFILE ?=

# Mac app (the single provider: mock + passthrough)
MAC_CODESIGN_MATCH ?= Developer ID Application
MAC_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(MAC_CODESIGN_MATCH)/ {print $$2; exit}')
MAC_CODESIGN_FLAGS ?= --options runtime --timestamp
MAC_SRCS = $(shell find Sources/ImpossiBLE-Mac \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) -not -path '*/.build/*' 2>/dev/null)
MAC_PLIST = Sources/ImpossiBLE-Mac/Resources/Info.plist
MAC_ENTITLEMENTS = Sources/ImpossiBLE-Mac/Resources/entitlements.plist
MAC_ICON = Sources/ImpossiBLE-Mac/Resources/ImpossiBLE.icns
MAC_BUNDLE = ImpossiBLE-Mac.app
MAC_BIN = $(MAC_BUNDLE)/Contents/MacOS/ImpossiBLE-Mac
MAC_BIN_NAME = ImpossiBLE-Mac
MAC_FONT_RESOURCE = Sources/ImpossiBLE-Mac/ProviderKit/Resources/fa-brands-400.ttf
INSTALLED_MAC_APP = $(INSTALL_DIR)/$(MAC_BUNDLE)
MAC_DIST_ZIP = ImpossiBLE-Mac.zip

# Legacy helper artifacts (pre-3.0), removed on uninstall
LEGACY_HELPER_APP = $(INSTALL_DIR)/impossible-helper.app
LEGACY_HELPER_WRAPPER = $(INSTALL_DIR)/impossible-helper

# Monotonic build number derived from commit count; falls back to the
# value already in the source Info.plist when the tree is not a git
# checkout (e.g. Homebrew unpacks a tarball).
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null)

.DEFAULT_GOAL := help

.PHONY: help install uninstall clean \
        mac mac-debug mac-dev mac-relaunch mac-install mac-run mac-stop mac-status mac-log mac-assess mac-notarize mac-clean

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Mac app (virtual BLE devices + passthrough to real hardware):"
	@echo "  mac         Build the Mac menubar app (release)"
	@echo "  mac-debug  Build with debug symbols"
	@echo "  mac-dev    Stop, debug-build, and run in foreground"
	@echo "  mac-relaunch  Quick debug rebuild and background relaunch"
	@echo "  mac-run    Install and start the Mac app"
	@echo "  mac-stop   Stop the running Mac app"
	@echo "  mac-status Show whether the Mac app is running"
	@echo "  mac-log    Tail system log output from the Mac app"
	@echo "  mac-assess Verify signing and Gatekeeper assessment"
	@echo "  mac-notarize Notarize the Mac app (requires NOTARY_PROFILE)"
	@echo "  mac-clean  Remove Mac build artifacts"
	@echo ""
	@echo "General:"
	@echo "  install     Build and install the Mac app to \$$(prefix)/bin  [$(prefix)]"
	@echo "  uninstall   Remove installed files from \$$(prefix)/bin"
	@echo "  clean       Remove all build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  prefix          Install prefix       [$(prefix)]"
	@echo "  MAC_CODESIGN_MATCH  Mac signing identity [$(MAC_CODESIGN_MATCH)]"
	@echo "  NOTARY_PROFILE  notarytool profile    [$(NOTARY_PROFILE)]"

install: mac-install

mac-install: mac
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_MAC_APP)
	cp -R $(MAC_BUNDLE) $(INSTALL_DIR)/
	@xattr -cr $(INSTALLED_MAC_APP) 2>/dev/null || true

uninstall:
	rm -rf $(INSTALLED_MAC_APP)
	rm -rf $(LEGACY_HELPER_APP)
	rm -f $(LEGACY_HELPER_WRAPPER)
	@echo "Uninstalled from $(INSTALL_DIR)"

# ---- Mac App ----

SWIFTFLAGS ?= -O
SWIFTFLAGS_COMMON = -swift-version 5
SWIFTPM_FLAGS ?= --disable-sandbox

mac: $(MAC_BIN)

mac-debug: SWIFTFLAGS = -g -Onone -DDEBUG
mac-debug: $(MAC_BIN)
	@echo "Debug build complete. Run with:"
	@echo "  $(MAC_BIN)"

mac-dev:
mac-dev: mac-clean $(MAC_BIN)
	@pkill -f "$(MAC_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@echo "Starting in foreground… (^C to stop)"
	$(MAC_BIN)

mac-relaunch:
	@mkdir -p $(MAC_BUNDLE)/Contents/MacOS
	@mkdir -p $(MAC_BUNDLE)/Contents/Resources
	@cp $(MAC_PLIST) $(MAC_BUNDLE)/Contents/Info.plist
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MAC_BUNDLE)/Contents/Info.plist; fi
	@cd Sources/ImpossiBLE-Mac && swift build $(SWIFTPM_FLAGS) 2>&1 | tail -3
	@cp Sources/ImpossiBLE-Mac/.build/debug/$(MAC_BIN_NAME) $(MAC_BIN)
	@cp $(MAC_ICON) $(MAC_BUNDLE)/Contents/Resources/ImpossiBLE.icns
	@cp $(MAC_FONT_RESOURCE) $(MAC_BUNDLE)/Contents/Resources/
	@codesign --force --sign - --entitlements $(MAC_ENTITLEMENTS) $(MAC_BUNDLE) >/dev/null
	@xattr -cr $(MAC_BUNDLE) 2>/dev/null || true
	@pkill -f "ImpossiBLE-Mac" 2>/dev/null && sleep 0.5 || true
	@open "$(MAC_BUNDLE)"
	@echo "Mac app relaunched (debug build)"

$(MAC_BIN): $(MAC_SRCS) $(MAC_PLIST) $(MAC_ENTITLEMENTS) $(MAC_ICON) $(MAC_FONT_RESOURCE)
	mkdir -p $(MAC_BUNDLE)/Contents/MacOS
	mkdir -p $(MAC_BUNDLE)/Contents/Resources
	cp $(MAC_PLIST) $(MAC_BUNDLE)/Contents/Info.plist
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MAC_BUNDLE)/Contents/Info.plist; fi
	cd Sources/ImpossiBLE-Mac && swift build $(SWIFTPM_FLAGS) -c release
	cp Sources/ImpossiBLE-Mac/.build/release/ImpossiBLE-Mac $(MAC_BIN)
	cp $(MAC_ICON) $(MAC_BUNDLE)/Contents/Resources/ImpossiBLE.icns
	cp $(MAC_FONT_RESOURCE) $(MAC_BUNDLE)/Contents/Resources/
	@if [ -z "$(MAC_SIGN_IDENTITY)" ]; then \
		echo "WARNING: No codesigning identity matching '$(MAC_CODESIGN_MATCH)' found in your keychain."; \
		echo "Signing the Mac app ad hoc. Gatekeeper will reject quarantined or distributed copies."; \
		codesign --force --sign - --entitlements $(MAC_ENTITLEMENTS) $(MAC_BUNDLE); \
	else \
		echo "Codesigning Mac app with: $(MAC_SIGN_IDENTITY)"; \
		codesign --force --sign "$(MAC_SIGN_IDENTITY)" $(MAC_CODESIGN_FLAGS) --entitlements $(MAC_ENTITLEMENTS) $(MAC_BUNDLE); \
	fi
	@xattr -cr $(MAC_BUNDLE) 2>/dev/null || true

mac-run: mac-install
	@pkill -f "$(MAC_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@open "$(INSTALLED_MAC_APP)"
	@echo "ImpossiBLE-Mac started"

mac-stop:
	@pid=$$(pgrep -f "$(MAC_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		kill "$$pid"; \
		echo "impossible-mac stopped (was PID $$pid)"; \
	else \
		echo "impossible-mac is not running"; \
	fi

mac-status:
	@pid=$$(pgrep -f "$(MAC_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		echo "impossible-mac is running (PID $$pid)"; \
	else \
		echo "impossible-mac is not running"; \
	fi

mac-log:
	@echo "Tailing logs for ImpossiBLE-Mac… (^C to stop)"
	@log stream --predicate 'process == "$(MAC_BIN_NAME)"' --style compact

mac-assess: mac
	codesign --verify --deep --strict --verbose=4 $(MAC_BUNDLE)
	spctl -a -vvv -t exec $(MAC_BUNDLE)

mac-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "ERROR: Set NOTARY_PROFILE to a notarytool keychain profile."; \
		echo "Example: xcrun notarytool store-credentials impossible-notary"; \
		exit 1; \
	fi
	$(MAKE) mac-clean
	$(MAKE) mac
	rm -f $(MAC_DIST_ZIP)
	ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 $(MAC_BUNDLE) $(MAC_DIST_ZIP)
	xcrun notarytool submit $(MAC_DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(MAC_BUNDLE)
	$(MAKE) mac-assess

mac-clean:
	rm -rf $(MAC_BUNDLE) $(MAC_DIST_ZIP)

# ---- General ----

clean: mac-clean
	rm -rf impossible-helper.app impossible-helper.zip
