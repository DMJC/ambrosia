#!/bin/bash

# This script is used to regenerate xdg-shell-protocol public code and headers
# from the XML specification.

wayland-scanner client-header  /usr/share/wayland-protocols/staging/wlr-output-management-unstable-v1.xml \
    wlr-output-management-unstable-v1-client-protocol.h
wayland-scanner private-code   /usr/share/wayland-protocols/staging/wlr-output-management-unstable-v1.xml \
    wlr-output-management-unstable-v1-protocol.c
