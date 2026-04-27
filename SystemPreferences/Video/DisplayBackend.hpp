// DisplayBackend.hpp
#pragma once
#include <string>
#include <vector>
#include <stdint.h>

struct ModeInfo {
  uint32_t width{};
  uint32_t height{};
  uint32_t refresh_mHz{};   // millihertz, e.g. 60000 = 60.0 Hz
  std::string id;           // backend-specific (RRMode as string or wl mode key)
  bool current{false};
};

struct OutputInfo {
  std::string name;
  std::vector<ModeInfo> modes;
  std::string currentModeId;  // id of current mode
  int x{0}, y{0};             // position on the virtual screen
  double scale{1.0};          // output scale factor
};

class DisplayBackend {
public:
  virtual ~DisplayBackend() = default;

  // Enumerate outputs + modes
  virtual std::vector<OutputInfo> listOutputs() = 0;

  // Apply a mode to an output; return true if compositor accepted it
  virtual bool setMode(const std::string& outputName, const std::string& modeId) = 0;

  // Optional: revert to remembered original mode for this output
  virtual bool revert(const std::string& outputName) = 0;

  // Move an output to a new position on the virtual screen
  virtual bool setPosition(const std::string& outputName, int x, int y) { return false; }

  // Set output scale factor (1.0 = native scaling)
  virtual bool setScale(const std::string& outputName, double scale) { return false; }

  // Apply all positions atomically (handles screen resize, ordering, etc.)
  // placements: list of (outputName, (x, y))
  virtual bool applyPositions(const std::vector<std::pair<std::string, std::pair<int,int>>>& placements) {
    bool ok = true;
    for (const auto& p : placements)
      if (!setPosition(p.first, p.second.first, p.second.second)) ok = false;
    return ok;
  }
};
