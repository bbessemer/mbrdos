/*
 * mkbfs - host tool for manipulating Bootdisk File System (BFS) images
 *
 * This is free and unencumbered software released into the public domain.
 * Written 2020 by Brent Bessemer.
 *
 * For documentation on BFS, see bfs.md in the root of this repository.
 */

#include <stdlib.h>
#include <stdio.h>
#include <dirent.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef unsigned long  u64;
typedef   signed char  s8;
typedef   signed short s16;
typedef   signed int   s32;
typedef   signed long  s64;

typedef struct bfs_header {
    char bfs[3];
    u8 word_size;
    u32 n_sectors;
    u16 sector_size;
    u16 mbr_magic;
} bfshdr_t;

typedef struct bfs16_dir {
    char name[24];
    u16 start;
    u16 sectors;
    u16 bytes_rem;
    u16 flags;
} bfs16dir_t;

typedef struct bfs32_dir {
    char name[52];
    u32 start;
    u32 sectors;
    u16 bytes_rem;
    u16 flags;
} bfs32dir_t;

#define BFS_DIR      (1 << 0)
#define BFS_HARDLINK (1 << 1)
#define BFS_SYMLINK  (1 << 2)

#define SUCCESS       0
#define ERR_NODIVIS  -1
#define ERR_WORDSIZE -2
#define ERR_LONGNAME -3
#define ERR_NOSPACE  -4
#define ERR_FILEIO   -5

static inline void *sector_ptr(bfshdr_t *header, u32 i)
{
    return (char *)header - 500 + header->sector_size * i;
}

static FILE *fopenat(DIR *srcdir, const char *path, const char *mode)
{
    int fd = openat(dirfd(srcdir), path, O_RDONLY);
    if (fd)
        return fdopen(fd, "rb");
    else
        return NULL;
}

static DIR *opendirat(DIR *srcdir, const char *path)
{
    int fd = openat(dirfd(srcdir), path, O_RDONLY);
    if (fd)
        return fdopendir(fd);
    else
        return NULL;
}

static int isdir(const char *path)
{
    struct stat statbuf;
    if (stat(path, &statbuf) < 0)
        return 0;
    return S_ISDIR(statbuf.st_mode);
}

int bfs_create(void *mem, long size, u16 sector_size, u8 word_size)
{
    if (size % sector_size != 0)
        return ERR_NODIVIS;

    if (word_size != 16 && word_size != 32)
        return ERR_WORDSIZE;

    bfshdr_t *header = mem + 500;
    header->word_size = word_size;
    header->n_sectors = size / (long)sector_size;
    header->sector_size = sector_size;
    header->mbr_magic = 0xaa55;

    return SUCCESS;
}

static s32 bfs16_mkfile(bfshdr_t *header, u32 start_sector, FILE *src,
                        bfs16dir_t *direntry)
{
    long sector_size = header->sector_size;
    if (sector_size == 0)
        sector_size = (1 << 16);

    for (u32 sector = start_sector; sector < header->n_sectors; sector++) {
        void *buf = sector_ptr(header, sector);
        long bytes_read = fread(buf, 1, sector_size, src);
        if (feof(src)) {
            if (bytes_read == sector_size)
                bytes_read = 0;
            sector++;
            u32 n_sectors = sector - start_sector;
            direntry->start = start_sector;
            direntry->sectors = n_sectors;
            direntry->bytes_rem = bytes_read;
            direntry->flags = 0;
            return n_sectors;
        } else if (ferror(src)) {
            return ERR_FILEIO;
        }
    }

    return ERR_NOSPACE;
}

static s32 bfs16_mkdir(bfshdr_t *header, u32 start_sector, DIR *srcdir,
                       bfs16dir_t *parent, bfs16dir_t *parent_entry)
{
    bfs16dir_t *start = sector_ptr(header, start_sector);
    u32 sector = start_sector;
    int n_entries = 2;
    long sector_size = header->sector_size;
    if (sector_size == 0)
        sector_size = (1 << 16);

    bfs16dir_t *entry = start + 2;
    while (1) {
        struct dirent *srcdirent = readdir(srcdir);
        if (!srcdirent)
            break;

        if (!strcmp(srcdirent->d_name, ".") || !strcmp(srcdirent->d_name, ".."))
            continue;

        if (strlen(srcdirent->d_name) > sizeof(entry->name) - 1)
            return ERR_LONGNAME;
        strcpy(entry->name, srcdirent->d_name);
        /* fprintf(stderr, "Made entry %s\n", entry->name); */

        if (++n_entries % (sector_size / sizeof(bfs16dir_t)) == 0)
            if (++sector >= header->n_sectors)
                return ERR_NOSPACE;
        entry++;
    }

    u32 n_sectors = sector - start_sector;
    int bytes_rem = n_entries * sizeof(bfs16dir_t) - n_sectors * sector_size;
    if (bytes_rem) {
        sector++;
        n_sectors++;
    }
    strcpy(start->name, ".");
    start->start = start_sector;
    start->sectors = n_sectors;
    start->bytes_rem = bytes_rem;
    start->flags = BFS_DIR;

    if (parent_entry) {
        parent_entry->start = start->start;
        parent_entry->sectors = start->sectors;
        parent_entry->bytes_rem = start->bytes_rem;
        parent_entry->flags = start->flags;
    }
    if (parent) {
        strcpy(start[1].name, "..");
        start[1].start = parent->start;
        start[1].sectors = parent->sectors;
        start[1].bytes_rem = parent->bytes_rem;
        start[1].flags = parent->flags;
    }

    for (bfs16dir_t *entry = start + 2; entry < start + n_entries; entry++) {
        s32 advance_by;
        if (isdir(entry->name)){
            DIR *dir = opendirat(srcdir, entry->name);
            if (!dir)
                return ERR_FILEIO;
            advance_by = bfs16_mkdir(header, sector, dir, start, entry);
        } else {
            FILE *file = fopenat(srcdir, entry->name, "rb");
            if (!file)
                return ERR_FILEIO;
            advance_by = bfs16_mkfile(header, sector, file, entry);
        }
        if (advance_by < 0)
            return advance_by;
        sector += advance_by;
    }

    return sector - start_sector;
}

s32 bfs_mkdir(bfshdr_t *header, u32 start_sector, DIR *srcdir, void *parent,
              void *parent_entry)
{
    if (header->word_size == 16)
        return bfs16_mkdir(header, start_sector, srcdir, parent, parent_entry);
    /* else if (header->word_size == 32) */
    /*     return bfs32_mkdir(header, start_sector, srcdir, parent); */
    else
        return ERR_WORDSIZE;
}

static void die(int errcode)
{
    const char *msg;
    switch (errcode) {
        case ERR_NODIVIS:
            msg = "Total size is not divisible by sector size";
            break;
        case ERR_WORDSIZE:
            msg = "Word size must be either 16 or 32";
            break;
        case ERR_LONGNAME:
            msg = "File name is too long";
            break;
        case ERR_NOSPACE:
            msg = "No space left on disk";
            break;
        case ERR_FILEIO:
            msg = "File I/O error";
            break;
        default:
            msg = "Unknown error";
            break;
    }
    fprintf(stderr, "error: %s\n", msg);
    exit(errcode);
}

int main(int argc, char **argv)
{
    // Default is a 16-bit floppy-size image
    u8 word_size = 16;
    u32 n_sectors = 2880;
    u16 sector_size = 512;

    // TODO: parse command-line args

    long size = (long)n_sectors * (long)sector_size;

    void *buf = malloc(size);
    bfshdr_t *header = buf + 500;
    bfs_create(buf, size, sector_size, word_size);

    DIR *srcdir = opendir(".");
    if (!srcdir) {
        fprintf(stderr, "Failed to open source directory.\n");
        die(ERR_FILEIO);
    }

    int rc = bfs_mkdir(header, 1, srcdir, NULL, NULL);

    if (rc < 0)
        die(rc);

    FILE *out = fopen("floppy.img", "wb");
    if (!out)
        die(ERR_FILEIO);

    rc = fwrite(buf, 1, size, out);
    if (rc != size)
        die(ERR_FILEIO);

    return 0;
}
