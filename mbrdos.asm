;;;
; MBRDOS - an x86 real-mode OS that fits into a 512-byte bootsector.
;
; This is free and unencumbered software released into the public domain.
; Written 2020 by Brent Bessemer.
;;;

    bits 16
    cpu 8086

    section .text

    global _start
_start:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    xor     sp, sp

    ;; Relocate ourselves to 0x0:0x600 from wherever we are
    ;; (doesn't have to be 0x7c00)
    call    .testaddr
.testaddr:
    pop     si
    sub     si, (.testaddr - _start)
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     di, _start
    mov     cx, 512
    rep     movsb

    ;; Zero the BSS section
    mov     di, __bss_start
    mov     cx, (__bss_end - __bss_start)
    xor     al, al
    rep     stosb

    mov     si, hello
    mov     ah, 0x07
    call    vga_print

halt:
    hlt
    jmp     halt

vga_print:
    push    bx                  ; Will store line number
    push    cx                  ; Will store columns remaining
    push    dx
    mov     bx, [vga_line]
    mov     cx, 80
    sub     cx, [vga_col]
    mov     dx, 0xb800
    mov     es, dx
.outer_loop:
    push    ax
    mov     ax, bx
    inc     ax
    mul     byte [.eighty]
    sub     ax, cx
    mov     di, ax
    pop     ax
.inner_loop:
    lodsb
    test    al, al
    jz      .end
    cmp     al, `\n`
    je      .newline
    stosw
    dec     cx
    jmp     .inner_loop
.eighty:
    db      80
.newline:
    xor     cx, cx
    inc     bx
    cmp     bx, 25
    jb      .outer_loop
.scroll:
    push    ds
    push    si
    mov     si, es
    mov     ds, si
    mov     si, 80
    xor     di, di
    mov     cx, 80*24
    rep     movsw
    mov     cx, 80
    xor     al, al
    rep     stosw
    pop     si
    pop     ds
    dec     bx
    jmp     .outer_loop
.end:
    mov     word [vga_line], bx
    mov     word [vga_col], 80
    sub     word [vga_col], cx
    pop     dx
    pop     cx
    pop     bx
    ret

hello:
    db "Hello, world!", 0

    section .bss
__bss_start:

vga_line:   resw 1
vga_col:    resw 1

__bss_end:
