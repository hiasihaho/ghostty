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

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize Ghostty global state, core app, and the (non-running,
// non-registered) GTK apprt Application. Returns 0 on success.
int ghostty_embed_init(void);

// Create a terminal surface widget. Returns a GtkWidget* with a floating
// reference, or NULL if the shim is not initialized or configuration
// cloning fails.
//
// working_directory: shell start directory, or NULL for the config/user
// default. env_keys/env_values: parallel arrays of env_len extra
// environment variables for the spawned shell (NULL allowed when
// env_len is 0). Both apply via a per-surface clone of the user config.
void* ghostty_embed_surface_new(const char* working_directory,
                                const char** env_keys,
                                const char** env_values,
                                size_t env_len);

// Write bytes RAW to the surface's PTY (no paste encoding) — send_text /
// send_key semantics, like vte_terminal_feed_child. Returns false while
// the surface's shell isn't running yet (unrealized background pane).
bool ghostty_embed_surface_send_text(void* widget,
                                     const unsigned char* bytes,
                                     size_t len);

// Read terminal text: the active screenful (ending at the cursor), or the
// whole buffer including scrollback history. Returns a NUL-terminated
// string to release with ghostty_embed_text_free, or NULL while the
// surface's shell isn't running yet.
char* ghostty_embed_surface_read_text(void* widget, bool include_scrollback);
void ghostty_embed_text_free(char* text);

#ifdef __cplusplus
}
#endif

#endif // GHOSTTY_GTK_EMBED_H
