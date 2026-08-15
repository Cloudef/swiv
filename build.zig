const std = @import("std");
const shimizu = @import("shimizu");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_dep = b.dependency("wayland", .{});
    const wayland_protocols_dep = b.dependency("wayland-protocols", .{});

    const shimizu_dep = b.dependency("shimizu", .{
        .target = target,
        .optimize = optimize,
    });

    const known_folders_dep = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });

    const wayland_unstable_dir = shimizu.generateProtocolZig(shimizu_dep.builder, shimizu_dep.artifact("shimizu-scanner"), .{
        .output_directory_name = "wayland-unstable",
        .source_files = &.{
            wayland_protocols_dep.path("stable/xdg-shell/xdg-shell.xml"),
            wayland_protocols_dep.path("stable/viewporter/viewporter.xml"),
            wayland_protocols_dep.path("staging/single-pixel-buffer/single-pixel-buffer-v1.xml"),
            wayland_protocols_dep.path("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"),
        },
        .interface_versions = &.{
            .{ .interface = "zxdg_decoration_manager_v1", .version = 1 },
        },
        .imports = &.{
            .{ .file = wayland_dep.path("protocol/wayland.xml"), .import_string = "@import(\"core\")" },
        },
    });

    const wayland_unstable = b.createModule(.{
        .root_source_file = wayland_unstable_dir.output_directory.?.path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "wire", .module = shimizu_dep.module("wire") },
            .{ .name = "core", .module = shimizu_dep.module("core") },
            .{ .name = "wayland-protocols", .module = shimizu_dep.module("wayland-protocols") },
        },
    });

    const dekoodaaja = b.dependency("dekoodaaja", .{ .target = target, .optimize = optimize }).module("dekoodaaja");

    const exe = b.addExecutable(.{
        .name = "swiv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .link_libc = false,
            .imports = &.{
                .{ .name = "known_folders", .module = known_folders_dep.module("known-folders") },
                .{ .name = "shimizu", .module = shimizu_dep.module("shimizu") },
                .{ .name = "wayland-protocols", .module = wayland_unstable },
                .{ .name = "dekoodaaja", .module = dekoodaaja },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run swiv");
    run_step.dependOn(&run.step);
}
