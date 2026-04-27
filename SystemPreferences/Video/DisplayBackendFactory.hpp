#pragma once
#include <memory>
#include "DisplayBackend.hpp"
std::unique_ptr<DisplayBackend> MakeX11Backend();
std::unique_ptr<DisplayBackend> MakeWaylandBackend(); // implemented below
