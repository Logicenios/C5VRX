#!/bin/sh
# Run the Gowin EDA Tcl shell headless with its own Qt (the system Qt 5.15.18 plugins clash
# with Gowin's bundled 5.15.14, and there is no display on the build path).
GOWIN=${GOWIN:-$HOME/.local/opt/gowin}
exec env -u QT_IM_MODULES -u QT_IM_MODULE QT_QPA_PLATFORM=offscreen \
    QT_PLUGIN_PATH="$GOWIN/IDE/plugins/qt" LD_LIBRARY_PATH="$GOWIN/IDE/lib" \
    "$GOWIN/IDE/bin/gw_sh" "$@"
