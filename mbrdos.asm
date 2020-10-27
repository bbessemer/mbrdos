;;;
; MBR-DOS - an x86 real-mode OS that fits into a 512-byte bootsector.
;
; This is free and unencumbered software released into the public domain.
; Written 2020 by Brent Bessemer.
;;;

    bits 16
    cpu 386

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
    mov     si, 0x7c00
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     di, _start
    mov     cx, 512
    rep     movsb
    jmp     0x0:.zero_bss

.zero_bss:
    mov     di, __bss_start
    mov     cx, (__bss_end - __bss_start)
    xor     al, al
    rep     stosb

    ;; mov     si, welcome
    ;; mov     cx, welcome.end - welcome
    ;; call    serial_send

halt:
    hlt
    jmp     halt


;;; FLOPPY DISK DRIVER

%define HEADS       2
%define CYLINDERS   80
%define SPC         18          ; cylinders per sector

;;; Convert logical block address to cylinder/head/sector address.
;;; Since this is a floppy, we can assume that the cylinder number fits into
;;; one byte and doesn't require storing the high bits in other registers.
;;;
;;; Inputs: LBA in ax
;;; Outputs: cylinder in ch
;;;          head in dh
;;;          sector in cl
;;;          dl destroyed
lba2chs:
    mov     cl, SPC
    div     cl                  ; ah = sector
    mov     dl, ah
    xor     ah, ah
    mov     cl, HEADS
    div     cl                  ; ah = cylinder; al = head
    mov     ch, ah
    mov     dh, al
    mov     cl, dl
    inc     cl
    ret

;;; Read several sectors from the first floppy disk.
;;;
;;; See below for inputs and outputs. This function additionally
;;; takes the number of sectors to read in cx.
read_sectors:
    call    read_sector
    test    ax, ax              ; nonzero = failure, pass it on
    jnz     .end
    dec     cx
    jnz     read_sectors
.end:
    ret

;;; Read a single sector from the first floppy disk.
;;;
;;; Inputs: LBA of sector to read in ax
;;;         Destination buffer at [es:di]
;;; Outputs: ax = 0 on success, != 0 on failure
read_sector:
    push    bx
    push    cx
    mov     bx, di
    call    lba2chs
    mov     ax, 0x0201          ; ah = function (read); al = # of sectors

    xor     dl, dl              ; drive number = 0 (first floppy)
    int     0x13                ; BIOS interrupt
    jc      .error              ; BIOS reports error with carry flag
    test    al, al              ; BIOS returns number of sectors actually read
    mov     al, 0
    jnz     .success
.error:
    inc     al
.success:
    pop     cx
    pop     bx
    ret



;;; INTERRUPTS AND SYSTEM CALLS

ivt_init:
    mov     word [0x80*4], handle_dispatch
    mov     word [0x80*4+2], 0
    ret

    struc   proc_handle
hnd_ptr:    resw 1
hnd_seg:    resw 1
hnd_rindex: resw 1
_reserved:  resw 1
hnd_size:
    endstruc

handle_dispatch:
    cmp     ax, 0x100
    jge     invalid_handle
    push    bx
    mov     bx, 8
    push    dx
    xor     dx, dx
    mul     bx
    pop     dx
    mov     bx, ax
    cmp     word [bx], 0
    je      invalid_handle
    mov     ax, [bx+hnd_rindex]
    ;; TODO: push floating-point registers
    call    far [bx]
    pop     bx
    iret

invalid_handle:
    xor     ax, ax
    dec     ax
    iret

;;; FUNCTIONS FOR USER PROCESSES

;;; The initial list of handles for a process looks like this:
;;; [0] exit
;;; [1] fork
;;; [2] create handle
;;; [3] transfer handle
;;;
;;; PID 1 will additionally get these (which will be inherited)
;;; [4] read working directory
;;; [5] open from working directory

;;; TODO: this returns to the calling process and probably should not be used
proc_exit:
    push    si
    mov     si, cs
    shr     si, 12
    dec     byte [used_pids+si]
    pop     si
    retf

;;; Kernel capability. Clones the calling process.
;;;
;;; Inputs:  dx = start address in new process
;;; Outputs: ax = handle to entry point of new process
proc_fork:
    push    cx
    push    di

    xor     ax, ax              ; Preload failure value
    dec     ax

    xor     di, di
.search:
    inc     di
    cmp     di, 9
    jg      .end
    cmp     byte [used_pids+di], 0
    je      .search
    ;; di = pid of new process
    push    di
    inc     byte [used_pids-1+di]
    shl     di, 12
    mov     es, di

    ;; Copy the old process's memory into the new process's space
    xor     di, di
    xor     si, si
    mov     cx, -1
    rep     movsb

    pop     di
    mov     si, ds
    shr     si, 12
    call    proc_make_handle_internal
.end:
    pop     di
    pop     cx
    retf

proc_make_handle:
    call    proc_make_handle_internal
    retf

;;; Inputs:  si = process to which handle should refer
;;;          di = process to which to give handle
;;;          dx = entry point
;;; Outputs: ax = new handle, or -1 on failure
proc_make_handle_internal:
    shl     si, 12
    shl     di, 12
    push    es
    mov     es, di
    xor     di, di
    xor     ax, ax
    dec     ax
.search:
    cmp     di, 0x100
    jge     .end
    cmp     word [di+hnd_ptr], 0
    je      .found
    add     di, hnd_size
    jmp     .search
.found:
    mov     [di+hnd_ptr], dx
    mov     [di+hnd_seg], si
    mov     word [di+hnd_rindex], 0
    mov     ax, di
    shr     ax, 12
.end:
    pop     es
    ret

proc_give_handle:
    retf

;;; DATA

;;; MBR PADDING AND SIGNATURE

    times 510-($-$$) db 0
    db 0x55
    db 0xaa

    section .bss
__bss_start:

sector_buf: resb 512

used_pids:  resb 9

__bss_end:
