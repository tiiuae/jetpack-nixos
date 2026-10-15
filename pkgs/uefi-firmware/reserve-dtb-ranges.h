/** @file
  Keep the EFI allocator out of the VM carveouts described by the UEFI DTB.

  SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

STATIC
VOID
ReserveUnallocatedRange (
  IN UINT64  Base,
  IN UINT64  End
  )
{
  EFI_PEI_HOB_POINTERS  Hob;
  UINT64                Cursor;
  UINT64                Next;
  UINT64                CoveredEnd;
  UINT64                AllocBase;
  UINT64                AllocEnd;

  Cursor = Base;
  while (Cursor < End) {
    Next       = End;
    CoveredEnd = Cursor;
    Hob.Raw    = GetHobList ();
    while ((Hob.Raw = GetNextHob (EFI_HOB_TYPE_MEMORY_ALLOCATION, Hob.Raw)) != NULL) {
      AllocBase = Hob.MemoryAllocation->AllocDescriptor.MemoryBaseAddress;
      AllocEnd  = AllocBase + Hob.MemoryAllocation->AllocDescriptor.MemoryLength;
      if ((AllocBase <= Cursor) && (Cursor < AllocEnd)) {
        CoveredEnd = MAX (CoveredEnd, AllocEnd);
      } else if (AllocBase > Cursor) {
        Next = MIN (Next, AllocBase);
      }

      Hob.Raw = GET_NEXT_HOB (Hob);
    }

    if (CoveredEnd > Cursor) {
      Cursor = CoveredEnd;
    } else {
      // Preserve existing allocations, but reserve every gap around them.
      BuildMemoryAllocationHob (Cursor, Next - Cursor, EfiBootServicesData);
      Cursor = Next;
    }
  }
}

STATIC
VOID
ReserveSystemMemoryRange (
  IN UINT64  Base,
  IN UINT64  Size
  )
{
  EFI_PEI_HOB_POINTERS  Hob;
  UINT64                Start;
  UINT64                End;

  Hob.Raw = GetHobList ();
  while ((Hob.Raw = GetNextHob (EFI_HOB_TYPE_RESOURCE_DESCRIPTOR, Hob.Raw)) != NULL) {
    if (Hob.ResourceDescriptor->ResourceType == EFI_RESOURCE_SYSTEM_MEMORY) {
      Start = MAX (Base, Hob.ResourceDescriptor->PhysicalStart);
      End   = MIN (Base + Size, Hob.ResourceDescriptor->PhysicalStart + Hob.ResourceDescriptor->ResourceLength);
      if (Start < End) {
        ReserveUnallocatedRange (Start, End);
      }
    }

    Hob.Raw = GET_NEXT_HOB (Hob);
  }
}

STATIC
EFI_STATUS
ReserveDtbRanges (
  VOID
  )
{
  EFI_STATUS     Status;
  VOID           *Dtb;
  UINTN          DtbSize;
  INT32          Node;
  CONST UINT32  *Reg;
  INT32          Length;
  UINT32         Index;
  UINT64         Base;
  UINT64         Size;

  Status = DtPlatformLoadDtb (&Dtb, &DtbSize);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Node = FdtPathOffset (Dtb, "/firmware/uefi/reserved-ranges");
  if (Node == -FDT_ERR_NOTFOUND) {
    return EFI_SUCCESS;
  }

  if ((Node < 0) || (FdtNodeCheckCompatible (Dtb, Node, "ghaf,uefi-reserved-ranges") != 0)) {
    return EFI_INVALID_PARAMETER;
  }

  Reg = FdtGetProp (Dtb, Node, "reg", &Length);
  if ((Reg == NULL) || (Length <= 0) || ((Length % (4 * sizeof (UINT32))) != 0)) {
    return EFI_INVALID_PARAMETER;
  }

  for (Index = 0; Index < (UINT32)Length / sizeof (UINT32); Index += 4) {
    Base = ((UINT64)Fdt32ToCpu (Reg[Index]) << 32) | Fdt32ToCpu (Reg[Index + 1]);
    Size = ((UINT64)Fdt32ToCpu (Reg[Index + 2]) << 32) | Fdt32ToCpu (Reg[Index + 3]);
    if ((Size == 0) || ((Base & EFI_PAGE_MASK) != 0) || ((Size & EFI_PAGE_MASK) != 0) ||
        (Base > MAX_UINT64 - Size))
    {
      return EFI_INVALID_PARAMETER;
    }

    // Boot-services memory excludes EFI-stub allocations, including KASLR.
    // Linux can still map it; the kernel DTB's removed-dma-pool nodes keep it
    // reserved for VFIO. Firmware holes already excluded from RAM stay intact.
    DEBUG ((DEBUG_ERROR, "VM reserved range: 0x%lx+0x%lx\n", Base, Size));
    ReserveSystemMemoryRange (Base, Size);
  }

  return EFI_SUCCESS;
}
