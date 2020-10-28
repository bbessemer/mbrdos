# Bootdisk File System

The Bootdisk File System (BFS) is a simple read-only file system intended for
use in bootdisks, RAM or ROM file systems, and other cases where simplicity
of implementation is valued over advanced features. Its primary goal is to
provide a format more suited for random-access reads than the linear archive
formats (TAR, CPIO) traditionally used for boot ramdisks. It may also be useful
as an archive format, although compression will negate many of its benefits.

A BFS image is made up of a sequence of sectors, which may be any size between
512 and 65536 bytes. Ideally the sector size should be equal to either the disk
sector size, if the file system is to be stored on a disk, or the architecture's
page size, if the file system is to exist in RAM or ROM. The sector size is
specified by one of the fields of the BFS header, which for compatibility
reasons exists at an offset of 500 bytes into the first sector. The format of
the header is as follows:

| Offset | Size | Field |
|--------|------|-------|
| 500    | 3    | The ASCII string `BFS` |
| 503    | 1    | Word size of the filesystem (either 16 or 32) |
| 504    | 4    | Number of sectors in the filesystem (including the boot sector) |
| 508    | 2    | Sector size in bytes (a value of 0 means a size of 65536) |
| 510    | 2    | The two bytes `0x55` `0xaa`, for compatibility reasons |

If the sector size is greater than 512, the rest of the sector is padded with
arbitrary data.

The remainder of the file system is made up of a combination of directories and
files, which always occupy a whole number of contiguous sectors. The format of a
directory depends on the filesystem's word size:

**16-bit word size (32-byte entries)**

| Offset | Size | Field |
|--------|------|-------|
| 0      | 24   | Name (null-terminated if less than 24 bytes) |
| 24     | 2    | Start sector |
| 26     | 2    | Total number of sectors occupied |
| 28     | 2    | Number of bytes used in last sector |
| 30     | 2    | Flags |

**32-bit word size (64-byte entries)**

| Offset | Size | Field |
|--------|------|-------|
| 0      | 52   | Name (null-terminated if less than 52 bytes) |
| 52     | 4    | Start sector |
| 56     | 4    | Total number of sectors occupied |
| 60     | 2    | Number of bytes used in last sector |
| 62     | 2    | Flags |

The special value 0 for the "number of bytes used in last sector" field means
that the full sector is occupied, regardless of the sector size.

