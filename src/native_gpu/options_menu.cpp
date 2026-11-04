// Adds an Options entry to the game's main menu. The native menu is a tree built
// by repeated calls to one function (New Game, Load Game, ..., Subtitles with On
// and Off as its children), and selections arrive by item name at one handler
// that ignores names it doesn't know. So the entries are added with the game's own
// functions and look like any other. A label that isn't a text tag is shown as is.
// To add a setting, add its items in AddOptionsItems and handle them in OnSelect.
// Keep settings directly under Options: a third level of this menu opens to a blank
// row that can't be selected, so each value is one item ("Frame Rate: 30 FPS").

#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "core/fable2_config.h"
#include "fable_2_pch.h"

extern "C" {
void ConstructRefCounted_8222CF18(PPCContext& ctx, uint8_t* base);  // String(this, text, -1).
void DestructRefCounted_82214F08(PPCContext& ctx, uint8_t* base);   // ~String(this).
void ProcessAndProcessAndProcess1726_82301D40(PPCContext& ctx, uint8_t* base);  // Text(this, tag).
void ReleaseGlobalRef_821C6868(PPCContext& ctx, uint8_t* base);     // ~Text(this).
void ProcessAndProcessAndProcess2440_826CB808(PPCContext& ctx, uint8_t* base);  // AddItem.
void sub_826CBA78(PPCContext& ctx, uint8_t* base);                  // SetItemSelected.
void Allocate_OrDbgBreak_8221F388(PPCContext& ctx, uint8_t* base);  // Allocate(size).
void __imp__sub_826CA6E0(PPCContext& __restrict ctx, uint8_t* base);
void __imp__ProcessAndProcessAndProcess2446_826C81A0(PPCContext& __restrict ctx, uint8_t* base);
}

namespace {

const char kOptions[] = "MacOptions";
const char kFrameRate30[] = "MacFrameRate30";
const char kFrameRateUncapped[] = "MacFrameRateUncapped";
const char kOptionsIcon[] = "Art\\GUI\\icon_options.tga";

// Guest copies of host strings, kept for the whole run.
uint32_t GuestString(PPCContext& ctx, uint8_t* base, const char* text) {
  static std::unordered_map<std::string, uint32_t> strings;
  auto it = strings.find(text);
  if (it != strings.end()) {
    return it->second;
  }
  size_t length = std::strlen(text) + 1;
  ctx.r3.u64 = length;
  Allocate_OrDbgBreak_8221F388(ctx, base);
  uint32_t address = ctx.r3.u32;
  std::memcpy(REX_RAW_ADDR(address), text, length);
  strings.emplace(text, address);
  return address;
}

void ConstructString(PPCContext& ctx, uint8_t* base, uint32_t object, const char* text) {
  uint32_t address = GuestString(ctx, base, text);
  ctx.r3.u64 = object;
  ctx.r4.u64 = address;
  ctx.r5.s64 = -1;
  ConstructRefCounted_8222CF18(ctx, base);
}

void DestructString(PPCContext& ctx, uint8_t* base, uint32_t object) {
  ctx.r3.u64 = object;
  DestructRefCounted_82214F08(ctx, base);
}

// In the frame, the same layout as the game's calls (the 9th argument is at +84).
constexpr uint32_t kFrameSize = 256;
constexpr uint32_t kArgument9 = 84;
constexpr uint32_t kName = 96, kIcon = 100, kParent = 104, kTextTag = 108, kText = 112;

void AddItem(PPCContext& ctx, uint8_t* base, uint32_t menu, const char* name, const char* label,
             const char* parent) {
  uint32_t frame = ctx.r1.u32;
  ConstructString(ctx, base, frame + kName, name);
  ConstructString(ctx, base, frame + kIcon, kOptionsIcon);
  ConstructString(ctx, base, frame + kParent, parent);
  ConstructString(ctx, base, frame + kTextTag, label);
  ctx.r3.u64 = frame + kText;
  ctx.r4.u64 = frame + kTextTag;  // Consumes the string.
  ProcessAndProcessAndProcess1726_82301D40(ctx, base);
  uint32_t text = ctx.r3.u32;
  REX_STORE_U32(frame + kArgument9, 0);
  ctx.r3.u64 = menu;
  ctx.r4.u64 = frame + kName;
  ctx.r5.u64 = text;
  ctx.r6.u64 = frame + kIcon;
  ctx.r7.u64 = frame + kParent;
  ctx.r8.u64 = 0;
  ctx.r9.u64 = 2;
  ctx.r10.u64 = REX_LOAD_U32(menu + 20);
  ProcessAndProcessAndProcess2440_826CB808(ctx, base);
  ctx.r3.u64 = frame + kText;
  ReleaseGlobalRef_821C6868(ctx, base);
  DestructString(ctx, base, frame + kParent);
  DestructString(ctx, base, frame + kIcon);
  DestructString(ctx, base, frame + kName);
}

void SetSelected(PPCContext& ctx, uint8_t* base, uint32_t menu, const char* name, bool selected) {
  uint32_t frame = ctx.r1.u32;
  ConstructString(ctx, base, frame + kName, name);
  ctx.r3.u64 = menu;
  ctx.r4.u64 = frame + kName;
  ctx.r5.u64 = selected ? 1 : 0;
  ctx.r6.u64 = REX_LOAD_U32(menu + 20);
  sub_826CBA78(ctx, base);
  DestructString(ctx, base, frame + kName);
}

bool IsUncapped() { return rex::cvar::GetFlagByName("vsync") != "true"; }

void AddOptionsItems(PPCContext& ctx, uint8_t* base, uint32_t menu) {
  AddItem(ctx, base, menu, kOptions, "Options", "Root");
  AddItem(ctx, base, menu, kFrameRate30, "Frame Rate: 30 FPS", kOptions);
  AddItem(ctx, base, menu, kFrameRateUncapped, "Frame Rate: Uncapped", kOptions);
  SetSelected(ctx, base, menu, IsUncapped() ? kFrameRateUncapped : kFrameRate30, true);
}

// Returns whether the name was one of the added items.
bool OnSelect(PPCContext& ctx, uint8_t* base, uint32_t menu, const char* name) {
  bool uncap;
  if (!std::strcmp(name, kFrameRate30)) {
    uncap = false;
  } else if (!std::strcmp(name, kFrameRateUncapped)) {
    uncap = true;
  } else {
    return false;
  }
  rex::cvar::SetFlagByName("vsync", uncap ? "false" : "true");
  fable2::config::SaveUncapFrameRate(uncap);
  REXSYS_INFO("[options] frame rate {}", uncap ? "uncapped" : "capped at 30 fps");
  SetSelected(ctx, base, menu, uncap ? kFrameRate30 : kFrameRateUncapped, false);
  SetSelected(ctx, base, menu, uncap ? kFrameRateUncapped : kFrameRate30, true);
  // Refresh the menu, like the game's Subtitles items.
  ctx.r3.u64 = REX_LOAD_U32(menu + 20);
  ctx.ctr.u64 = REX_LOAD_U32(REX_LOAD_U32(ctx.r3.u32) + 12);
  REX_CALL_INDIRECT_FUNC(ctx.ctr.u32);
  ctx.ctr.u64 = REX_LOAD_U32(REX_LOAD_U32(ctx.r3.u32) + 16);
  REX_CALL_INDIRECT_FUNC(ctx.ctr.u32);
  return true;
}

}  // namespace

// Builds the main menu's items.
extern "C" void sub_826CA6E0(PPCContext& __restrict ctx, uint8_t* base) {
  uint32_t menu = ctx.r3.u32;
  uint64_t saved_lr = ctx.lr;
  __imp__sub_826CA6E0(ctx, base);
  ctx.r1.u32 -= kFrameSize;
  AddOptionsItems(ctx, base, menu);
  ctx.r1.u32 += kFrameSize;
  ctx.lr = saved_lr;
}

// The main menu's event handler.
extern "C" void ProcessAndProcessAndProcess2446_826C81A0(PPCContext& __restrict ctx, uint8_t* base) {
  uint32_t menu = ctx.r3.u32;
  uint32_t event = ctx.r4.u32;
  uint32_t type = REX_LOAD_U32(event + 4);
  if (type != 302 && type != 141 && type != 140) {
    uint32_t name_object = REX_LOAD_U32(event);
    uint32_t name_address = name_object ? REX_LOAD_U32(name_object) : 0;
    if (name_address) {
      const char* name = reinterpret_cast<const char*>(REX_RAW_ADDR(name_address));
      uint64_t saved_lr = ctx.lr;
      ctx.r1.u32 -= kFrameSize;
      bool handled = OnSelect(ctx, base, menu, name);
      ctx.r1.u32 += kFrameSize;
      ctx.lr = saved_lr;
      if (handled) {
        return;
      }
      ctx.r3.u64 = menu;
      ctx.r4.u64 = event;
    }
  }
  __imp__ProcessAndProcessAndProcess2446_826C81A0(ctx, base);
}
