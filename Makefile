HELPER_SRC = Sources/Helper/CBSHelperMain.m
HELPER_PLIST = Sources/Helper/Info.plist
HELPER_ENTITLEMENTS = Sources/Helper/entitlements.plist
APP_BUNDLE = impossible-helper.app
APP_BIN = $(APP_BUNDLE)/Contents/MacOS/impossible-helper
prefix ?= $(HOME)/.local
INSTALL_DIR = $(prefix)/bin
INSTALLED_APP = $(INSTALL_DIR)/impossible-helper.app
HELPER_BIN_NAME = impossible-helper
CODESIGN_MATCH ?= Apple Development
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(CODESIGN_MATCH)/ {print $$2; exit}')

CFLAGS ?= -O2
CFLAGS_COMMON = -fobjc-arc
FRAMEWORKS = -framework Foundation -framework CoreBluetooth

.DEFAULT_GOAL := help

.PHONY: help helper debug dev install uninstall clean run stop restart status log watch

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Build:"
	@echo "  helper      Build the helper app (release)"
	@echo "  debug       Build the helper app with debug symbols"
	@echo "  clean       Remove build artifacts"
	@echo ""
	@echo "Install:"
	@echo "  install     Build and install to \$$(prefix)/bin  [$(prefix)]"
	@echo "  uninstall   Remove installed files from \$$(prefix)/bin"
	@echo ""
	@echo "Run:"
	@echo "  dev         Stop, debug-build, and run in foreground"
	@echo "  run         Install and start (if not already running)"
	@echo "  stop        Stop the running helper"
	@echo "  restart     Install, stop, and restart the helper"
	@echo "  status      Show whether the helper is running"
	@echo "  log         Tail system log output from the helper"
	@echo "  watch       Rebuild and restart on source changes (requires fswatch)"
	@echo ""
	@echo "Variables:"
	@echo "  prefix          Install prefix       [$(prefix)]"
	@echo "  CODESIGN_MATCH  Signing identity      [$(CODESIGN_MATCH)]"

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
		echo "Proceeding unsigned. Install a certificate or set CODESIGN_MATCH to sign."; \
	else \
		echo "Codesigning with: $(SIGN_IDENTITY)"; \
		codesign --force --sign "$(SIGN_IDENTITY)" --entitlements $(HELPER_ENTITLEMENTS) $(APP_BUNDLE); \
	fi

install: helper
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_APP)
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	install -m 755 bin/impossible-helper $(INSTALL_DIR)/impossible-helper

uninstall:
	rm -rf $(INSTALLED_APP)
	rm -f $(INSTALL_DIR)/impossible-helper
	@echo "Uninstalled from $(INSTALL_DIR)"

restart: install
	-pkill -f $(HELPER_BIN_NAME) 2>/dev/null; sleep 0.5
	open -a "$(INSTALLED_APP)"
	@echo "impossible-helper restarted"

run: install
	@if ! pgrep -f $(HELPER_BIN_NAME) > /dev/null 2>&1; then \
		open -a "$(INSTALLED_APP)"; \
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

watch: install
	@if ! pgrep -f $(HELPER_BIN_NAME) > /dev/null 2>&1; then \
		open -a "$(INSTALLED_APP)"; \
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
			open -a "$(INSTALLED_APP)"; \
			echo "=== Restarted ==="; \
		else \
			echo "=== Build failed ==="; \
		fi; \
	done

clean:
	rm -rf $(APP_BUNDLE)
