const std = @import("std");
const dekoodaaja = @import("dekoodaaja");
const log = std.log.scoped(.swiv);
const shimizu = @import("shimizu");
const wp = @import("wayland-protocols");
const xdg_shell = wp.xdg_shell;

const RecvFn = fn (*shimizu.Connection) anyerror!void;

const Globals = struct {
    shm: shimizu.core.wl_shm,
    compositor: shimizu.core.wl_compositor,
    subcompositor: shimizu.core.wl_subcompositor,
    single_pixel_buffer_manager: wp.single_pixel_buffer_v1.wp_single_pixel_buffer_manager_v1,
    viewporter: wp.viewporter.wp_viewporter,
    wm_base: xdg_shell.xdg_wm_base,
    seat: shimizu.core.wl_seat,

    const Id = @Type(.{ .@"enum" = .{
        .fields = D: {
            const names = std.meta.fieldNames(Globals);
            var fields: [names.len]std.builtin.Type.EnumField = undefined;
            for (&fields, names, 0..) |*f, name, idx| {
                f.name = name;
                f.value = idx;
            }
            break :D &fields;
        },
        .is_exhaustive = true,
        .tag_type = std.math.IntFittingRange(0, std.meta.fields(Globals).len),
        .decls = &.{},
    } });
};

allocator: std.mem.Allocator,
conn: *shimizu.Connection,
recv: *const RecvFn,
global: Globals,
registered: std.enums.EnumSet(Globals.Id),
ww: u32,
wh: u32,
zoom: f32,
mouse_x: u32,
mouse_y: u32,
offset_x: i32,
offset_y: i32,
panning: bool,
transform: shimizu.core.wl_output.Transform,
main_surface: shimizu.core.wl_surface,
main_surface_configured: bool,
main_viewport: wp.viewporter.wp_viewport,
main_buffer: Buffer,
image_surface: shimizu.core.wl_surface,
image_subsurface: shimizu.core.wl_subsurface,
image_viewport: wp.viewporter.wp_viewport,
image_buffer: Buffer,
xdg_surface: xdg_shell.xdg_surface,
xdg_toplevel: xdg_shell.xdg_toplevel,
got_seat_capabilities: bool,
keyboard: ?shimizu.core.wl_keyboard,
pointer: ?shimizu.core.wl_pointer,
touch: ?shimizu.core.wl_touch,

const Strings = struct {
    buffer: std.ArrayList(u8),

    const empty: @This() = .{ .buffer = .empty };

    const Range = struct {
        offset: u32,
        length: u16,
    };

    fn append(self: *@This(), gpa: std.mem.Allocator, bytes: []const u8) !Range {
        const offset = self.buffer.items.len;
        try self.buffer.appendSlice(gpa, bytes);
        return .{ .offset = @intCast(offset), .length = @intCast(bytes.len) };
    }

    fn slice(self: *const @This(), range: Range) []const u8 {
        return self.buffer.items[range.offset..][0..range.length];
    }

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.buffer.deinit(gpa);
        self.* = undefined;
    }
};

const Converter = struct {
    name: Strings.Range,
    check: Strings.Range,
    convert: Strings.Range,

    const Index = enum(usize) {
        qoi = std.math.maxInt(usize),
        _,
    };

    fn init(gpa: std.mem.Allocator, strings: *Strings, dir: std.fs.Dir, sub_path: []const u8) !@This() {
        const content = try dir.readFileAlloc(gpa, sub_path, std.math.maxInt(u32));
        defer gpa.free(content);
        const name = try strings.append(gpa, std.fs.path.basenamePosix(sub_path));
        var iter = std.mem.tokenizeScalar(u8, content, '\n');
        const check = try strings.append(gpa, iter.next() orelse return error.InvalidConverter);
        const convert = try strings.append(gpa, iter.next() orelse return error.InvalidConverter);
        return .{
            .name = name,
            .check = check,
            .convert = convert,
        };
    }
};

fn getConverters(gpa: std.mem.Allocator, env: *std.process.EnvMap, strings: *Strings) ![]const Converter {
    var converters: std.ArrayList(Converter) = .empty;
    errdefer converters.deinit(gpa);

    if (std.fs.cwd().openDir("/usr/share/swiv", .{ .iterate = true })) |dir| {
        var iter = dir.iterate();
        while (try iter.next()) |entry| try converters.append(gpa, try .init(gpa, strings, dir, entry.name));
    } else |_| {}

    const known_folders = @import("known_folders");
    if (try known_folders.open(gpa, .local_configuration, .{})) |root| {
        if (root.openDir("swiv", .{ .iterate = true })) |dir| {
            var iter = dir.iterate();
            while (try iter.next()) |entry| try converters.append(gpa, try .init(gpa, strings, dir, entry.name));
        } else |_| {}
    }

    if (env.get("SWIV_CONVERTER_PATH")) |envp| {
        var paths = std.mem.tokenizeScalar(u8, envp, ':');
        while (paths.next()) |path| {
            if (std.fs.cwd().openDir(path, .{ .iterate = true })) |dir| {
                var iter = dir.iterate();
                while (try iter.next()) |entry| try converters.append(gpa, try .init(gpa, strings, dir, entry.name));
            } else |_| {}
        }
    }

    return try converters.toOwnedSlice(gpa);
}

const Image = struct {
    header: dekoodaaja.Header,
    pixels: []const u8,
};

const CacheEntry = union(enum) {
    pending_identification: void,
    pending_conversion: Converter.Index,
    image: Image,
    no_converter: void,
};

const ImageCache = std.AutoArrayHashMapUnmanaged(Strings.Range, CacheEntry);

const Pixel = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
    const default: @This() = .{ .r = 30, .g = 30, .b = 30, .a = 0xff };
    const red: @This() = .{ .r = 0xff, .g = 0, .b = 0, .a = 0xff };
    const green: @This() = .{ .r = 0, .g = 0xff, .b = 0, .a = 0xff };
    const blue: @This() = .{ .r = 0, .g = 0, .b = 0xff, .a = 0xff };
    const black: @This() = .{ .r = 0, .g = 0, .b = 0, .a = 0xff };

    fn toVector(self: @This()) @Vector(4, u8) {
        return @bitCast(self);
    }

    fn premultiply(self: @This()) @This() {
        const alpha: @Vector(4, u8) = @splat(self.a);
        const scale: @Vector(4, f32) = @splat(255.0);
        const linear_a: @Vector(4, f32) = @floatFromInt(alpha);
        const linear_rgba: @Vector(4, f32) = @floatFromInt(self.toVector());
        const u8_rgba: @Vector(4, u8) = @intFromFloat((linear_rgba * linear_a) / scale);
        return @bitCast(u8_rgba);
    }
};

const Buffer = struct {
    wl: shimizu.core.wl_buffer,
    backing: union(enum) {
        uninitialized: void,
        pixel: void,
        image: struct {
            fd: std.posix.fd_t,
            pool: shimizu.core.wl_shm_pool,
            image: Image,
        },
    },

    const uninitialized: @This() = .{ .wl = undefined, .backing = .uninitialized };

    fn initPixelBuffer(conn: *shimizu.Connection, manager: wp.single_pixel_buffer_v1.wp_single_pixel_buffer_manager_v1, pixel: Pixel) !@This() {
        return .{
            .wl = try manager.create_u32_rgba_buffer(
                conn,
                @as(u32, pixel.r) * 0x01010101,
                @as(u32, pixel.g) * 0x01010101,
                @as(u32, pixel.b) * 0x01010101,
                @as(u32, pixel.a) * 0x01010101,
            ),
            .backing = .pixel,
        };
    }

    fn initImageBuffer(conn: *shimizu.Connection, shm: shimizu.core.wl_shm, image: Image) !@This() {
        const fd = try std.posix.memfd_create("", 0);
        errdefer std.posix.close(fd);
        const raw_size = image.header.w * image.header.h * 4;
        try std.posix.ftruncate(fd, raw_size);
        const mem = try std.posix.mmap(null, raw_size, std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
        defer std.posix.munmap(mem);
        @memcpy(mem, image.pixels);
        const pool = try shm.create_pool(conn, @enumFromInt(fd), @intCast(image.pixels.len));
        errdefer pool.destroy(conn) catch unreachable;
        return .{
            .wl = try pool.create_buffer(
                conn,
                0,
                @intCast(image.header.w),
                @intCast(image.header.h),
                @intCast(image.header.w * 4),
                .argb8888,
            ),
            .backing = .{ .image = .{
                .fd = fd,
                .pool = pool,
                .image = image,
            } },
        };
    }

    fn applyToSurface(self: *@This(), conn: *shimizu.Connection, surface: shimizu.core.wl_surface) !void {
        std.debug.assert(self.backing != .uninitialized);
        try surface.attach(conn, self.wl, 0, 0);
        try surface.damage(conn, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        try surface.commit(conn);
    }

    fn deinit(self: *@This(), conn: *shimizu.Connection) void {
        switch (self.backing) {
            .uninitialized => return,
            .pixel => {},
            .image => |d| {
                d.pool.destroy(conn) catch unreachable;
                std.posix.close(d.fd);
            },
        }
        self.wl.destroy(conn) catch unreachable;
    }
};

fn onRegistryEvent(self: *@This(), conn: *shimizu.Connection, registry: shimizu.core.wl_registry, event: shimizu.core.wl_registry.Event) !void {
    switch (event) {
        .global => |global| {
            inline for (std.meta.fields(Globals), 0..) |f, idx| {
                if (std.mem.eql(u8, global.interface, f.type.NAME)) {
                    @field(self.global, f.name) = @enumFromInt(@intFromEnum(try registry.bind(conn, global.name, f.type.NAME, @min(global.version, f.type.VERSION))));
                    self.registered.insert(@enumFromInt(idx));
                }
            }
        },
        .global_remove => {},
    }
}

fn updateViewport(self: *@This(), update: enum { alone, with_main }) !void {
    if (self.image_buffer.backing != .image) return;
    const header = self.image_buffer.backing.image.image.header;

    const Viewport = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        const zero: @This() = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    };

    var src_w: f32 = @floatFromInt(header.w);
    var src_h: f32 = @floatFromInt(header.h);
    const dst_aspect: f32 = src_w / src_h;
    const src_aspect: f32 = @as(f32, @floatFromInt(self.ww)) / @as(f32, @floatFromInt(self.wh));

    var vp: Viewport = .zero;
    if (src_w > src_h) {
        if (src_aspect > dst_aspect) {
            vp.h = @intCast(self.wh);
            vp.w = @intFromFloat(@round(@as(f32, @floatFromInt(vp.h)) * dst_aspect));
        } else {
            vp.w = @intCast(self.ww);
            vp.h = @intFromFloat(@round(@as(f32, @floatFromInt(vp.w)) / dst_aspect));
        }
    } else {
        if (src_aspect > dst_aspect) {
            vp.h = @intCast(self.wh);
            vp.w = @intFromFloat(@round(@as(f32, @floatFromInt(vp.h)) * dst_aspect));
        } else {
            vp.w = @intCast(self.ww);
            vp.h = @intFromFloat(@round(@as(f32, @floatFromInt(vp.w)) / dst_aspect));
        }
    }

    const rotated = @intFromEnum(self.transform) % 2 == 1;
    if (rotated) {
        std.mem.swap(i32, &vp.w, &vp.h);
        std.mem.swap(f32, &src_w, &src_h);
    }

    vp.x = @intFromFloat(@round(@as(f32, @floatFromInt(@as(i32, @intCast(self.ww)) - vp.w)) / 2));
    vp.y = @intFromFloat(@round(@as(f32, @floatFromInt(@as(i32, @intCast(self.wh)) - vp.h)) / 2));

    // Surface local coordinates
    const dst_w: f32 = @as(f32, @floatFromInt(vp.w)) * self.zoom;
    const dst_h: f32 = @as(f32, @floatFromInt(vp.h)) * self.zoom;
    const dst_x: f32 = @as(f32, @floatFromInt(vp.x)) - (dst_w - @as(f32, @floatFromInt(vp.w))) / 2 + @as(f32, @floatFromInt(self.offset_x));
    const dst_y: f32 = @as(f32, @floatFromInt(vp.y)) - (dst_h - @as(f32, @floatFromInt(vp.h))) / 2 + @as(f32, @floatFromInt(self.offset_y));

    // Clip to main surface / window
    const win_w: f32 = @floatFromInt(self.ww);
    const win_h: f32 = @floatFromInt(self.wh);
    const clip_x0 = @max(dst_x, 0);
    const clip_y0 = @max(dst_y, 0);
    const clip_x1 = @min(dst_x + dst_w, win_w);
    const clip_y1 = @min(dst_y + dst_h, win_h);
    const clip_w = @max(@round(clip_x1 - clip_x0), 0);
    const clip_h = @max(@round(clip_y1 - clip_y0), 0);

    if (dst_w <= 0 or dst_h <= 0 or clip_w <= 0 or clip_h <= 0) {
        // Surface is completely out of bounds
        try self.image_surface.attach(self.conn, null, 0, 0);
    } else {
        // Convert back to surface coordinates
        const scale_x = src_w / dst_w;
        const scale_y = src_h / dst_h;
        const src_x0 = @min(@max(@round((clip_x0 - dst_x) * scale_x), 0), src_w - 1);
        const src_y0 = @min(@max(@round((clip_y0 - dst_y) * scale_y), 0), src_h - 1);
        const src_cw = @max(@min(@round(clip_w * scale_x), src_w - src_x0), 1);
        const src_ch = @max(@min(@round(clip_h * scale_y), src_h - src_y0), 1);

        try self.image_surface.attach(self.conn, self.image_buffer.wl, 0, 0);

        try self.image_subsurface.set_position(
            self.conn,
            @intFromFloat(@round(clip_x0)),
            @intFromFloat(@round(clip_y0)),
        );
        try self.image_viewport.set_destination(
            self.conn,
            @intFromFloat(clip_w),
            @intFromFloat(clip_h),
        );
        try self.image_viewport.set_source(
            self.conn,
            .fromInt(@intFromFloat(src_x0), 0),
            .fromInt(@intFromFloat(src_y0), 0),
            .fromInt(@intFromFloat(src_cw), 0),
            .fromInt(@intFromFloat(src_ch), 0),
        );
    }

    try self.image_surface.set_buffer_transform(self.conn, self.transform);
    try self.image_surface.commit(self.conn);

    if (update == .with_main) {
        try self.main_surface.commit(self.conn);
    }
}

fn onXdgSurfaceEvent(self: *@This(), conn: *shimizu.Connection, xdg_surface: xdg_shell.xdg_surface, event: xdg_shell.xdg_surface.Event) !void {
    switch (event) {
        .configure => |configure| {
            if (!self.main_surface_configured) {
                try xdg_surface.ack_configure(conn, configure.serial);
                self.main_surface_configured = true;
                return;
            }
            try self.updateViewport(.alone);
            try self.xdg_surface.set_window_geometry(conn, 0, 0, @intCast(self.ww), @intCast(self.wh));
            try self.main_viewport.set_destination(conn, @intCast(self.ww), @intCast(self.wh));
            try xdg_surface.ack_configure(conn, configure.serial);
            try self.main_surface.commit(self.conn);
        },
    }
}

fn onXdgTopLevelEvent(self: *@This(), _: *shimizu.Connection, _: xdg_shell.xdg_toplevel, event: xdg_shell.xdg_toplevel.Event) !void {
    switch (event) {
        .configure => |configure| {
            self.ww = @max(configure.width, 320);
            self.wh = @max(configure.height, 320);
        },
        .configure_bounds => {},
        .wm_capabilities => {},
        .close => std.process.exit(0),
    }
}

fn onWlSeatEvent(self: *@This(), conn: *shimizu.Connection, seat: shimizu.core.wl_seat, event: shimizu.core.wl_seat.Event) !void {
    switch (event) {
        .capabilities => |ev| {
            if (ev.capabilities.keyboard) {
                self.keyboard = try seat.get_keyboard(conn);
            }
            if (ev.capabilities.pointer) {
                self.pointer = try seat.get_pointer(conn);
            }
            if (ev.capabilities.touch) {
                self.touch = try seat.get_touch(conn);
            }
            self.got_seat_capabilities = true;
        },
        .name => {},
    }
}

const Key = enum(u32) {
    esc = 1,
    _,
};

fn onKeyboardEvent(self: *@This(), conn: *shimizu.Connection, keyboard: shimizu.core.wl_keyboard, event: shimizu.core.wl_keyboard.Event) !void {
    _ = self;
    _ = conn;
    _ = keyboard;
    switch (event) {
        .enter => {},
        .key => |ev| switch (@as(Key, @enumFromInt(ev.key))) {
            .esc => std.process.exit(0), // ESC
            _ => {},
        },
        .keymap => {},
        .leave => {},
        .modifiers => {},
        .repeat_info => {},
    }
}

fn onPointerEvent(self: *@This(), conn: *shimizu.Connection, pointer: shimizu.core.wl_pointer, event: shimizu.core.wl_pointer.Event) !void {
    _ = conn;
    _ = pointer;
    switch (event) {
        .axis => |ev| switch (ev.axis) {
            .vertical_scroll => {
                self.zoom *= if (ev.value.integer > 0) 1 - 0.1 else 1 + 0.1;
                try self.updateViewport(.with_main);
            },
            .horizontal_scroll => {},
        },
        .axis_discrete => {},
        .axis_relative_direction => {},
        .axis_source => {},
        .axis_stop => {},
        .axis_value120 => {},
        .button => |ev| switch (ev.state) {
            .pressed => switch (ev.button) {
                272 => self.panning = true,
                273 => {
                    self.transform = @enumFromInt((@intFromEnum(self.transform) + 1) % 7);
                    try self.updateViewport(.with_main);
                },
                274 => {
                    self.zoom = 1.0;
                    self.transform = .normal;
                    self.offset_x = 0;
                    self.offset_y = 0;
                    try self.updateViewport(.with_main);
                },
                else => std.log.info("{}", .{ev.button}),
            },
            .released => switch (ev.button) {
                272 => self.panning = false,
                else => {},
            },
        },
        .enter => {},
        .frame => {},
        .leave => {},
        .motion => |ev| {
            const mx: i32 = @max(ev.surface_x.integer, 0);
            const my: i32 = @max(ev.surface_y.integer, 0);
            if (self.panning) {
                self.offset_x += mx - @as(i32, @intCast(self.mouse_x));
                self.offset_y += my - @as(i32, @intCast(self.mouse_y));
                try self.updateViewport(.with_main);
            }
            self.mouse_x = @intCast(mx);
            self.mouse_y = @intCast(my);
        },
    }
}

fn onTouchEvent(self: *@This(), conn: *shimizu.Connection, touch: shimizu.core.wl_touch, event: shimizu.core.wl_touch.Event) !void {
    _ = self;
    _ = conn;
    _ = touch;
    switch (event) {
        .cancel => {},
        .down => {},
        .frame => {},
        .motion => {},
        .orientation => {},
        .shape => {},
        .up => {},
    }
}

fn onWlCallbackSetTrue(bool_ptr: *bool, _: *shimizu.Connection, _: shimizu.core.wl_callback, _: shimizu.core.wl_callback.Event) !void {
    bool_ptr.* = true;
}

fn init(self: *@This(), gpa: std.mem.Allocator, conn: *shimizu.Connection, dpy: shimizu.core.wl_display, recv: *const RecvFn) !void {
    self.* = .{
        .allocator = gpa,
        .conn = conn,
        .recv = recv,
        .global = undefined,
        .ww = 320,
        .wh = 320,
        .zoom = 1.0,
        .mouse_x = 0,
        .mouse_y = 0,
        .offset_x = 0,
        .offset_y = 0,
        .panning = false,
        .transform = .normal,
        .image_buffer = .uninitialized,
        .image_subsurface = undefined,
        .image_surface = undefined,
        .image_viewport = undefined,
        .main_buffer = .uninitialized,
        .main_surface = undefined,
        .main_viewport = undefined,
        .main_surface_configured = false,
        .registered = .initEmpty(),
        .xdg_surface = undefined,
        .xdg_toplevel = undefined,
        .got_seat_capabilities = false,
        .keyboard = null,
        .pointer = null,
        .touch = null,
    };

    const registry = try dpy.get_registry(conn);
    const registry_done_callback = try dpy.sync(conn);
    try conn.setEventListener(registry, *@This(), onRegistryEvent, self);
    var registration_done = false;
    try conn.setEventListener(registry_done_callback, *bool, onWlCallbackSetTrue, &registration_done);
    while (!registration_done) try recv(self.conn);

    if (self.registered.count() != std.enums.values(Globals.Id).len) {
        inline for (std.enums.values(Globals.Id), std.meta.fields(Globals)) |e, f| {
            if (!self.registered.contains(e)) {
                log.err("compositor does not support {s} v{}", .{ f.type.NAME, f.type.VERSION });
            }
        }
        return error.UnsupportedCompositor;
    }

    try conn.setEventListener(self.global.seat, *@This(), onWlSeatEvent, self);
    while (!self.got_seat_capabilities) try recv(self.conn);

    if (self.keyboard) |keyboard| try conn.setEventListener(keyboard, *@This(), onKeyboardEvent, self);
    if (self.pointer) |pointer| try conn.setEventListener(pointer, *@This(), onPointerEvent, self);
    if (self.touch) |touch| try conn.setEventListener(touch, *@This(), onTouchEvent, self);

    self.main_surface = try self.global.compositor.create_surface(conn);
    self.main_viewport = try self.global.viewporter.get_viewport(conn, self.main_surface);
    self.xdg_surface = try self.global.wm_base.get_xdg_surface(conn, self.main_surface);
    self.xdg_toplevel = try self.xdg_surface.get_toplevel(conn);
    try self.xdg_toplevel.set_app_id(conn, "pw.cloudef.swiv");
    try self.xdg_toplevel.set_title(conn, "swiv");

    try conn.setEventListener(self.xdg_surface, *@This(), onXdgSurfaceEvent, self);
    try conn.setEventListener(self.xdg_toplevel, *@This(), onXdgTopLevelEvent, self);
    try self.main_surface.commit(conn);
    while (!self.main_surface_configured) try recv(self.conn);

    self.main_buffer = try .initPixelBuffer(conn, self.global.single_pixel_buffer_manager, .default);
    try self.main_buffer.applyToSurface(conn, self.main_surface);

    const region = try self.global.compositor.create_region(conn);
    self.image_surface = try self.global.compositor.create_surface(conn);
    try self.image_surface.set_input_region(conn, region);
    self.image_subsurface = try self.global.subcompositor.get_subsurface(conn, self.image_surface, self.main_surface);
    try self.image_subsurface.set_sync(self.conn);
    self.image_viewport = try self.global.viewporter.get_viewport(conn, self.image_surface);

    self.image_buffer = try .initPixelBuffer(conn, self.global.single_pixel_buffer_manager, .default);
    try self.image_buffer.applyToSurface(conn, self.image_surface);
}

fn initChild(gpa: std.mem.Allocator, path: []const u8, cmd: []const u8, argv: *[64][]const u8) std.process.Child {
    var num: usize = 0;
    var iter = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (iter.next()) |arg| {
        if (num >= argv.len) std.debug.panic("command too long: {s}", .{cmd});
        if (std.mem.eql(u8, arg, "%i")) {
            argv[num] = path;
        } else {
            argv[num] = arg;
        }
        num += 1;
    }
    return std.process.Child.init(argv[0..num], gpa);
}

fn identify(gpa: std.mem.Allocator, path: []const u8, cmd: []const u8) !bool {
    var argv: [64][]const u8 = undefined;
    var child = initChild(gpa, path, cmd, &argv);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    return term == .Exited and term.Exited == 0;
}

fn imageFromQoi(gpa: std.mem.Allocator, source: *std.Io.Reader) !Image {
    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();
    const hdr = try dekoodaaja.qoi.decode(source, &allocating.writer);
    const buffer = try allocating.toOwnedSlice();
    const pixels = std.mem.bytesAsSlice(Pixel, buffer);
    for (pixels) |*p| p.* = p.premultiply();
    return .{ .header = .{ .w = hdr.w, .h = hdr.h }, .pixels = buffer };
}

fn convertToQoi(gpa: std.mem.Allocator, path: []const u8, cmd: []const u8) !Image {
    var argv: [64][]const u8 = undefined;
    var child = initChild(gpa, path, cmd, &argv);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(gpa);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(gpa);
    try child.collectOutput(gpa, &stdout, &stderr, std.math.maxInt(usize));
    const term = try child.wait();
    if (term != .Exited and term.Exited != 0) {
        return error.ConversionFailed;
    }
    var reader: std.Io.Reader = .fixed(stdout.items);
    return try imageFromQoi(gpa, &reader);
}

fn run(self: *@This(), strings: *const Strings, converters: []const Converter, cache: ImageCache) !void {
    var title_buf: [256]u8 = undefined;
    var title: std.Io.Writer = .fixed(&title_buf);

    for (cache.entries.items(.key), cache.entries.items(.value)) |k, *v| {
        if (v.* != .pending_conversion) continue;
        switch (v.pending_conversion) {
            .qoi => {
                if (std.fs.cwd().openFile(strings.slice(k), .{})) |f| {
                    var buf: [4096]u8 = undefined;
                    var reader = f.readerStreaming(&buf);
                    v.* = .{ .image = try imageFromQoi(self.allocator, &reader.interface) };
                } else |_| {}
            },
            _ => |idx| {
                v.* = .{ .image = try convertToQoi(self.allocator, strings.slice(k), strings.slice(converters[@intFromEnum(idx)].convert)) };
            },
        }
    }

    const active_image: usize = 0;
    try title.print("swiv <{s}>\x00", .{strings.slice(cache.keys()[active_image])});
    try self.xdg_toplevel.set_title(self.conn, title.buffered()[0 .. title.buffered().len - 1 :0]);
    try title.flush();
    self.image_buffer.deinit(self.conn);
    self.image_buffer = try .initImageBuffer(self.conn, self.global.shm, cache.values()[active_image].image);
    try self.image_buffer.applyToSurface(self.conn, self.image_surface);

    while (true) try self.recv(self.conn);
}

fn deinit(self: *@This()) void {
    self.main_buffer.deinit(self.conn);
    self.image_buffer.deinit(self.conn);
    self.* = undefined;
}

fn recvFn(conn: *shimizu.Connection) !void {
    var posix_conn: *shimizu.posix.Connection = @fieldParentPtr("connection", conn);
    try posix_conn.recv();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var strings: Strings = .empty;
    defer strings.deinit(gpa.allocator());

    var cache: ImageCache = .empty;
    defer cache.deinit(gpa.allocator());

    {
        var args = try std.process.argsWithAllocator(gpa.allocator());
        defer args.deinit();
        _ = args.skip();
        while (args.next()) |arg| {
            const range = try strings.append(gpa.allocator(), arg);
            try cache.put(gpa.allocator(), range, .pending_identification);
        }
    }

    if (cache.count() == 0) {
        log.err("usage: swiv [paths...]", .{});
        std.process.exit(1);
    }

    var env = try std.process.getEnvMap(gpa.allocator());
    defer env.deinit();

    const converters = try getConverters(gpa.allocator(), &env, &strings);
    defer gpa.allocator().free(converters);
    for (converters) |c| {
        log.info("{s}: [{s}] [{s}]", .{ strings.slice(c.name), strings.slice(c.check), strings.slice(c.convert) });
    }

    for (cache.entries.items(.key), cache.entries.items(.value)) |k, *v| {
        if (v.* != .pending_identification) continue;
        if (dekoodaaja.qoi.detectExtension(strings.slice(k))) {
            v.* = .{ .pending_conversion = .qoi };
        } else {
            for (converters, 0..) |c, idx| {
                if (try identify(gpa.allocator(), strings.slice(k), strings.slice(c.check))) {
                    v.* = .{ .pending_conversion = @enumFromInt(idx) };
                    break;
                }
            } else {
                v.* = .no_converter;
            }
        }
    }

    var posix_conn = try shimizu.posix.Connection.open(gpa.allocator(), .{});
    defer posix_conn.close();

    var app: @This() = undefined;
    try app.init(gpa.allocator(), &posix_conn.connection, posix_conn.getDisplay(), recvFn);
    defer app.deinit();
    try app.run(&strings, converters, cache);
}
