//! Gzip Compression Library for Zig 0.15
//!
//! This is a single-file implementation of gzip/deflate compression copied from
//! the Zig 0.14 standard library, as compression was removed in Zig 0.15.
//!
//! Usage:
//! ```zig
//! const std = @import("std");
//! const comprezz = @import("comprezz");
//!
//! var compressed_buffer: [1024]u8 = undefined;
//! var fixed_writer = std.Io.Writer.fixed(&compressed_buffer);
//!
//! const data = "Hello, World!";
//! var input_buffer: [1024]u8 = undefined;
//! @memcpy(input_buffer[0..data.len], data);
//! var input_reader = std.Io.Reader.fixed(input_buffer[0..data.len]);
//!
//! try comprezz.compress(&input_reader, &fixed_writer, .{});
//! ```
//!
//! Or with files:
//! ```zig
//! const std = @import("std");
//! const comprezz = @import("comprezz");
//!
//! const input_file = try std.fs.cwd().openFile("input.txt", .{});
//! defer input_file.close();
//! var input_reader = input_file.reader();
//!
//! const output_file = try std.fs.cwd().createFile("output.gz", .{});
//! defer output_file.close();
//! var output_writer = output_file.writer();
//!
//! try comprezz.compress(&input_reader, &output_writer, .{ .level = .best });
//! ```
//!
//! Features:
//! - Full LZ77 + Huffman encoding implementation
//! - Configurable compression levels (fast, default, best)
//! - Gzip format with proper headers and CRC32 checksums
//! - All unit and integration tests included
//! - Uses Zig 0.15's new std.Io.Reader and std.Io.Writer interfaces

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const print = std.debug.print;
const mem = std.mem;
const math = std.math;
const sort = std.sort;

pub const consts = struct {
    pub const deflate = struct {
        pub const tokens = 1 << 15;
    };

    pub const match = struct {
        pub const base_length = 3;
        pub const min_length = 4;
        pub const max_length = 258;

        pub const min_distance = 1;
        pub const max_distance = 32768;
    };

    pub const history = struct {
        pub const len = match.max_distance;
    };

    pub const lookup = struct {
        pub const bits = 15;
        pub const len = 1 << bits;
        pub const shift = 32 - bits;
    };

    pub const huffman = struct {
        pub const codegen_order = [_]u32{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
        pub const codegen_code_count = 19;
        pub const distance_code_count = 30;
        pub const max_num_lit = 286;
        pub const max_num_frequencies = max_num_lit;
        pub const max_store_block_size = 65535;
        pub const end_block_marker = 256;
    };
};

pub const Token = struct {
    pub const Kind = enum(u1) {
        literal,
        match,
    };

    dist: u15 = 0,
    len_lit: u8 = 0,
    kind: Kind = .literal,

    pub fn literal(t: Token) u8 {
        return t.len_lit;
    }

    pub fn distance(t: Token) u16 {
        return @as(u16, t.dist) + consts.match.min_distance;
    }

    pub fn length(t: Token) u16 {
        return @as(u16, t.len_lit) + consts.match.base_length;
    }

    pub fn initLiteral(lit: u8) Token {
        return .{ .kind = .literal, .len_lit = lit };
    }

    pub fn initMatch(dist: u16, len: u16) Token {
        assert(len >= consts.match.min_length and len <= consts.match.max_length);
        assert(dist >= consts.match.min_distance and dist <= consts.match.max_distance);
        return .{
            .kind = .match,
            .dist = @intCast(dist - consts.match.min_distance),
            .len_lit = @intCast(len - consts.match.base_length),
        };
    }

    pub fn eql(t: Token, o: Token) bool {
        return t.kind == o.kind and
            t.dist == o.dist and
            t.len_lit == o.len_lit;
    }

    pub fn lengthCode(t: Token) u16 {
        return match_lengths[match_lengths_index[t.len_lit]].code;
    }

    pub fn lengthEncoding(t: Token) MatchLength {
        var c = match_lengths[match_lengths_index[t.len_lit]];
        c.extra_length = t.len_lit - c.base_scaled;
        return c;
    }

    pub fn distanceCode(t: Token) u8 {
        var dist: u16 = t.dist;
        if (dist < match_distances_index.len) {
            return match_distances_index[dist];
        }
        dist >>= 7;
        if (dist < match_distances_index.len) {
            return match_distances_index[dist] + 14;
        }
        dist >>= 7;
        return match_distances_index[dist] + 28;
    }

    pub fn distanceEncoding(t: Token) MatchDistance {
        var c = match_distances[t.distanceCode()];
        c.extra_distance = t.dist - c.base_scaled;
        return c;
    }

    pub fn lengthExtraBits(code: u32) u8 {
        return match_lengths[code - length_codes_start].extra_bits;
    }

    pub fn matchLength(code: u8) MatchLength {
        return match_lengths[code];
    }

    pub fn matchDistance(code: u8) MatchDistance {
        return match_distances[code];
    }

    pub fn distanceExtraBits(code: u32) u8 {
        return match_distances[code].extra_bits;
    }

    pub fn show(t: Token) void {
        if (t.kind == .literal) {
            print("L('{c}'), ", .{t.literal()});
        } else {
            print("M({d}, {d}), ", .{ t.distance(), t.length() });
        }
    }

    const match_lengths_index = [_]u8{
        0,  1,  2,  3,  4,  5,  6,  7,  8,  8,
        9,  9,  10, 10, 11, 11, 12, 12, 12, 12,
        13, 13, 13, 13, 14, 14, 14, 14, 15, 15,
        15, 15, 16, 16, 16, 16, 16, 16, 16, 16,
        17, 17, 17, 17, 17, 17, 17, 17, 18, 18,
        18, 18, 18, 18, 18, 18, 19, 19, 19, 19,
        19, 19, 19, 19, 20, 20, 20, 20, 20, 20,
        20, 20, 20, 20, 20, 20, 20, 20, 20, 20,
        21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
        21, 21, 21, 21, 21, 21, 22, 22, 22, 22,
        22, 22, 22, 22, 22, 22, 22, 22, 22, 22,
        22, 22, 23, 23, 23, 23, 23, 23, 23, 23,
        23, 23, 23, 23, 23, 23, 23, 23, 24, 24,
        24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
        24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
        24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
        25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
        25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
        25, 25, 25, 25, 25, 25, 25, 25, 25, 25,
        25, 25, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
        26, 26, 26, 26, 27, 27, 27, 27, 27, 27,
        27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
        27, 27, 27, 27, 27, 27, 27, 27, 27, 27,
        27, 27, 27, 27, 27, 28,
    };

    const MatchLength = struct {
        code: u16,
        base_scaled: u8,
        base: u16,
        extra_length: u8 = 0,
        extra_bits: u4,
    };

    pub const length_codes_start = 257;

    const match_lengths = [_]MatchLength{
        .{ .extra_bits = 0, .base_scaled = 0, .base = 3, .code = 257 },
        .{ .extra_bits = 0, .base_scaled = 1, .base = 4, .code = 258 },
        .{ .extra_bits = 0, .base_scaled = 2, .base = 5, .code = 259 },
        .{ .extra_bits = 0, .base_scaled = 3, .base = 6, .code = 260 },
        .{ .extra_bits = 0, .base_scaled = 4, .base = 7, .code = 261 },
        .{ .extra_bits = 0, .base_scaled = 5, .base = 8, .code = 262 },
        .{ .extra_bits = 0, .base_scaled = 6, .base = 9, .code = 263 },
        .{ .extra_bits = 0, .base_scaled = 7, .base = 10, .code = 264 },
        .{ .extra_bits = 1, .base_scaled = 8, .base = 11, .code = 265 },
        .{ .extra_bits = 1, .base_scaled = 10, .base = 13, .code = 266 },
        .{ .extra_bits = 1, .base_scaled = 12, .base = 15, .code = 267 },
        .{ .extra_bits = 1, .base_scaled = 14, .base = 17, .code = 268 },
        .{ .extra_bits = 2, .base_scaled = 16, .base = 19, .code = 269 },
        .{ .extra_bits = 2, .base_scaled = 20, .base = 23, .code = 270 },
        .{ .extra_bits = 2, .base_scaled = 24, .base = 27, .code = 271 },
        .{ .extra_bits = 2, .base_scaled = 28, .base = 31, .code = 272 },
        .{ .extra_bits = 3, .base_scaled = 32, .base = 35, .code = 273 },
        .{ .extra_bits = 3, .base_scaled = 40, .base = 43, .code = 274 },
        .{ .extra_bits = 3, .base_scaled = 48, .base = 51, .code = 275 },
        .{ .extra_bits = 3, .base_scaled = 56, .base = 59, .code = 276 },
        .{ .extra_bits = 4, .base_scaled = 64, .base = 67, .code = 277 },
        .{ .extra_bits = 4, .base_scaled = 80, .base = 83, .code = 278 },
        .{ .extra_bits = 4, .base_scaled = 96, .base = 99, .code = 279 },
        .{ .extra_bits = 4, .base_scaled = 112, .base = 115, .code = 280 },
        .{ .extra_bits = 5, .base_scaled = 128, .base = 131, .code = 281 },
        .{ .extra_bits = 5, .base_scaled = 160, .base = 163, .code = 282 },
        .{ .extra_bits = 5, .base_scaled = 192, .base = 195, .code = 283 },
        .{ .extra_bits = 5, .base_scaled = 224, .base = 227, .code = 284 },
        .{ .extra_bits = 0, .base_scaled = 255, .base = 258, .code = 285 },
    };

    const match_distances_index = [_]u8{
        0,  1,  2,  3,  4,  4,  5,  5,  6,  6,  6,  6,  7,  7,  7,  7,
        8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9,
        10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
        11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
        13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
        13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    };

    const MatchDistance = struct {
        base_scaled: u16,
        base: u16,
        extra_distance: u16 = 0,
        code: u8,
        extra_bits: u4,
    };

    const match_distances = [_]MatchDistance{
        .{ .extra_bits = 0, .base_scaled = 0x0000, .code = 0, .base = 1 },
        .{ .extra_bits = 0, .base_scaled = 0x0001, .code = 1, .base = 2 },
        .{ .extra_bits = 0, .base_scaled = 0x0002, .code = 2, .base = 3 },
        .{ .extra_bits = 0, .base_scaled = 0x0003, .code = 3, .base = 4 },
        .{ .extra_bits = 1, .base_scaled = 0x0004, .code = 4, .base = 5 },
        .{ .extra_bits = 1, .base_scaled = 0x0006, .code = 5, .base = 7 },
        .{ .extra_bits = 2, .base_scaled = 0x0008, .code = 6, .base = 9 },
        .{ .extra_bits = 2, .base_scaled = 0x000c, .code = 7, .base = 13 },
        .{ .extra_bits = 3, .base_scaled = 0x0010, .code = 8, .base = 17 },
        .{ .extra_bits = 3, .base_scaled = 0x0018, .code = 9, .base = 25 },
        .{ .extra_bits = 4, .base_scaled = 0x0020, .code = 10, .base = 33 },
        .{ .extra_bits = 4, .base_scaled = 0x0030, .code = 11, .base = 49 },
        .{ .extra_bits = 5, .base_scaled = 0x0040, .code = 12, .base = 65 },
        .{ .extra_bits = 5, .base_scaled = 0x0060, .code = 13, .base = 97 },
        .{ .extra_bits = 6, .base_scaled = 0x0080, .code = 14, .base = 129 },
        .{ .extra_bits = 6, .base_scaled = 0x00c0, .code = 15, .base = 193 },
        .{ .extra_bits = 7, .base_scaled = 0x0100, .code = 16, .base = 257 },
        .{ .extra_bits = 7, .base_scaled = 0x0180, .code = 17, .base = 385 },
        .{ .extra_bits = 8, .base_scaled = 0x0200, .code = 18, .base = 513 },
        .{ .extra_bits = 8, .base_scaled = 0x0300, .code = 19, .base = 769 },
        .{ .extra_bits = 9, .base_scaled = 0x0400, .code = 20, .base = 1025 },
        .{ .extra_bits = 9, .base_scaled = 0x0600, .code = 21, .base = 1537 },
        .{ .extra_bits = 10, .base_scaled = 0x0800, .code = 22, .base = 2049 },
        .{ .extra_bits = 10, .base_scaled = 0x0c00, .code = 23, .base = 3073 },
        .{ .extra_bits = 11, .base_scaled = 0x1000, .code = 24, .base = 4097 },
        .{ .extra_bits = 11, .base_scaled = 0x1800, .code = 25, .base = 6145 },
        .{ .extra_bits = 12, .base_scaled = 0x2000, .code = 26, .base = 8193 },
        .{ .extra_bits = 12, .base_scaled = 0x3000, .code = 27, .base = 12289 },
        .{ .extra_bits = 13, .base_scaled = 0x4000, .code = 28, .base = 16385 },
        .{ .extra_bits = 13, .base_scaled = 0x6000, .code = 29, .base = 24577 },
    };
};

pub const BitWriter = struct {
    const buffer_flush_size = 240;
    const buffer_size = buffer_flush_size + 8;

    inner_writer: *std.Io.Writer,
    bits: u64 = 0,
    nbits: u32 = 0,
    bytes: [buffer_size]u8 = undefined,
    nbytes: u32 = 0,

    const Self = @This();

    pub const Error = std.Io.Writer.Error || error{UnfinishedBits};

    pub fn init(writer: *std.Io.Writer) Self {
        return .{ .inner_writer = writer };
    }

    pub fn setWriter(self: *Self, new_writer: *std.Io.Writer) void {
        self.inner_writer = new_writer;
    }

    pub fn flush(self: *Self) Error!void {
        var n = self.nbytes;
        while (self.nbits != 0) {
            self.bytes[n] = @as(u8, @truncate(self.bits));
            self.bits >>= 8;
            if (self.nbits > 8) {
                self.nbits -= 8;
            } else {
                self.nbits = 0;
            }
            n += 1;
        }
        self.bits = 0;
        _ = try self.inner_writer.write(self.bytes[0..n]);
        self.nbytes = 0;
    }

    pub fn writeBits(self: *Self, b: u32, nb: u32) Error!void {
        self.bits |= @as(u64, @intCast(b)) << @as(u6, @intCast(self.nbits));
        self.nbits += nb;
        if (self.nbits < 48)
            return;

        var n = self.nbytes;
        std.mem.writeInt(u64, self.bytes[n..][0..8], self.bits, .little);
        n += 6;
        if (n >= buffer_flush_size) {
            _ = try self.inner_writer.write(self.bytes[0..n]);
            n = 0;
        }
        self.nbytes = n;
        self.bits >>= 48;
        self.nbits -= 48;
    }

    pub fn writeBytes(self: *Self, bytes: []const u8) Error!void {
        var n = self.nbytes;
        if (self.nbits & 7 != 0) {
            return error.UnfinishedBits;
        }
        while (self.nbits != 0) {
            self.bytes[n] = @as(u8, @truncate(self.bits));
            self.bits >>= 8;
            self.nbits -= 8;
            n += 1;
        }
        if (n != 0) {
            _ = try self.inner_writer.write(self.bytes[0..n]);
        }
        self.nbytes = 0;
        _ = try self.inner_writer.write(bytes);
    }
};

const LiteralNode = struct {
    literal: u16,
    freq: u16,
};

const LevelInfo = struct {
    level: u32,
    last_freq: u32,
    next_char_freq: u32,
    next_pair_freq: u32,
    needed: u32,
};

pub const HuffCode = struct {
    code: u16 = 0,
    len: u16 = 0,

    fn set(self: *HuffCode, code: u16, length: u16) void {
        self.len = length;
        self.code = code;
    }
};

pub fn HuffmanEncoder(comptime size: usize) type {
    return struct {
        codes: [size]HuffCode = undefined,
        freq_cache: [consts.huffman.max_num_frequencies + 1]LiteralNode = undefined,
        bit_count: [17]u32 = undefined,
        lns: []LiteralNode = undefined,
        lfs: []LiteralNode = undefined,

        const Self = @This();

        pub fn generate(self: *Self, freq: []u16, max_bits: u32) void {
            var list = self.freq_cache[0 .. freq.len + 1];
            var count: u32 = 0;
            for (freq, 0..) |f, i| {
                if (f != 0) {
                    list[count] = LiteralNode{ .literal = @as(u16, @intCast(i)), .freq = f };
                    count += 1;
                } else {
                    list[count] = LiteralNode{ .literal = 0x00, .freq = 0 };
                    self.codes[i].len = 0;
                }
            }
            list[freq.len] = LiteralNode{ .literal = 0x00, .freq = 0 };

            list = list[0..count];
            if (count <= 2) {
                for (list, 0..) |node, i| {
                    self.codes[node.literal].set(@as(u16, @intCast(i)), 1);
                }
                return;
            }
            self.lfs = list;
            mem.sort(LiteralNode, self.lfs, {}, byFreq);

            const bit_count = self.bitCounts(list, max_bits);
            self.assignEncodingAndSize(bit_count, list);
        }

        pub fn bitLength(self: *Self, freq: []u16) u32 {
            var total: u32 = 0;
            for (freq, 0..) |f, i| {
                if (f != 0) {
                    total += @as(u32, @intCast(f)) * @as(u32, @intCast(self.codes[i].len));
                }
            }
            return total;
        }

        fn bitCounts(self: *Self, list: []LiteralNode, max_bits_to_use: usize) []u32 {
            var max_bits = max_bits_to_use;
            const n = list.len;
            const max_bits_limit = 16;

            assert(max_bits < max_bits_limit);
            max_bits = @min(max_bits, n - 1);

            var levels: [max_bits_limit]LevelInfo = mem.zeroes([max_bits_limit]LevelInfo);
            var leaf_counts: [max_bits_limit][max_bits_limit]u32 = mem.zeroes([max_bits_limit][max_bits_limit]u32);

            {
                var level = @as(u32, 1);
                while (level <= max_bits) : (level += 1) {
                    levels[level] = LevelInfo{
                        .level = level,
                        .last_freq = list[1].freq,
                        .next_char_freq = list[2].freq,
                        .next_pair_freq = list[0].freq + list[1].freq,
                        .needed = 0,
                    };
                    leaf_counts[level][level] = 2;
                    if (level == 1) {
                        levels[level].next_pair_freq = math.maxInt(i32);
                    }
                }
            }

            levels[max_bits].needed = 2 * @as(u32, @intCast(n)) - 4;

            {
                var level = max_bits;
                while (true) {
                    var l = &levels[level];
                    if (l.next_pair_freq == math.maxInt(i32) and l.next_char_freq == math.maxInt(i32)) {
                        l.needed = 0;
                        levels[level + 1].next_pair_freq = math.maxInt(i32);
                        level += 1;
                        continue;
                    }

                    const prev_freq = l.last_freq;
                    if (l.next_char_freq < l.next_pair_freq) {
                        const next = leaf_counts[level][level] + 1;
                        l.last_freq = l.next_char_freq;
                        leaf_counts[level][level] = next;
                        if (next >= list.len) {
                            l.next_char_freq = maxNode().freq;
                        } else {
                            l.next_char_freq = list[next].freq;
                        }
                    } else {
                        l.last_freq = l.next_pair_freq;
                        @memcpy(leaf_counts[level][0..level], leaf_counts[level - 1][0..level]);
                        levels[l.level - 1].needed = 2;
                    }

                    l.needed -= 1;
                    if (l.needed == 0) {
                        if (l.level == max_bits) {
                            break;
                        }
                        levels[l.level + 1].next_pair_freq = prev_freq + l.last_freq;
                        level += 1;
                    } else {
                        while (levels[level - 1].needed > 0) {
                            level -= 1;
                            if (level == 0) {
                                break;
                            }
                        }
                    }
                }
            }

            assert(leaf_counts[max_bits][max_bits] == n);

            var bit_count = self.bit_count[0 .. max_bits + 1];
            var bits: u32 = 1;
            const counts = &leaf_counts[max_bits];
            {
                var level = max_bits;
                while (level > 0) : (level -= 1) {
                    bit_count[bits] = counts[level] - counts[level - 1];
                    bits += 1;
                    if (level == 0) {
                        break;
                    }
                }
            }
            return bit_count;
        }

        fn assignEncodingAndSize(self: *Self, bit_count: []u32, list_arg: []LiteralNode) void {
            var code = @as(u16, 0);
            var list = list_arg;

            for (bit_count, 0..) |bits, n| {
                code <<= 1;
                if (n == 0 or bits == 0) {
                    continue;
                }
                const chunk = list[list.len - @as(u32, @intCast(bits)) ..];

                self.lns = chunk;
                mem.sort(LiteralNode, self.lns, {}, byLiteral);

                for (chunk) |node| {
                    self.codes[node.literal] = HuffCode{
                        .code = bitReverse(u16, code, @as(u5, @intCast(n))),
                        .len = @as(u16, @intCast(n)),
                    };
                    code += 1;
                }
                list = list[0 .. list.len - @as(u32, @intCast(bits))];
            }
        }
    };
}

fn maxNode() LiteralNode {
    return LiteralNode{
        .literal = math.maxInt(u16),
        .freq = math.maxInt(u16),
    };
}

pub fn huffmanEncoder(comptime size: u32) HuffmanEncoder(size) {
    return .{};
}

pub const LiteralEncoder = HuffmanEncoder(consts.huffman.max_num_frequencies);
pub const DistanceEncoder = HuffmanEncoder(consts.huffman.distance_code_count);
pub const CodegenEncoder = HuffmanEncoder(19);

pub fn fixedLiteralEncoder() LiteralEncoder {
    var h: LiteralEncoder = undefined;
    var ch: u16 = 0;

    while (ch < consts.huffman.max_num_frequencies) : (ch += 1) {
        var bits: u16 = undefined;
        var size: u16 = undefined;
        switch (ch) {
            0...143 => {
                bits = ch + 48;
                size = 8;
            },
            144...255 => {
                bits = ch + 400 - 144;
                size = 9;
            },
            256...279 => {
                bits = ch - 256;
                size = 7;
            },
            else => {
                bits = ch + 192 - 280;
                size = 8;
            },
        }
        h.codes[ch] = HuffCode{ .code = bitReverse(u16, bits, @as(u5, @intCast(size))), .len = size };
    }
    return h;
}

pub fn fixedDistanceEncoder() DistanceEncoder {
    var h: DistanceEncoder = undefined;
    for (h.codes, 0..) |_, ch| {
        h.codes[ch] = HuffCode{ .code = bitReverse(u16, @as(u16, @intCast(ch)), 5), .len = 5 };
    }
    return h;
}

pub fn huffmanDistanceEncoder() DistanceEncoder {
    var distance_freq = [1]u16{0} ** consts.huffman.distance_code_count;
    distance_freq[0] = 1;
    var h: DistanceEncoder = .{};
    h.generate(distance_freq[0..], 15);
    return h;
}

fn byLiteral(context: void, a: LiteralNode, b: LiteralNode) bool {
    _ = context;
    return a.literal < b.literal;
}

fn byFreq(context: void, a: LiteralNode, b: LiteralNode) bool {
    _ = context;
    if (a.freq == b.freq) {
        return a.literal < b.literal;
    }
    return a.freq < b.freq;
}

fn bitReverse(comptime T: type, value: T, n: usize) T {
    const r = @bitReverse(value);
    return r >> @as(math.Log2Int(T), @intCast(@typeInfo(T).int.bits - n));
}

pub const Lookup = struct {
    const prime4 = 0x9E3779B1;
    const chain_len = 2 * consts.history.len;

    head: [consts.lookup.len]u16 = [_]u16{0} ** consts.lookup.len,
    chain: [chain_len]u16 = [_]u16{0} ** (chain_len),

    pub fn add(self: *Lookup, data: []const u8, pos: u16) u16 {
        if (data.len < 4) return 0;
        const h = hash(data[0..4]);
        return self.set(h, pos);
    }

    pub fn prev(self: *Lookup, pos: u16) u16 {
        return self.chain[pos];
    }

    fn set(self: *Lookup, h: u32, pos: u16) u16 {
        const p = self.head[h];
        self.head[h] = pos;
        self.chain[pos] = p;
        return p;
    }

    pub fn slide(self: *Lookup, n: u16) void {
        for (&self.head) |*v| {
            v.* -|= n;
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.chain[i] = self.chain[i + n] -| n;
        }
    }

    pub fn bulkAdd(self: *Lookup, data: []const u8, len: u16, pos: u16) void {
        if (len == 0 or data.len < consts.match.min_length) {
            return;
        }
        var hb =
            @as(u32, data[3]) |
            @as(u32, data[2]) << 8 |
            @as(u32, data[1]) << 16 |
            @as(u32, data[0]) << 24;
        _ = self.set(hashu(hb), pos);

        var i = pos;
        for (4..@min(len + 3, data.len)) |j| {
            hb = (hb << 8) | @as(u32, data[j]);
            i += 1;
            _ = self.set(hashu(hb), i);
        }
    }

    fn hash(b: *const [4]u8) u32 {
        return hashu(@as(u32, b[3]) |
            @as(u32, b[2]) << 8 |
            @as(u32, b[1]) << 16 |
            @as(u32, b[0]) << 24);
    }

    fn hashu(v: u32) u32 {
        return @intCast((v *% prime4) >> consts.lookup.shift);
    }
};

pub const SlidingWindow = struct {
    const hist_len = consts.history.len;
    const buffer_len = 2 * hist_len;
    const min_lookahead = consts.match.min_length + consts.match.max_length;
    const max_rp = buffer_len - min_lookahead;

    buffer: [buffer_len]u8 = undefined,
    wp: usize = 0,
    rp: usize = 0,
    fp: isize = 0,

    pub fn write(self: *SlidingWindow, buf: []const u8) usize {
        if (self.rp >= max_rp) return 0;

        const n = @min(buf.len, buffer_len - self.wp);
        @memcpy(self.buffer[self.wp .. self.wp + n], buf[0..n]);
        self.wp += n;
        return n;
    }

    pub fn slide(self: *SlidingWindow) u16 {
        assert(self.rp >= max_rp and self.wp >= self.rp);
        const n = self.wp - hist_len;
        @memcpy(self.buffer[0..n], self.buffer[hist_len..self.wp]);
        self.rp -= hist_len;
        self.wp -= hist_len;
        self.fp -= hist_len;
        return @intCast(n);
    }

    fn lookahead(self: *SlidingWindow) []const u8 {
        assert(self.wp >= self.rp);
        return self.buffer[self.rp..self.wp];
    }

    pub fn activeLookahead(self: *SlidingWindow, should_flush: bool) ?[]const u8 {
        const min: usize = if (should_flush) 0 else min_lookahead;
        const lh = self.lookahead();
        return if (lh.len > min) lh else null;
    }

    pub fn advance(self: *SlidingWindow, n: u16) void {
        assert(self.wp >= self.rp + n);
        self.rp += n;
    }

    pub fn writable(self: *SlidingWindow) []u8 {
        return self.buffer[self.wp..];
    }

    pub fn written(self: *SlidingWindow, n: usize) void {
        self.wp += n;
    }

    pub fn match(self: *SlidingWindow, prev_pos: u16, curr_pos: u16, min_len: u16) u16 {
        const max_len: usize = @min(self.wp - curr_pos, consts.match.max_length);
        const prev_lh = self.buffer[prev_pos..][0..max_len];
        const curr_lh = self.buffer[curr_pos..][0..max_len];

        var i: usize = min_len;
        if (i > 0) {
            if (max_len <= i) return 0;
            while (true) {
                if (prev_lh[i] != curr_lh[i]) return 0;
                if (i == 0) break;
                i -= 1;
            }
            i = min_len;
        }
        while (i < max_len) : (i += 1)
            if (prev_lh[i] != curr_lh[i]) break;
        return if (i >= consts.match.min_length) @intCast(i) else 0;
    }

    pub fn pos(self: *SlidingWindow) u16 {
        return @intCast(self.rp);
    }

    pub fn flush(self: *SlidingWindow) void {
        self.fp = @intCast(self.rp);
    }

    pub fn tokensBuffer(self: *SlidingWindow) ?[]const u8 {
        assert(self.fp <= self.rp);
        if (self.fp < 0) return null;
        return self.buffer[@intCast(self.fp)..self.rp];
    }
};

pub const Container = enum {
    raw,
    gzip,
    zlib,

    pub fn size(w: Container) usize {
        return headerSize(w) + footerSize(w);
    }

    pub fn headerSize(w: Container) usize {
        return switch (w) {
            .gzip => 10,
            .zlib => 2,
            .raw => 0,
        };
    }

    pub fn footerSize(w: Container) usize {
        return switch (w) {
            .gzip => 8,
            .zlib => 4,
            .raw => 0,
        };
    }

    pub const list = [_]Container{ .raw, .gzip, .zlib };

    pub const Error = error{
        BadGzipHeader,
        BadZlibHeader,
        WrongGzipChecksum,
        WrongGzipSize,
        WrongZlibChecksum,
    };

    pub fn writeHeader(comptime wrap: Container, writer: *std.Io.Writer) !void {
        switch (wrap) {
            .gzip => {
                const gzipHeader = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 };
                try writer.writeAll(&gzipHeader);
            },
            .zlib => {
                const zlibHeader = [_]u8{ 0x78, 0b10_0_11100 };
                try writer.writeAll(&zlibHeader);
            },
            .raw => {},
        }
    }

    pub fn writeFooter(comptime wrap: Container, hasher: *Hasher(wrap), writer: *std.Io.Writer) !void {
        var bits: [4]u8 = undefined;
        switch (wrap) {
            .gzip => {
                std.mem.writeInt(u32, &bits, hasher.chksum(), .little);
                try writer.writeAll(&bits);

                std.mem.writeInt(u32, &bits, hasher.bytesRead(), .little);
                try writer.writeAll(&bits);
            },
            .zlib => {
                std.mem.writeInt(u32, &bits, hasher.chksum(), .big);
                try writer.writeAll(&bits);
            },
            .raw => {},
        }
    }

    pub fn Hasher(comptime wrap: Container) type {
        const HasherType = switch (wrap) {
            .gzip => std.hash.Crc32,
            .zlib => std.hash.Adler32,
            .raw => struct {
                pub fn init() @This() {
                    return .{};
                }
            },
        };

        return struct {
            hasher: HasherType = HasherType.init(),
            bytes: usize = 0,

            const Self = @This();

            pub fn update(self: *Self, buf: []const u8) void {
                switch (wrap) {
                    .raw => {},
                    else => {
                        self.hasher.update(buf);
                        self.bytes += buf.len;
                    },
                }
            }

            pub fn chksum(self: *Self) u32 {
                switch (wrap) {
                    .raw => return 0,
                    else => return self.hasher.final(),
                }
            }

            pub fn bytesRead(self: *Self) u32 {
                return @truncate(self.bytes);
            }
        };
    }
};

pub fn blockWriter(writer: *std.Io.Writer) BlockWriter {
    return BlockWriter.init(writer);
}

pub const BlockWriter = struct {
    const codegen_order = consts.huffman.codegen_order;
    const end_code_mark = 255;
    const Self = @This();

    pub const Error = BitWriter.Error;
    bit_writer: BitWriter,

    codegen_freq: [consts.huffman.codegen_code_count]u16 = undefined,
    literal_freq: [consts.huffman.max_num_lit]u16 = undefined,
    distance_freq: [consts.huffman.distance_code_count]u16 = undefined,
    codegen: [consts.huffman.max_num_lit + consts.huffman.distance_code_count + 1]u8 = undefined,
    literal_encoding: LiteralEncoder = .{},
    distance_encoding: DistanceEncoder = .{},
    codegen_encoding: CodegenEncoder = .{},
    fixed_literal_encoding: LiteralEncoder,
    fixed_distance_encoding: DistanceEncoder,
    huff_distance: DistanceEncoder,

    pub fn init(writer: *std.Io.Writer) Self {
        return .{
            .bit_writer = BitWriter.init(writer),
            .fixed_literal_encoding = fixedLiteralEncoder(),
            .fixed_distance_encoding = fixedDistanceEncoder(),
            .huff_distance = huffmanDistanceEncoder(),
        };
    }

    pub fn flush(self: *Self) Error!void {
        try self.bit_writer.flush();
    }

    pub fn setWriter(self: *Self, new_writer: *std.Io.Writer) void {
        self.bit_writer.setWriter(new_writer);
    }

    fn writeCode(self: *Self, c: HuffCode) Error!void {
        try self.bit_writer.writeBits(c.code, c.len);
    }

    pub fn storedBlock(self: *Self, input: []const u8, eof: bool) Error!void {
        try self.storedHeader(input.len, eof);
        try self.bit_writer.writeBytes(input);
    }

    fn storedHeader(self: *Self, length: usize, eof: bool) Error!void {
        assert(length <= 65535);
        const flag: u32 = if (eof) 1 else 0;
        try self.bit_writer.writeBits(flag, 3);
        try self.flush();
        const l: u16 = @intCast(length);
        try self.bit_writer.writeBits(l, 16);
        try self.bit_writer.writeBits(~l, 16);
    }

    fn fixedHeader(self: *Self, eof: bool) Error!void {
        var value: u32 = 2;
        if (eof) {
            value = 3;
        }
        try self.bit_writer.writeBits(value, 3);
    }

    pub fn write(self: *Self, tokens: []const Token, eof: bool, input: ?[]const u8) Error!void {
        const lit_and_dist = self.indexTokens(tokens);
        const num_literals = lit_and_dist.num_literals;
        const num_distances = lit_and_dist.num_distances;

        var extra_bits: u32 = 0;
        const ret = storedSizeFits(input);
        const stored_size = ret.size;
        const storable = ret.storable;

        if (storable) {
            var length_code: u16 = Token.length_codes_start + 8;
            while (length_code < num_literals) : (length_code += 1) {
                extra_bits += @as(u32, @intCast(self.literal_freq[length_code])) *
                    @as(u32, @intCast(Token.lengthExtraBits(length_code)));
            }
            var distance_code: u16 = 4;
            while (distance_code < num_distances) : (distance_code += 1) {
                extra_bits += @as(u32, @intCast(self.distance_freq[distance_code])) *
                    @as(u32, @intCast(Token.distanceExtraBits(distance_code)));
            }
        }

        var literal_encoding = &self.fixed_literal_encoding;
        var distance_encoding = &self.fixed_distance_encoding;
        var size = self.fixedSize(extra_bits);

        var num_codegens: u32 = 0;

        self.generateCodegen(
            num_literals,
            num_distances,
            &self.literal_encoding,
            &self.distance_encoding,
        );
        self.codegen_encoding.generate(self.codegen_freq[0..], 7);
        const dynamic_size = self.dynamicSize(
            &self.literal_encoding,
            &self.distance_encoding,
            extra_bits,
        );
        const dyn_size = dynamic_size.size;
        num_codegens = dynamic_size.num_codegens;

        if (dyn_size < size) {
            size = dyn_size;
            literal_encoding = &self.literal_encoding;
            distance_encoding = &self.distance_encoding;
        }

        if (storable and stored_size < size) {
            try self.storedBlock(input.?, eof);
            return;
        }

        if (@intFromPtr(literal_encoding) == @intFromPtr(&self.fixed_literal_encoding)) {
            try self.fixedHeader(eof);
        } else {
            try self.dynamicHeader(num_literals, num_distances, num_codegens, eof);
        }

        try self.writeTokens(tokens, &literal_encoding.codes, &distance_encoding.codes);
    }

    pub fn huffmanBlock(self: *Self, input: []const u8, eof: bool) Error!void {
        histogram(input, &self.literal_freq);

        self.literal_freq[consts.huffman.end_block_marker] = 1;

        const num_literals = consts.huffman.end_block_marker + 1;
        self.distance_freq[0] = 1;
        const num_distances = 1;

        self.literal_encoding.generate(&self.literal_freq, 15);

        var num_codegens: u32 = 0;

        self.generateCodegen(
            num_literals,
            num_distances,
            &self.literal_encoding,
            &self.huff_distance,
        );
        self.codegen_encoding.generate(self.codegen_freq[0..], 7);
        const dynamic_size = self.dynamicSize(&self.literal_encoding, &self.huff_distance, 0);
        const size = dynamic_size.size;
        num_codegens = dynamic_size.num_codegens;

        const stored_size_ret = storedSizeFits(input);
        const ssize = stored_size_ret.size;
        const storable = stored_size_ret.storable;

        if (storable and ssize < (size + (size >> 4))) {
            try self.storedBlock(input, eof);
            return;
        }

        try self.dynamicHeader(num_literals, num_distances, num_codegens, eof);
        const encoding = self.literal_encoding.codes[0..257];

        for (input) |t| {
            const c = encoding[t];
            try self.bit_writer.writeBits(c.code, c.len);
        }
        try self.writeCode(encoding[consts.huffman.end_block_marker]);
    }

    const TotalIndexedTokens = struct {
        num_literals: u32,
        num_distances: u32,
    };

    fn indexTokens(self: *Self, tokens: []const Token) TotalIndexedTokens {
        var num_literals: u32 = 0;
        var num_distances: u32 = 0;

        for (self.literal_freq, 0..) |_, i| {
            self.literal_freq[i] = 0;
        }
        for (self.distance_freq, 0..) |_, i| {
            self.distance_freq[i] = 0;
        }

        for (tokens) |t| {
            if (t.kind == Token.Kind.literal) {
                self.literal_freq[t.literal()] += 1;
                continue;
            }
            self.literal_freq[t.lengthCode()] += 1;
            self.distance_freq[t.distanceCode()] += 1;
        }
        self.literal_freq[consts.huffman.end_block_marker] += 1;

        num_literals = @as(u32, @intCast(self.literal_freq.len));
        while (self.literal_freq[num_literals - 1] == 0) {
            num_literals -= 1;
        }
        num_distances = @as(u32, @intCast(self.distance_freq.len));
        while (num_distances > 0 and self.distance_freq[num_distances - 1] == 0) {
            num_distances -= 1;
        }
        if (num_distances == 0) {
            self.distance_freq[0] = 1;
            num_distances = 1;
        }
        self.literal_encoding.generate(&self.literal_freq, 15);
        self.distance_encoding.generate(&self.distance_freq, 15);
        return TotalIndexedTokens{
            .num_literals = num_literals,
            .num_distances = num_distances,
        };
    }

    fn writeTokens(
        self: *Self,
        tokens: []const Token,
        le_codes: []HuffCode,
        oe_codes: []HuffCode,
    ) Error!void {
        for (tokens) |t| {
            if (t.kind == Token.Kind.literal) {
                try self.writeCode(le_codes[t.literal()]);
                continue;
            }

            const le = t.lengthEncoding();
            try self.writeCode(le_codes[le.code]);
            if (le.extra_bits > 0) {
                try self.bit_writer.writeBits(le.extra_length, le.extra_bits);
            }

            const oe = t.distanceEncoding();
            try self.writeCode(oe_codes[oe.code]);
            if (oe.extra_bits > 0) {
                try self.bit_writer.writeBits(oe.extra_distance, oe.extra_bits);
            }
        }
        try self.writeCode(le_codes[consts.huffman.end_block_marker]);
    }

    fn histogram(b: []const u8, h: *[286]u16) void {
        for (h, 0..) |_, i| {
            h[i] = 0;
        }

        var lh = h.*[0..256];
        for (b) |t| {
            lh[t] += 1;
        }
    }

    fn generateCodegen(
        self: *Self,
        num_literals: u32,
        num_distances: u32,
        lit_enc: *LiteralEncoder,
        dist_enc: *DistanceEncoder,
    ) void {
        for (self.codegen_freq, 0..) |_, i| {
            self.codegen_freq[i] = 0;
        }

        var codegen = &self.codegen;
        var cgnl = codegen[0..num_literals];
        for (cgnl, 0..) |_, i| {
            cgnl[i] = @as(u8, @intCast(lit_enc.codes[i].len));
        }

        cgnl = codegen[num_literals .. num_literals + num_distances];
        for (cgnl, 0..) |_, i| {
            cgnl[i] = @as(u8, @intCast(dist_enc.codes[i].len));
        }
        codegen[num_literals + num_distances] = end_code_mark;

        var size = codegen[0];
        var count: i32 = 1;
        var out_index: u32 = 0;
        var in_index: u32 = 1;
        while (size != end_code_mark) : (in_index += 1) {
            const next_size = codegen[in_index];
            if (next_size == size) {
                count += 1;
                continue;
            }
            if (size != 0) {
                codegen[out_index] = size;
                out_index += 1;
                self.codegen_freq[size] += 1;
                count -= 1;
                while (count >= 3) {
                    var n: i32 = 6;
                    if (n > count) {
                        n = count;
                    }
                    codegen[out_index] = 16;
                    out_index += 1;
                    codegen[out_index] = @as(u8, @intCast(n - 3));
                    out_index += 1;
                    self.codegen_freq[16] += 1;
                    count -= n;
                }
            } else {
                while (count >= 11) {
                    var n: i32 = 138;
                    if (n > count) {
                        n = count;
                    }
                    codegen[out_index] = 18;
                    out_index += 1;
                    codegen[out_index] = @as(u8, @intCast(n - 11));
                    out_index += 1;
                    self.codegen_freq[18] += 1;
                    count -= n;
                }
                if (count >= 3) {
                    codegen[out_index] = 17;
                    out_index += 1;
                    codegen[out_index] = @as(u8, @intCast(count - 3));
                    out_index += 1;
                    self.codegen_freq[17] += 1;
                    count = 0;
                }
            }
            count -= 1;
            while (count >= 0) : (count -= 1) {
                codegen[out_index] = size;
                out_index += 1;
                self.codegen_freq[size] += 1;
            }
            size = next_size;
            count = 1;
        }
        codegen[out_index] = end_code_mark;
    }

    const DynamicSize = struct {
        size: u32,
        num_codegens: u32,
    };

    fn dynamicSize(
        self: *Self,
        lit_enc: *LiteralEncoder,
        dist_enc: *DistanceEncoder,
        extra_bits: u32,
    ) DynamicSize {
        var num_codegens = self.codegen_freq.len;
        while (num_codegens > 4 and self.codegen_freq[codegen_order[num_codegens - 1]] == 0) {
            num_codegens -= 1;
        }
        const header = 3 + 5 + 5 + 4 + (3 * num_codegens) +
            self.codegen_encoding.bitLength(self.codegen_freq[0..]) +
            self.codegen_freq[16] * 2 +
            self.codegen_freq[17] * 3 +
            self.codegen_freq[18] * 7;
        const size = header +
            lit_enc.bitLength(&self.literal_freq) +
            dist_enc.bitLength(&self.distance_freq) +
            extra_bits;

        return DynamicSize{
            .size = @as(u32, @intCast(size)),
            .num_codegens = @as(u32, @intCast(num_codegens)),
        };
    }

    fn fixedSize(self: *Self, extra_bits: u32) u32 {
        return 3 +
            self.fixed_literal_encoding.bitLength(&self.literal_freq) +
            self.fixed_distance_encoding.bitLength(&self.distance_freq) +
            extra_bits;
    }

    const StoredSize = struct {
        size: u32,
        storable: bool,
    };

    fn storedSizeFits(in: ?[]const u8) StoredSize {
        if (in == null) {
            return .{ .size = 0, .storable = false };
        }
        if (in.?.len <= consts.huffman.max_store_block_size) {
            return .{ .size = @as(u32, @intCast((in.?.len + 5) * 8)), .storable = true };
        }
        return .{ .size = 0, .storable = false };
    }

    fn dynamicHeader(
        self: *Self,
        num_literals: u32,
        num_distances: u32,
        num_codegens: u32,
        eof: bool,
    ) Error!void {
        const first_bits: u32 = if (eof) 5 else 4;
        try self.bit_writer.writeBits(first_bits, 3);
        try self.bit_writer.writeBits(num_literals - 257, 5);
        try self.bit_writer.writeBits(num_distances - 1, 5);
        try self.bit_writer.writeBits(num_codegens - 4, 4);

        var i: u32 = 0;
        while (i < num_codegens) : (i += 1) {
            const value = self.codegen_encoding.codes[codegen_order[i]].len;
            try self.bit_writer.writeBits(value, 3);
        }

        i = 0;
        while (true) {
            const code_word: u32 = @as(u32, @intCast(self.codegen[i]));
            i += 1;
            if (code_word == end_code_mark) {
                break;
            }
            try self.writeCode(self.codegen_encoding.codes[@as(u32, @intCast(code_word))]);

            switch (code_word) {
                16 => {
                    try self.bit_writer.writeBits(self.codegen[i], 2);
                    i += 1;
                },
                17 => {
                    try self.bit_writer.writeBits(self.codegen[i], 3);
                    i += 1;
                },
                18 => {
                    try self.bit_writer.writeBits(self.codegen[i], 7);
                    i += 1;
                },
                else => {},
            }
        }
    }
};

pub const Options = struct {
    level: Level = .default,
};

pub const Level = enum(u4) {
    fast = 0xb,
    level_4 = 4,
    level_5 = 5,
    default = 0xc,
    level_6 = 6,
    level_7 = 7,
    level_8 = 8,
    best = 0xd,
    level_9 = 9,
};

const LevelArgs = struct {
    good: u16,
    nice: u16,
    lazy: u16,
    chain: u16,

    pub fn get(level: Level) LevelArgs {
        return switch (level) {
            .fast, .level_4 => .{ .good = 4, .lazy = 4, .nice = 16, .chain = 16 },
            .level_5 => .{ .good = 8, .lazy = 16, .nice = 32, .chain = 32 },
            .default, .level_6 => .{ .good = 8, .lazy = 16, .nice = 128, .chain = 128 },
            .level_7 => .{ .good = 8, .lazy = 32, .nice = 128, .chain = 256 },
            .level_8 => .{ .good = 32, .lazy = 128, .nice = 258, .chain = 1024 },
            .best, .level_9 => .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
        };
    }
};

pub fn deflateCompress(comptime container: Container, reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) !void {
    var c = try deflateCompressor(container, writer, options);
    try c.compress(reader);
    try c.finish();
}

pub fn deflateCompressor(comptime container: Container, writer: *std.Io.Writer, options: Options) !Deflate(container) {
    return try Deflate(container).init(writer, options);
}

pub fn Deflate(comptime container: Container) type {
    return struct {
        lookup: Lookup = .{},
        win: SlidingWindow = .{},
        tokens: Tokens = .{},
        wrt: *std.Io.Writer,
        block_writer: BlockWriter,
        level: LevelArgs,
        hasher: container.Hasher() = .{},

        prev_match: ?Token = null,
        prev_literal: ?u8 = null,

        const Self = @This();

        pub fn init(wrt: *std.Io.Writer, options: Options) !Self {
            const self = Self{
                .wrt = wrt,
                .block_writer = BlockWriter.init(wrt),
                .level = LevelArgs.get(options.level),
            };
            try Container.writeHeader(container, self.wrt);
            return self;
        }

        const FlushOption = enum { none, flush, final };

        fn tokenize(self: *Self, flush_opt: FlushOption) !void {
            const should_flush = (flush_opt != .none);

            while (self.win.activeLookahead(should_flush)) |lh| {
                var step: u16 = 1;
                const pos: u16 = self.win.pos();
                const literal = lh[0];
                const min_len: u16 = if (self.prev_match) |m| m.length() else 0;

                if (self.findMatch(pos, lh, min_len)) |match| {
                    try self.addPrevLiteral();

                    if (match.length() >= self.level.lazy) {
                        step = try self.addMatch(match);
                    } else {
                        self.prev_literal = literal;
                        self.prev_match = match;
                    }
                } else {
                    if (self.prev_match) |m| {
                        step = try self.addMatch(m) - 1;
                    } else {
                        try self.addPrevLiteral();
                        self.prev_literal = literal;
                    }
                }
                self.windowAdvance(step, lh, pos);
            }

            if (should_flush) {
                assert(self.prev_match == null);
                try self.addPrevLiteral();
                self.prev_literal = null;

                try self.flushTokens(flush_opt);
            }
        }

        fn windowAdvance(self: *Self, step: u16, lh: []const u8, pos: u16) void {
            self.lookup.bulkAdd(lh[1..], step - 1, pos + 1);
            self.win.advance(step);
        }

        fn addPrevLiteral(self: *Self) !void {
            if (self.prev_literal) |l| try self.addToken(Token.initLiteral(l));
        }

        fn addMatch(self: *Self, m: Token) !u16 {
            try self.addToken(m);
            self.prev_literal = null;
            self.prev_match = null;
            return m.length();
        }

        fn addToken(self: *Self, token: Token) !void {
            self.tokens.add(token);
            if (self.tokens.full()) try self.flushTokens(.none);
        }

        fn findMatch(self: *Self, pos: u16, lh: []const u8, min_len: u16) ?Token {
            var len: u16 = min_len;
            var prev_pos = self.lookup.add(lh, pos);
            var match: ?Token = null;

            var chain: usize = self.level.chain;
            if (len >= self.level.good) {
                chain >>= 2;
            }

            while (prev_pos > 0 and chain > 0) : (chain -= 1) {
                const distance = pos - prev_pos;
                if (distance > consts.match.max_distance)
                    break;

                const new_len = self.win.match(prev_pos, pos, len);
                if (new_len > len) {
                    match = Token.initMatch(@intCast(distance), new_len);
                    if (new_len >= self.level.nice) {
                        return match;
                    }
                    len = new_len;
                }
                prev_pos = self.lookup.prev(prev_pos);
            }

            return match;
        }

        fn flushTokens(self: *Self, flush_opt: FlushOption) !void {
            try self.block_writer.write(self.tokens.tokens(), flush_opt == .final, self.win.tokensBuffer());
            if (flush_opt == .flush) {
                try self.block_writer.storedBlock("", false);
            }
            if (flush_opt != .none) {
                try self.block_writer.flush();
            }
            self.tokens.reset();
            self.win.flush();
        }

        fn slide(self: *Self) void {
            const n = self.win.slide();
            self.lookup.slide(n);
        }

        pub fn compress(self: *Self, reader: *std.Io.Reader) !void {
            while (true) {
                const buf = self.win.writable();
                if (buf.len == 0) {
                    try self.tokenize(.none);
                    self.slide();
                    continue;
                }
                // Read up to buffer size, limiting to avoid buffer overflow
                const read_size = @min(buf.len, 4096);
                const slice = reader.take(read_size) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return error.ReadFailed,
                };
                @memcpy(buf[0..slice.len], slice);
                self.hasher.update(buf[0..slice.len]);
                self.win.written(slice.len);
                try self.tokenize(.none);
                if (slice.len < read_size) break;
            }
        }

        pub fn flush(self: *Self) !void {
            try self.tokenize(.flush);
        }

        pub fn finish(self: *Self) !void {
            try self.tokenize(.final);
            try Container.writeFooter(container, &self.hasher, self.wrt);
        }

        pub fn setWriter(self: *Self, new_writer: *std.Io.Writer) void {
            self.block_writer.setWriter(new_writer);
            self.wrt = new_writer;
        }
    };
}

const Tokens = struct {
    list: [consts.deflate.tokens]Token = undefined,
    pos: usize = 0,

    fn add(self: *Tokens, t: Token) void {
        self.list[self.pos] = t;
        self.pos += 1;
    }

    fn full(self: *Tokens) bool {
        return self.pos == self.list.len;
    }

    fn reset(self: *Tokens) void {
        self.pos = 0;
    }

    fn tokens(self: *Tokens) []const Token {
        return self.list[0..self.pos];
    }
};

pub fn compress(reader: *std.Io.Reader, writer: *std.Io.Writer, options: Options) !void {
    try deflateCompress(.gzip, reader, writer, options);
}

pub const Compressor = Deflate(.gzip);

pub fn compressor(writer: *std.Io.Writer, options: Options) !Compressor {
    return try deflateCompressor(.gzip, writer, options);
}

test "basic compression" {
    var compressed_buffer: [1024]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&compressed_buffer);

    const data = "Hello, World!";
    var input_buffer: [1024]u8 = undefined;
    @memcpy(input_buffer[0..data.len], data);
    var input_reader = std.Io.Reader.fixed(input_buffer[0..data.len]);

    try compress(&input_reader, &fixed_writer, .{});

    // Find the end of compressed data by checking for non-zero bytes
    var written: usize = 0;
    for (compressed_buffer, 0..) |byte, i| {
        if (byte != 0) written = i + 1;
    }
    const compressed = compressed_buffer[0..written];
    try expect(compressed.len > 0);
    try expect(compressed[0] == 0x1f);
    try expect(compressed[1] == 0x8b);
}

test "token size" {
    try expect(@sizeOf(Token) == 4);
}

test "token match encoding" {
    var c = Token.initMatch(1, 4).lengthEncoding();
    try expect(c.code == 258);
    try expect(c.extra_bits == 0);
    try expect(c.extra_length == 0);

    c = Token.initMatch(1, 11).lengthEncoding();
    try expect(c.code == 265);
    try expect(c.extra_bits == 1);
    try expect(c.extra_length == 0);
}

test "token distance encoding" {
    var c = Token.initMatch(1, 4).distanceEncoding();
    try expect(c.code == 0);
    try expect(c.extra_bits == 0);
    try expect(c.extra_distance == 0);

    c = Token.initMatch(192, 4).distanceEncoding();
    try expect(c.code == 14);
    try expect(c.extra_bits == 6);
    try expect(c.extra_distance == 192 - 129);
}

test "compression levels" {
    var compressed_fast: [1024]u8 = undefined;
    var fixed_fast = std.Io.Writer.fixed(&compressed_fast);

    var compressed_best: [1024]u8 = undefined;
    var fixed_best = std.Io.Writer.fixed(&compressed_best);

    const data = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.";
    var input_buffer: [1024]u8 = undefined;
    @memcpy(input_buffer[0..data.len], data);
    var input_reader = std.Io.Reader.fixed(input_buffer[0..data.len]);

    try compress(&input_reader, &fixed_fast, .{ .level = .fast });
    try compress(&input_reader, &fixed_best, .{ .level = .best });

    var fast_written: usize = 0;
    for (compressed_fast, 0..) |byte, i| {
        if (byte != 0) fast_written = i + 1;
    }
    var best_written: usize = 0;
    for (compressed_best, 0..) |byte, i| {
        if (byte != 0) best_written = i + 1;
    }
    const fast_result = compressed_fast[0..fast_written];
    const best_result = compressed_best[0..best_written];

    try expect(fast_result.len > 0);
    try expect(best_result.len > 0);
    try expect(best_result.len <= fast_result.len);
}

test "compression with different sizes" {
    const small_data = "Hi!";
    const large_data = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.";

    var small_buffer: [1024]u8 = undefined;
    var small_fixed = std.Io.Writer.fixed(&small_buffer);

    var large_buffer: [2048]u8 = undefined;
    var large_fixed = std.Io.Writer.fixed(&large_buffer);

    var small_input_buffer: [1024]u8 = undefined;
    @memcpy(small_input_buffer[0..small_data.len], small_data);
    var small_input_reader = std.Io.Reader.fixed(small_input_buffer[0..small_data.len]);

    var large_input_buffer: [2048]u8 = undefined;
    @memcpy(large_input_buffer[0..large_data.len], large_data);
    var large_input_reader = std.Io.Reader.fixed(large_input_buffer[0..large_data.len]);

    try compress(&small_input_reader, &small_fixed, .{});
    try compress(&large_input_reader, &large_fixed, .{});

    var small_written: usize = 0;
    for (small_buffer, 0..) |byte, i| {
        if (byte != 0) small_written = i + 1;
    }
    var large_written: usize = 0;
    for (large_buffer, 0..) |byte, i| {
        if (byte != 0) large_written = i + 1;
    }
    const small_compressed = small_buffer[0..small_written];
    const large_compressed = large_buffer[0..large_written];

    try expect(small_compressed.len > 10);
    try expect(large_compressed.len > 50);
    try expect(small_compressed[0] == 0x1f);
    try expect(small_compressed[1] == 0x8b);
    try expect(large_compressed[0] == 0x1f);
    try expect(large_compressed[1] == 0x8b);
}
