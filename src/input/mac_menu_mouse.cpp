// See mac_menu_mouse.h.

#include "mac_menu_mouse.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <mutex>
#include <vector>

#include <rex/input/input.h>
#include <rex/logging.h>
#include <rex/ui/window.h>

#ifdef __APPLE__
#include <CoreGraphics/CoreGraphics.h>
#include <rex/input/mnk/mnk_input_driver.h>
#include <rex/ui/windowed_app_context.h>
#endif

namespace fable2::menumouse {
namespace {

using rex::X_RESULT;
using rex::X_STATUS;

using Clock = std::chrono::steady_clock;

std::atomic<int64_t> last_menu_activity_us{0};

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch())
      .count();
}

bool MenuOpen() {
  // Menus run their Lua every frame; gameplay doesn't.
  return NowUs() - last_menu_activity_us.load(std::memory_order_relaxed) < 750000;
}

#ifdef __APPLE__

using rex::input::X_INPUT_GAMEPAD_BUTTON;

// The menus' layout on the 1280x720 screen the game draws: rows 58.6 apart, the
// highlighted one at y 192, the Back bar at the bottom left.
constexpr float kRowLeft = 215, kRowRight = 625;
constexpr float kHighlightY = 192, kRowSpacing = 58.6f;
constexpr float kBackLeft = 215, kBackRight = 415, kBackTop = 592, kBackBottom = 640;

// A pointer in the game's colours: gold, dark outline. 32x32 RGBA, tip at 2,2.
std::vector<uint8_t> DrawCursor(uint32_t size) {
  std::vector<uint8_t> pixels(size_t(size) * size * 4, 0);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      pixels.data(), size, size, 8, size * 4, space,
      uint32_t(kCGImageAlphaPremultipliedLast) | uint32_t(kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(space);
  CGContextSetShouldAntialias(context, true);
  // Drawn on a 32 unit grid, y down.
  CGContextTranslateCTM(context, 0, size);
  CGContextScaleCTM(context, size / 32.0, -(size / 32.0));
  CGMutablePathRef arrow = CGPathCreateMutable();
  CGPathMoveToPoint(arrow, nullptr, 2, 2);
  CGPathAddLineToPoint(arrow, nullptr, 2, 25);
  CGPathAddLineToPoint(arrow, nullptr, 8, 19.5);
  CGPathAddLineToPoint(arrow, nullptr, 12.5, 29);
  CGPathAddLineToPoint(arrow, nullptr, 16.5, 27);
  CGPathAddLineToPoint(arrow, nullptr, 12, 18);
  CGPathAddLineToPoint(arrow, nullptr, 20, 18);
  CGPathCloseSubpath(arrow);
  CGContextAddPath(context, arrow);
  CGContextSetRGBStrokeColor(context, 0.12, 0.08, 0.05, 1.0);
  CGContextSetLineWidth(context, 3.0);
  CGContextSetLineJoin(context, kCGLineJoinRound);
  CGContextStrokePath(context);
  CGContextSaveGState(context);
  CGContextAddPath(context, arrow);
  CGContextClip(context);
  const CGFloat colors[] = {0.98, 0.88, 0.58, 1.0, 0.72, 0.52, 0.22, 1.0};
  CGGradientRef gradient = CGGradientCreateWithColorComponents(
      CGBitmapContextGetColorSpace(context), colors, nullptr, 2);
  CGContextDrawLinearGradient(context, gradient, CGPointMake(2, 2), CGPointMake(14, 29), 0);
  CGGradientRelease(gradient);
  CGContextRestoreGState(context);
  CGPathRelease(arrow);
  CGContextRelease(context);
  // Straight alpha.
  for (size_t i = 0; i < pixels.size(); i += 4) {
    uint8_t alpha = pixels[i + 3];
    for (int c = 0; c < 3; ++c) {
      pixels[i + c] = alpha ? uint8_t(std::min(255, pixels[i + c] * 255 / alpha)) : 0;
    }
  }
  return pixels;
}

class Driver final : public rex::input::InputDriver {
 public:
  explicit Driver(rex::ui::Window* window) : InputDriver(window, 0) {}

  X_STATUS Setup() override { return X_STATUS_SUCCESS; }

  void EnumerateDevices(std::vector<rex::input::DeviceInfo>& out) override {
    rex::input::DeviceInfo info;
    info.id = kDevice;
    info.name = "Menu pointer";
    info.synthetic = true;
    out.push_back(info);
  }

  X_RESULT GetDeviceState(rex::input::DeviceId id, rex::input::X_INPUT_STATE* out) override {
    if (id != kDevice) return X_ERROR_DEVICE_NOT_CONNECTED;
    bool open = MenuOpen();
    if (open != menu_open_) {
      menu_open_ = open;
      REXSYS_INFO("[menu-mouse] menu {}", open ? "open: pointer" : "closed: mouse look");
      rex::input::mnk::SetMouseLookActive(!open);
      if (open) {
        SetCursor();
      }
      presses_.clear();
      rex::input::mnk::PointerEvent discard;
      while (rex::input::mnk::TakePointerEvent(discard)) {
      }
    }
    if (open) {
      rex::input::mnk::PointerEvent event;
      while (rex::input::mnk::TakePointerEvent(event)) {
        OnPointer(event);
      }
    }
    uint16_t buttons = 0;
    int64_t now = NowUs();
    while (!presses_.empty() && now >= presses_.front().end_us) {
      presses_.pop_front();
      if (!presses_.empty()) {
        // Each press starts after a gap, so the menu sees separate presses.
        presses_.front().start_us = std::max(presses_.front().start_us, now + kGapUs);
        presses_.front().end_us = presses_.front().start_us + kHoldUs;
      }
    }
    if (!presses_.empty() && now >= presses_.front().start_us) {
      buttons = presses_.front().button;
    }
    if (buttons != last_buttons_) {
      ++packet_;
      last_buttons_ = buttons;
    }
    *out = {};
    out->packet_number = packet_;
    out->gamepad.buttons = buttons;
    return X_ERROR_SUCCESS;
  }

  X_RESULT GetDeviceCapabilities(rex::input::DeviceId id, uint32_t,
                                 rex::input::X_INPUT_CAPABILITIES* caps) override {
    if (id != kDevice) return X_ERROR_DEVICE_NOT_CONNECTED;
    *caps = {};
    caps->type = 0x01;
    caps->sub_type = 0x01;
    return X_ERROR_SUCCESS;
  }
  X_RESULT SetDeviceVibration(rex::input::DeviceId id, rex::input::X_INPUT_VIBRATION*) override {
    return id == kDevice ? X_ERROR_SUCCESS : X_ERROR_DEVICE_NOT_CONNECTED;
  }
  X_RESULT GetDeviceKeystroke(rex::input::DeviceId id, uint32_t,
                              rex::input::X_INPUT_KEYSTROKE*) override {
    return id == kDevice ? X_ERROR_EMPTY : X_ERROR_DEVICE_NOT_CONNECTED;
  }

 private:
  static constexpr rex::input::DeviceId kDevice{1ull << 59};
  static constexpr int64_t kHoldUs = 70000, kGapUs = 110000;

  struct Press {
    uint16_t button;
    int64_t start_us;
    int64_t end_us;
  };

  void Queue(uint16_t button) {
    int64_t start = presses_.empty() ? NowUs() : INT64_MAX / 2;
    presses_.push_back({button, start, start + kHoldUs});
  }

  void OnPointer(const rex::input::mnk::PointerEvent& event) {
    using Type = rex::input::mnk::PointerEvent::Type;
    if (!presses_.empty()) {
      return;  // Still acting on the last one.
    }
    if (event.type == Type::kWheel) {
      Queue(event.wheel > 0 ? X_INPUT_GAMEPAD_BUTTON::X_INPUT_GAMEPAD_DPAD_UP
                            : X_INPUT_GAMEPAD_BUTTON::X_INPUT_GAMEPAD_DPAD_DOWN);
      return;
    }
    if (event.type == Type::kRight) {
      Queue(X_INPUT_GAMEPAD_BUTTON::X_INPUT_GAMEPAD_B);
      return;
    }
    if (event.type != Type::kLeft) {
      return;
    }
    // To the game's 1280x720, letterboxed in the window.
    rex::ui::Window* window = rex::input::mnk::GetPointerWindow();
    if (!window) return;
    float width = float(std::max<uint32_t>(1, window->GetActualPhysicalWidth()));
    float height = float(std::max<uint32_t>(1, window->GetActualPhysicalHeight()));
    float scale = std::min(width / 1280.0f, height / 720.0f);
    float x = (event.x * width - (width - 1280.0f * scale) * 0.5f) / scale;
    float y = (event.y * height - (height - 720.0f * scale) * 0.5f) / scale;
    if (x >= kBackLeft && x <= kBackRight && y >= kBackTop && y <= kBackBottom) {
      Queue(X_INPUT_GAMEPAD_BUTTON::X_INPUT_GAMEPAD_B);
      return;
    }
    if (x < kRowLeft || x > kRowRight) {
      return;
    }
    int row = int(std::lround((y - kHighlightY) / kRowSpacing));
    if (row < -1 || row > 6 || std::fabs(y - (kHighlightY + row * kRowSpacing)) > 24) {
      return;
    }
    for (int i = 0; i < std::abs(row); ++i) {
      Queue(row > 0 ? X_INPUT_GAMEPAD_BUTTON::X_INPUT_GAMEPAD_DPAD_DOWN
                    : X_INPUT_GAMEPAD_BUTTON::X_INPUT_GAMEPAD_DPAD_UP);
    }
    Queue(X_INPUT_GAMEPAD_BUTTON::X_INPUT_GAMEPAD_A);
  }

  void SetCursor() {
    rex::ui::Window* window = rex::input::mnk::GetPointerWindow();
    if (!window || cursor_set_) return;
    cursor_set_ = true;
    window->app_context().CallInUIThreadDeferred([window] {
      static const std::vector<uint8_t> pixels = DrawCursor(32);
      window->SetCursorImage(pixels.data(), 32, 32, 2, 2);
    });
  }

  bool menu_open_ = false;
  bool cursor_set_ = false;
  std::deque<Press> presses_;
  uint16_t last_buttons_ = 0;
  uint32_t packet_ = 0;
};

#endif

}  // namespace

void NoteMenuActivity() { last_menu_activity_us.store(NowUs(), std::memory_order_relaxed); }
void NoteMenuClosed() { last_menu_activity_us.store(0, std::memory_order_relaxed); }

std::unique_ptr<rex::input::InputDriver> CreateDriver(rex::ui::Window* window) {
#ifdef __APPLE__
  return std::make_unique<Driver>(window);
#else
  (void)window;
  return nullptr;
#endif
}

}  // namespace fable2::menumouse
