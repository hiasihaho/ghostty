// Ghostty GTK embedding shim — C API for hosting Ghostty terminal
// surfaces inside a foreign GTK4/libadwaita application on Linux.
//
// This is NOT the libghostty embedding API (ghostty.h, macOS/iOS only).
// Built via `zig build lib-gtk -Dapp-runtime=gtk` as libghostty-gtk.so.
//
// Contract:
//  - Call ghostty_embed_init() once, on the GTK main thread, after GTK
//    initialization (adw_init/gtk_init or GApplication startup).
//  - ghostty_embed_surface_new() returns a floating GtkWidget* (a
//    GhosttySurface: AdwBin subclass). Add it to a container; normal GTK
//    ownership rules apply. The shell spawns when the widget is realized.
//  - OSC title/pwd updates surface as GObject property notifications on
//    the widget ("notify::title", "notify::pwd").

#ifndef GHOSTTY_GTK_EMBED_H
#define GHOSTTY_GTK_EMBED_H

#ifdef __cplusplus
extern "C" {
#endif

// Initialize Ghostty global state, core app, and the (non-running,
// non-registered) GTK apprt Application. Returns 0 on success.
int ghostty_embed_init(void);

// Create a terminal surface widget. Returns a GtkWidget* with a floating
// reference, or NULL if the shim is not initialized.
void* ghostty_embed_surface_new(void);

#ifdef __cplusplus
}
#endif

#endif // GHOSTTY_GTK_EMBED_H
