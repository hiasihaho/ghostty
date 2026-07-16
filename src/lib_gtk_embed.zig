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
const terminal = @import("terminal/main.zig");
const termio = @import("termio.zig");
const CoreApp = @import("App.zig");
const CoreSurface = @import("Surface.zig");
const ApprtApp = @import("apprt/gtk/App.zig");
const Application = @import("apprt/gtk/class/application.zig").Application;
const Config = @import("apprt/gtk/class/config.zig").Config;
const Surface = @import("apprt/gtk/class/surface.zig").Surface;
const SurfaceScrolledWindow = @import("apprt/gtk/class/surface_scrolled_window.zig").SurfaceScrolledWindow;

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
/// `working_directory` (nullable) and `env` (parallel key/value arrays,
/// nullable when `env_len` is 0) apply to the spawned shell via a
/// per-surface clone of the user's config (`working-directory` + `env`
/// config keys), leaving the app-level config untouched.
///
/// Returns NULL if the shim is not initialized or the config clone fails.
export fn ghostty_embed_surface_new(
    working_directory: ?[*:0]const u8,
    env_keys: ?[*]const [*:0]const u8,
    env_values: ?[*]const [*:0]const u8,
    env_len: usize,
) ?*gtk.Widget {
    if (embed_state.core_app == null) {
        log.err("ghostty_embed_surface_new before ghostty_embed_init", .{});
        return null;
    }

    const surface = Surface.new();

    if (working_directory != null or env_len > 0) {
        applySurfaceOverrides(
            surface,
            working_directory,
            env_keys,
            env_values,
            env_len,
        ) catch |err| {
            log.err("per-surface config overrides failed error={}", .{err});
            surface.as(gobject.Object).unref();
            return null;
        };
    }

    return surface.as(gtk.Widget);
}

/// Clone the app config, apply per-surface working-directory/env
/// overrides, and hand the clone to the surface. Must run before the
/// widget is realized (the core surface reads the config at realize).
fn applySurfaceOverrides(
    surface: *Surface,
    working_directory: ?[*:0]const u8,
    env_keys: ?[*]const [*:0]const u8,
    env_values: ?[*]const [*:0]const u8,
    env_len: usize,
) !void {
    const app = Application.default();
    const app_config = app.getConfig();
    defer app_config.unref();

    // Config.new clones the core config (own arena); mutate the clone.
    const surface_config = try Config.new(state.alloc, app_config.get());
    defer surface_config.unref();

    const core = surface_config.getMut();
    const arena = core._arena.?.allocator();

    if (working_directory) |wd| {
        core.@"working-directory" = try arena.dupe(u8, std.mem.span(wd));
    }

    if (env_len > 0) {
        const keys = env_keys orelse return error.InvalidEnv;
        const values = env_values orelse return error.InvalidEnv;
        for (0..env_len) |i| {
            const entry = try std.fmt.allocPrint(arena, "{s}={s}", .{
                std.mem.span(keys[i]),
                std.mem.span(values[i]),
            });
            try core.env.parseCLI(arena, entry);
        }
    }

    surface.setConfig(surface_config);
}

/// Widget → GhosttySurface → core surface. Null until the GLArea has
/// realized and the core surface exists (e.g. panes in never-shown
/// background workspaces).
fn coreSurfaceFromWidget(widget: *gtk.Widget) ?*CoreSurface {
    const surface = gobject.ext.cast(
        Surface,
        widget.as(gobject.Object),
    ) orelse return null;
    return surface.core();
}

/// Write bytes RAW to the surface's PTY (no paste encoding) — the
/// semantics of the host's send_text/send_key verbs, matching a
/// vte_terminal_feed_child. Returns false when the core surface isn't
/// initialized yet (unrealized background pane) or the widget is not a
/// GhosttySurface.
export fn ghostty_embed_surface_send_text(
    widget: *gtk.Widget,
    ptr: [*]const u8,
    len: usize,
) bool {
    const core_surface = coreSurfaceFromWidget(widget) orelse return false;
    if (len == 0) return true;
    const msg = termio.Message.writeReq(
        state.alloc,
        ptr[0..len],
    ) catch return false;
    core_surface.queueIo(msg, .unlocked);
    return true;
}

/// Read terminal text: the active screen area ("screenful ending at the
/// cursor", matching the host's VTE read_text) or, with
/// `include_scrollback`, the whole screen buffer including history.
/// Returns a NUL-terminated string owned by the shim — free it with
/// ghostty_embed_text_free — or NULL if the core surface isn't ready.
export fn ghostty_embed_surface_read_text(
    widget: *gtk.Widget,
    include_scrollback: bool,
) ?[*:0]u8 {
    const core_surface = coreSurfaceFromWidget(widget) orelse return null;

    core_surface.renderer_state.mutex.lock();
    defer core_surface.renderer_state.mutex.unlock();

    const screen = core_surface.renderer_state.terminal.screens.active;
    const pages = &screen.pages;
    const tl = if (include_scrollback)
        pages.pin(.{ .screen = .{ .x = 0, .y = 0 } })
    else
        pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const br = pages.pin(.{ .active = .{
        .x = pages.cols -| 1,
        .y = pages.rows -| 1,
    } });
    const sel: terminal.Selection = .{
        .bounds = .{ .untracked = .{
            .start = tl orelse return null,
            .end = br orelse return null,
        } },
        .rectangle = false,
    };

    var text = core_surface.dumpTextLocked(state.alloc, sel) catch |err| {
        log.warn("read_text failed error={}", .{err});
        return null;
    };
    defer text.deinit(state.alloc);

    const out = state.alloc.dupeZ(u8, text.text) catch return null;
    return out.ptr;
}

/// Free a string returned by ghostty_embed_surface_read_text.
export fn ghostty_embed_text_free(ptr: ?[*:0]u8) void {
    if (ptr) |p| state.alloc.free(std.mem.span(p));
}

/// Wrap a surface widget in Ghostty's own scrolled-window container
/// (config-bound scrollbar visibility, hscrollbar never). Hosts should
/// use this as the pane child: a plain GtkScrolledWindow with automatic
/// policies lets the scrollable surface keep its natural size instead of
/// tracking the host window, so panes never resize with the window.
/// Returns a floating GtkWidget*, or NULL if `surface_widget` is not a
/// GhosttySurface.
export fn ghostty_embed_surface_container_new(
    surface_widget: *gtk.Widget,
) ?*gtk.Widget {
    const surface = gobject.ext.cast(
        Surface,
        surface_widget.as(gobject.Object),
    ) orelse return null;
    const scrolled = gobject.ext.newInstance(SurfaceScrolledWindow, .{});
    scrolled.setSurface(surface);
    return scrolled.as(gtk.Widget);
}
