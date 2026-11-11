# ==============================================================================
# bubbleOS - bubble-settings
# ==============================================================================
PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
LIBEXECDIR ?= $(PREFIX)/libexec/bubbleos
DATADIR ?= $(PREFIX)/share
APPLICATIONSDIR ?= $(DATADIR)/applications
POLKITDIR ?= $(DATADIR)/polkit-1/actions
ICONDIR ?= $(DATADIR)/icons/hicolor/scalable/apps
SETTINGSDIR ?= $(DATADIR)/bubbleos/settings

CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	-Wno-deprecated-declarations
GTK_CFLAGS := $(shell $(PKG_CONFIG) --cflags gtk+-3.0)
GTK_LIBS := $(shell $(PKG_CONFIG) --libs gtk+-3.0)

OBJECTS = main.o pages.o users.o
TARGETS = bubble-settings bubble-settings-helper

.PHONY: all clean install uninstall check

all: $(TARGETS)

bubble-settings: $(OBJECTS)
	$(CC) $(LDFLAGS) -o $@ $(OBJECTS) $(GTK_LIBS)

%.o: %.c settings.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(GTK_CFLAGS) -c -o $@ $<

bubble-settings-helper: bubble-settings-helper.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $<

install: all
	install -Dm755 bubble-settings \
		$(DESTDIR)$(BINDIR)/bubble-settings
	install -Dm755 bubble-settings-helper \
		$(DESTDIR)$(LIBEXECDIR)/bubble-settings-helper
	install -Dm644 bubble-settings.css \
		$(DESTDIR)$(SETTINGSDIR)/bubble-settings.css
	install -Dm644 bubble-settings.desktop \
		$(DESTDIR)$(APPLICATIONSDIR)/bubble-settings.desktop
	install -Dm644 org.bubbleos.settings.policy \
		$(DESTDIR)$(POLKITDIR)/org.bubbleos.settings.policy
	install -Dm644 bubbleos-settings.svg \
		$(DESTDIR)$(ICONDIR)/bubbleos-settings.svg

uninstall:
	rm -f \
		$(DESTDIR)$(BINDIR)/bubble-settings \
		$(DESTDIR)$(LIBEXECDIR)/bubble-settings-helper \
		$(DESTDIR)$(SETTINGSDIR)/bubble-settings.css \
		$(DESTDIR)$(APPLICATIONSDIR)/bubble-settings.desktop \
		$(DESTDIR)$(POLKITDIR)/org.bubbleos.settings.policy \
		$(DESTDIR)$(ICONDIR)/bubbleos-settings.svg

clean:
	rm -f $(OBJECTS) $(TARGETS)
