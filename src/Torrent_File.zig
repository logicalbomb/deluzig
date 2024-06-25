const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;

// Fields that begin with _ are meant for internal use only
_contents: []u8,
_unk_key_pos: ?[]u64 = null,
_unk_key_val: ?[][]u8 = null,

announce: ?[]u8 = null,
creation_date: ?u64 = null,
comment: ?[]u8 = null,
created_by: ?[]u8 = null,
encoding: ?[]u8 = null,

const Torrent_File = @This();

// TODO: implement *ANY* err handling!
pub fn readFile(allocator: std.mem.Allocator, filename: [:0]u8) !Torrent_File {
    // TODO: copy filename into a struct member
    print("Reading: {s}\n", .{filename});
    
    const file = std.fs.cwd().openFile(filename, .{}) catch |err| return err;
    defer file.close();

    const metadata = file.metadata() catch |err| return err;
    const file_size: u64 = metadata.size();
    const buffer = try allocator.alloc(u8, file_size);
    const bytes_read = file.readAll(buffer) catch |err| return err;
    assert(bytes_read == file_size);
    
    const result: Torrent_File = try index(allocator, buffer);

    print("Finished reading: {s}\n", .{filename});
    return result;
}

pub fn printSummary(self: Torrent_File, writer: anytype) !void {
    try writer.print("Summary of <unnamed> file:\n", .{});
    if (self.announce) |ann| {
        try writer.print("  Announce: {s}\n", .{ann});
    }
    if (self.creation_date) |cd| {
        try writer.print("  Creation Date: {d}\n", .{cd});
    }
    if (self.comment) |com| {
        try writer.print("  Comment: {s}\n", .{com});
    }
    if (self.created_by) |cb| {
        try writer.print("  Created By: {s}\n", .{cb});
    }
    if (self.encoding) |enc| {
        try writer.print("  Encoding: {s}\n", .{enc});
    }
    for (self._unk_key_pos.?, self._unk_key_val.?) |pos, val| {
        try writer.print("  Unknown key - {s} @{d}\n", .{val, pos});
    }
    try writer.print("Summary complete.\n", .{});
}

// Parse the torrent file and index the important parts
// More info on the format can be found here: https://wiki.theory.org/BitTorrentSpecification
// TODO: get smarter about dynamic allocations?!?
fn index(allocator: std.mem.Allocator, contents: []u8) !Torrent_File {
    // Generic file format
    // file - d
    // - info - d
    //   - piece length - i
    //   - pieces - s
    //   - private - i
    //   - name - s
    //   - length - i
    //   - md5sum - s
    //   - files - l(d)
    //     - length - i
    //     - md5sum - s
    //     - path - l(s)
    // x announce - s
    // - announce-list - l(l(s))
    // x creation date - i
    // x comment - s
    // x created by - s
    // x encoding - s

    print("Starting the index.\n", .{});

    var stack_depth: u8 = 0xFF;
    var stack_type = [_]u8{0xFF} ** ((1 << 9) - 1);
    var stack_pos = [_]u64{0xFFFFFFFFFFFFFFFF} ** ((1 << 9) - 1);

    var is_key: bool = false;

    var kv_num: u8 = 0;
    var key_slices = [_][]u8{contents[0..10]} ** ((1 << 9) - 1);
    var key_pos = [_]u64{0xFFFFFFFFFFFFFFFF} ** ((1 << 9) - 1);
    var val_slices = [_][]u8{contents[0..10]} ** ((1 << 9) - 1);
    var val_ints = [_]u64{0xFFFFFFFFFFFFFFFF} ** ((1 << 9) - 1);

    var result: Torrent_File = .{ ._contents = contents };

    var byte_pos: u64 = 0;
    while (byte_pos < contents.len) {
        const byte: u8 = contents[byte_pos];
        switch (byte) {
            // #'s for string len
            0x30...0x39 => {
                const decoded = try bDecodeInteger(contents, byte_pos, 0x3A);
                const str_val = contents[(decoded[0] + 1)..(decoded[0] + 1 + decoded[1])];
                assert(str_val.len == decoded[1]);
                if (is_key) {
                    key_slices[kv_num] = str_val;
                    key_pos[kv_num] = byte_pos;
                    kv_num += 1;
                } else {
                    val_slices[kv_num - 1] = str_val;
                }
                byte_pos = decoded[0] + decoded[1];
            },
            // d for dictionary - keys are always strings or l for list
            0x64, 0x6C => {
                stack_depth = @addWithOverflow(stack_depth, 1)[0];
                stack_type[stack_depth] = byte;
                stack_pos[stack_depth] = byte_pos;
                // TODO: figure out how to properly handle these vals
            },
            // e for end of encoding for a dictionary or a list
            0x65 => {
                stack_type[stack_depth] = 0xFF;
                stack_pos[stack_depth] = 0xFFFFFFFFFFFFFFFF;
                const res = @subWithOverflow(stack_depth, 1);
                stack_depth = res[0];
                // If we popped back to a dictionary, we need to prepare for a key
                if (stack_type[stack_depth] == 0x64) { is_key = false; }
            },
            // i for integer
            0x69 => {
                byte_pos += 1;
                const decoded = try bDecodeInteger(contents, byte_pos, 0x65);
                val_ints[kv_num - 1] = decoded[1];
                byte_pos = decoded[0];
            },
            else => unreachable,
        }
        byte_pos += 1;
        // Flip between key or val when we are on a dictionary
        if (stack_type[stack_depth] == 0x64) { is_key = !is_key; }
    }

    assert(stack_depth == 255);
    assert(stack_type[0] == 0xFF);
    assert(stack_pos[0] == 0xFFFFFFFFFFFFFFFF);

    // Hydrate the result's fields from the parse
    var found_fields: u8 = 0;
    const torrent_fields = comptime std.meta.fields(@TypeOf(result));
    for (0..kv_num) |i| {
        const key = key_slices[i];
        std.mem.replaceScalar(u8, key, ' ', '_');
        inline for (torrent_fields) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                @field(result, field.name) = switch (field.type) {
                    ?[]u8 => val_slices[i],
                    ?u64 => val_ints[i],
                    else => undefined,
                };
                key_slices[i][0] = 0x5F;
                found_fields += 1;
            }
        }
    }

    // Record any unhandled keys
    var skips: u8 = 0;
    result._unk_key_pos = try allocator.alloc(u64, kv_num - found_fields);
    result._unk_key_val = try allocator.alloc([]u8, kv_num - found_fields);
    for (0..kv_num) |i| {
        if (key_slices[i][0] == 0x5F) {
            skips += 1;
            continue;
        }
        result._unk_key_pos.?[i - skips] = key_pos[i];
        result._unk_key_val.?[i - skips] = key_slices[i];
    }

    
    assert(found_fields == skips);

    print("Ending the index.\n", .{});

    return result;
}

fn bDecodeInteger(contents: []u8, og_pos: u64, delimiter: u8) !*const[2]u64 {
    var pos = og_pos;
    var check = contents[pos];
    while (check != delimiter) : ({ pos += 1; check = contents[pos]; }) {
        assert((check >= 0x30 and check <= 0x39) or check == delimiter);
    }
    return &[_]u64{ pos, try std.fmt.parseInt(u64, contents[og_pos..pos], 10) };
}
