// fable2_menu_probe.h - strong overrides for the main-menu input path.
//
// Funnel the menu input functions through fable2::uir::hook() so the
// render-probe infrastructure (timeline + FABLE2_UIR_IN_DUMP input dumps)
// can observe them:
//
//   - FrontMenu_PollEventQueue (0x82185C90): per-frame UI input-event queue
//     poller; calls the per-press handler (FrontMenu_InputEvent) once per
//     pending button press (Up/Down/A/Back).
//   - FrontMenu_EnsureElement (0x82C217B8): get-or-create UI element node
//     (fires on effective actions: selection change / activation).
//   - FrontMenu_InputEvent (0x82BE3F30): the per-press handler itself.
//
// NOTE: FrontMenu_PressBitDispatch (0x82188F20, the raw press bit-dispatch)
// is overridden in fable2_modmenu.h instead, which layers the mod-menu mirror
// index / activation on top of the stock body.
//
// These same overrides are the future mod-menu hook points; they are cheap
// (one atomic window check per call) and active in all debug builds.

#pragma once

#include "fable2_ui_render_probe.h"

extern "C" void __imp__FrontMenu_InputEvent(PPCContext& ctx, uint8_t* base);
extern "C" void FrontMenu_InputEvent(PPCContext& ctx, uint8_t* base) {
  if (fable2::uir::hook("FrontMenu_InputEvent", ctx, base)) return;
  __imp__FrontMenu_InputEvent(ctx, base);
}

extern "C" void __imp__FrontMenu_PollEventQueue(PPCContext& ctx,
                                                uint8_t* base);
void fable2_options_menu_poll(PPCContext& ctx, uint8_t* base);  // native_gpu/options_menu.cpp
extern "C" void FrontMenu_PollEventQueue(PPCContext& ctx, uint8_t* base) {
  if (fable2::uir::hook("FrontMenu_PollEventQueue", ctx, base)) return;
  __imp__FrontMenu_PollEventQueue(ctx, base);
  fable2_options_menu_poll(ctx, base);
}

extern "C" void __imp__FrontMenu_EnsureElement(PPCContext& ctx,
                                               uint8_t* base);
extern "C" void FrontMenu_EnsureElement(PPCContext& ctx, uint8_t* base) {
  if (fable2::uir::hook("FrontMenu_EnsureElement", ctx, base)) return;
  __imp__FrontMenu_EnsureElement(ctx, base);
}
