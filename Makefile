# Build infrastructure for the fuses in this repository.
#
#   make            syntax-check and run the tests
#   make install    install the fuses into Resolve's Fuses directory
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
#   FORCE=1             overwrite files in FUSEDIR we didn't install

LUA ?= luajit

FUSES := $(wildcard Fuses/*.fuse)
LUA_SOURCES := $(wildcard test/*.lua)
TESTS := test/test_apertureprobe.lua

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

.PHONY: all help check test install install-copy install-symlink uninstall

all: check test

help:
	@echo 'targets:'
	@echo '  make install          install into Resolve (FORCE=1 to overwrite strangers)'
	@echo '  make install-copy     force a copy'
	@echo '  make install-symlink  force a symlink'
	@echo '  make uninstall        remove the fuses this repository installed'
	@echo '  make test             run the test suite'
	@echo '  make check            syntax-check the Lua'
	@echo
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
		$(LUA) test/syntax.lua $(FUSES) $(LUA_SOURCES); \
	else \
		echo "skipping syntax check ($(LUA) not found; override with LUA=)"; \
	fi

test:
	@command -v $(LUA) >/dev/null 2>&1 || \
		{ echo "$(LUA) not found; install a Lua 5.1-compatible interpreter or set LUA=" >&2; exit 1; }
	@$(LUA) $(TESTS)

install: MODE := $(DEFAULT_MODE)
install-copy: MODE := copy
install-symlink: MODE := symlink

install install-copy install-symlink: check
	@set -e; \
	dest="$(FUSEDIR)"; \
	if [ -z "$$dest" ]; then \
		echo "no default Fuses directory for $(UNAME_S); pass FUSEDIR=..." >&2; \
		exit 1; \
	fi; \
	if [ -z "$(strip $(FUSES))" ]; then \
		echo "no .fuse files found in Fuses/" >&2; \
		exit 1; \
	fi; \
	mkdir -p "$$dest"; \
	for fuse in $(FUSES); do \
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
			if [ -z "$(FORCE)" ]; then \
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
	for fuse in $(FUSES); do \
		name=`basename "$$fuse"`; \
		target="$$dest/$$name"; \
		if [ -L "$$target" ]; then \
			existing=`readlink "$$target"`; \
			case "$$existing" in \
				"$(CURDIR)"/*) rm -f "$$target"; echo "removed $$target" ;; \
				*) echo "left $$target alone (symlink to $$existing)" ;; \
			esac; \
		elif [ -e "$$target" ]; then \
			if cmp -s "$$fuse" "$$target"; then \
				rm -f "$$target"; echo "removed $$target"; \
			else \
				echo "left $$target alone (differs from $$fuse)"; \
			fi; \
		else \
			echo "not installed: $$name"; \
		fi; \
	done
