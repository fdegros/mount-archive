PROJECT = fuse-archive
PKG_CONFIG ?= pkg-config
OS := $(shell uname -s)

# C++ standard version (override with CXXSTD=20 for older compilers)
CXXSTD ?= 23

FUSE_MAJOR_VERSION ?= 3

ifeq ($(FUSE_MAJOR_VERSION), 3)
  DEPS = fuse3
  PKG_CXXFLAGS = -DFUSE_USE_VERSION=30
else ifeq ($(FUSE_MAJOR_VERSION), 2)
  DEPS = fuse
  PKG_CXXFLAGS = -DFUSE_USE_VERSION=26
endif

DEPS += libarchive
UNIT_TEST_DEPS = gtest gtest_main

# On macOS, libarchive is keg-only (not symlinked into the default search
# path). Wire the Homebrew path into PKG_CONFIG_PATH so every pkg-config call
# in this Makefile resolves the correct version regardless of shell environment.
ifeq ($(OS), Darwin)
  PKG_CXXFLAGS += -std=gnu++$(CXXSTD)
  BREW_PREFIX := $(shell brew --prefix 2>/dev/null)
  ifneq ($(BREW_PREFIX),)
    PKG_CONFIG = env PKG_CONFIG_PATH="$(BREW_PREFIX)/opt/libarchive/lib/pkgconfig" pkg-config
    PKG_CXXFLAGS += -I$(BREW_PREFIX)/opt/boost/include
    # macFUSE enables Darwin-extended operation signatures by default
    # (fuse_darwin_attr*, struct statfs*, 5-arg getxattr, fuse_darwin_fill_dir_t).
    # fuse-archive uses standard POSIX signatures, so opt out of the extensions.
    PKG_CXXFLAGS += -DFUSE_DARWIN_ENABLE_EXTENSIONS=0
  endif
else
  PKG_CXXFLAGS += -std=c++$(CXXSTD)
endif

# 16-byte atomics (std::atomic<timespec>, used for Node::atime) are
# implemented via libatomic's runtime fallback on platforms without a
# lock-free 16-byte compare-and-swap. Only glibc/Linux splits this out into
# a separate library; FreeBSD's compiler-rt provides the fallback directly,
# and this isn't linked on Darwin either.
ifeq ($(OS), Linux)
  PKG_LDFLAGS += -latomic
endif

# On FreeBSD, Boost headers installed from the ports are in
# /usr/local/include and the base Clang does not look there by default.
ifeq ($(OS), FreeBSD)
  PKG_CXXFLAGS += -I/usr/local/include
endif

PKG_CXXFLAGS += $(shell $(PKG_CONFIG) --cflags $(DEPS) 2>/dev/null)
PKG_LDFLAGS += $(shell $(PKG_CONFIG) --libs $(DEPS) 2>/dev/null)

HAS_GTEST := $(shell $(PKG_CONFIG) --exists $(UNIT_TEST_DEPS) 2>/dev/null && echo 1 || echo 0)

ifeq ($(HAS_GTEST), 1)
  UNIT_TEST_CXXFLAGS := $(shell $(PKG_CONFIG) --cflags $(UNIT_TEST_DEPS) 2>/dev/null)
  UNIT_TEST_LDFLAGS := $(shell $(PKG_CONFIG) --libs $(UNIT_TEST_DEPS) 2>/dev/null)
endif

PKG_CXXFLAGS += -Wall -Wextra -Wno-missing-field-initializers -Wno-sign-compare -I.
PKG_CXXFLAGS += -D_FILE_OFFSET_BITS=64 -D_TIME_BITS=64

ifeq ($(DEBUG), 1)
  PKG_CXXFLAGS += -O0 -g
else
  PKG_CXXFLAGS += -O2 -DNDEBUG
endif

ifeq ($(ASAN), 1)
  PKG_CXXFLAGS += -fsanitize=address
  PKG_LDFLAGS += -fsanitize=address
endif

ifeq ($(UBSAN), 1)
  PKG_CXXFLAGS += -fsanitize=undefined
  PKG_LDFLAGS += -fsanitize=undefined
endif

ifeq ($(COVERAGE), 1)
  PKG_CXXFLAGS += -fprofile-arcs -ftest-coverage
  LDFLAGS += --coverage
endif

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man/man1
MAN = $(PROJECT).1
INSTALL = install

OUT = out

all: $(OUT)/$(PROJECT)

# ---- Formatting

FORMAT = clang-format
CC_FILES = $(wildcard *.cc lib/*.cc tests/*.cc)
H_FILES = $(wildcard lib/*.h tests/*.h)
ALL_CXX_FILES = $(CC_FILES) $(H_FILES)

format:
	$(FORMAT) -i -style=file $(ALL_CXX_FILES)

check-format:
	$(FORMAT) --dry-run -Werror -style=file $(ALL_CXX_FILES)

# ---- Library

LIB_DIR = lib
LIB_OUT = $(OUT)/$(LIB_DIR)
LIB_SOURCES = $(wildcard $(LIB_DIR)/*.cc)
LIB_OBJECTS = $(addprefix $(OUT)/,$(LIB_SOURCES:.cc=.o))
LIB_ARCHIVE = $(OUT)/lib$(PROJECT).a

$(LIB_ARCHIVE): $(LIB_OBJECTS)
	$(AR) $(ARFLAGS) $@ $(LIB_OBJECTS)

$(OUT)/$(LIB_DIR)/%.o: $(LIB_DIR)/%.cc
	@mkdir -p $(dir $@)
	$(CXX) -c $(PKG_CXXFLAGS) $(CPPFLAGS) $(CXXFLAGS) $< -o $@ -MMD -MP -MF $(@:.o=.d)

# ---- Binaries

$(OUT)/$(PROJECT): $(PROJECT).cc $(LIB_ARCHIVE)
	mkdir -p $(OUT)
	$(CXX) -Ilib $(PKG_CXXFLAGS) $(CPPFLAGS) $(CXXFLAGS) $< $(LIB_ARCHIVE) $(PKG_LDFLAGS) $(LDFLAGS) -o $@

# ---- Unit Tests

UNIT_TEST = unit_tests
UNIT_TEST_SOURCES = $(wildcard tests/*.cc)
UNIT_TEST_OBJECTS = $(addprefix $(OUT)/,$(UNIT_TEST_SOURCES:.cc=.o))

ifeq ($(HAS_GTEST), 1)
$(OUT)/$(UNIT_TEST): $(UNIT_TEST_OBJECTS) $(LIB_ARCHIVE)
	$(CXX) $(PKG_CXXFLAGS) $(UNIT_TEST_CXXFLAGS) $(CPPFLAGS) $(CXXFLAGS) $^ $(PKG_LDFLAGS) $(UNIT_TEST_LDFLAGS) $(LDFLAGS) -o $@

$(OUT)/tests/%.o: tests/%.cc
	@mkdir -p $(dir $@)
	$(CXX) -Ilib -c $(PKG_CXXFLAGS) $(UNIT_TEST_CXXFLAGS) $(CPPFLAGS) $(CXXFLAGS) $< -o $@ -MMD -MP -MF $(@:.o=.d)

UNIT_TEST_BIN = $(OUT)/$(UNIT_TEST)
else
UNIT_TEST_BIN =
endif

# ---- Standard targets

check: $(OUT)/$(PROJECT) $(UNIT_TEST_BIN) tests/data/big.zip tests/data/collisions.zip tests/data/deep.tar tests/data/many_nodes.zip
	$(if $(UNIT_TEST_BIN),$(UNIT_TEST_BIN))
	python3 tests/test.py

check-fast: $(OUT)/$(PROJECT) $(UNIT_TEST_BIN)
	$(if $(UNIT_TEST_BIN),$(UNIT_TEST_BIN))
	python3 tests/test.py --fast

valgrind: $(OUT)/$(PROJECT) $(UNIT_TEST_BIN)
	$(if $(UNIT_TEST_BIN),valgrind -q --leak-check=full --track-origins=yes --error-exitcode=33 $(UNIT_TEST_BIN))
	MOUNT_WRAPPER="valgrind -q --leak-check=full --error-exitcode=33" python3 tests/test.py --fast

CHECK_TARGET ?= check-fast

coverage:
	$(MAKE) clean
	$(MAKE) DEBUG=1 COVERAGE=1 $(CHECK_TARGET)
	lcov --capture --directory $(OUT) --output-file $(OUT)/coverage.info --ignore-errors mismatch,inconsistent
	lcov --remove $(OUT)/coverage.info '/usr/include/*' '/usr/lib/*' 'tests/*' --output-file $(OUT)/coverage.info --ignore-errors unused,inconsistent
	genhtml $(OUT)/coverage.info --output-directory $(OUT)/coverage --ignore-errors inconsistent
	@echo "Coverage report generated at $(OUT)/coverage/index.html"

test: check

unit_tests: $(UNIT_TEST_BIN)
	$(if $(UNIT_TEST_BIN),$(UNIT_TEST_BIN),@echo "Google Test not found; cannot run unit tests.")

clean:
	rm -rf $(OUT)

clean-data:
	rm -f tests/data/big.zip tests/data/collisions.zip tests/data/deep.tar tests/data/many_nodes.zip

doc: $(MAN)
	@if [ -z "$(QUIET)" ]; then man -l $(MAN); fi

release:
	python3 release.py $(VERSION)

$(MAN): README.md
	pandoc $< -s -t man | \
	sed -e 's/^\.IP \\(bu/.PD 0\n.IP \\(bu/g' \
	    -e 's/^\.SH/.PD\n.SH/g' \
	    -e 's/^\.SS/.PD\n.SS/g' \
	    -e 's/^\.PP/.PD\n.PP/g' \
	    -e 's/^\.TP/.PD\n.TP/g' > $@

ifneq ($(filter clean%,$(MAKECMDGOALS)),)
else
-include $(LIB_OBJECTS:.o=.d)
-include $(UNIT_TEST_OBJECTS:.o=.d)
endif

install: $(OUT)/$(PROJECT)
	mkdir -p "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(MANDIR)"
	$(INSTALL) "$(OUT)/$(PROJECT)" "$(DESTDIR)$(BINDIR)/$(PROJECT)"
	$(INSTALL) -m 644 $(MAN) "$(DESTDIR)$(MANDIR)/$(MAN)"

install-strip: $(OUT)/$(PROJECT)
	mkdir -p "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(MANDIR)"
	$(INSTALL) -s "$(OUT)/$(PROJECT)" "$(DESTDIR)$(BINDIR)/$(PROJECT)"
	$(INSTALL) -m 644 $(MAN) "$(DESTDIR)$(MANDIR)/$(MAN)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(PROJECT)" "$(DESTDIR)$(MANDIR)/$(MAN)"

tests/data/big.zip: tests/make_big_zip.py
	python3 tests/make_big_zip.py

tests/data/collisions.zip: tests/make_collisions.py
	python3 tests/make_collisions.py

tests/data/deep.tar: tests/make_deep.py
	python3 tests/make_deep.py

tests/data/many_nodes.zip: tests/make_many_nodes.py
	python3 tests/make_many_nodes.py

.PHONY: all check check-fast check-format clean clean-data coverage doc format install install-strip release test uninstall unit_tests valgrind
