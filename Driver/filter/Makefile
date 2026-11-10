# Makefile – LabelWerk CUPS-Filter (rastertolabelwerk, commandtolabelwerk)
#
# Ziele:
#   make all        Filter für das aktuelle System nach build/ bauen
#   make test       Filter + Testwerkzeuge bauen, C-Unit-Tests und End-to-End-Tests ausführen
#   make asan       wie test, aber mit -fsanitize=address,undefined (nach build/asan/)
#   make valgrind   Unit-Tests und End-to-End-Kurzlauf unter Valgrind (falls installiert)
#   make universal  nur macOS: Universal Binary (arm64 + x86_64, ab macOS 11) nach build/universal/
#   make install    nach $(DESTDIR)/Library/Printers/LabelWerk/Filter (Modus 0755);
#                   auf macOS werden die Universal Binaries installiert
#   make clean      build/ entfernen
#
# Funktioniert aus jedem Verzeichnis, z. B. `make -C Driver/filter test` vom Repository-Wurzel.
# Kompatibel mit GNU Make 3.81 (macOS).

SRCDIR    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILDDIR  ?= $(SRCDIR)/build
TESTDIR   := $(SRCDIR)/tests

UNAME_S   := $(shell uname -s)

CC        ?= cc
CFLAGS    ?= -O2
PYTHON    ?= python3
INSTALL   ?= install
DESTDIR   ?=
FILTERDIR ?= /Library/Printers/LabelWerk/Filter

# Zusätzliche Flags, z. B. für Sanitizer (vom Ziel `asan` gesetzt).
SAN_FLAGS ?=

# Die PPD-API (ppdOpenFile, cupsMarkOptions …) ist in libcups als „deprecated“ markiert, ist aber
# weiterhin die offizielle Schnittstelle für Treiberfilter; die Warnungen werden daher
# abgeschaltet (auf macOS laut Projektvorgabe, auf Linux identisch für warnungsfreie Builds).
WARN_FLAGS := -Wall -Wextra -Wno-deprecated-declarations
STD_FLAGS  := -std=c11

ifeq ($(UNAME_S),Darwin)
  SDKROOT        ?= $(shell xcrun --show-sdk-path 2>/dev/null)
  # Ältere SDKs führen die Raster-API noch in libcupsimage; neuere enthalten sie in libcups.
  CUPSIMAGE_LIB  := $(if $(wildcard $(SDKROOT)/usr/lib/libcupsimage.tbd),-lcupsimage,)
  PLATFORM_FLAGS :=
else
  CUPSIMAGE_LIB  :=
  PLATFORM_FLAGS := -D_DEFAULT_SOURCE
endif

ALL_CFLAGS := $(CFLAGS) $(STD_FLAGS) $(WARN_FLAGS) $(PLATFORM_FLAGS) $(SAN_FLAGS) $(CPPFLAGS) -I$(SRCDIR)
LIBS       := -lcups $(CUPSIMAGE_LIB) -lz -lm
ALL_LDFLAGS := $(LDFLAGS) $(SAN_FLAGS)

LIB_SRCS := lw_util.c lw_bitmap.c lw_dither.c lw_encode.c lw_raster.c lw_options.c lw_fit.c lw_job.c lw_cups.c
LIB_OBJS := $(addprefix $(BUILDDIR)/obj/,$(LIB_SRCS:.c=.o))

FILTERS     := $(BUILDDIR)/rastertolabelwerk $(BUILDDIR)/commandtolabelwerk
TEST_TOOLS  := $(BUILDDIR)/tests/test_main $(BUILDDIR)/tests/mkraster

UNIVERSAL_DIR   := $(BUILDDIR)/universal
UNIVERSAL_FLAGS := -arch arm64 -arch x86_64 -mmacosx-version-min=11.0

.PHONY: all tests test unit e2e asan valgrind universal install clean

all: $(FILTERS)

tests: $(FILTERS) $(TEST_TOOLS)

# --- Übersetzen ---------------------------------------------------------------------------

$(BUILDDIR)/obj/%.o: $(SRCDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -MMD -MP -c $< -o $@

$(BUILDDIR)/obj/tests/%.o: $(TESTDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -MMD -MP -c $< -o $@

$(BUILDDIR)/rastertolabelwerk: $(BUILDDIR)/obj/rastertolabelwerk.o $(LIB_OBJS)
	$(CC) $(ALL_LDFLAGS) -o $@ $^ $(LIBS)

$(BUILDDIR)/commandtolabelwerk: $(BUILDDIR)/obj/commandtolabelwerk.o $(LIB_OBJS)
	$(CC) $(ALL_LDFLAGS) -o $@ $^ $(LIBS)

$(BUILDDIR)/tests/test_main: $(BUILDDIR)/obj/tests/test_main.o $(LIB_OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_LDFLAGS) -o $@ $^ $(LIBS)

$(BUILDDIR)/tests/mkraster: $(BUILDDIR)/obj/tests/mkraster.o
	@mkdir -p $(dir $@)
	$(CC) $(ALL_LDFLAGS) -o $@ $^ $(LIBS)

-include $(wildcard $(BUILDDIR)/obj/*.d $(BUILDDIR)/obj/tests/*.d)

# --- Tests --------------------------------------------------------------------------------

unit: $(BUILDDIR)/tests/test_main
	$(BUILDDIR)/tests/test_main

e2e: tests
	$(PYTHON) $(TESTDIR)/run_e2e.py --bindir $(BUILDDIR) $(E2E_ARGS)

test: tests
	$(BUILDDIR)/tests/test_main
	$(PYTHON) $(TESTDIR)/run_e2e.py --bindir $(BUILDDIR) $(E2E_ARGS)

asan:
	$(MAKE) -f $(SRCDIR)/Makefile BUILDDIR=$(BUILDDIR)/asan CFLAGS="-O1 -g" \
		SAN_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined" \
		test

valgrind: tests
	@command -v valgrind >/dev/null 2>&1 || { echo "valgrind ist nicht installiert" >&2; exit 1; }
	valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect -q \
		$(BUILDDIR)/tests/test_main
	$(PYTHON) $(TESTDIR)/run_e2e.py --bindir $(BUILDDIR) --quick \
		--wrapper "valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect -q"

# --- macOS Universal Binary ---------------------------------------------------------------

ifeq ($(UNAME_S),Darwin)
universal: $(UNIVERSAL_DIR)/rastertolabelwerk $(UNIVERSAL_DIR)/commandtolabelwerk

$(UNIVERSAL_DIR)/%: $(SRCDIR)/%.c $(addprefix $(SRCDIR)/,$(LIB_SRCS)) $(wildcard $(SRCDIR)/*.h)
	@mkdir -p $(dir $@)
	clang $(UNIVERSAL_FLAGS) $(CFLAGS) $(STD_FLAGS) $(WARN_FLAGS) $(CPPFLAGS) -I$(SRCDIR) \
		-o $@ $< $(addprefix $(SRCDIR)/,$(LIB_SRCS)) $(LIBS)

INSTALL_SOURCES := $(UNIVERSAL_DIR)/rastertolabelwerk $(UNIVERSAL_DIR)/commandtolabelwerk
else
universal:
	@echo "Fehler: 'make universal' ist nur auf macOS verfügbar." >&2
	@exit 1

INSTALL_SOURCES := $(FILTERS)
endif

# --- Installation -------------------------------------------------------------------------

install: $(INSTALL_SOURCES)
	$(INSTALL) -d $(DESTDIR)$(FILTERDIR)
	$(INSTALL) -m 0755 $(INSTALL_SOURCES) $(DESTDIR)$(FILTERDIR)/

clean:
	rm -rf $(BUILDDIR)
