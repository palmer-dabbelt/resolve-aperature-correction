# Build infrastructure for the fuses in this repository.
#
#   make            syntax-check and run the tests
#   make install    install into Resolve's Fuses directory
#   make install-all      install every fuse, including the probe
#   make install-copy     force a copy
#   make install-symlink  force a symlink
#   make uninstall  remove them again
#   make test       run the test suite
#   make check      syntax-check the Lua without running it
#   make help       list the targets
#
# "make install" copies or symlinks depending on where it is installing to;
# see DEFAULT_MODE below.
#
# Resolve only loads fuses at startup, so restart it after installing.
#
# Overridable:
#   LUA=lua5.1          interpreter used for check and test
#   FUSEDIR=/some/path  where to install (defaults per platform, below)
#   INSTALL_FUSES=...   which fuses to install (default: the normaliser only)
#   FORCE=1             overwrite files in FUSEDIR we didn't install

LUA ?= luajit

ALL_FUSES := $(wildcard Fuses/*.fuse)

# Aperture Probe is a diagnostic: useful when working out what a camera tags,
# but not something to leave in a comp, and Aperture Normalize can write its
# own report now. So only the normaliser is installed unless asked otherwise.
INSTALL_FUSES ?= Fuses/ApertureNormalize.fuse
LUA_SOURCES := $(wildcard test/*.lua)
TESTS := $(wildcard test/test_*.lua)

UNAME_S := $(shell uname -s)

# The Mac App Store build of Resolve is sandboxed, so the Fusion profile it
# actually reads lives inside the app's container -- not in the
# ~/Library/Application Support/Blackmagic Design/... path the non-sandboxed
# build uses. Installing to the latter looks like it worked and silently does
# nothing, so prefer a container whenever one is present.
CONTAINERS := $(HOME)/Library/Containers
FUSION_PROFILE := $(shell \
	for d in "$(CONTAINERS)"/com.blackmagic-design.DaVinciResolve*/Data/Library/"Application Support"/Fusion; do \
		if [ -d "$$d" ]; then echo "$$d"; exit 0; fi; \
	done)

ifeq ($(origin FUSEDIR),undefined)
ifeq ($(UNAME_S),Darwin)
ifeq ($(FUSION_PROFILE),)
FUSEDIR := $(HOME)/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses
else
FUSEDIR := $(FUSION_PROFILE)/Fuses
endif
endif
ifeq ($(UNAME_S),Linux)
FUSEDIR := $(HOME)/.local/share/DaVinciResolve/Fusion/Fuses
endif
endif
FUSEDIR ?=

# A sandboxed Resolve can't read through a symlink pointing out of its
# container, so installing there has to copy. Elsewhere symlinking is better:
# edits to this repository take effect on the next Resolve restart.
ifeq ($(FUSION_PROFILE),)
DEFAULT_MODE := symlink
else
DEFAULT_MODE := copy
endif

# FUSEDIR contains spaces on macOS, so it is only ever used quoted inside a
# recipe -- never as a target or prerequisite, where make would split it.

# Sets $ours to yes when the file already at $target is one of ours: it
# registers the same fuse class as the file we are about to put there. Content
# comparison is not enough, because an install made by copying stops matching
# the repository the moment the fuse is edited -- which is exactly when it
# needs reinstalling. Two fuses registering one class could not coexist in
# Fusion anyway, so replacing it is the only sensible reading.
define fuse_is_ours
class=`sed -n 's/.*FuRegisterClass("\([A-Za-z0-9_]*\)".*/\1/p' "$$fuse" | head -1`; if [ -n "$$class" ] && grep -q "FuRegisterClass(\"$$class\"" "$$target" 2>/dev/null; then ours=yes; else ours=no; fi
endef

.PHONY: all help check test install install-copy install-symlink install-all uninstall

all: check test

help:
	@echo 'targets:'
	@echo '  make install          install into Resolve (FORCE=1 to overwrite strangers)'
	@echo '  make install-all      install every fuse, including the probe'
	@echo '  make install-copy     force a copy'
	@echo '  make install-symlink  force a symlink'
	@echo '  make uninstall        remove the fuses this repository installed'
	@echo '  make test             run the test suite'
	@echo '  make check            syntax-check the Lua'
	@echo
	@echo 'installing:    $(notdir $(INSTALL_FUSES))'
	@echo 'installing to: $(FUSEDIR)'
	@echo 'install mode:  $(DEFAULT_MODE)'
ifeq ($(FUSION_PROFILE),)
	@echo 'no sandboxed Resolve container found; using the plain support path'
else
	@echo 'sandboxed Resolve detected, so installing copies rather than symlinks'
endif

# Tolerant of a missing interpreter: not having Lua on the box shouldn't stop
# someone installing a fuse. "make test" is the one that insists.
check:
	@if command -v $(LUA) >/dev/null 2>&1; then \
		$(LUA) test/syntax.lua $(ALL_FUSES) $(LUA_SOURCES); \
	else \
		echo "skipping syntax check ($(LUA) not found; override with LUA=)"; \
	fi

test:
	@command -v $(LUA) >/dev/null 2>&1 || \
		{ echo "$(LUA) not found; install a Lua 5.1-compatible interpreter or set LUA=" >&2; exit 1; }
	@fail=0; \
	for t in $(TESTS); do \
		echo "== $$t"; \
		$(LUA) "$$t" || fail=1; \
	done; \
	exit $$fail

install: MODE := $(DEFAULT_MODE)
install-copy: MODE := copy
install-symlink: MODE := symlink
install-all: MODE := $(DEFAULT_MODE)
install-all: INSTALL_FUSES := $(ALL_FUSES)

install install-copy install-symlink install-all: check
	@set -e; \
	dest="$(FUSEDIR)"; \
	if [ -z "$$dest" ]; then \
		echo "no default Fuses directory for $(UNAME_S); pass FUSEDIR=..." >&2; \
		exit 1; \
	fi; \
	if [ -z "$(strip $(INSTALL_FUSES))" ]; then \
		echo "no .fuse files selected to install" >&2; \
		exit 1; \
	fi; \
	mkdir -p "$$dest"; \
	for fuse in $(INSTALL_FUSES); do \
		name=`basename "$$fuse"`; \
		target="$$dest/$$name"; \
		if [ -L "$$target" ]; then \
			existing=`readlink "$$target"`; \
			case "$$existing" in \
				"$(CURDIR)"/*) ;; \
				*) \
					if [ -z "$(FORCE)" ]; then \
						echo "refusing to replace $$target (symlink to $$existing); re-run with FORCE=1" >&2; \
						exit 1; \
					fi ;; \
			esac; \
		elif [ -e "$$target" ]; then \
			$(fuse_is_ours); \
			if [ "$$ours" = no ] && [ -z "$(FORCE)" ]; then \
				echo "refusing to replace existing file $$target; re-run with FORCE=1" >&2; \
				exit 1; \
			fi; \
		fi; \
		rm -f "$$target"; \
		if [ "$(MODE)" = "copy" ]; then \
			cp "$$fuse" "$$target"; \
		else \
			ln -s "$(CURDIR)/$$fuse" "$$target"; \
		fi; \
		echo "installed $$name -> $$target"; \
	done; \
	echo; \
	if [ "$(MODE)" = "copy" ]; then \
		echo "Installed as copies, so re-run 'make install' after editing a fuse."; \
	fi; \
	echo "Restart Resolve, then look under Fuses > Metadata."

# Only removes what this repository put there: a symlink pointing back here, or
# a copy still byte-identical to ours. Anything else is left alone and reported.
uninstall:
	@set -e; \
	dest="$(FUSEDIR)"; \
	if [ -z "$$dest" ]; then \
		echo "no default Fuses directory for $(UNAME_S); pass FUSEDIR=..." >&2; \
		exit 1; \
	fi; \
	for fuse in $(ALL_FUSES); do \
		name=`basename "$$fuse"`; \
		target="$$dest/$$name"; \
		if [ -L "$$target" ]; then \
			existing=`readlink "$$target"`; \
			case "$$existing" in \
				"$(CURDIR)"/*) rm -f "$$target"; echo "removed $$target" ;; \
				*) echo "left $$target alone (symlink to $$existing)" ;; \
			esac; \
		elif [ -e "$$target" ]; then \
			$(fuse_is_ours); \
			if [ "$$ours" = yes ]; then \
				rm -f "$$target"; echo "removed $$target"; \
			else \
				echo "left $$target alone (not one of ours)"; \
			fi; \
		else \
			echo "not installed: $$name"; \
		fi; \
	done
