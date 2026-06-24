PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
SCRIPT  := create-dokploy-s3-destination.sh
BIN     := create-dokploy-s3-destination

.PHONY: install uninstall lint test help

help:
	@echo "Targets:"
	@echo "  make install     Install '$(BIN)' to $(BINDIR) (override with PREFIX=...)"
	@echo "  make uninstall   Remove '$(BIN)' from $(BINDIR)"
	@echo "  make lint        Run shellcheck on the script"
	@echo "  make test        Run the bats test suite (tests/)"
	@echo ""
	@echo "Examples:"
	@echo "  sudo make install                 # system-wide"
	@echo "  make install PREFIX=\$$HOME/.local  # user-only, no sudo"

install:
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 "$(SCRIPT)" "$(DESTDIR)$(BINDIR)/$(BIN)"
	@echo "Installed $(BIN) -> $(DESTDIR)$(BINDIR)/$(BIN)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(BIN)"
	@echo "Removed $(DESTDIR)$(BINDIR)/$(BIN)"

lint:
	shellcheck "$(SCRIPT)" install.sh

test:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "bats not found. Install bats-core: https://github.com/bats-core/bats-core (e.g. 'brew install bats-core')"; \
		exit 1; \
	fi
	bats tests/
