// WaylandBackend.cpp - wlr-randr based backend
#include "DisplayBackend.hpp"
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <regex>
#include <sstream>
#include <unordered_map>

class WaylandBackend : public DisplayBackend {
  std::unordered_map<std::string,std::string> originals_;
public:
  WaylandBackend() { std::fprintf(stderr, "[WaylandBackend] init\n"); }
  ~WaylandBackend() override { std::fprintf(stderr, "[WaylandBackend] destroy\n"); }

  std::vector<OutputInfo> listOutputs() override {
    std::fprintf(stderr, "[WaylandBackend] listOutputs\n");
    std::vector<OutputInfo> outs;
    FILE* fp = popen("wlr-randr", "r");
    if (!fp) return outs;
    char buf[256];
    OutputInfo cur;
    while (fgets(buf, sizeof(buf), fp)) {
      std::string line(buf);
      if (!line.empty() && line.back()=='\n') line.pop_back();
      if (line.empty()) continue;
      if (line[0] != ' ' && line[0] != '\t') {
        if (!cur.name.empty()) { outs.push_back(cur); cur = OutputInfo(); }
        std::istringstream iss(line);
        iss >> cur.name;
      } else {
        line.erase(0, line.find_first_not_of(" \t"));

        // Parse "Position: X,Y"
        if (line.substr(0, 9) == "Position:") {
          int px = 0, py = 0;
          sscanf(line.c_str(), "Position: %d,%d", &px, &py);
          cur.x = px; cur.y = py;
          continue;
        }
        if (line.substr(0, 6) == "Scale:") {
          double sc = 1.0;
          if (sscanf(line.c_str(), "Scale: %lf", &sc) == 1 && sc > 0.0)
            cur.scale = sc;
          continue;
        }

        bool current = false;
        if (!line.empty() && line[0]=='*') { current=true; line.erase(0,1); }

        // Support multiple wlr-randr output formats
        static const std::regex modePattern(
          R"((\d+)x(\d+)(?:\s*px)?\s*(?:@|,)?\s*(\d+(?:\.\d+)?)\s*Hz?)",
          std::regex::icase);
        std::smatch m;
        if (std::regex_search(line, m, modePattern)) {
          unsigned w = (unsigned)std::strtoul(m[1].str().c_str(), nullptr, 10);
          unsigned h = (unsigned)std::strtoul(m[2].str().c_str(), nullptr, 10);
          double hz = std::strtod(m[3].str().c_str(), nullptr);

          if (!current && line.find("current") != std::string::npos) current = true;

          ModeInfo mi;
          mi.width = w;
          mi.height = h;
          mi.refresh_mHz = (uint32_t)(hz * 1000.0 + 0.5);
          std::ostringstream id; id << w << "x" << h << "@" << mi.refresh_mHz; mi.id = id.str();
          mi.current = current;
          if (current) cur.currentModeId = mi.id;
          bool seen = false;
          for (const auto& existing : cur.modes) {
            if (existing.id == mi.id) { seen = true; break; }
          }
          if (!seen) {
            cur.modes.push_back(mi);
          } else if (current) {
            for (auto& existing : cur.modes) {
              if (existing.id == mi.id) { existing.current = true; break; }
            }
          }
        }
      }
    }
    if (!cur.name.empty()) outs.push_back(cur);
    pclose(fp);
    originals_.clear();
    for (const auto& o : outs) originals_[o.name]=o.currentModeId;
    return outs;
  }

  bool setMode(const std::string& name, const std::string& modeId) override {
    std::fprintf(stderr, "[WaylandBackend] setMode %s -> %s\n", name.c_str(), modeId.c_str());
    unsigned w=0,h=0; unsigned mhz=0;
    if (sscanf(modeId.c_str(), "%ux%u@%u", &w,&h,&mhz)!=3) return false;
    std::ostringstream cmd; cmd<<"wlr-randr --output "<<name<<" --mode "<<w<<"x"<<h<<"@"<<(mhz/1000.0);
    int rc = std::system(cmd.str().c_str());
    return rc==0;
  }

  bool revert(const std::string& name) override {
    std::fprintf(stderr, "[WaylandBackend] revert %s\n", name.c_str());
    auto it = originals_.find(name);
    if (it==originals_.end()) return false;
    return setMode(name, it->second);
  }

  bool setPosition(const std::string& name, int x, int y) override {
    std::fprintf(stderr, "[WaylandBackend] setPosition %s -> %d,%d\n", name.c_str(), x, y);
    std::ostringstream cmd;
    cmd << "wlr-randr --output " << name << " --pos " << x << "," << y;
    return std::system(cmd.str().c_str()) == 0;
  }

  bool setScale(const std::string& name, double scale) override {
    if (scale <= 0.0) return false;
    std::fprintf(stderr, "[WaylandBackend] setScale %s -> %.3f\n", name.c_str(), scale);
    std::ostringstream cmd;
    cmd << "wlr-randr --output " << name << " --scale " << scale;
    return std::system(cmd.str().c_str()) == 0;
  }

  bool applyPositions(const std::vector<std::pair<std::string, std::pair<int,int>>>& placements) override {
    if (placements.empty()) return true;
    std::ostringstream cmd;
    cmd << "wlr-randr";
    for (const auto& p : placements)
      cmd << " --output " << p.first << " --pos " << p.second.first << "," << p.second.second;
    std::fprintf(stderr, "[WaylandBackend] applyPositions: %s\n", cmd.str().c_str());
    return std::system(cmd.str().c_str()) == 0;
  }
};

std::unique_ptr<DisplayBackend> MakeWaylandBackend() {
  std::fprintf(stderr, "[Factory] MakeWaylandBackend\n");
  return std::unique_ptr<DisplayBackend>(new WaylandBackend());
}
