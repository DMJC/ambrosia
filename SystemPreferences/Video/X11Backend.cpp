// X11Backend.cpp
extern "C" {
  #include <X11/Xlib.h>
  #include <X11/extensions/Xrandr.h>
}
#include "DisplayBackend.hpp"
#include <unordered_map>
#include <memory>
#include <sstream>
#include <cstdio>
#include <cstdlib>

class X11Backend : public DisplayBackend {
  Display* dpy_{nullptr};
  Window root_{};
  int screen_{};
  struct Orig { RRCrtc crtc{}; RRMode mode{}; int x{}; int y{}; Rotation rot{}; };
  std::unordered_map<std::string, Orig> originals_;
public:
  X11Backend() {
    std::fprintf(stderr, "[X11Backend] init\n");
    dpy_ = XOpenDisplay(nullptr);
    if (dpy_) { screen_ = DefaultScreen(dpy_); root_ = RootWindow(dpy_, screen_); }
  }
  ~X11Backend() override {
    std::fprintf(stderr, "[X11Backend] destroy\n");
    if (dpy_) XCloseDisplay(dpy_);
  }

  std::vector<OutputInfo> listOutputs() override {
    std::fprintf(stderr, "[X11Backend] listOutputs\n");
    std::vector<OutputInfo> out;
    if (!dpy_) return out;
    XRRScreenResources* res = XRRGetScreenResourcesCurrent(dpy_, root_);
    if (!res) return out;
    for (int i=0;i<res->noutput;i++) {
      XRROutputInfo* oi = XRRGetOutputInfo(dpy_, res, res->outputs[i]);
      if (!oi) continue;
      if (oi->connection != RR_Connected || oi->crtc == 0 || oi->nmode == 0) { XRRFreeOutputInfo(oi); continue; }
      XRRCrtcInfo* ci = XRRGetCrtcInfo(dpy_, res, oi->crtc);
      if (!ci) { XRRFreeOutputInfo(oi); continue; }

      OutputInfo O;
      O.name.assign(oi->name, oi->name + oi->nameLen);
      O.x = ci->x;
      O.y = ci->y;
      originals_[O.name] = { oi->crtc, ci->mode, ci->x, ci->y, ci->rotation };

      for (int m=0;m<oi->nmode;m++) {
        RRMode mid = oi->modes[m];
        for (int j=0;j<res->nmode;j++) if (res->modes[j].id == mid) {
          const XRRModeInfo& mi = res->modes[j];
          ModeInfo M;
          M.width = mi.width; M.height = mi.height;
          uint32_t mhz = (mi.hTotal && mi.vTotal) ? (uint64_t)mi.dotClock * 1000ull / (mi.hTotal * mi.vTotal) : 0;
          M.refresh_mHz = mhz;
          std::ostringstream os; os << mid; M.id = os.str();
          M.current = (ci->mode == mid);
          if (M.current) O.currentModeId = M.id;
          O.modes.push_back(M);
          break;
        }
      }
      out.push_back(std::move(O));
      XRRFreeCrtcInfo(ci);
      XRRFreeOutputInfo(oi);
    }
    XRRFreeScreenResources(res);
    return out;
  }

  bool setMode(const std::string& name, const std::string& modeId) override {
    std::fprintf(stderr, "[X11Backend] setMode %s -> %s\n", name.c_str(), modeId.c_str());
    if (!dpy_) return false;
    XRRScreenResources* res = XRRGetScreenResourcesCurrent(dpy_, root_);
    if (!res) return false;

    RRCrtc crtc{}; RRMode newMode{};
    int ox=0, oy=0; Rotation rot=RR_Rotate_0;
    for (int i=0;i<res->noutput;i++) {
      XRROutputInfo* oi = XRRGetOutputInfo(dpy_, res, res->outputs[i]);
      if (!oi) continue;
      std::string nm(oi->name, oi->name + oi->nameLen);
      if (nm == name && oi->crtc) {
        XRRCrtcInfo* ci = XRRGetCrtcInfo(dpy_, res, oi->crtc);
        if (ci) { crtc=oi->crtc; ox=ci->x; oy=ci->y; rot=ci->rotation; XRRFreeCrtcInfo(ci); }
        newMode = (RRMode)strtoull(modeId.c_str(), nullptr, 10);
        XRRFreeOutputInfo(oi);
        break;
      }
      XRRFreeOutputInfo(oi);
    }

    if (!crtc || !newMode) { XRRFreeScreenResources(res); return false; }
    Status st = XRRSetCrtcConfig(dpy_, res, crtc, CurrentTime, ox, oy, newMode, rot, nullptr, 0);
    XSync(dpy_, False);
    XRRFreeScreenResources(res);
    return st == Success;
  }

  bool revert(const std::string& name) override {
    std::fprintf(stderr, "[X11Backend] revert %s\n", name.c_str());
    if (!dpy_) return false;
    auto it = originals_.find(name);
    if (it == originals_.end()) return false;
    XRRScreenResources* res = XRRGetScreenResourcesCurrent(dpy_, root_);
    if (!res) return false;
    const Orig& o = it->second;
    Status st = XRRSetCrtcConfig(dpy_, res, o.crtc, CurrentTime, o.x, o.y, o.mode, o.rot, nullptr, 0);
    XSync(dpy_, False);
    XRRFreeScreenResources(res);
    return st == Success;
  }

  bool setPosition(const std::string& name, int newX, int newY) override {
    std::fprintf(stderr, "[X11Backend] setPosition %s -> %d,%d\n", name.c_str(), newX, newY);
    if (!dpy_) return false;
    XRRScreenResources* res = XRRGetScreenResourcesCurrent(dpy_, root_);
    if (!res) return false;
    bool ok = false;
    for (int i = 0; i < res->noutput; i++) {
      XRROutputInfo* oi = XRRGetOutputInfo(dpy_, res, res->outputs[i]);
      if (!oi) continue;
      std::string nm(oi->name, oi->name + oi->nameLen);
      if (nm == name && oi->crtc) {
        XRRCrtcInfo* ci = XRRGetCrtcInfo(dpy_, res, oi->crtc);
        if (ci) {
          Status st = XRRSetCrtcConfig(dpy_, res, oi->crtc, CurrentTime,
                                        newX, newY, ci->mode, ci->rotation,
                                        ci->outputs, ci->noutput);
          ok = (st == Success);
          XRRFreeCrtcInfo(ci);
        }
        XRRFreeOutputInfo(oi);
        break;
      }
      XRRFreeOutputInfo(oi);
    }
    XSync(dpy_, False);
    XRRFreeScreenResources(res);
    return ok;
  }

  bool applyPositions(const std::vector<std::pair<std::string, std::pair<int,int>>>& placements) override {
    if (!dpy_) return false;
    XRRScreenResources* res = XRRGetScreenResourcesCurrent(dpy_, root_);
    if (!res) return false;

    // Build name->position lookup
    std::unordered_map<std::string, std::pair<int,int>> posMap;
    for (const auto& p : placements) posMap[p.first] = p.second;

    // Calculate bounding box needed for the new layout
    int newW = 0, newH = 0;
    for (int i = 0; i < res->noutput; i++) {
      XRROutputInfo* oi = XRRGetOutputInfo(dpy_, res, res->outputs[i]);
      if (!oi) continue;
      std::string nm(oi->name, oi->name + oi->nameLen);
      if (oi->crtc) {
        XRRCrtcInfo* ci = XRRGetCrtcInfo(dpy_, res, oi->crtc);
        if (ci) {
          int x = ci->x, y = ci->y;
          if (posMap.count(nm)) { x = posMap.at(nm).first; y = posMap.at(nm).second; }
          for (int j = 0; j < res->nmode; j++) {
            if (res->modes[j].id == ci->mode) {
              int right  = x + (int)res->modes[j].width;
              int bottom = y + (int)res->modes[j].height;
              if (right  > newW) newW = right;
              if (bottom > newH) newH = bottom;
              break;
            }
          }
          XRRFreeCrtcInfo(ci);
        }
      }
      XRRFreeOutputInfo(oi);
    }

    // Expand screen to cover the new layout before moving CRTCs
    int curW = DisplayWidth(dpy_,  screen_);
    int curH = DisplayHeight(dpy_, screen_);
    if (newW > curW || newH > curH) {
      int w = (newW > curW) ? newW : curW;
      int h = (newH > curH) ? newH : curH;
      XRRSetScreenSize(dpy_, root_, w, h,
                       (int)(w * 25.4 / 96.0),
                       (int)(h * 25.4 / 96.0));
      XSync(dpy_, False);
      XRRFreeScreenResources(res);
      res = XRRGetScreenResourcesCurrent(dpy_, root_);
      if (!res) return false;
    }

    // Move each CRTC that has a new position
    bool allOk = true;
    for (int i = 0; i < res->noutput; i++) {
      XRROutputInfo* oi = XRRGetOutputInfo(dpy_, res, res->outputs[i]);
      if (!oi) continue;
      std::string nm(oi->name, oi->name + oi->nameLen);
      if (oi->crtc && posMap.count(nm)) {
        XRRCrtcInfo* ci = XRRGetCrtcInfo(dpy_, res, oi->crtc);
        if (ci) {
          int nx = posMap.at(nm).first;
          int ny = posMap.at(nm).second;
          Status st = XRRSetCrtcConfig(dpy_, res, oi->crtc, CurrentTime,
                                        nx, ny, ci->mode, ci->rotation,
                                        ci->outputs, ci->noutput);
          if (st != Success) {
            std::fprintf(stderr, "[X11Backend] applyPositions: failed to move %s\n", nm.c_str());
            allOk = false;
          }
          XRRFreeCrtcInfo(ci);
        }
      }
      XRRFreeOutputInfo(oi);
    }

    // Shrink screen to the actual bounding box if the layout got smaller
    if (newW < curW || newH < curH) {
      int w = (newW > 0) ? newW : curW;
      int h = (newH > 0) ? newH : curH;
      XRRSetScreenSize(dpy_, root_, w, h,
                       (int)(w * 25.4 / 96.0),
                       (int)(h * 25.4 / 96.0));
    }

    XSync(dpy_, False);
    XRRFreeScreenResources(res);
    return allOk;
  }

  bool setScale(const std::string& name, double scale) override {
    if (scale <= 0.0) return false;
    std::fprintf(stderr, "[X11Backend] setScale %s -> %.3f\n", name.c_str(), scale);
    std::ostringstream cmd;
    cmd << "xrandr --output \"" << name << "\" --scale " << scale << "x" << scale;
    return std::system(cmd.str().c_str()) == 0;
  }
};

std::unique_ptr<DisplayBackend> MakeX11Backend() {
  std::fprintf(stderr, "[Factory] MakeX11Backend\n");
  return std::unique_ptr<DisplayBackend>(new X11Backend());
}
