// Replaces the controller button icons the game shows in prompts with the keyboard
// and mouse keys they're bound to (macOS).
//
// The icons are entries of data/art/gui/gui_textures.bnk. A, B, X and Y
// (Art\GUI\Controller\icon_button_*.tex) are 64x64 ARGB levels, tiled the way the
// Xenos GPU reads them, after a 4-byte size. The bank is read through the guest's
// file calls, so the SDK's read hook (rex::system::g_xfile_read_hook) replaces those
// bytes as they're read with keycaps drawn here with Core Graphics. Each keycap
// shows the first key bound to its button (src/input/mac_controls.h) when the bank
// is read, so a rebinding shows in the prompts after the game restarts.

#include "mac_prompts.h"

#ifdef __APPLE__

#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <zlib.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/graphics/texture_replacement.h>
#include <rex/system/xfile.h>

#include "mac_controls.h"

namespace fable2::prompts {
namespace {

constexpr uint32_t kSize = 64;
constexpr uint32_t kBytes = kSize * kSize * 4;

struct Icon {
  const char* entry;  // bank entry name
  const char* cvar;   // the button's keybind cvar
  uint64_t pixels_offset = 0;  // in the bank file, 0 if not found
  std::vector<uint8_t> tiled;  // the keycap, as stored
};

std::array<Icon, 4> icons = {{
    {"Art\\GUI\\Controller\\icon_button_a.tex", "keybind_a"},
    {"Art\\GUI\\Controller\\icon_button_b.tex", "keybind_b"},
    {"Art\\GUI\\Controller\\icon_button_x.tex", "keybind_x"},
    {"Art\\GUI\\Controller\\icon_button_y.tex", "keybind_y"},
}};
std::once_flag icons_drawn;

// Byte offset of a 32bpp texel in a tiled 2D Xenos texture.
uint32_t TiledOffset(uint32_t x, uint32_t y, uint32_t pitch) {
  constexpr uint32_t bpb_log2 = 2;
  pitch = (pitch + 31) & ~31u;
  uint32_t macro = ((x >> 5) + (y >> 5) * (pitch >> 5)) << (bpb_log2 + 7);
  uint32_t micro = ((x & 7) + ((y & 0xE) << 2)) << bpb_log2;
  uint32_t offset = macro + ((micro & ~0xFu) << 1) + (micro & 0xF) + ((y & 1) << 4);
  return ((offset & ~0x1FFu) << 3) + ((y & 16) << 7) + ((offset & 0x1C0) << 2) +
         (((((y & 8) >> 2) + (x >> 3)) & 3) << 6) + (offset & 0x3F);
}

uint32_t ReadU32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}

// Finds the icon entries in the bank's table of contents (zlib, big-endian:
// count, then per entry name length, name, data offset, size).
void FindIcons(const std::filesystem::path& bank) {
  std::ifstream in(bank, std::ios::binary);
  uint8_t header[17];
  if (!in.read(reinterpret_cast<char*>(header), sizeof(header))) {
    REXSYS_WARN("[prompts] {} not readable", bank.string());
    return;
  }
  uint32_t base = ReadU32(header);
  uint32_t compressed_size = ReadU32(header + 9);
  uint32_t size = ReadU32(header + 13);
  std::vector<uint8_t> compressed(compressed_size), toc(size);
  in.read(reinterpret_cast<char*>(compressed.data()), compressed_size);
  z_stream stream = {};
  stream.next_in = compressed.data();
  stream.avail_in = compressed_size;
  stream.next_out = toc.data();
  stream.avail_out = size;
  inflateInit(&stream);
  inflate(&stream, Z_FINISH);  // The stream may lack its checksum; the data is all there.
  inflateEnd(&stream);
  if (stream.total_out != size) {
    REXSYS_WARN("[prompts] {} table of contents unreadable", bank.string());
    return;
  }
  size_t offset = 4;
  uint32_t count = ReadU32(toc.data());
  for (uint32_t i = 0; i < count && offset + 4 <= toc.size(); ++i) {
    uint32_t name_length = ReadU32(&toc[offset]);
    if (offset + 4 + name_length + 8 > toc.size()) {
      break;
    }
    std::string name(reinterpret_cast<const char*>(&toc[offset + 4]), name_length ? name_length - 1 : 0);
    offset += 4 + name_length;
    uint32_t data_offset = ReadU32(&toc[offset]);
    uint32_t data_size = ReadU32(&toc[offset + 4]);
    offset += 8;
    for (Icon& icon : icons) {
      // A 64x64 ARGB level after its size.
      if (name == icon.entry && data_size == kBytes + 4) {
        icon.pixels_offset = uint64_t(base) + data_offset + 4;
      }
    }
  }
  for (const Icon& icon : icons) {
    if (!icon.pixels_offset) {
      REXSYS_WARN("[prompts] {} not found in {}", icon.entry, bank.string());
    }
  }
}

std::string FirstKey(const char* cvar) {
  std::string keys = fable2::controls::CurrentKeys(cvar);
  return keys.substr(0, keys.find(','));
}

CGColorRef Color(double r, double g, double b, double a = 1.0) {
  static CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  const CGFloat components[] = {r, g, b, a};
  return CGColorCreate(space, components);
}

void FillPath(CGContextRef context, CGPathRef path, CGColorRef color) {
  CGContextAddPath(context, path);
  CGContextSetFillColorWithColor(context, color);
  CGContextFillPath(context);
  CGColorRelease(color);
}

void StrokePath(CGContextRef context, CGPathRef path, CGColorRef color, double width) {
  CGContextAddPath(context, path);
  CGContextSetStrokeColorWithColor(context, color);
  CGContextSetLineWidth(context, width);
  CGContextStrokePath(context);
  CGColorRelease(color);
}

// A mouse, with the pressed button lit: 0 left, 1 right, 2 wheel.
void DrawMouse(CGContextRef context, int button) {
  CGRect body = CGRectMake(19, 9, 26, 40);
  CGPathRef outline = CGPathCreateWithRoundedRect(body, 13, 13, nullptr);
  FillPath(context, outline, Color(0.16, 0.13, 0.11));
  CGContextSaveGState(context);
  CGContextAddPath(context, outline);
  CGContextClip(context);
  // Buttons are the top 40% of the body (y grows up).
  CGRect left = CGRectMake(body.origin.x, body.origin.y + body.size.height * 0.6,
                           body.size.width / 2, body.size.height * 0.4);
  CGRect right = left;
  right.origin.x += body.size.width / 2;
  if (button == 0 || button == 1) {
    CGContextSetFillColorWithColor(context, Color(0.93, 0.76, 0.38));
    CGContextFillRect(context, button == 0 ? left : right);
  }
  CGContextRestoreGState(context);
  CGMutablePathRef lines = CGPathCreateMutable();
  CGPathMoveToPoint(lines, nullptr, body.origin.x + body.size.width / 2,
                    body.origin.y + body.size.height);
  CGPathAddLineToPoint(lines, nullptr, body.origin.x + body.size.width / 2,
                       body.origin.y + body.size.height * 0.6);
  CGPathMoveToPoint(lines, nullptr, body.origin.x, body.origin.y + body.size.height * 0.6);
  CGPathAddLineToPoint(lines, nullptr, body.origin.x + body.size.width,
                       body.origin.y + body.size.height * 0.6);
  StrokePath(context, lines, Color(0.79, 0.64, 0.35), 1.5);
  CGPathRelease(lines);
  CGRect wheel = CGRectMake(body.origin.x + body.size.width / 2 - 3,
                            body.origin.y + body.size.height * 0.68, 6, 10);
  CGPathRef wheel_path = CGPathCreateWithRoundedRect(wheel, 3, 3, nullptr);
  FillPath(context, wheel_path,
           button == 2 ? Color(0.93, 0.76, 0.38) : Color(0.45, 0.38, 0.30));
  CGPathRelease(wheel_path);
  StrokePath(context, outline, Color(0.79, 0.64, 0.35), 2.0);
  CGPathRelease(outline);
}

void DrawLabel(CGContextRef context, const std::string& label) {
  CFStringRef text = CFStringCreateWithCString(nullptr, label.c_str(), kCFStringEncodingUTF8);
  // As large as fits the cap.
  double font_size = label.size() <= 1 ? 32 : label.size() == 2 ? 24 : label.size() == 3 ? 18 : 14;
  CTLineRef line = nullptr;
  CGRect bounds = {};
  for (; font_size >= 9; font_size -= 1) {
    CTFontRef font = CTFontCreateWithName(CFSTR("Palatino-Bold"), font_size, nullptr);
    CGColorRef color = Color(0.96, 0.91, 0.78);
    const void* keys[] = {kCTFontAttributeName, kCTForegroundColorAttributeName};
    const void* values[] = {font, color};
    CFDictionaryRef attributes = CFDictionaryCreate(nullptr, keys, values, 2,
                                                    &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef string = CFAttributedStringCreate(nullptr, text, attributes);
    if (line) {
      CFRelease(line);
    }
    line = CTLineCreateWithAttributedString(string);
    CFRelease(string);
    CFRelease(attributes);
    CGColorRelease(color);
    CFRelease(font);
    bounds = CTLineGetImageBounds(line, context);
    if (bounds.size.width <= 46) {
      break;
    }
  }
  CGContextSetTextPosition(context, 32 - bounds.size.width / 2 - bounds.origin.x,
                           32 - bounds.size.height / 2 - bounds.origin.y);
  CTLineDraw(line, context);
  CFRelease(line);
  CFRelease(text);
}

// A keycap in the game's colours: dark wood, gold rim, parchment lettering. `size`
// pixels square (drawn on a 64 unit grid); `round` for a cap that fits a gem's ring.
std::vector<uint8_t> DrawKeycap(const std::string& key, uint32_t size = kSize,
                                bool round = false) {
  std::vector<uint8_t> premultiplied(size_t(size) * size * 4, 0);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  // A, R, G, B bytes, like the texture.
  CGContextRef context = CGBitmapContextCreate(
      premultiplied.data(), size, size, 8, size * 4, space,
      uint32_t(kCGImageAlphaPremultipliedFirst) | uint32_t(kCGBitmapByteOrder32Big));
  CGColorSpaceRelease(space);
  CGContextSetShouldAntialias(context, true);
  CGContextScaleCTM(context, double(size) / kSize, double(size) / kSize);
  double corner = round ? 27 : 10;
  if (key == "LMB" || key == "RMB" || key == "MMB") {
    if (round) {
      CGPathRef disc = CGPathCreateWithEllipseInRect(CGRectMake(5, 5, 54, 54), nullptr);
      FillPath(context, disc, Color(0.13, 0.10, 0.08));
      StrokePath(context, disc, Color(0.79, 0.64, 0.35), 2.5);
      CGPathRelease(disc);
      CGContextTranslateCTM(context, 32, 32);
      CGContextScaleCTM(context, 0.8, 0.8);
      CGContextTranslateCTM(context, -32, -32);
    }
    DrawMouse(context, key == "LMB" ? 0 : key == "RMB" ? 1 : 2);
  } else {
    CGRect cap = CGRectMake(5, 5, 54, 54);
    CGPathRef shadow = CGPathCreateWithRoundedRect(CGRectOffset(cap, 0, -2), corner, corner, nullptr);
    FillPath(context, shadow, Color(0, 0, 0, 0.55));
    CGPathRelease(shadow);
    CGPathRef outline = CGPathCreateWithRoundedRect(cap, corner, corner, nullptr);
    // Top lit, bottom dark.
    CGContextSaveGState(context);
    CGContextAddPath(context, outline);
    CGContextClip(context);
    CGColorRef top = Color(0.36, 0.29, 0.22), bottom = Color(0.13, 0.10, 0.08);
    const void* colors[] = {bottom, top};
    CFArrayRef array = CFArrayCreate(nullptr, colors, 2, &kCFTypeArrayCallBacks);
    CGColorSpaceRef gradient_space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(gradient_space, array, nullptr);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 5), CGPointMake(0, 59), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(gradient_space);
    CFRelease(array);
    CGColorRelease(top);
    CGColorRelease(bottom);
    CGContextRestoreGState(context);
    StrokePath(context, outline, Color(0.79, 0.64, 0.35), 2.5);
    CGPathRelease(outline);
    DrawLabel(context, fable2::controls::KeyDisplayName(key) == "Esc" ? "Esc"
                       : key.size() > 5 ? key.substr(0, 5)
                                        : key);
  }
  CGContextRelease(context);
  // Straight alpha; the bitmap's rows run from the top.
  for (size_t i = 0; i < premultiplied.size(); i += 4) {
    uint8_t alpha = premultiplied[i];
    for (int c = 1; c < 4; ++c) {
      premultiplied[i + c] = alpha ? uint8_t(std::min(255, premultiplied[i + c] * 255 / alpha)) : 0;
    }
  }
  return premultiplied;
}

// As the bank stores 32bpp icons: tiled.
std::vector<uint8_t> Tile(const std::vector<uint8_t>& argb) {
  std::vector<uint8_t> tiled(kBytes, 0);
  for (uint32_t y = 0; y < kSize; ++y) {
    for (uint32_t x = 0; x < kSize; ++x) {
      std::memcpy(&tiled[TiledOffset(x, y, kSize)], &argb[(y * kSize + x) * 4], 4);
    }
  }
  return tiled;
}

// Byte offset of a 128-bit block in a tiled 2D Xenos texture (pitch in blocks).
uint32_t TiledBlockOffset(uint32_t x, uint32_t y, uint32_t pitch) {
  constexpr uint32_t bpb_log2 = 4;
  pitch = (pitch + 31) & ~31u;
  uint32_t macro = ((x >> 5) + (y >> 5) * (pitch >> 5)) << (bpb_log2 + 7);
  uint32_t micro = ((x & 7) + ((y & 0xE) << 2)) << bpb_log2;
  uint32_t offset = macro + ((micro & ~0xFu) << 1) + (micro & 0xF) + ((y & 1) << 4);
  return ((offset & ~0x1FFu) << 3) + ((y & 16) << 7) + ((offset & 0x1C0) << 2) +
         (((((y & 8) >> 2) + (x >> 3)) & 3) << 6) + (offset & 0x3F);
}

// DXT5, tiled, 8-in-16 endian, to RGBA rows from the top.
std::vector<uint8_t> DecodeDxt5(const rex::graphics::GuestTextureData& texture) {
  uint32_t blocks_x = (texture.width + 3) / 4, blocks_y = (texture.height + 3) / 4;
  std::vector<uint8_t> rgba(size_t(texture.width) * texture.height * 4, 0);
  for (uint32_t by = 0; by < blocks_y; ++by) {
    for (uint32_t bx = 0; bx < blocks_x; ++bx) {
      size_t offset = texture.tiled ? TiledBlockOffset(bx, by, blocks_x)
                                    : (size_t(by) * blocks_x + bx) * 16;
      if (offset + 16 > texture.length) {
        continue;
      }
      uint8_t block[16];
      std::memcpy(block, texture.data + offset, 16);
      if (texture.endian == 1) {
        for (int i = 0; i < 16; i += 2) {
          std::swap(block[i], block[i + 1]);
        }
      }
      uint8_t alpha[8] = {block[0], block[1]};
      if (alpha[0] > alpha[1]) {
        for (int i = 0; i < 6; ++i) alpha[2 + i] = uint8_t(((6 - i) * alpha[0] + (i + 1) * alpha[1]) / 7);
      } else {
        for (int i = 0; i < 4; ++i) alpha[2 + i] = uint8_t(((4 - i) * alpha[0] + (i + 1) * alpha[1]) / 5);
        alpha[6] = 0;
        alpha[7] = 255;
      }
      uint64_t alpha_bits = 0;
      for (int i = 0; i < 6; ++i) alpha_bits |= uint64_t(block[2 + i]) << (8 * i);
      uint16_t c[2] = {uint16_t(block[8] | (block[9] << 8)), uint16_t(block[10] | (block[11] << 8))};
      int palette[4][3];
      for (int i = 0; i < 2; ++i) {
        palette[i][0] = ((c[i] >> 11) & 31) * 255 / 31;
        palette[i][1] = ((c[i] >> 5) & 63) * 255 / 63;
        palette[i][2] = (c[i] & 31) * 255 / 31;
      }
      for (int k = 0; k < 3; ++k) {
        palette[2][k] = (2 * palette[0][k] + palette[1][k]) / 3;
        palette[3][k] = (palette[0][k] + 2 * palette[1][k]) / 3;
      }
      uint32_t color_bits = block[12] | (block[13] << 8) | (block[14] << 16) | (uint32_t(block[15]) << 24);
      for (int i = 0; i < 16; ++i) {
        uint32_t x = bx * 4 + i % 4, y = by * 4 + i / 4;
        if (x >= texture.width || y >= texture.height) continue;
        uint8_t* out = &rgba[(size_t(y) * texture.width + x) * 4];
        const int* color = palette[(color_bits >> (2 * i)) & 3];
        out[0] = uint8_t(color[0]);
        out[1] = uint8_t(color[1]);
        out[2] = uint8_t(color[2]);
        out[3] = alpha[(alpha_bits >> (3 * i)) & 7];
      }
    }
  }
  return rgba;
}

// Art\GUI\Persistant\abyx.tex as decoded by the game: the A, B, Y and X gems in
// 64x64 cells (a lit row, then a dimmer one) above the menu's rings.
constexpr uint64_t kAbyxSheet = 0xBD011766CAD4A839ull;

// The front end's menu atlas (512x512 DXT5): the A gem beside the selected item and
// the B gem in its ring, by centre and radius.
constexpr uint64_t kMenuAtlas = 0x82D3519765AD2444ull;
struct Gem {
  const char* cvar;
  int x, y, radius;
};
constexpr Gem kMenuAtlasGems[] = {{"keybind_a", 35, 397, 22}, {"keybind_b", 67, 217, 21}};

// Clears a gem's disc and draws a round keycap of the key bound to it there.
void PaintGem(std::vector<uint8_t>& rgba, uint32_t width, const Gem& gem) {
  int diameter = gem.radius * 2 + 4;
  std::vector<uint8_t> cap = DrawKeycap(FirstKey(gem.cvar), uint32_t(diameter), true);
  int left = gem.x - diameter / 2, top = gem.y - diameter / 2;
  for (int y = -gem.radius - 3; y <= gem.radius + 3; ++y) {
    for (int x = -gem.radius - 3; x <= gem.radius + 3; ++x) {
      if (x * x + y * y <= (gem.radius + 2) * (gem.radius + 2)) {
        std::memset(&rgba[(size_t(gem.y + y) * width + gem.x + x) * 4], 0, 4);
      }
    }
  }
  for (int y = 0; y < diameter; ++y) {
    for (int x = 0; x < diameter; ++x) {
      const uint8_t* source = &cap[(size_t(y) * diameter + x) * 4];  // A, R, G, B
      if (!source[0]) continue;
      uint8_t* dest = &rgba[(size_t(top + y) * width + left + x) * 4];
      float alpha = source[0] / 255.0f, keep = 1.0f - alpha;
      for (int c = 0; c < 3; ++c) {
        dest[c] = uint8_t(source[1 + c] * alpha + dest[c] * keep);
      }
      dest[3] = uint8_t(std::min(255.0f, source[0] + dest[3] * keep));
    }
  }
}

bool ReplaceTexture(const rex::graphics::GuestTextureData& texture,
                    rex::graphics::TextureReplacement& out) {
  if (texture.hash == kMenuAtlas && texture.width == 512 && texture.height == 512 &&
      texture.format == 20) {
    out.width = texture.width;
    out.height = texture.height;
    out.rgba = DecodeDxt5(texture);
    for (const Gem& gem : kMenuAtlasGems) {
      PaintGem(out.rgba, out.width, gem);
    }
    return true;
  }
  if (texture.hash != kAbyxSheet || texture.width != 256 || texture.height != 256 ||
      texture.format != 20 /* k_DXT4_5 */) {
    return false;
  }
  out.width = texture.width;
  out.height = texture.height;
  out.rgba = DecodeDxt5(texture);
  static const char* const kCells[] = {"keybind_a", "keybind_b", "keybind_y", "keybind_x"};
  for (uint32_t cell = 0; cell < 4; ++cell) {
    std::vector<uint8_t> cap = DrawKeycap(FirstKey(kCells[cell]));
    for (uint32_t row = 0; row < 2; ++row) {
      float shade = row ? 0.8f : 1.0f;
      for (uint32_t y = 0; y < kSize; ++y) {
        for (uint32_t x = 0; x < kSize; ++x) {
          const uint8_t* source = &cap[(y * kSize + x) * 4];  // A, R, G, B
          uint8_t* dest = &out.rgba[((size_t(row * kSize + y) * 256) + cell * kSize + x) * 4];
          dest[0] = uint8_t(source[1] * shade);
          dest[1] = uint8_t(source[2] * shade);
          dest[2] = uint8_t(source[3] * shade);
          dest[3] = source[0];
        }
      }
    }
  }
  return true;
}

void OnRead(const std::string& path, uint8_t* data, size_t length, uint64_t file_offset) {
  if (path.size() < 16) {
    return;
  }
  std::string lower = path.substr(path.size() - 16);
  for (char& c : lower) {
    c = char(std::tolower(static_cast<unsigned char>(c)));
  }
  if (lower != "gui_textures.bnk") {
    return;
  }
  std::call_once(icons_drawn, [] {
    for (Icon& icon : icons) {
      if (icon.pixels_offset) {
        icon.tiled = Tile(DrawKeycap(FirstKey(icon.cvar)));
      }
    }
  });
  uint64_t read_end = file_offset + length;
  for (const Icon& icon : icons) {
    if (icon.tiled.empty()) {
      continue;
    }
    uint64_t start = std::max(file_offset, icon.pixels_offset);
    uint64_t end = std::min(read_end, icon.pixels_offset + kBytes);
    if (start < end) {
      std::memcpy(data + (start - file_offset), icon.tiled.data() + (start - icon.pixels_offset),
                  size_t(end - start));
    }
  }
}

}  // namespace

void Install(const std::filesystem::path& game_data_root) {
  FindIcons(game_data_root / "data" / "art" / "gui" / "gui_textures.bnk");
  rex::system::g_xfile_read_hook = OnRead;
  rex::graphics::g_texture_replacement_hook = ReplaceTexture;
}

}  // namespace fable2::prompts

#else

namespace fable2::prompts {
void Install(const std::filesystem::path&) {}
}  // namespace fable2::prompts

#endif
