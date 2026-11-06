// Adds an Options entry to the game's main menu. The native menu is a tree built
// by repeated calls to one function (New Game, Load Game, ..., Subtitles with On
// and Off as its children), and selections arrive by item name at one handler
// that ignores names it doesn't know. So the entries are added with the game's own
// functions and look like any other. A label that isn't a text tag is shown as is.
// To add a setting, add its items in AddOptionsItems and handle them in OnSelect.
// Keep settings directly under a top level entry: a third level of this menu opens
// to a blank row that can't be selected. A setting with several values is one item
// that steps to the next value when selected, and is relabelled in place with the
// menu's own RefreshButtonText event (scripts/gameface/expandablemenu, spawning).
//
// Controls (macOS) lists each keyboard and mouse action with its keys. Selecting
// one waits for a key (Esc cancels) through the MnK driver's key capture, polled
// from FrontMenu_PollEventQueue, then saves it (src/input/mac_controls.h).

#include <cstdint>
#include <cstring>
#include <string>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <unordered_map>

#include <rex/cvar.h>
#include <rex/logging.h>

#include "core/fable2_config.h"
#include "input/mac_controls.h"
#ifndef _WIN32
#include <rex/input/mnk/mnk_input_driver.h>
#endif
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
void ProcessAndProcessAndProcess26_8259D6C8(PPCContext& ctx, uint8_t* base);  // SetString(lua, key, value, element).
void ProcessAndVcallAndProcess16_823F8908(PPCContext& ctx, uint8_t* base);   // Run(lua, element).
}

namespace {

const char kOptions[] = "MacOptions";
struct FrameRateItem {
  const char* name;
  const char* label;
  int32_t limit;  // 0 for no limit.
};
const FrameRateItem kFrameRates[] = {
    {"30", "Frame Rate: 30 FPS", 30},
    {"40", "Frame Rate: 40 FPS", 40},
    {"60", "Frame Rate: 60 FPS", 60},
    {"90", "Frame Rate: 90 FPS", 90},
    {"0", "Frame Rate: Uncapped", 0},
};
const char kFrameRate[] = "MacFrameRate";
const char kSensitivity[] = "MacMouseSensitivity";
const char kReduceFlashing[] = "MacReduceFlashing";
const char kControls[] = "MacControls";
const char kBindPrefix[] = "MacBind_";
const char kControlsReset[] = "MacControlsReset";
// The limit of this run, as last chosen.
int32_t current_frame_rate_limit = -1;
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

// The Lua engine the menu's events go to, as the game's menu functions find it: the
// front end's, and the one of in-game menus (pause).
uint32_t MenuEngine(uint8_t* base) {
  uint32_t root = REX_LOAD_U32(0x83496928);
  return REX_LOAD_U32(REX_LOAD_U32(REX_LOAD_U32(root + 8) + 80) + 40);
}
uint32_t GameMenuEngine(uint8_t* base) { return REX_LOAD_U32(REX_LOAD_U32(0x834968A4) + 40); }
// The engine of the menu being changed.
uint32_t current_engine = 0;

void SetElementString(PPCContext& ctx, uint8_t* base, uint32_t element, const char* key,
                      const std::string& value) {
  uint32_t frame = ctx.r1.u32;
  ConstructString(ctx, base, frame + kName, key);
  ConstructString(ctx, base, frame + kText, value.c_str());
  ctx.r3.u64 = current_engine;
  ctx.r4.u64 = frame + kName;
  ctx.r5.u64 = frame + kText;
  ctx.r6.u64 = element;
  ProcessAndProcessAndProcess26_8259D6C8(ctx, base);
  DestructString(ctx, base, frame + kText);
  DestructString(ctx, base, frame + kName);
}

// Changes an item's label (RefreshButtonText reads String1 and String2).
void Relabel(PPCContext& ctx, uint8_t* base, uint32_t element, const char* name,
             const std::string& label) {
  SetElementString(ctx, base, element, "String1", name);
  SetElementString(ctx, base, element, "String2", label);
  uint32_t frame = ctx.r1.u32;
  ConstructString(ctx, base, frame + kName, "g_Menu:RefreshButtonText()");
  ctx.r3.u64 = frame + kName;
  ctx.r4.u64 = element;
  ProcessAndVcallAndProcess16_823F8908(ctx, base);
  DestructString(ctx, base, frame + kName);
  // Run what was queued, like the game's own Subtitles items.
  ctx.r3.u64 = element;
  ctx.ctr.u64 = REX_LOAD_U32(REX_LOAD_U32(ctx.r3.u32) + 12);
  REX_CALL_INDIRECT_FUNC(ctx.ctr.u32);
  // On the object the first call returns.
  ctx.ctr.u64 = REX_LOAD_U32(REX_LOAD_U32(ctx.r3.u32) + 16);
  REX_CALL_INDIRECT_FUNC(ctx.ctr.u32);
}

const FrameRateItem& CurrentFrameRate() {
  for (const FrameRateItem& item : kFrameRates) {
    if (item.limit == current_frame_rate_limit) {
      return item;
    }
  }
  return kFrameRates[0];
}

std::string SensitivityLabel(double sensitivity) {
  char text[64];
  std::snprintf(text, sizeof(text), "Mouse Sensitivity: %.2gx", sensitivity);
  return text;
}

std::string ReduceFlashingLabel() {
  return fable2::controls::ReduceFlashing() ? "Reduce Flashing: On" : "Reduce Flashing: Off";
}

std::string BindName(size_t index) { return kBindPrefix + std::to_string(index); }

std::string BindLabel(const fable2::controls::Action& action) {
  return std::string(action.label) + ": " +
         fable2::controls::KeysDisplay(fable2::controls::CurrentKeys(action.cvar));
}

// A rebind waiting for its key, finished from the menu's per-frame poll.
struct PendingCapture {
  bool active = false;
  size_t action = 0;
  uint32_t element = 0;
  uint32_t engine = 0;
} pending_capture;

void AddOptionsItems(PPCContext& ctx, uint8_t* base, uint32_t menu) {
  AddItem(ctx, base, menu, kOptions, "Options", "Root");
  AddItem(ctx, base, menu, kFrameRate, CurrentFrameRate().label, kOptions);
#ifndef _WIN32
  AddItem(ctx, base, menu, kReduceFlashing, ReduceFlashingLabel().c_str(), kOptions);
  AddItem(ctx, base, menu, kSensitivity,
          SensitivityLabel(fable2::controls::CurrentSensitivity()).c_str(), kOptions);
  AddItem(ctx, base, menu, kControls, "Controls", "Root");
  for (size_t i = 0; i < std::size(fable2::controls::kActions); ++i) {
    AddItem(ctx, base, menu, BindName(i).c_str(),
            BindLabel(fable2::controls::kActions[i]).c_str(), kControls);
  }
  AddItem(ctx, base, menu, kControlsReset, "Reset to Defaults", kControls);
#endif
}

#ifndef _WIN32
void RelabelAllBinds(PPCContext& ctx, uint8_t* base, uint32_t element) {
  for (size_t i = 0; i < std::size(fable2::controls::kActions); ++i) {
    Relabel(ctx, base, element, BindName(i).c_str(), BindLabel(fable2::controls::kActions[i]));
  }
  Relabel(ctx, base, element, kSensitivity,
          SensitivityLabel(fable2::controls::CurrentSensitivity()));
}
#endif

// Returns whether the name was one of the added items.
bool OnSelect(PPCContext& ctx, uint8_t* base, uint32_t element, uint32_t engine,
              const char* name) {
  current_engine = engine;
  if (!std::strcmp(name, kFrameRate)) {
    const FrameRateItem* next = &kFrameRates[0];
    for (size_t i = 0; i < std::size(kFrameRates); ++i) {
      if (kFrameRates[i].limit == CurrentFrameRate().limit) {
        next = &kFrameRates[(i + 1) % std::size(kFrameRates)];
      }
    }
    current_frame_rate_limit = next->limit;
    fable2::config::ApplyFrameRateLimit(next->limit);
    fable2::config::SaveFrameRateLimit(next->limit);
    REXSYS_INFO("[options] frame rate limit {}", next->limit);
    Relabel(ctx, base, element, kFrameRate, next->label);
    return true;
  }
#ifndef _WIN32
  if (!std::strcmp(name, kReduceFlashing)) {
    fable2::controls::SetReduceFlashing(!fable2::controls::ReduceFlashing());
    Relabel(ctx, base, element, kReduceFlashing, ReduceFlashingLabel());
    return true;
  }
  if (!std::strcmp(name, kSensitivity)) {
    double current = fable2::controls::CurrentSensitivity();
    double next = fable2::controls::kSensitivities[0];
    for (size_t i = 0; i < std::size(fable2::controls::kSensitivities); ++i) {
      if (fable2::controls::kSensitivities[i] > current + 1e-6) {
        next = fable2::controls::kSensitivities[i];
        break;
      }
    }
    fable2::controls::SetSensitivity(next);
    Relabel(ctx, base, element, kSensitivity, SensitivityLabel(next));
    return true;
  }
  if (!std::strcmp(name, kControlsReset)) {
    rex::input::mnk::CancelKeyCapture();
    pending_capture.active = false;
    fable2::controls::ResetToDefaults();
    RelabelAllBinds(ctx, base, element);
    return true;
  }
  if (!std::strncmp(name, kBindPrefix, sizeof(kBindPrefix) - 1)) {
    size_t index = std::strtoul(name + sizeof(kBindPrefix) - 1, nullptr, 10);
    if (index >= std::size(fable2::controls::kActions)) {
      return true;
    }
    if (pending_capture.active) {
      // Another item was selected while waiting: put the old label back.
      current_engine = pending_capture.engine;
      Relabel(ctx, base, pending_capture.element, BindName(pending_capture.action).c_str(),
              BindLabel(fable2::controls::kActions[pending_capture.action]));
      current_engine = engine;
    }
    pending_capture = {true, index, element, engine};
    rex::input::mnk::BeginKeyCapture();
    Relabel(ctx, base, element, name,
            std::string(fable2::controls::kActions[index].label) + ": Press a key");
    return true;
  }
#endif
  return false;
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
      bool handled = OnSelect(ctx, base, REX_LOAD_U32(menu + 20), MenuEngine(base), name);
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

// Called each frame the front end menu polls its input (src/diagnostics/fable2_menu_probe.h).
void fable2_options_menu_poll(PPCContext& ctx, uint8_t* base) {
#ifndef _WIN32
  // Relabelling runs Lua, which comes back here through the Lua hook.
  static bool polling = false;
  if (!pending_capture.active || polling) {
    return;
  }
  struct Guard {
    Guard() { polling = true; }
    ~Guard() { polling = false; }
  } guard;
  // Esc, or a capture that timed out, keeps the old keys.
  std::string key = "Escape";
  if (!rex::input::mnk::TakeCapturedKey(key) && rex::input::mnk::IsKeyCaptureWaiting()) {
    return;
  }
  pending_capture.active = false;
  const fable2::controls::Action& action = fable2::controls::kActions[pending_capture.action];
  if (key != "Escape") {
    fable2::controls::SetKeys(action.cvar, key);
    REXSYS_INFO("[options] {} bound to {}", action.cvar, key);
  }
  PPCRegister saved_r3 = ctx.r3;
  uint64_t saved_lr = ctx.lr;
  ctx.r1.u32 -= kFrameSize;
  current_engine = pending_capture.engine;
  Relabel(ctx, base, pending_capture.element, BindName(pending_capture.action).c_str(),
          BindLabel(action));
  ctx.r1.u32 += kFrameSize;
  ctx.lr = saved_lr;
  ctx.r3 = saved_r3;
#else
  (void)ctx;
  (void)base;
#endif
}

namespace {

// The pause menu's Options page is filled by the menu's Lua (g_Menu:SetPopulationTable
// with the parent's MenuPopulationScript "OptionsMenu"). When a GUI presentation has
// loaded its scripts, its Lua gets the current labels and, once, a wrapper of
// SetPopulationTable that adds the settings to Options and turns Controls into a
// submenu: the controller layout screen, then the key bindings.
std::string LuaQuote(const std::string& text) {
  std::string out = "'";
  for (char c : text) {
    if (c == '\'' || c == '\\') out += '\\';
    out += c;
  }
  return out + "'";
}

std::string PauseOptionsLua() {
  std::string lua = "MacOptionItems = {";
  auto item = [&](const char* name, const std::string& label) {
    lua += "{Name=" + LuaQuote(name) + ",TextTag=" + LuaQuote(label) + "},";
  };
  item(kFrameRate, CurrentFrameRate().label);
#ifndef _WIN32
  item(kReduceFlashing, ReduceFlashingLabel());
  item(kSensitivity, SensitivityLabel(fable2::controls::CurrentSensitivity()));
  lua += "} MacBindItems = {";
  for (size_t i = 0; i < std::size(fable2::controls::kActions); ++i) {
    item(BindName(i).c_str(), BindLabel(fable2::controls::kActions[i]));
  }
  item(kControlsReset, "Reset to Defaults");
#endif
  lua += R"(}
if not MacOptionsWrapped and g_Menu and g_Menu.SetPopulationTable then
  MacOptionsWrapped = true
  local original = g_Menu.SetPopulationTable
  g_Menu.SetPopulationTable = function(self)
    original(self)
    local parent = getElement('parent', g_Menu.element)
    if not parent or getAttribute(parent, 'MenuPopulationScript') ~= 'OptionsMenu' then return end
    local t = g_Menu.PopulationTable
    local icon = 'Art\\GUI\\WheelIcons\\Abilities\\icon_logbook.tga'
    local button = self.EventConst.EVENT_TYPE_MENU_ITEM_NODE
    local layout = nil
    for _, entry in ipairs(t) do
      if entry.Name == 'Controls' then
        layout = {Name='Controls', TextTag='Controller Layout', IconTexture=entry.IconTexture,
                  EventType=entry.EventType, Parent='MacControls'}
        entry.Name = 'MacControls'
        entry.EventType = self.EventConst.EVENT_TYPE_SUBMENU
      end
    end
    for _, o in ipairs(MacOptionItems) do
      table.insert(t, {Name=o.Name, TextTag=o.TextTag, IconTexture=icon, EventType=button})
    end
    if layout then
      table.insert(t, layout)
      for _, o in ipairs(MacBindItems) do
        table.insert(t, {Name=o.Name, TextTag=o.TextTag, IconTexture=icon, EventType=button,
                         Parent='MacControls'})
      end
    end
  end
end)";
  return lua;
}

}  // namespace

// Runs Lua on a GUI element, as the game does: (code string, element).
// The element of the in-game menu whose highlighted item was last read.
uint32_t last_highlight_element = 0;
void fable2_options_menu_poll(PPCContext& ctx, uint8_t* base);

extern "C" void __imp__ProcessAndVcallAndProcess16_823F8908(PPCContext& ctx, uint8_t* base);
extern "C" void ProcessAndVcallAndProcess16_823F8908(PPCContext& ctx, uint8_t* base) {
  uint32_t code_object = REX_LOAD_U32(ctx.r3.u32);
  uint32_t code = code_object ? REX_LOAD_U32(code_object) : 0;
  bool scripts_loaded =
      code && !std::strcmp(reinterpret_cast<const char*>(REX_RAW_ADDR(code)),
                           "GUI:StoreScriptsDirectoryAndLoadAppropriateScripts()");
  static const bool log_lua = std::getenv("FABLE2_LUA_LOG") != nullptr;
  if (code && log_lua) {
    REXSYS_INFO("[lua] lr {:08X} {:08X}: {}", uint32_t(ctx.lr), ctx.r4.u32,
                std::string(reinterpret_cast<const char*>(REX_RAW_ADDR(code))).substr(0, 100));
  }
  uint32_t element = ctx.r4.u32;
  if (code && !std::strcmp(reinterpret_cast<const char*>(REX_RAW_ADDR(code)),
                           "g_Menu:GetHighlightedMenuItemData()")) {
    last_highlight_element = element;
  }
  __imp__ProcessAndVcallAndProcess16_823F8908(ctx, base);
  // In-game menus run Lua every frame; a rebind waiting there finishes here.
  fable2_options_menu_poll(ctx, base);
  if (scripts_loaded) {
    // Once the presentation's scripts are loaded, before its menu is populated.
    PPCRegister r3 = ctx.r3, r4 = ctx.r4;
    uint64_t saved_lr = ctx.lr;
    ctx.r1.u32 -= kFrameSize;
    uint32_t frame = ctx.r1.u32;
    std::string lua = PauseOptionsLua();
    ConstructString(ctx, base, frame + kName, lua.c_str());
    ctx.r3.u64 = frame + kName;
    ctx.r4.u64 = element;
    __imp__ProcessAndVcallAndProcess16_823F8908(ctx, base);
    DestructString(ctx, base, frame + kName);
    ctx.r1.u32 += kFrameSize;
    ctx.lr = saved_lr;
    ctx.r3 = r3;
    ctx.r4 = r4;
  }
}

// The pause Options screen's button handler: (screen, button, pressed). On A (36)
// with no panel open, it reads the highlighted item (sub_8259DB00: type at +0, then
// String name and label at +8 and +12) and opens the panel for its type. The
// settings added there are handled instead, without a panel.
extern "C" void __imp__sub_8259DB00(PPCContext& ctx, uint8_t* base);
extern "C" void __imp__sub_82582E50(PPCContext& ctx, uint8_t* base);
extern "C" void sub_82582E50(PPCContext& ctx, uint8_t* base) {
  constexpr uint32_t kButtonA = 36;
  if (ctx.r4.u32 != kButtonA || ctx.r5.u32 != 1 || REX_LOAD_U8(ctx.r3.u32 + 24)) {
    __imp__sub_82582E50(ctx, base);
    return;
  }
  PPCRegister r3 = ctx.r3, r4 = ctx.r4, r5 = ctx.r5;
  uint64_t saved_lr = ctx.lr;
  ctx.r1.u32 -= kFrameSize;
  uint32_t item = ctx.r1.u32 + kName;
  for (uint32_t i = 0; i < 16; i += 4) {
    REX_STORE_U32(item + i, 0);
  }
  // The two empty strings share the game's empty string, as the screen sets them up.
  constexpr uint32_t kEmptyStringReferences = 0x83496EB8;
  REX_STORE_U32(kEmptyStringReferences, REX_LOAD_U32(kEmptyStringReferences) + 2);
  ctx.r3.u64 = REX_LOAD_U32(REX_LOAD_U32(REX_LOAD_U32(0x834968A4) + 28) + 60);
  ctx.r4.u64 = item;
  __imp__sub_8259DB00(ctx, base);
  uint32_t name_object = REX_LOAD_U32(item + 8);
  uint32_t name_address = name_object ? REX_LOAD_U32(name_object) : 0;
  std::string name = name_address ? reinterpret_cast<const char*>(REX_RAW_ADDR(name_address)) : "";
  DestructString(ctx, base, item + 12);
  DestructString(ctx, base, item + 8);
  bool handled = false;
  if (!name.compare(0, 3, "Mac") && last_highlight_element) {
    if (name == "MacControls") {
      // A submenu: opened by the menu's own Lua, as the main menu's are.
      uint32_t frame = ctx.r1.u32;
      ConstructString(ctx, base, frame + kParent, "g_Menu:SelectMenuItem()");
      ctx.r3.u64 = frame + kParent;
      ctx.r4.u64 = last_highlight_element;
      __imp__ProcessAndVcallAndProcess16_823F8908(ctx, base);
      DestructString(ctx, base, frame + kParent);
      handled = true;
    } else {
      handled = OnSelect(ctx, base, last_highlight_element, GameMenuEngine(base), name.c_str());
    }
  }
  ctx.r1.u32 += kFrameSize;
  ctx.lr = saved_lr;
  ctx.r3 = r3;
  ctx.r4 = r4;
  ctx.r5 = r5;
  if (!handled) {
    __imp__sub_82582E50(ctx, base);
  }
}
