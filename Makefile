
all: mbrdos

mbrdos: mbrdos.o
	ld -m elf_i386 -T link.ld $^ -o $@

%.o: %.asm
	nasm -f elf32 $< -o $@
