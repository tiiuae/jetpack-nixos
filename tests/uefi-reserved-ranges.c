// SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef uint64_t UINT64;
typedef uint32_t UINT32;
typedef int32_t INT32;
typedef size_t UINTN;
typedef int EFI_STATUS;
#define STATIC static
#define VOID void
#define IN
#define CONST const
#define EFI_SUCCESS 0
#define EFI_INVALID_PARAMETER 1
#define EFI_ERROR(s) ((s) != 0)
#define EFI_PAGE_MASK 4095
#define MAX_UINT64 UINT64_MAX
#define EFI_HOB_TYPE_MEMORY_ALLOCATION 1
#define EFI_HOB_TYPE_RESOURCE_DESCRIPTOR 2
#define EFI_RESOURCE_SYSTEM_MEMORY 0
#define EfiBootServicesData 4
#define FDT_ERR_NOTFOUND 1
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define DEBUG(args) ((void)0)

struct hob {
    int type;
    struct { UINT64 MemoryBaseAddress, MemoryLength; } AllocDescriptor;
    int ResourceType;
    UINT64 PhysicalStart, ResourceLength;
};
typedef union {
    struct hob *Raw, *MemoryAllocation, *ResourceDescriptor;
} EFI_PEI_HOB_POINTERS;
#define GET_NEXT_HOB(h) ((h).Raw + 1)
static struct hob hobs[128];
static size_t count;
static struct hob *GetHobList(void) { return hobs; }
static struct hob *GetNextHob(int type, struct hob *h) {
    for (; h < hobs + count; h++) if (h->type == type) return h;
    return NULL;
}
static void BuildMemoryAllocationHob(UINT64 base, UINT64 size, int type) {
    assert(type == EfiBootServicesData);
    assert(size && !(base & EFI_PAGE_MASK) && !(size & EFI_PAGE_MASK));
    for (size_t i = 0; i < count; i++) {
        if (hobs[i].type != EFI_HOB_TYPE_MEMORY_ALLOCATION) continue;
        UINT64 start = hobs[i].AllocDescriptor.MemoryBaseAddress;
        UINT64 end = start + hobs[i].AllocDescriptor.MemoryLength;
        assert(base + size <= start || base >= end);
    }
    assert(count < 128);
    hobs[count++] = (struct hob){.type = EFI_HOB_TYPE_MEMORY_ALLOCATION,
        .AllocDescriptor = {base, size}};
}
static void resource(UINT64 base, UINT64 size, int type) {
    assert(count < 128);
    hobs[count++] = (struct hob){.type = EFI_HOB_TYPE_RESOURCE_DESCRIPTOR,
        .ResourceType = type, .PhysicalStart = base, .ResourceLength = size};
}
static int node = 1, compatible, reg_length = 16;
static UINT32 reg_cells[8];
static EFI_STATUS DtPlatformLoadDtb(void **dtb, UINTN *size) {
    *dtb = reg_cells; *size = sizeof reg_cells; return 0;
}
static INT32 FdtPathOffset(const void *dtb, const char *path) {
    (void)dtb;
    assert(!strcmp(path, "/firmware/uefi/reserved-ranges"));
    return node;
}
static int FdtNodeCheckCompatible(const void *dtb, int n, const char *c) {
    (void)dtb; (void)n;
    assert(!strcmp(c, "ghaf,uefi-reserved-ranges"));
    return compatible;
}
static const void *FdtGetProp(const void *dtb, int n, const char *p, int *len) {
    (void)dtb; (void)n; assert(!strcmp(p, "reg"));
    *len = reg_length; return reg_cells;
}
static UINT32 Fdt32ToCpu(UINT32 v) { return v; }

#include "reserve-dtb-ranges.h"

static void reset(void) {
    count = 0; node = 1; compatible = 0; reg_length = 16;
    memset(reg_cells, 0, sizeof reg_cells);
}
static void range(UINT64 base, UINT64 size) {
    reg_cells[0] = base >> 32; reg_cells[1] = base;
    reg_cells[2] = size >> 32; reg_cells[3] = size;
}
static int allocated(UINT64 address) {
    for (size_t i = 0; i < count; i++) {
        if (hobs[i].type != EFI_HOB_TYPE_MEMORY_ALLOCATION) continue;
        UINT64 base = hobs[i].AllocDescriptor.MemoryBaseAddress;
        if (address >= base && address - base < hobs[i].AllocDescriptor.MemoryLength) return 1;
    }
    return 0;
}
int main(void) {
    // An existing allocation in the middle must not leave either side free.
    reset(); resource(0x1000, 0x10000, 0); range(0x2000, 0x8000);
    BuildMemoryAllocationHob(0x5000, 0x2000, EfiBootServicesData);
    assert(ReserveDtbRanges() == EFI_SUCCESS);
    for (UINT64 p = 0x2000; p < 0xa000; p += 0x1000) assert(allocated(p));
    assert(!allocated(0x1000) && !allocated(0xa000));
    size_t before = count;
    assert(ReserveDtbRanges() == EFI_SUCCESS && count == before);

    // Unsorted allocations cover both boundaries and leave multiple gaps.
    reset(); resource(0x1000, 0x10000, 0); range(0x2000, 0x8000);
    BuildMemoryAllocationHob(0x9000, 0x3000, EfiBootServicesData);
    BuildMemoryAllocationHob(0x1000, 0x2000, EfiBootServicesData);
    BuildMemoryAllocationHob(0x5000, 0x1000, EfiBootServicesData);
    assert(ReserveDtbRanges() == EFI_SUCCESS);
    for (UINT64 p = 0x2000; p < 0xa000; p += 0x1000) assert(allocated(p));

    // Firmware holes and non-RAM apertures must not become allocations.
    reset(); resource(0x80000000, 0x2000, 0); resource(0x80004000, 0x2000, 0);
    resource(0x80002000, 0x2000, 1); range(0x80000000, 0x6000);
    assert(ReserveDtbRanges() == EFI_SUCCESS);
    assert(allocated(0x80000000) && allocated(0x80005000));
    assert(!allocated(0x80002000) && !allocated(0x80003000));

    reset(); resource(0x200000000, 0x10000, 0); range(0x200002000, 0x3000);
    assert(ReserveDtbRanges() == EFI_SUCCESS);
    assert(allocated(0x200002000) && allocated(0x200004000));
    assert(!allocated(0x200005000));

    // Multiple DTB entries, including overlapping reservations, are a union.
    reset(); resource(0x1000, 0x10000, 0); range(0x2000, 0x4000);
    reg_length = 32; reg_cells[5] = 0x4000; reg_cells[7] = 0x4000;
    assert(ReserveDtbRanges() == EFI_SUCCESS);
    for (UINT64 p = 0x2000; p < 0x8000; p += 0x1000) assert(allocated(p));
    assert(!allocated(0x1000) && !allocated(0x8000));

    // Reject malformed configuration; a missing optional node is harmless.
    reset(); range(0x1000, 0); assert(ReserveDtbRanges() == EFI_INVALID_PARAMETER);
    range(0x1001, 0x1000); assert(ReserveDtbRanges() == EFI_INVALID_PARAMETER);
    range(0x1000, 0x1001); assert(ReserveDtbRanges() == EFI_INVALID_PARAMETER);
    range(UINT64_MAX - 4095, 0x1000); assert(ReserveDtbRanges() == EFI_INVALID_PARAMETER);
    reg_length = 15; assert(ReserveDtbRanges() == EFI_INVALID_PARAMETER);
    reg_length = 0; assert(ReserveDtbRanges() == EFI_INVALID_PARAMETER);
    compatible = 1; assert(ReserveDtbRanges() == EFI_INVALID_PARAMETER);
    node = -FDT_ERR_NOTFOUND; assert(ReserveDtbRanges() == EFI_SUCCESS);
    assert(count == 0);
    puts("UEFI reservation coverage tests passed");
}
