%define SERIAL(n)   (0x3f8 + n)

;;; Send a single character over the default serial port.
;;; Inputs: character to send in al.
serial_sendchar:
    cmp     al, `\n`
    jne     .not_newline
    mov     al, `\r`
    call    .not_newline
    mov     al, `\n`
.not_newline:
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
;;;
;;; Inputs: address of string in si
;;;         length to send in cx
serial_send:
    lodsb
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

