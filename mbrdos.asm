;;;
; MBR-DOS - an x86 real-mode OS that fits into a 512-byte bootsector.
;
; This is free and unencumbered software released into the public domain.
; Written 2020 by Brent Bessemer.
;;;

    bits 16
    cpu 8086

    org 0x600

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

    mov     si, welcome
    call    serial_send

halt:
    hlt
    jmp     halt


;;; SERIAL I/O

%define SERIAL(n)   (0x3f8 + n)

;;; Send a single character over the default serial port.
;;; Inputs: character to send in al.
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

;;; Send a string over the default serial port.
;;; String terminated by either null byte or specified limit.
;;;
;;; Inputs: address of string in si
;;;         maximum length to send in cx
serial_send:
    lodsb
    test    al, al
    jz      .end
    call    serial_sendchar
    dec     cx
    jnz     serial_send
.end:
    ret

;;; Recieve a single character over the default serial port.
;;; Outputs: character received in al
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

;;; Recieve a string over the default serial port.
;;; String terminated by either newline or specified limit.
;;; A null byte is written either way.
;;;
;;; Inputs: address to write string to in di
;;; Outputs: number of characters actually read (not counting null) in cx
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

;;; FLOPPY DISK DRIVER

    ;; TODO

;;; FAT16 DRIVER

    ;; TODO

;;; DATA

welcome: db `Welcome to MBR-DOS v0.1.0\r\n`, 0

;;; MBR PADDING AND SIGNATURE

    times 510-($-$$) db 0
    db 0x55
    db 0xaa

    section .bss
__bss_start:

__bss_end:
