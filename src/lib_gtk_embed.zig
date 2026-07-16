//! Linux GTK embedding shim.
//!
//! Exports a small C API that lets a foreign GTK4/libadwaita application
//! host Ghostty terminal surfaces as plain GtkWidgets. This is NOT the
//! general-purpose libghostty C API (include/ghostty.h + apprt/embedded,
//! which is macOS/iOS-only today) — it wraps the GTK apprt's GObject
//! Surface class directly and leaves window/tab/split management to the
//! host application.
//!
//! Built only as a library with -Dapp-runtime=gtk (`zig build lib-gtk`).
//! The host must be running a GLib main loop on the default main context;
//! Ghostty's core tick is pumped via coalesced idle sources (see
//! Application.wakeup embed branch in class/application.zig).

const std = @import("std");
const builtin = @import("builtin");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("apprt.zig");
const main = @import("main_ghostty.zig");
const state = &@import("global.zig").state;
const CoreApp = @import("App.zig");
const ApprtApp = @import("apprt/gtk/App.zig");
const Application = @import("apprt/gtk/class/application.zig").Application;
const Surface = @import("apprt/gtk/class/surface.zig").Surface;

const log = std.log.scoped(.gtk_embed);

comptime {
    if (!builtin.is_test) {
        if (apprt.runtime != apprt.gtk) {
            @compileError("lib_gtk_embed requires -Dapp-runtime=gtk");
        }
    }
}

/// Use Ghostty's logging setup for std.log, same as the exe and main_c.
pub const std_options = main.std_options;

/// Embed-global state. The apprt App must live at a stable address for
/// the whole process lifetime: the Application GObject and every
/// CoreSurface hold pointers to it (same contract as the stack slot in
/// main_ghostty.zig that lives for the duration of main()).
var embed_state: struct {
    core_app: ?*CoreApp = null,
    rt_app: ApprtApp = undefined,
} = .{};

/// Initialize the Ghostty global state, core app, and the GTK apprt
/// Application object — everything Application.run would rely on, without
/// registering or running the GApplication (the host owns the main loop
/// and the process-default application). Idempotent-hostile: call exactly
/// once, from the GTK main thread, after the host's GTK init.
///
/// Returns 0 on success.
export fn ghostty_embed_init() c_int {
    if (embed_state.core_app != null) {
        log.warn("ghostty_embed_init called twice; ignoring", .{});
        return 0;
    }

    state.init() catch |err| {
        log.err("global state init failed error={}", .{err});
        return 1;
    };

    const core_app = CoreApp.create(state.alloc) catch |err| {
        log.err("core app create failed error={}", .{err});
        return 1;
    };

    // The host has already initialized GTK; Application.new must skip
    // its pre-GTK-init work (setGtkEnv asserts GTK is uninitialized).
    Application.setEmbedMode();

    // Application.new: config load, adw.init, winproto detection, CSS
    // provider — but no register/run/activate.
    embed_state.rt_app.init(core_app, .{}) catch |err| {
        log.err("apprt app init failed error={}", .{err});
        return 1;
    };

    // From here on, Application.default() resolves to our instance and
    // wakeup() pumps ticks through the host's main loop.
    embed_state.rt_app.app.setEmbedInstance();
    embed_state.core_app = core_app;

    log.info("ghostty embed initialized", .{});
    return 0;
}

/// Create a new terminal surface widget. Returns a floating-referenced
/// GtkWidget* (a GhosttySurface, subclass of AdwBin) ready to be added to
/// any container — the usual GTK ownership rules apply. The core surface
/// (shell spawn, renderer + IO threads) initializes lazily when the
/// widget's GLArea is first realized and sized.
///
/// Returns NULL if the shim is not initialized.
export fn ghostty_embed_surface_new() ?*gtk.Widget {
    if (embed_state.core_app == null) {
        log.err("ghostty_embed_surface_new before ghostty_embed_init", .{});
        return null;
    }
    const surface = Surface.new();
    return surface.as(gtk.Widget);
}
