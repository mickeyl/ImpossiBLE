HELPER_SRC = Sources/Helper/CBSHelperMain.m
HELPER_PLIST = Sources/Helper/Info.plist
HELPER_ENTITLEMENTS = Sources/Helper/entitlements.plist
APP_BUNDLE = impossible-helper.app
APP_BIN = $(APP_BUNDLE)/Contents/MacOS/impossible-helper
INSTALL_DIR = $(HOME)/.local/bin
INSTALLED_APP = $(INSTALL_DIR)/impossible-helper.app
HELPER_BIN_NAME = impossible-helper
CODESIGN_MATCH ?= Apple Development
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(CODESIGN_MATCH)/ {print $$2; exit}')

.PHONY: helper install clean run restart watch

helper: $(APP_BIN)

$(APP_BIN): $(HELPER_SRC) $(HELPER_PLIST) $(HELPER_ENTITLEMENTS)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp $(HELPER_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	clang -fobjc-arc -framework Foundation -framework CoreBluetooth \
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
