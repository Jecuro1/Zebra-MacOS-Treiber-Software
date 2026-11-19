# Makefile – LabelWerk CUPS-Backend „labelwerk“ (ARCHITECTURE.md §10 „Backend labelwerk“)
#
# Ziele:
#   make all        Backend für das aktuelle System nach build/ bauen
#   make test       Backend + Unit-Tests bauen, C-Unit-Tests und End-to-End-Tests mit einem
#                   nachgebildeten Zebra-Drucker (tests/run_backend_e2e.py) ausführen
#   make asan       wie test, mit -fsanitize=address,undefined (nach build/asan/)
#   make valgrind   Unit-Tests und End-to-End-Kurzlauf unter Valgrind
#   make universal  nur macOS: Universal Binary (arm64 + x86_64, ab macOS 11) nach build/universal/
#   make install    nach $(DESTDIR)/usr/libexec/cups/backend/labelwerk (Modus 0755, siehe unten);
#                   auf macOS das Universal Binary
#   make clean      build/ entfernen
#
# Das Backend nutzt die Optionsauswertung des Filters (Driver/filter: lw_options, lw_cups …), um die
# Steuerzeichen „Intern“ (lwControlChars) und die Druckersprache aus argv[5] und der PPD zu lesen.
#
# Modus 0755, nicht 0700: CUPS startet Backends, die für „andere“ ausführbar sind, als
# unprivilegierter Benutzer (lp bzw. _lp); 0700 (root) brauchen nur Backends mit
# Gerätezugriff. Dieses Backend öffnet nur eine TCP-Verbindung zum Drucker.
#
# Kompatibel mit GNU Make 3.81 (macOS).

SRCDIR     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
FILTERDIR  := $(abspath $(SRCDIR)/../filter)
BUILDDIR   ?= $(SRCDIR)/build
TESTDIR    := $(SRCDIR)/tests

UNAME_S    := $(shell uname -s)

CC         ?= cc
CFLAGS     ?= -O2
PYTHON     ?= python3
INSTALL    ?= install
DESTDIR    ?=
BACKENDDIR ?= /usr/libexec/cups/backend

SAN_FLAGS  ?=

WARN_FLAGS := -Wall -Wextra -Wno-deprecated-declarations
STD_FLAGS  := -std=c11

ifeq ($(UNAME_S),Darwin)
  SDKROOT        ?= $(shell xcrun --show-sdk-path 2>/dev/null)
  CUPSIMAGE_LIB  := $(if $(wildcard $(SDKROOT)/usr/lib/libcupsimage.tbd),-lcupsimage,)
  PLATFORM_FLAGS :=
else
  CUPSIMAGE_LIB  :=
  PLATFORM_FLAGS := -D_DEFAULT_SOURCE
endif

ALL_CFLAGS  := $(CFLAGS) $(STD_FLAGS) $(WARN_FLAGS) $(PLATFORM_FLAGS) $(SAN_FLAGS) $(CPPFLAGS) -I$(SRCDIR) -I$(FILTERDIR)
LIBS        := -lcups $(CUPSIMAGE_LIB) -lz -lm
ALL_LDFLAGS := $(LDFLAGS) $(SAN_FLAGS)

# Bibliothek des Filters (Optionen, PPD) und eigener Kern.
FILTER_SRCS := lw_util.c lw_bitmap.c lw_dither.c lw_encode.c lw_raster.c lw_options.c lw_fit.c lw_job.c lw_cups.c
FILTER_OBJS := $(addprefix $(BUILDDIR)/obj/filter/,$(FILTER_SRCS:.c=.o))
CORE_OBJS   := $(BUILDDIR)/obj/lwb_core.o

BACKEND     := $(BUILDDIR)/labelwerk
TEST_TOOLS  := $(BUILDDIR)/tests/test_backend

UNIVERSAL_DIR   := $(BUILDDIR)/universal
UNIVERSAL_FLAGS := -arch arm64 -arch x86_64 -mmacosx-version-min=11.0

.PHONY: all tests test unit e2e asan valgrind universal install clean

all: $(BACKEND)

tests: $(BACKEND) $(TEST_TOOLS)

$(BUILDDIR)/obj/filter/%.o: $(FILTERDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -MMD -MP -c $< -o $@

$(BUILDDIR)/obj/%.o: $(SRCDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -MMD -MP -c $< -o $@

$(BUILDDIR)/obj/tests/%.o: $(TESTDIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(ALL_CFLAGS) -MMD -MP -c $< -o $@

$(BACKEND): $(BUILDDIR)/obj/labelwerk.o $(CORE_OBJS) $(FILTER_OBJS)
	$(CC) $(ALL_LDFLAGS) -o $@ $^ $(LIBS)

$(BUILDDIR)/tests/test_backend: $(BUILDDIR)/obj/tests/test_backend.o $(CORE_OBJS) $(FILTER_OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(ALL_LDFLAGS) -o $@ $^ $(LIBS)

-include $(wildcard $(BUILDDIR)/obj/*.d $(BUILDDIR)/obj/filter/*.d $(BUILDDIR)/obj/tests/*.d)

# --- Tests --------------------------------------------------------------------------------

unit: $(BUILDDIR)/tests/test_backend
	$(BUILDDIR)/tests/test_backend

e2e: $(BACKEND)
	$(PYTHON) $(TESTDIR)/run_backend_e2e.py --backend $(BACKEND) $(E2E_ARGS)

test: tests
	$(BUILDDIR)/tests/test_backend
	$(PYTHON) $(TESTDIR)/run_backend_e2e.py --backend $(BACKEND) $(E2E_ARGS)

asan:
	$(MAKE) -f $(SRCDIR)/Makefile BUILDDIR=$(BUILDDIR)/asan CFLAGS="-O1 -g" \
		SAN_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined" \
		test

valgrind: tests
	@command -v valgrind >/dev/null 2>&1 || { echo "valgrind ist nicht installiert" >&2; exit 1; }
	valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect -q \
		$(BUILDDIR)/tests/test_backend
	$(PYTHON) $(TESTDIR)/run_backend_e2e.py --backend $(BACKEND) --quick \
		--wrapper "valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite,indirect -q"

# --- macOS Universal Binary ---------------------------------------------------------------

ifeq ($(UNAME_S),Darwin)
universal: $(UNIVERSAL_DIR)/labelwerk

$(UNIVERSAL_DIR)/labelwerk: $(SRCDIR)/labelwerk.c $(SRCDIR)/lwb_core.c $(SRCDIR)/lwb_core.h \
		$(addprefix $(FILTERDIR)/,$(FILTER_SRCS)) $(wildcard $(FILTERDIR)/*.h)
	@mkdir -p $(dir $@)
	clang $(UNIVERSAL_FLAGS) $(CFLAGS) $(STD_FLAGS) $(WARN_FLAGS) $(CPPFLAGS) -I$(SRCDIR) -I$(FILTERDIR) \
		-o $@ $(SRCDIR)/labelwerk.c $(SRCDIR)/lwb_core.c $(addprefix $(FILTERDIR)/,$(FILTER_SRCS)) $(LIBS)

INSTALL_SOURCE := $(UNIVERSAL_DIR)/labelwerk
else
universal:
	@echo "Fehler: 'make universal' ist nur auf macOS verfügbar." >&2
	@exit 1

INSTALL_SOURCE := $(BACKEND)
endif

# --- Installation -------------------------------------------------------------------------

install: $(INSTALL_SOURCE)
	$(INSTALL) -d $(DESTDIR)$(BACKENDDIR)
	$(INSTALL) -m 0755 $(INSTALL_SOURCE) $(DESTDIR)$(BACKENDDIR)/labelwerk

clean:
	rm -rf $(BUILDDIR)
