###
# Makefile for MBR-DOS
#
# This is free and unencumbered software released into the public domain.
# Written 2020 by Brent Bessemer.
###

all: mbrdos.com

%.com: %.asm
	nasm -f bin $< -o $@

clean:
	rm -rvf *.com
