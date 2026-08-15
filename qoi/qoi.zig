const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub const Header = struct {
    w: u32,
    h: u32,
    channels: Channels,
    colorspace: Colorspace,
};

const Op = packed struct(u8) {
    data: u6,
    tag: u2,
};

const Pixel = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    const black: @This() = .{ .r = 0, .g = 0, .b = 0, .a = 0xff };
    const transparent: @This() = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    fn hash(self: @This()) u6 {
        // vectorized version seems slower on my machine
        return @truncate(self.r *% 3 +% self.g *% 5 +% self.b *% 7 +% self.a *% 11);
    }

    fn toVector(self: @This()) @Vector(4, u8) {
        return @bitCast(self);
    }

    fn diffRgb(self: @This(), data: u6) @This() {
        const Stream = packed struct(u6) { b: u2, g: u2, r: u2 };
        const diff: Stream = @bitCast(data);
        const bias: @Vector(4, i8) = .{ -2, -2, -2, 0 };
        const vec: @Vector(4, i8) = .{ diff.b, diff.g, diff.r, 0 };
        return @bitCast(self.toVector() +% @as(@Vector(4, u8), @bitCast(vec + bias)));
    }

    fn diffLuma(self: @This(), data: u6, extra: u8) @This() {
        const Stream = packed struct(u16) { g: u6, _: u2, b: u4, r: u4 };
        const payload: [2]u8 = .{ data, extra };
        const diff: Stream = @bitCast(payload);
        const g: @Vector(4, i8) = .{ diff.g, 0, diff.g, 0 };
        const bias: @Vector(4, i8) = .{ -40, -32, -40, 0 };
        const vec: @Vector(4, i8) = .{ diff.b, diff.g, diff.r, 0 };
        return @bitCast(self.toVector() +% @as(@Vector(4, u8), @bitCast(vec + g + bias)));
    }

    fn fromRgb(rgb: [3]u8, a: u8) @This() {
        return fromRgba(.{ rgb[0], rgb[1], rgb[2], a });
    }

    fn fromRgba(rgba: [4]u8) @This() {
        const swizzle: @Vector(4, u8) = .{ 2, 1, 0, 3 };
        return @bitCast(@shuffle(u8, rgba, undefined, swizzle));
    }
};

/// Decode QOI image from source
/// Writes pixels in [31:0] A:R:G:B 8:8:8:8 format (BGRA little-endian) to the sink
pub fn decode(source: *std.Io.Reader, sink: *std.Io.Writer) !Header {
    var magic: [4]u8 = undefined;
    try source.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, "qoif")) return error.InvalidHeader;

    const hdr: Header = .{
        .w = try source.takeInt(u32, .big),
        .h = try source.takeInt(u32, .big),
        .channels = try source.takeEnum(Channels, native_endian),
        .colorspace = try source.takeEnum(Colorspace, native_endian),
    };

    const start = sink.end;
    const raw_size = hdr.w * hdr.h * @sizeOf(Pixel);
    const buffer = (try sink.writableSliceGreedy(raw_size))[0..raw_size];

    var pixel: Pixel = .black;
    var lut: [64]Pixel = undefined;
    @memset(&lut, .transparent);
    loop: while (sink.end < raw_size) {
        var remaining = std.mem.bytesAsSlice(Pixel, buffer[sink.end - start ..]);
        const op = try source.takeStruct(Op, native_endian);
        switch (op.tag) {
            0b00 => {
                pixel = lut[op.data];
                remaining[0] = pixel;
                sink.advance(@sizeOf(Pixel));
                continue :loop;
            },
            0b01 => pixel = pixel.diffRgb(op.data),
            0b10 => pixel = pixel.diffLuma(op.data, try source.takeByte()),
            0b11 => switch (op.data) {
                0b111110 => pixel = Pixel.fromRgb((try source.takeArray(3)).*, pixel.a),
                0b111111 => pixel = Pixel.fromRgba((try source.takeArray(4)).*),
                0 => {
                    remaining[0] = pixel;
                    sink.advance(@sizeOf(Pixel));
                    continue :loop;
                },
                else => |data| {
                    const count: usize = data + 1;
                    std.debug.assert(count > 1 and count <= 62);
                    @memset(remaining[0..count], pixel);
                    sink.advance(count * @sizeOf(Pixel));
                    continue :loop;
                },
            },
        }
        remaining[0] = pixel;
        sink.advance(@sizeOf(Pixel));
        lut[pixel.hash()] = pixel;
    }

    std.debug.assert(sink.end == raw_size);
    return hdr;
}
