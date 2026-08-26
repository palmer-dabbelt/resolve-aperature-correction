# Build infrastructure for the fuses in this repository.
#
#   make            syntax-check and run the tests
#   make install    symlink the fuses into Resolve's Fuses directory
#   make install-copy   copy them instead of symlinking
#   make uninstall  remove them again
#   make test       run the test suite
#   make check      syntax-check the Lua without running it
#   make help       list the targets
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

ifeq ($(UNAME_S),Darwin)
FUSEDIR ?= $(HOME)/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses
endif
ifeq ($(UNAME_S),Linux)
FUSEDIR ?= $(HOME)/.local/share/DaVinciResolve/Fusion/Fuses
endif
FUSEDIR ?=

# FUSEDIR contains spaces on macOS, so it is only ever used quoted inside a
# recipe -- never as a target or prerequisite, where make would split it.

.PHONY: all help check test install install-copy uninstall

all: check test

help:
	@echo 'targets:'
	@echo '  make install       symlink the fuses into Resolve (FORCE=1 to overwrite strangers)'
	@echo '  make install-copy  copy them instead of symlinking'
	@echo '  make uninstall     remove the fuses this repository installed'
	@echo '  make test          run the test suite'
	@echo '  make check         syntax-check the Lua'
	@echo
	@echo 'installing to: $(FUSEDIR)'

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

install: MODE := symlink
install-copy: MODE := copy

install install-copy: check
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
