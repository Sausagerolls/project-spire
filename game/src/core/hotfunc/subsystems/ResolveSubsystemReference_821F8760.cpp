// Hand-tuned override of recompiled ResolveSubsystemReference_821F8760
// (recompiler output: fable_2_recomp.130.cpp; generated transforms nv=1 mfmsr=1
// glock=0 gt=0). The "// Hand-tuned override" first line makes
// tools/make_hotfunc_overrides.py skip this file; re-run that script to
// regenerate the literal reference copy.
//
// The recompiler emits recompiled guest functions as WEAK extern "C" aliases
// of __imp__ResolveSubsystemReference_821F8760; fable_2_register.cpp registers
// the ALIAS in the indirect-dispatch table. This strong definition intercepts
// both direct bl calls and bctrl dispatch. __imp__ResolveSubsystemReference_821F8760
// remains the original.
//
// Behavior-identical to the generated copy: same guest RAM reads/writes, same
// dispatch targets and guest return addresses, same r1/r3/r4/r5/r12/cr6 side
// effects on every path, same trap calls. (Volatile non-argument registers
// r7-r11 may end up holding different values than in the generated copy;
// under the PPC32 ABI they are caller-saved, so well-formed guest code writes
// them before use - only r2, r13-r30, r1 and the argument registers are
// preserved across calls, and those are preserved exactly here.) Modernized
// from the generated goto structure to plain if/else; no behavioral change.
//
// Guest logic (see per-instruction disassembly references):
//
//   struct* ResolveSubsystemReference(struct* a /* r3 */)
//   {
//     struct* node = *(u32*)0x83496940;          // lis r11,-31927; lwz 26912;
//     node = node->p12->p140;                    // lwz r10,12(r11); lwz r11,140(r10)
//     bool fast = node->b52 != 0 && node->b54 != 0;  // (clrlwi keeps low 8 bits
//     // in this recompiler; b52 is already a byte, so the second test of it
//     // is redundant but mirrored)
//     if (fast) {
//       r3 = Resolve(a, mode=2);                 // li r4,2; mr r3,r5; bl 0x822641f0
//       if (r3 != 0) return *(struct**)(r3 + 4); // lwz r3,4(r3)
//       // r3 == 0 -> fall back to the slow path below
//     }
//     r3 = Resolve(a, mode=1);                   // li r4,1; mr r3,r5; bl 0x822641f0
//     return r3 != 0 ? *(struct**)(r3 + 4) : r3; // bne -> lwz r3,4(r3)
//   }

#include "fable_2_pch.h"

extern "C" void ProcessAndProcessAndProcess1124_822641F0(PPCContext& ctx, uint8_t* base);

namespace {

// Non-volatile guest-RAM access. Same address math and byte order as the pch's
// REX_LOAD_*/REX_STORE_* macros, without `volatile` (safe: this function
// touches no MMIO, and the calls it makes are opaque to the optimizer, so
// no access can be CSE'd across one).
//
// Marked always_inline so each access expands to a direct memory op even at
// -O0 (the Debug build). A plain `inline` here would make clang emit a call
// per access at -O0, which would make this override *slower* than the
// generated copy (whose GV*/SV* macros are always direct memory ops).
#define HOTFUNC_ALWAYS_INLINE __attribute__((always_inline))
HOTFUNC_ALWAYS_INLINE uint8_t* gaddr(u32 addr, uint8_t* base) {
  return base + (u32)addr + REX_PHYS_HOST_OFFSET(addr);
}
HOTFUNC_ALWAYS_INLINE u32 gload32(u32 addr, uint8_t* base) {
  return __builtin_bswap32(*reinterpret_cast<const u32*>(gaddr(addr, base)));
}
HOTFUNC_ALWAYS_INLINE u8 gload8(u32 addr, uint8_t* base) {
  return *reinterpret_cast<const u8*>(gaddr(addr, base));
}
HOTFUNC_ALWAYS_INLINE void gstore32(u32 addr, uint8_t* base, u32 v) {
  *reinterpret_cast<u32*>(gaddr(addr, base)) = __builtin_bswap32(v);
}

}  // namespace

extern "C" void ResolveSubsystemReference_821F8760(PPCContext& __restrict ctx, uint8_t* base) {
  REX_FUNC_PROLOGUE();

  // --- Guest prologue: mflr r12; stw r12,-8(r1); stwu r1,-96(r1);
  //     mr r5,r3 (protect the argument across the guest calls) ---
  const u32 entry_sp = ctx.r1.u32;
  const u32 frame_sp = entry_sp - 96;
  ctx.r12.u64 = ctx.lr;                 // mflr r12
  gstore32(entry_sp - 8, base, (u32)ctx.r12.u64);  // stw r12,-8(r1)
  gstore32(frame_sp, base, entry_sp);   // stwu r1,-96(r1)
  ctx.r1.u32 = frame_sp;
  ctx.r5.u64 = ctx.r3.u64;              // mr r5,r3

  // Global chain (0x821f876c-0x821f8780): lis r11,-31927 (0x83490000);
  // lwz r11,26912(r11); lwz r10,12(r11); lwz r11,140(r10); lbz r9,52(r11)
  const u32 node =
      gload32(gload32(gload32(0x83490000 + 26912, base) + 12, base) + 140, base);
  const u8 byte52 = gload8(node + 52, base);
  ctx.cr6.compare<u32>(byte52, 0, ctx.xer);      // cmplwi cr6,r9,0

  // Path selection (0x821f8784-0x821f87b8): fast (path A) iff byte52 != 0
  // (re-tested through `clrlwi` - the recompiler keeps the low 8 bits - so
  // the extra compare is redundant for a byte but mirrored) and
  // node->b54 != 0; the low byte of the 0/1 result is re-checked before
  // dispatch.
  bool fast_path =
      ctx.cr6.eq == false && (byte52 & 0xFF) != 0;  // beq / clrlwi / beq -> slow
  if (fast_path) {
    const u8 byte54 = gload8(node + 54, base);      // lbz r11,54(r11)
    ctx.cr6.compare<u32>(byte54, 0, ctx.xer);       // cmplwi cr6,r11,0
    fast_path = ctx.cr6.eq == false;                // bne -> fast (r11 = 1)
  }
  const u32 pick = fast_path ? 1u : 0u;             // li r11,1 / li r11,0
  ctx.cr6.compare<u32>(pick & 0xFF, 0, ctx.xer);    // clrlwi r11,r11,24; cmplwi

  // --- Path A (fast, 0x821f87bc): li r4,2; mr r3,r5; bl 0x822641f0 ---
  bool fast_resolved = false;
  if (ctx.cr6.eq == false) {
    ctx.r4.s64 = 2;
    ctx.r3.u64 = ctx.r5.u64;
    ctx.lr = 0x821F87C4;
    ProcessAndProcessAndProcess1124_822641F0(ctx, base);
    ctx.cr6.compare<u32>(ctx.r3.u32, 0, ctx.xer);   // cmplwi cr6,r3,0
    if (ctx.cr6.eq == false) {
      // 0x821f87cc: lwz r3,4(r3) -> epilogue.
      ctx.r3.u64 = gload32(ctx.r3.u32 + 4, base);
      fast_resolved = true;
    }
    // r3 == 0 -> fall back to path B (the generated beq targets 0x821f87e0).
  }

  // --- Path B (slow, 0x821f87e0): li r4,1; mr r3,r5; bl 0x822641f0 ---
  if (!fast_resolved) {
    ctx.r4.s64 = 1;
    ctx.r3.u64 = ctx.r5.u64;
    ctx.lr = 0x821F87EC;
    ProcessAndProcessAndProcess1124_822641F0(ctx, base);
    ctx.cr6.compare<u32>(ctx.r3.u32, 0, ctx.xer);   // cmplwi cr6,r3,0
    if (ctx.cr6.eq == false) {
      // bne -> 0x821f87cc: lwz r3,4(r3).
      ctx.r3.u64 = gload32(ctx.r3.u32 + 4, base);
    }
    // r3 == 0 -> epilogue with r3 = 0 (the call result, unchanged).
  }

  // --- Guest epilogue: addi r1,r1,96; lwz r12,-8(r1); mtlr r12; blr ---
  ctx.r1.s64 = entry_sp;
  ctx.r12.u64 = gload32(entry_sp - 8, base);
  ctx.lr = ctx.r12.u64;
}
