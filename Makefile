PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
SCRIPT  := create-dokploy-s3-destination.sh
BIN     := create-dokploy-s3-destination

.PHONY: install uninstall lint help

help:
	@echo "Targets:"
	@echo "  make install     Install '$(BIN)' to $(BINDIR) (override with PREFIX=...)"
	@echo "  make uninstall   Remove '$(BIN)' from $(BINDIR)"
	@echo "  make lint        Run shellcheck on the script"
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
	shellcheck "$(SCRIPT)"
