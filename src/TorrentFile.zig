const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;

// Fields that begin with _ are meant for internal use only
_text: []u8,
_unk_key_pos: ?[]u64 = null,
_unk_key_val: ?[][]u8 = null,

announce: ?[]u8 = null,
creation_date: ?u64 = null,
comment: ?[]u8 = null,
created_by: ?[]u8 = null,
encoding: ?[]u8 = null,

const TorrentFile = @This();

pub fn printSummary(self: TorrentFile, writer: anytype) !void {
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

// TODO: implement *ANY* err handling!
pub fn readFile(allocator: std.mem.Allocator, filename: [:0]u8) !TorrentFile {
    // TODO: copy filename into a struct member
    print("Reading: {s}\n", .{filename});
    
    const file = std.fs.cwd().openFile(filename, .{}) catch |err| return err;
    defer file.close();

    const metadata = file.metadata() catch |err| return err;
    const file_size: u64 = metadata.size();
    const buffer = try allocator.alloc(u8, file_size);
    const bytes_read = file.readAll(buffer) catch |err| return err;
    assert(bytes_read == file_size);
    
    const result: TorrentFile = try index(allocator, buffer);

    print("Finished reading: {s}\n", .{filename});
    return result;
}


const TFIndexContext = struct {
    text: []u8 = undefined,
    result: TorrentFile = undefined,

    // TODO: can we trash the stack and go recursive?
    stack_depth: u8 = 0xFF,
    stack_type: []u8 = undefined,
    stack_pos: []u64 = undefined,

    is_key: bool = false,

    kv_num: u8 = 0,
    key_slices: [][]u8 = undefined,
    key_pos: []u64 = undefined,
    val_slices: [][]u8 = undefined,
    val_ints: []u64 = undefined,

    // TODO: modify to use union
    // TODO: preallocate one and reuse
    pub fn init(allocator: std.mem.Allocator, text: []u8,
            result: TorrentFile) !TFIndexContext {
        return TFIndexContext {
            .text = text,
            .result = result,

            .stack_type = try allocator.alloc(u8, 512),
            .stack_pos = try allocator.alloc(u64, 512),
            .key_slices = try allocator.alloc([]u8, 512),
            .key_pos = try allocator.alloc(u64, 512),
            .val_slices = try allocator.alloc([]u8, 512),
            .val_ints = try allocator.alloc(u64, 512),
        };
    }
};

// TODO: create a struct for the info section
// TODO: create a struct for the file section
// TODO: create a union of the 3 to simplify parsing


// Parse the torrent file and index the important parts
// More info on the format can be found here: https://wiki.theory.org/BitTorrentSpecification
// TODO: get smarter about dynamic allocations?!?
fn index(allocator: std.mem.Allocator, text: []u8) !TorrentFile {
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

    var result: TorrentFile = .{ ._text = text };
    var context = try TFIndexContext.init(allocator, text, result);

    // TODO: I bet this cleans up better if we allocate one of these!
    // Shenanigans about creating non-const slices
    //const shenanigan: u64 = @as(u64, text.len);
    //context.stack_type = &[_]u8{text[0]} ** ((1 << 9) - 1);
    //context.stack_pos = &[_]u64{shenanigan} ** ((1 << 9) - 1);
    //context.key_slices = &[_][]u8{text[0..2]} ** ((1 << 9) - 1);
    //context.key_pos = &[_]u64{shenanigan} ** ((1 << 9) - 1);
    //context.val_slices = &[_][]u8{text[0..2]} ** ((1 << 9) - 1);
    //context.val_ints = &[_]u64{shenanigan} ** ((1 << 9) - 1);

    var byte_pos: u64 = 0;
    while (byte_pos < context.text.len) {
        const byte: u8 = context.text[byte_pos];
        switch (byte) {
            // #'s for string len
            '0'...'9' => {
                byte_pos = try parseString(&context, byte_pos);
            },
            // d for dictionary - keys are always strings or l for list
            'd', 'l' => {
                context.stack_depth = @addWithOverflow(context.stack_depth, 1)[0];
                context.stack_type[context.stack_depth] = byte;
                context.stack_pos[context.stack_depth] = byte_pos;
                // TODO: figure out how to properly handle these vals
            },
            // e for end of encoding for a dictionary or a list
            'e' => {
                context.stack_type[context.stack_depth] = 0xFF;
                context.stack_pos[context.stack_depth] = 0xFFFFFFFFFFFFFFFF;
                const res = @subWithOverflow(context.stack_depth, 1);
                context.stack_depth = res[0];
                // If we popped back to a dictionary, we need to prepare for a key
                if (context.stack_type[context.stack_depth] == 'd') { context.is_key = false; }
            },
            // i for integer
            'i' => {
                byte_pos = try parseInteger(&context, byte_pos);
            },
            else => unreachable,
        }
        byte_pos += 1;
        // Flip between key or val when we are on a dictionary
        if (context.stack_type[context.stack_depth] == 'd') { context.is_key = !context.is_key; }
    }

    assert(context.stack_depth == 255);
    assert(context.stack_type[0] == 0xFF);
    assert(context.stack_pos[0] == 0xFFFFFFFFFFFFFFFF);

    // TODO: incorporate this giant chunk of code into/shortly after the switch
    // Hydrate the result's fields from the parse
    var found_fields: u8 = 0;
    const torrent_fields = comptime std.meta.fields(@TypeOf(result));
    for (0..context.kv_num) |i| {
        const key = context.key_slices[i];
        std.mem.replaceScalar(u8, key, ' ', '_');
        inline for (torrent_fields) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                @field(result, field.name) = switch (field.type) {
                    ?[]u8 => context.val_slices[i],
                    ?u64 => context.val_ints[i],
                    else => undefined,
                };
                // TODO: do something better than a magic value here
                context.key_slices[i][0] = '_';
                found_fields += 1;
            }
        }
    }

    // Record any unhandled keys
    var skips: u8 = 0;
    result._unk_key_pos = try allocator.alloc(u64, context.kv_num - found_fields);
    result._unk_key_val = try allocator.alloc([]u8, context.kv_num - found_fields);
    for (0..context.kv_num) |i| {
        if (context.key_slices[i][0] == '_') {
            skips += 1;
            continue;
        }
        result._unk_key_pos.?[i - skips] = context.key_pos[i];
        result._unk_key_val.?[i - skips] = context.key_slices[i];
    }
    
    assert(found_fields == skips);
    // TODO: end chunk for refactoring

    print("Ending the index.\n", .{});

    return result;
}

// Consume the integer at the pointer and return a pointer to the next char
fn parseInteger(context: *TFIndexContext, og_pos: u64) !u64 {
    const pos = og_pos + 1;
    const decoded = try bDecodeInteger(context.text, pos, 'e');
    context.val_ints[context.kv_num - 1] = decoded[1];
    return decoded[0];
}

// Consume the string at the pointer and return a pointer to the next char
fn parseString(context: *TFIndexContext, og_pos: u64) !u64 {
    const decoded = try bDecodeInteger(context.text, og_pos, ':');
    const str_val = context.text[(decoded[0] + 1)..(decoded[0] + 1 + decoded[1])];
    assert(str_val.len == decoded[1]);
    if (context.is_key) {
        context.key_slices[context.kv_num] = str_val;
        context.key_pos[context.kv_num] = og_pos;
        context.kv_num += 1;
    } else {
        context.val_slices[context.kv_num - 1] = str_val;
    }
    return decoded[0] + decoded[1];
}

// Can decode an integer and returns a tuple of the next index in the stream
// to parse and the value of the integer
fn bDecodeInteger(text: []u8, og_pos: u64, delimiter: u8) !*const[2]u64 {
    var pos = og_pos;
    var check = text[pos];
    while (check != delimiter) : ({ pos += 1; check = text[pos]; }) {
        //print("Decoding an integer: pos={d}, val={c} del={c}\n", .{ pos, check, delimiter });
        assert((check >= '0' and check <= '9') or check == delimiter);
    }
    return &[_]u64{ pos, try std.fmt.parseInt(u64, text[og_pos..pos], 10) };
}
