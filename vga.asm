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
    cmp     al, `\r`
    je      .cr
    stosw
    dec     cx
    jmp     .inner_loop
.eighty:
    db      80
.cr:
    mov     cx, 80
    jmp     .outer_loop
.newline:
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

