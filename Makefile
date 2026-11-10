# LabelWerk – zentrale Befehle für Entwicklung, Tests und Release
#
#   make            Übersicht (dieses Hilfe-Ziel)
#   make test       alle Tests: Swift, CUPS-Filter, PPD-Generator, Werkzeuge, Katalogprüfung
#   make app        LabelWerk.app (macOS, Universal Binary)
#   make pkg        Installationspaket dist/LabelWerk-<Version>.pkg (macOS)
#
# Kompatibel mit GNU Make 3.81 (macOS) und 4.x (Linux). Konfiguration (Version, Bundle-ID,
# Signaturidentitäten) steht in Installer/config.env und lässt sich per Umgebung überschreiben:
#   VERSION=1.1.0 BUILD=42 make pkg
#   DEVELOPER_ID_APP="Developer ID Application: Firma (TEAMID)" make app

SHELL   := /bin/bash
PYTHON  ?= python3
SWIFT   ?= swift
UNAME_S := $(shell uname -s)

# Parallele Jobs für swift/make, z. B. `make test JOBS=2` (leer = Werkzeug entscheidet).
JOBS ?=
SWIFT_JOBS := $(if $(JOBS),-j $(JOBS),)
MAKE_JOBS  := $(if $(JOBS),-j $(JOBS),)

# Zusätzliche Optionen für die Skripte, z. B. `make app APP_ARGS=--debug`.
APP_ARGS      ?=
PKG_ARGS      ?=
DRIVER_ARGS   ?=
NOTARIZE_ARGS ?=

ifeq ($(UNAME_S),Darwin)
  DRIVER_HOST_ARGS :=
  CI_SCRIPT        := Scripts/ci_macos.sh
else
  # Universal Binaries gibt es nur auf macOS – anderswo ein Testaufbau für das eigene System.
  DRIVER_HOST_ARGS := --host
  CI_SCRIPT        := Scripts/ci_linux.sh
endif

PPD_CHECK_DIR := build/ppd-check
DEV_ROOT      := build/driver-root

.DEFAULT_GOAL := help

.PHONY: help catalog catalog-check build test test-swift test-driver test-ppd test-scripts \
        driver app pkg notarize icons strings strings-check lint ci clean distclean \
        install-dev uninstall-dev

help:
	@echo "LabelWerk – verfügbare Ziele"
	@echo ""
	@echo "  Entwicklung"
	@echo "    make build          Swift-Pakete bauen (Kern, lwctl; auf macOS auch die App)"
	@echo "    make catalog        Catalog/models.json neu erzeugen und in Swift einbetten"
	@echo "    make strings        Lokalisierung aus den tr(\"…\")-Aufrufen aktualisieren"
	@echo "    make icons          App- und Druckersymbol neu zeichnen (benötigt Pillow)"
	@echo ""
	@echo "  Tests & Prüfungen"
	@echo "    make test           alle Tests (Swift, Filter, PPD, Werkzeuge, Katalog)"
	@echo "    make test-swift     swift test"
	@echo "    make test-driver    CUPS-Filter: C-Unit-Tests und End-to-End-Tests"
	@echo "    make test-ppd       PPDs erzeugen, mit cupstestppd prüfen, Generator-Tests"
	@echo "    make test-scripts   Tests der Python- und Shell-Werkzeuge"
	@echo "    make lint           Syntax, ShellCheck, Workflow-YAML, Lokalisierung, Katalog"
	@echo "    make ci             kompletter CI-Lauf wie auf GitHub ($(CI_SCRIPT))"
	@echo ""
	@echo "  Release (macOS)"
	@echo "    make driver         Treiberbaum nach $(DEV_ROOT) (Filter, PPDs, Symbol, VERSION)"
	@echo "    make app            build/LabelWerk.app (Universal Binary, signiert)"
	@echo "    make pkg            dist/LabelWerk-<Version>.pkg"
	@echo "    make notarize       Paket notarisieren und Ticket anheften"
	@echo ""
	@echo "  Lokal installieren (macOS, sudo)"
	@echo "    make install-dev    Treiber direkt nach /Library/Printers installieren"
	@echo "    make uninstall-dev  Treiber wieder entfernen (App bleibt)"
	@echo ""
	@echo "  Aufräumen"
	@echo "    make clean          build/, dist/ und Zwischendateien entfernen"
	@echo "    make distclean      zusätzlich den SwiftPM-Ordner .build/"
	@echo ""
	@echo "  Variablen: JOBS=n (parallele Jobs), PYTHON, SWIFT, APP_ARGS, PKG_ARGS, DRIVER_ARGS, NOTARIZE_ARGS"

# --- Katalog & Lokalisierung -------------------------------------------------------------------

catalog:
	$(PYTHON) Catalog/build_catalog.py
	$(PYTHON) Scripts/generate_catalog_swift.py

catalog-check:
	$(PYTHON) Scripts/generate_catalog_swift.py --check

strings:
	$(PYTHON) Scripts/extract_strings.py

strings-check:
	$(PYTHON) Scripts/extract_strings.py --check --strict

icons:
	@$(PYTHON) -c 'import PIL' 2>/dev/null || { \
		echo "Fehler: Pillow fehlt – z. B. „$(PYTHON) -m pip install pillow“." >&2; exit 1; }
	$(PYTHON) Scripts/make_icons.py

# --- Bauen & Testen ----------------------------------------------------------------------------

build:
	$(SWIFT) build $(SWIFT_JOBS)

test: catalog-check test-swift test-driver test-ppd test-scripts
	@echo "Alle Tests erfolgreich."

test-swift:
	$(SWIFT) test $(SWIFT_JOBS)

test-driver:
	@if [ ! -f Driver/filter/Makefile ]; then \
		echo "Hinweis: Driver/filter/Makefile fehlt – Filtertests übersprungen."; \
	elif [ "$(UNAME_S)" != "Darwin" ] && [ ! -f /usr/include/cups/raster.h ]; then \
		echo "Hinweis: libcups-Header fehlen – Filtertests übersprungen" \
		     "(sudo apt install libcups2-dev libcupsimage2-dev zlib1g-dev cups-client)."; \
	else \
		$(MAKE) -C Driver/filter $(MAKE_JOBS) tests && $(MAKE) -C Driver/filter test; \
	fi

test-ppd:
	@if [ ! -f Driver/ppd/generate_ppds.py ]; then \
		echo "Hinweis: Driver/ppd/generate_ppds.py fehlt – PPD-Tests übersprungen."; \
	else \
		rm -rf "$(PPD_CHECK_DIR)" && \
		$(PYTHON) Driver/ppd/generate_ppds.py --output "$(PPD_CHECK_DIR)" --gzip --check && \
		$(PYTHON) Driver/ppd/tests/test_generate.py; \
	fi

test-scripts:
	$(PYTHON) -m unittest discover -s Scripts/tests -t Scripts/tests

lint: catalog-check strings-check
	Scripts/ci_linux.sh lint

ci:
	$(CI_SCRIPT)

# --- Release (macOS) ---------------------------------------------------------------------------

driver:
	Scripts/build_driver.sh $(DRIVER_HOST_ARGS) --output $(DEV_ROOT) $(DRIVER_ARGS)

app:
	Scripts/build_app.sh $(APP_ARGS)

pkg:
	Scripts/make_pkg.sh $(PKG_ARGS)

notarize:
	Scripts/notarize.sh $(NOTARIZE_ARGS)

# --- Lokale Installation (macOS) ---------------------------------------------------------------
#
# Installiert den frisch gebauten Treiber wie das Paket: alte Version entfernen (preinstall),
# Filter/Symbol/VERSION und PPDs kopieren, Rechte setzen und cupsd neu starten (postinstall).
# Bestehende Systemordner (/Library/Printers …) werden dabei nicht verändert.

install-dev:
	@if [ "$(UNAME_S)" != "Darwin" ]; then \
		echo "Fehler: install-dev ist nur auf macOS möglich (unter Linux: make driver)." >&2; exit 2; fi
	Scripts/build_driver.sh --output $(DEV_ROOT) $(DRIVER_ARGS)
	sudo Installer/pkg/scripts/driver/preinstall "" / /
	sudo mkdir -p /Library/Printers/PPDs/Contents/Resources
	sudo ditto $(DEV_ROOT)/Library/Printers/LabelWerk /Library/Printers/LabelWerk
	sudo cp $(DEV_ROOT)/Library/Printers/PPDs/Contents/Resources/LabelWerk-*.ppd.gz \
		/Library/Printers/PPDs/Contents/Resources/
	sudo Installer/pkg/scripts/driver/postinstall "" / /
	@echo "Treiber $$(cat /Library/Printers/LabelWerk/VERSION) installiert – Protokoll: log stream --predicate 'process == \"cupsd\"'"

uninstall-dev:
	@if [ "$(UNAME_S)" != "Darwin" ]; then \
		echo "Fehler: uninstall-dev ist nur auf macOS möglich." >&2; exit 2; fi
	sudo Scripts/uninstall.sh --keep-app

# --- Aufräumen ---------------------------------------------------------------------------------

clean:
	rm -rf build dist Driver/ppd/out
	@if [ -f Driver/filter/Makefile ]; then $(MAKE) -C Driver/filter clean; fi
	find Scripts Driver Catalog -name __pycache__ -type d -prune -exec rm -rf {} +

distclean: clean
	rm -rf .build .swiftpm
