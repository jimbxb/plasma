#
# This is free and unencumbered software released into the public domain.
# See ../LICENSE.unlicense
#
# vim: noet sw=4 ts=4
#

MMC_MAKE=mmc --make
MCFLAGS=--use-grade-subdirs
CC=gcc
CFLAGS=-Wall

vpath %.m src
vpath %.c runtime
vpath %.h runtime
vpath %.o runtime

MERCURY_SOURCES=$(wildcard src/*.m)
C_SOURCES=runtime/pzrun.c \
		runtime/pz.c \
		runtime/pz_read.c \
		runtime/tlv_read.c
C_HEADERS=$(wildcard runtime/*.h)
C_OBJECTS=$(patsubst %.c,%.o,$(C_SOURCES))

all : tags src/pzasm runtime/pzrun

src/pzasm : $(MERCURY_SOURCES)
	(cd src; $(MMC_MAKE) $(MCFLAGS) pzasm)
	(cd src; touch pzasm)

runtime/pzrun : $(C_OBJECTS)
	$(CC) $(CFLAGS) -o $@ $^

%.o : %.c $(C_HEADERS)
	$(CC) $(CFLAGS) -o $@ -c $<

.PHONY: tags
tags : src/tags runtime/tags
src/tags : $(MERCURY_SOURCES)
	(cd src; mtags *.m)
runtime/tags: $(C_SOURCES) $(C_HEADERS)
	(cd runtime; ctags *.c *.h)

.PHONY: clean
clean :
	rm -rf src/Mercury src/tags src/pzasm src/*.err src/*.mh
	rm -rf runtime/tags runtime/pzrun runtime/*.o
