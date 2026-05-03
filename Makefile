HELPER_SRC = Sources/Helper/CBSHelperMain.m
HELPER_PLIST = Sources/Helper/Info.plist
HELPER_ENTITLEMENTS = Sources/Helper/entitlements.plist
APP_BUNDLE = impossible-helper.app
APP_BIN = $(APP_BUNDLE)/Contents/MacOS/impossible-helper
prefix ?= $(HOME)/.local
INSTALL_DIR = $(prefix)/bin
INSTALLED_APP = $(INSTALL_DIR)/impossible-helper.app
HELPER_BIN_NAME = impossible-helper
CODESIGN_MATCH ?= Developer ID Application
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(CODESIGN_MATCH)/ {print $$2; exit}')
HELPER_CODESIGN_FLAGS ?= --options runtime --timestamp
HELPER_DIST_ZIP = impossible-helper.zip

CFLAGS ?= -O2
CFLAGS_COMMON = -fobjc-arc
FRAMEWORKS = -framework Foundation -framework CoreBluetooth

# Mock app
MOCK_CODESIGN_MATCH ?= Developer ID Application
MOCK_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(MOCK_CODESIGN_MATCH)/ {print $$2; exit}')
MOCK_CODESIGN_FLAGS ?= --options runtime --timestamp
MOCK_SRCS = $(shell find Sources/MockApp -name '*.swift' 2>/dev/null)
MOCK_PLIST = Sources/MockApp/Resources/Info.plist
MOCK_ENTITLEMENTS = Sources/MockApp/Resources/entitlements.plist
MOCK_BUNDLE = ImpossiBLE-Mock.app
MOCK_BIN = $(MOCK_BUNDLE)/Contents/MacOS/ImpossiBLE-Mock
MOCK_BIN_NAME = ImpossiBLE-Mock
MOCK_FONT_RESOURCE = Sources/MockApp/Resources/fa-brands-400.ttf
INSTALLED_MOCK_APP = $(INSTALL_DIR)/$(MOCK_BUNDLE)
MOCK_DIST_ZIP = ImpossiBLE-Mock.zip
NOTARY_PROFILE ?=

.DEFAULT_GOAL := help

.PHONY: help helper debug dev install uninstall clean run stop restart status log watch helper-assess helper-notarize \
        mock mock-debug mock-dev mock-relaunch mock-install mock-run mock-stop mock-assess mock-notarize mock-clean

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Helper (real BLE bridge):"
	@echo "  helper      Build the helper app (release)"
	@echo "  debug       Build the helper app with debug symbols"
	@echo "  dev         Stop, debug-build, and run in foreground"
	@echo "  run         Install and start (if not already running)"
	@echo "  stop        Stop the running helper"
	@echo "  restart     Install, stop, and restart the helper"
	@echo "  status      Show whether the helper is running"
	@echo "  log         Tail system log output from the helper"
	@echo "  watch       Rebuild and restart on source changes (requires fswatch)"
	@echo "  helper-assess Verify signing and Gatekeeper assessment"
	@echo "  helper-notarize Notarize the helper app (requires NOTARY_PROFILE)"
	@echo ""
	@echo "Mock (virtual BLE devices):"
	@echo "  mock        Build the mock menubar app (release)"
	@echo "  mock-debug  Build with debug symbols"
	@echo "  mock-dev    Stop, debug-build, and run in foreground"
	@echo "  mock-relaunch  Quick helper/mock debug rebuild and background relaunch"
	@echo "  mock-run    Install and start the mock app"
	@echo "  mock-stop   Stop the running mock app"
	@echo "  mock-assess Verify signing and Gatekeeper assessment"
	@echo "  mock-notarize Notarize the mock app (requires NOTARY_PROFILE)"
	@echo "  mock-clean  Remove mock build artifacts"
	@echo ""
	@echo "General:"
	@echo "  install     Build and install both apps to \$$(prefix)/bin  [$(prefix)]"
	@echo "  uninstall   Remove installed files from \$$(prefix)/bin"
	@echo "  clean       Remove all build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  prefix          Install prefix       [$(prefix)]"
	@echo "  CODESIGN_MATCH  Signing identity      [$(CODESIGN_MATCH)]"
	@echo "  MOCK_CODESIGN_MATCH  Mock signing identity [$(MOCK_CODESIGN_MATCH)]"
	@echo "  NOTARY_PROFILE  notarytool profile    [$(NOTARY_PROFILE)]"

helper: $(APP_BIN)

debug: CFLAGS = -g -O0 -DDEBUG
debug: $(APP_BIN)
	@echo "Debug build complete. Run with:"
	@echo "  $(APP_BIN)"

dev: CFLAGS = -g -O0 -DDEBUG
dev: clean $(APP_BIN)
	@pkill -f "$(HELPER_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@echo "Starting in foreground… (^C to stop)"
	$(APP_BIN)

$(APP_BIN): $(HELPER_SRC) $(HELPER_PLIST) $(HELPER_ENTITLEMENTS)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp $(HELPER_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	clang $(CFLAGS_COMMON) $(CFLAGS) $(FRAMEWORKS) \
		-o $(APP_BIN) $(HELPER_SRC)
	@if [ -z "$(SIGN_IDENTITY)" ]; then \
		echo "WARNING: No codesigning identity matching '$(CODESIGN_MATCH)' found in your keychain."; \
		echo "Signing the helper ad hoc. Gatekeeper will reject quarantined or distributed copies."; \
		codesign --force --sign - --entitlements $(HELPER_ENTITLEMENTS) $(APP_BUNDLE); \
	else \
		echo "Codesigning helper with: $(SIGN_IDENTITY)"; \
		codesign --force --sign "$(SIGN_IDENTITY)" $(HELPER_CODESIGN_FLAGS) --entitlements $(HELPER_ENTITLEMENTS) $(APP_BUNDLE); \
	fi
	@xattr -cr $(APP_BUNDLE) 2>/dev/null || true

install: helper mock
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_APP)
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@xattr -cr $(INSTALLED_APP) 2>/dev/null || true
	install -m 755 bin/impossible-helper $(INSTALL_DIR)/impossible-helper
	rm -rf $(INSTALLED_MOCK_APP)
	cp -R $(MOCK_BUNDLE) $(INSTALL_DIR)/
	@xattr -cr $(INSTALLED_MOCK_APP) 2>/dev/null || true

mock-install: mock
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_MOCK_APP)
	cp -R $(MOCK_BUNDLE) $(INSTALL_DIR)/
	@xattr -cr $(INSTALLED_MOCK_APP) 2>/dev/null || true

uninstall:
	rm -rf $(INSTALLED_APP)
	rm -f $(INSTALL_DIR)/impossible-helper
	rm -rf $(INSTALLED_MOCK_APP)
	@echo "Uninstalled from $(INSTALL_DIR)"

restart: install
	-pkill -f $(HELPER_BIN_NAME) 2>/dev/null; sleep 0.5
	open "$(INSTALLED_APP)"
	@echo "impossible-helper restarted"

run: install
	@if ! pgrep -f $(HELPER_BIN_NAME) > /dev/null 2>&1; then \
		open "$(INSTALLED_APP)"; \
		echo "impossible-helper started"; \
	else \
		echo "impossible-helper already running"; \
	fi

stop:
	@pid=$$(pgrep -f "$(HELPER_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		kill "$$pid"; \
		echo "impossible-helper stopped (was PID $$pid)"; \
	else \
		echo "impossible-helper is not running"; \
	fi

status:
	@pid=$$(pgrep -f "$(HELPER_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		echo "impossible-helper is running (PID $$pid)"; \
	else \
		echo "impossible-helper is not running"; \
	fi

log:
	@echo "Tailing logs for ImpossiBLE-Helper… (^C to stop)"
	@log stream --predicate 'process == "impossible-helper"' --style compact

helper-assess: helper
	codesign --verify --deep --strict --verbose=4 $(APP_BUNDLE)
	spctl -a -vvv -t exec $(APP_BUNDLE)

helper-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "ERROR: Set NOTARY_PROFILE to a notarytool keychain profile."; \
		echo "Example: xcrun notarytool store-credentials impossible-notary"; \
		exit 1; \
	fi
	rm -rf $(APP_BUNDLE)
	$(MAKE) helper
	rm -f $(HELPER_DIST_ZIP)
	ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 $(APP_BUNDLE) $(HELPER_DIST_ZIP)
	xcrun notarytool submit $(HELPER_DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP_BUNDLE)
	$(MAKE) helper-assess

watch: install
	@if ! pgrep -f $(HELPER_BIN_NAME) > /dev/null 2>&1; then \
		open "$(INSTALLED_APP)"; \
		echo "impossible-helper started"; \
	else \
		echo "impossible-helper already running"; \
	fi
	@echo "Watching for changes in Sources/Helper/…"
	@fswatch -o Sources/Helper/ | while read _; do \
		echo ""; \
		echo "=== Source changed, rebuilding… ==="; \
		if $(MAKE) install; then \
			pkill -f $(HELPER_BIN_NAME) 2>/dev/null; sleep 0.5; \
			open "$(INSTALLED_APP)"; \
			echo "=== Restarted ==="; \
		else \
			echo "=== Build failed ==="; \
		fi; \
	done

# ---- Mock App ----

SWIFTFLAGS ?= -O
SWIFTFLAGS_COMMON = -swift-version 5
SWIFTPM_FLAGS ?= --disable-sandbox

mock: $(MOCK_BIN)

mock-debug: SWIFTFLAGS = -g -Onone -DDEBUG
mock-debug: $(MOCK_BIN)
	@echo "Debug build complete. Run with:"
	@echo "  $(MOCK_BIN)"

mock-dev:
mock-dev: mock-clean $(MOCK_BIN)
	@pkill -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@echo "Starting in foreground… (^C to stop)"
	$(MOCK_BIN)

mock-relaunch: helper
	@mkdir -p $(MOCK_BUNDLE)/Contents/MacOS
	@mkdir -p $(MOCK_BUNDLE)/Contents/Resources
	@cp $(MOCK_PLIST) $(MOCK_BUNDLE)/Contents/Info.plist
	@cd Sources/MockApp && swift build $(SWIFTPM_FLAGS) 2>&1 | tail -3
	@cp Sources/MockApp/.build/debug/$(MOCK_BIN_NAME) $(MOCK_BIN)
	@cp $(MOCK_FONT_RESOURCE) $(MOCK_BUNDLE)/Contents/Resources/
	@codesign --force --sign - --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE) >/dev/null
	@xattr -cr $(MOCK_BUNDLE) 2>/dev/null || true
	@pkill -f "$(HELPER_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@pkill -f "ImpossiBLE-Mock" 2>/dev/null && sleep 0.5 || true
	@open "$(MOCK_BUNDLE)"
	@echo "Mock app relaunched (debug build)"

$(MOCK_BIN): $(MOCK_SRCS) $(MOCK_PLIST) $(MOCK_ENTITLEMENTS) $(MOCK_FONT_RESOURCE)
	mkdir -p $(MOCK_BUNDLE)/Contents/MacOS
	mkdir -p $(MOCK_BUNDLE)/Contents/Resources
	cp $(MOCK_PLIST) $(MOCK_BUNDLE)/Contents/Info.plist
	cd Sources/MockApp && swift build $(SWIFTPM_FLAGS) -c release
	cp Sources/MockApp/.build/release/ImpossiBLE-Mock $(MOCK_BIN)
	cp $(MOCK_FONT_RESOURCE) $(MOCK_BUNDLE)/Contents/Resources/
	@if [ -z "$(MOCK_SIGN_IDENTITY)" ]; then \
		echo "WARNING: No codesigning identity matching '$(MOCK_CODESIGN_MATCH)' found in your keychain."; \
		echo "Signing the mock app ad hoc. Gatekeeper will reject quarantined or distributed copies."; \
		codesign --force --sign - --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE); \
	else \
		echo "Codesigning mock app with: $(MOCK_SIGN_IDENTITY)"; \
		codesign --force --sign "$(MOCK_SIGN_IDENTITY)" $(MOCK_CODESIGN_FLAGS) --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE); \
	fi
	@xattr -cr $(MOCK_BUNDLE) 2>/dev/null || true

mock-run: mock-install
	@if ! pgrep -f $(MOCK_BIN_NAME) > /dev/null 2>&1; then \
		open "$(INSTALLED_MOCK_APP)"; \
		echo "impossible-mock started"; \
	else \
		echo "impossible-mock already running"; \
	fi

mock-stop:
	@pid=$$(pgrep -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		kill "$$pid"; \
		echo "impossible-mock stopped (was PID $$pid)"; \
	else \
		echo "impossible-mock is not running"; \
	fi

mock-assess: mock
	codesign --verify --deep --strict --verbose=4 $(MOCK_BUNDLE)
	spctl -a -vvv -t exec $(MOCK_BUNDLE)

mock-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "ERROR: Set NOTARY_PROFILE to a notarytool keychain profile."; \
		echo "Example: xcrun notarytool store-credentials impossible-notary"; \
		exit 1; \
	fi
	$(MAKE) mock-clean
	$(MAKE) mock
	rm -f $(MOCK_DIST_ZIP)
	ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 $(MOCK_BUNDLE) $(MOCK_DIST_ZIP)
	xcrun notarytool submit $(MOCK_DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(MOCK_BUNDLE)
	$(MAKE) mock-assess

mock-clean:
	rm -rf $(MOCK_BUNDLE) $(MOCK_DIST_ZIP)

# ---- General ----

clean:
	rm -rf $(APP_BUNDLE) $(HELPER_DIST_ZIP) $(MOCK_BUNDLE) $(MOCK_DIST_ZIP)
