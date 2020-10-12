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
    call    serial_send

halt:
    hlt
    jmp     halt


;;; SERIAL I/O

%define SERIAL(n)   (0x3f8 + n)

serial_sendchar:
    push    dx
    push    ax
    mov     dx, SERIAL(5)
.wait_thre:
    in      al, dx
    test    al, 0x20
    jz      .wait_thre
    pop     ax
    mov     dx, SERIAL(0)
    out     dx, al
    pop     dx
    ret

serial_send:
    lodsb
    test    al, al
    jz      .end
    call    serial_sendchar
    dec     cx
    jnz     serial_send
.end:
    ret

serial_recvchar:
    push    dx
    mov     dx, SERIAL(5)
.wait_dr:
    in      al, dx
    test    al, 1
    jz      .wait_dr
    mov     dx, SERIAL(0)
    in      al, dx
    pop     dx
    ret

serial_recv:
    push    ax
    push    cx
.loop:
    call    serial_recvchar
    cmp     al, `\r`
    je      .loop               ; CR is completely ignored
    cmp     al, `\n`
    je      .end
    stosb
    dec     cx
    jnz     .loop
.end:
    pop     ax                  ; Original max count
    neg     cx                  ; cx = -(remaining count)
    add     cx, ax              ; cx = count actually read
    mov     byte [di], 0        ; null terminator
    pop     ax
    ret

hello:
    db "Hello, world!", 0

    section .bss
__bss_start:

__bss_end:
