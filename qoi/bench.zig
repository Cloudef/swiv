const std = @import("std");
const qoi = @import("qoi.zig");

const total_rounds = 4096;

pub fn main() !void {
    const progress = std.Progress.start(.{});
    try perform(progress);
}

fn perform(progress: std.Progress.Node) !void {
    const allocator = std.heap.smp_allocator;

    const source_data = @embedFile("zero.qoi");
    const ref_data = D: {
        const data: []align(1) const u32 = comptime std.mem.bytesAsSlice(u32, @embedFile("zero.raw"));
        var swizzled: [data.len]u32 = undefined;
        for (data, &swizzled) |*src, *dst| {
            const vec: @Vector(4, u8) = @bitCast(src.*);
            const swizzle: @Vector(4, u8) = .{ 2, 1, 0, 3 };
            dst.* = @bitCast(@shuffle(u8, vec, undefined, swizzle));
        }
        break :D swizzled;
    };

    const benchmark = progress.start("Benchmark", total_rounds);

    var total_time: u64 = 0;

    var rounds: usize = total_rounds;
    while (rounds > 0) {
        rounds -= 1;

        const start_point = std.time.nanoTimestamp();
        var reader: std.Io.Reader = .fixed(source_data);
        var allocating: std.Io.Writer.Allocating = .init(allocator);
        defer allocating.deinit();
        const hdr = try qoi.decode(&reader, &allocating.writer);
        const end_point = std.time.nanoTimestamp();

        if (hdr.w != 512 or hdr.h != 512)
            return error.DecodingError;

        if (!std.mem.eql(u8, std.mem.sliceAsBytes(&ref_data), allocating.written()))
            return error.DecodingError;

        total_time += @as(u64, @intCast(end_point - start_point));
        benchmark.completeOne();
    }

    std.debug.print("Decoding time for {} => {} bytes: {D}\n", .{
        source_data.len,
        ref_data.len * @sizeOf(u32),
        total_time / total_rounds,
    });
}
