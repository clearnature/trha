# BSD sandbox launcher (T5.1 capsicum / T5.2 pledge+unveil).
#
# One source, two binaries. On a non-BSD host they compile into a stub that
# refuses to run commands (exit 126) — which `make check` exercises.

CC      ?= cc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -O2
TARGETS  = trha-sandbox-bsd trha-sandbox-obsd

.PHONY: all check syntax clean

all: $(TARGETS)

trha-sandbox-bsd: launcher.c
	$(CC) $(CFLAGS) -o $@ $<

trha-sandbox-obsd: launcher.c
	$(CC) $(CFLAGS) -o $@ $<

# Syntax-only pass, usable when a BSD target cannot be linked here.
syntax:
	$(CC) $(CFLAGS) -fsyntax-only launcher.c

check: all
	sh ./smoke.sh

clean:
	rm -f $(TARGETS)
