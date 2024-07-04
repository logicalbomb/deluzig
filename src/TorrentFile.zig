const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;

// Fields that begin with _ are meant for internal use only
_filename: []u8,
_text: []u8,

announce: []u8,
announce_list: ?[][][]u8 = null,
creation_date: ?u64 = null,
comment: ?[]u8 = null,
created_by: ?[]u8 = null,
encoding: ?[]u8 = null,
info: TorrentInfo,

const TorrentFile = @This();

pub const InfoTag = enum {
    single,
    multi,
};

pub const TorrentInfo = union(InfoTag) {
    single: TorrentInfoSingle,
    multi: TorrentInfoMulti,
};

pub const TorrentInfoSingle = struct {
    piece_length: u64,
    pieces: []u8,
    private: ?u8,
    name: []u8,
    length: u64,
    md5sum: ?[]u8,

    pub fn printSummary(self: TorrentInfoSingle, writer: anytype, comptime num_space: u8) !void {
        const prefix = " " ** num_space;
        try writer.print("{s}Piece Length: {d}\n", .{prefix, self.piece_length});
        // TODO: pullup magic value 20 into a constant somewhere
        try writer.print("{s}Pieces amount: {d}\n", .{prefix, self.pieces.len/20});
        if (self.private) |pv| {
            try writer.print("{s}Private: {d}\n", .{prefix, pv});
        }
        try writer.print("{s}Name: {s}\n", .{prefix, self.name});
        try writer.print("{s}Length: {d}\n", .{prefix, self.length});
        if (self.md5sum) |md5| {
            try writer.print("{s}MD5Sum: {s}\n", .{prefix, md5});
        }
    }
};

pub const TorrentInfoMulti = struct {
    piece_length: u64,
    pieces: []u8,
    private: ?u8,
    name: []u8,
    files: []TorrentInnerFile,

    pub fn printSummary(self: TorrentInfoMulti, writer: anytype, comptime num_space: u8) !void {
        const prefix = " " ** num_space;
        try writer.print("{s}Piece Length: {d}\n", .{prefix, self.piece_length});
        try writer.print("{s}Pieces: {s}\n", .{prefix, self.pieces});
        if (self.private) |pv| {
            try writer.print("{s}Private: {d}\n", .{prefix, pv});
        }
        try writer.print("{s}Name: {s}\n", .{prefix, self.name});
        for (self.files, 0..) |file, i| {
            try writer.print("{s}  File #{d}:\n", .{prefix, i});
            try file.printSummary(writer, num_space + 4);
        }
    }
};

pub const TorrentInnerFile = struct {
    length: u64,
    md5sum: ?[]u8,
    path: [][]u8,

    pub fn printSummary(self: TorrentInnerFile, writer: anytype, comptime num_space: u8) !void {
        const prefix = " " ** num_space;
        try writer.print("{s}Length: {d}\n", .{prefix, self.length});
        if (self.md5sum) |md5| {
            try writer.print("{s}MD5Sum: {s}\n", .{ prefix, md5 });
        }
        try writer.print("{s}Path: ", .{prefix});
        for (self.path) |part| {
            try writer.print("||{s}", .{part});
        }
        try writer.print("\n", .{});
    }
};

pub fn printSummary(self: TorrentFile, writer: anytype) !void {
    try writer.print("Summary of {s} file:\n", .{self._filename});
    try writer.print("  Announce: {s}\n", .{self.announce});
    if (self.announce_list) |al| {
        try writer.print("  Announce-List:\n", .{});
        for (al, 0..) |tier, i| {
            try writer.print("    Tier #{d}:\n", .{i});
            for (tier) |host| {
                try writer.print("      {s}\n", .{host});
            }
        }
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
    switch(self.info) {
        InfoTag.single => |single| {
            try writer.print("  Info:\n", .{});
            try single.printSummary(writer, 4);
        },
        InfoTag.multi => |multi| {
            try writer.print("  Info:\n", .{});
            try multi.printSummary(writer, 4);
        },
    }
    // TODO: maybe bring this back?
    //for (self._unk_key_pos.?, self._unk_key_val.?) |pos, val| {
    //    try writer.print("  Unknown key - {s} @{d}\n", .{val, pos});
    //}
    try writer.print("Summary complete.\n", .{});
}

// TODO: implement *ANY* err handling!
// TODO: make sure there is an Arena allocator for this Torrent
pub fn readFile(allocator: std.mem.Allocator, filename: [:0]u8) !*TorrentFile {
    print("Reading: {s}\n", .{filename});
    
    const file = std.fs.cwd().openFile(filename, .{}) catch |err| return err;
    defer file.close();

    const metadata = file.metadata() catch |err| return err;
    const file_size: u64 = metadata.size();
    const buffer = try allocator.alloc(u8, file_size);
    const bytes_read = file.readAll(buffer) catch |err| return err;
    assert(bytes_read == file_size);
    
    const result: *TorrentFile = try index(allocator, buffer);
    result._filename = try allocator.dupe(u8, filename);

    print("Finished reading: {s}\n", .{filename});
    return result;
}

// Parse the torrent file and index the important parts
// More info on the format can be found here: https://wiki.theory.org/BitTorrentSpecification
fn index(allocator: std.mem.Allocator, text: []u8) !*TorrentFile {
    print("Starting the index.\n", .{});
    // TODO: check on allocation/initialization behavior here
    var result: *TorrentFile = try allocator.create(TorrentFile);
    result.* = TorrentFile {
            ._filename = undefined,
            ._text = text,
            .announce = undefined,
            .info = undefined,
    };

    var pos: u64 = 0;
    // 'd' better start our dictionary
    assert(text[pos] == 'd');
    pos += 1;
    // 'e' is the end of our dictionary
    while (text[pos] != 'e') {
        const key: []u8 = try parseString(text, &pos);
        // TODO: May want to look into this switch-based solution:
        // https://andrewkelley.me/post/string-matching-comptime-perfect-hashing-zig.html
        if (std.mem.eql(u8, key, "announce")) {
            result.announce = try parseString(text, &pos);
        } else if (std.mem.eql(u8, key, "announce-list")) {
            result.announce_list = try parseAnnounceList(allocator, text, &pos);
        } else if (std.mem.eql(u8, key, "creation date")) {
            result.creation_date = try parseInt(text, &pos);
        } else if (std.mem.eql(u8, key, "comment")) {
            result.comment = try parseString(text, &pos);
        } else if (std.mem.eql(u8, key, "created by")) {
            result.created_by = try parseString(text, &pos);
        } else if (std.mem.eql(u8, key, "encoding")) {
            result.encoding = try parseString(text, &pos);
        } else if (std.mem.eql(u8, key, "info")) {
            result.info = try parseInfo(allocator, text, &pos);
        } else {
            print("We failed gang! Unrecognized property: {s}\n", .{key});
            try skip(text, &pos);
        }
    }
    

    print("Ending the index.\n", .{});
    return result;
}

// Parse and return a string while chewing up the used bytes
fn parseString(text: []u8, pos: *u64) ![]u8 {
    assert(text[pos.*] >= '0' and text[pos.*] <= '9');
    const length = try bDecodeInteger(text, pos, ':');
    const result: []u8 = text[pos.*..(pos.* + length)];
    pos.* += length;
    return result;
}

// Parse and return an int while chewing up the used bytes
fn parseInt(text: []u8, pos: *u64) !u64 {
    assert(text[pos.*] == 'i');
    pos.* += 1;
    return try bDecodeInteger(text, pos, 'e');
}

// Can decode an integer and returns a tuple of the next index in the stream
// to parse and the value of the integer
fn bDecodeInteger(text: []u8, pos: *u64, delimiter: u8) !u64 {
    const og_pos = pos.*;
    var check = text[pos.*];
    while (check != delimiter) : ({ pos.* += 1; check = text[pos.*]; }) {
        //print("Decoding an integer: pos={d}, val={c} del={c}\n", .{ pos, check, delimiter });
        assert((check >= '0' and check <= '9') or check == delimiter);
    }
    const result = try std.fmt.parseInt(u64, text[og_pos..pos.*], 10);
    pos.* += 1;
    return result;
}

// Parse and return the announce list while chewing up the bytes
fn parseAnnounceList(allocator: std.mem.Allocator, text: []u8, pos: *u64) ![][][]u8 {
    // 'l' better start our list
    assert(text[pos.*] == 'l');
    pos.* += 1;
    var cursor = pos.*;
    // TODO: pull up magic val 10 here
    var lengths: [10]u64 = undefined;
    var tier: u8 = @as(u8, 0);

    // first pass for lengths
    // 'e' is the end of our list
    while (text[cursor] != 'e') {
        // 'l' will start our tier list
        assert(text[cursor] == 'l');
        cursor += 1;
        var count: u8 = @as(u8, 0);

        // 'e' is the end of our tier list
        while (text[cursor] != 'e') {
            try skipString(text, &cursor);
            count += 1;
        }
        lengths[tier] = count;
        cursor += 1;
        count += 1;
        tier += 1;
    }

    var result: [][][]u8 = try allocator.alloc([][]u8, tier);
    for (0..tier) |i| {
        result[i] = try allocator.alloc([]u8, lengths[i]);
    }

    // second pass to fill the structure
    tier = @as(u8, 0);
    while (text[pos.*] != 'e') {
        assert(text[pos.*] == 'l');
        pos.* += 1;
        var count: u8 = @as(u8, 0);
        
        while (text[pos.*] != 'e') {
            result[tier][count] = try parseString(text, pos);
            count += 1;
        }
        pos.* += 1;
        count += 1;
        tier += 1;
    }
    pos.* += 1;
    return result;
}

fn parseInfo(allocator: std.mem.Allocator, text: []u8, pos: *u64) !TorrentInfo {
    var _p_length: u64 = undefined;
    var _ps: []u8 = undefined;
    var _priv: ?u8 = null;
    var _nam: []u8 = undefined;
    var _len: u64 = 0;
    var _md5: ?[]u8 = null;
    var _filz: []TorrentInnerFile = undefined;

    // 'd' better start our dictionary
    assert(text[pos.*] == 'd');
    pos.* += 1;
    // 'e' is the end of our dictionary
    while (text[pos.*] != 'e') {
        const key: []u8 = try parseString(text, pos);
        // TODO: May want to look into this switch-based solution:
        // https://andrewkelley.me/post/string-matching-comptime-perfect-hashing-zig.html
        if (std.mem.eql(u8, key, "piece length")) {
            _p_length = try parseInt(text, pos);
        } else if (std.mem.eql(u8, key, "pieces")) {
            _ps = try parseString(text, pos);
        } else if (std.mem.eql(u8, key, "private")) {
            const temp = try parseInt(text, pos);
            _priv = if (temp == 1) 1 else 0;
        } else if (std.mem.eql(u8, key, "name")) {
            _nam = try parseString(text, pos);
        } else if (std.mem.eql(u8, key, "length")) {
            _len = try parseInt(text, pos);
        } else if (std.mem.eql(u8, key, "md5sum")) {
            _md5 = try parseString(text, pos);
        } else if (std.mem.eql(u8, key, "files")) {
            assert(text[pos.*] == 'l');
            pos.* += 1;
            var cursor = pos.*;
            var file_count: usize = 0;
            while (text[cursor] != 'e') {
                try skip(text, &cursor);
                file_count += 1;
            }
            _filz = try allocator.alloc(TorrentInnerFile, file_count);
            file_count = 0;
            while (text[pos.*] != 'e') {
                assert(text[pos.*] == 'd');
                pos.* += 1;
                while(text[pos.*] != 'e') {
                    const sub_key: []u8 = try parseString(text, pos);
                    if (std.mem.eql(u8, sub_key, "length")) {
                        _filz[file_count].length = try parseInt(text, pos);
                    } else if (std.mem.eql(u8, sub_key, "md5sum")) {
                        _filz[file_count].md5sum = try parseString(text, pos);
                    } else if (std.mem.eql(u8, sub_key, "path")) {
                        assert(text[pos.*] == 'l');
                        pos.* += 1;
                        var cursor2 = pos.*;
                        var path_count: usize = 0;
                        while (text[cursor2] != 'e') {
                            try skipString(text, &cursor2);
                            path_count += 1;
                        }
                        _filz[file_count].path = try allocator.alloc([]u8, path_count);
                        path_count = 0;
                        while (text[pos.*] != 'e') {
                            _filz[file_count].path[path_count] = try parseString(text, pos);
                            path_count += 1;
                        }
                        pos.* += 1;
                    } else {
                        print("We really screwed up! {s}", .{sub_key});
                    }
                }
                pos.* += 1;
                file_count += 1;
            }
            pos.* += 1;
        } else {
            print("We failed gang! Unrecognized property in info: {s}\n", .{key});
            try skip(text, pos);
        }
    }
    pos.* += 1;
    
    if (_len > 0) {
        const info: *TorrentInfoSingle = try allocator.create(TorrentInfoSingle);
        info.* = TorrentInfoSingle {
            .piece_length = _p_length,
            .pieces = _ps,
            .private = undefined,
            .name = _nam,
            .length = _len,
            .md5sum = undefined,
        };
        info.private = if (_priv) |p| p else null;
        info.md5sum = if (_md5) |m| m else null;
        return TorrentInfo { .single = info.*, };
    }
    const info: *TorrentInfoMulti = try allocator.create(TorrentInfoMulti);
    info.* = TorrentInfoMulti {
        .piece_length = _p_length,
        .pieces = _ps,
        .private = undefined,
        .name = _nam,
        .files = _filz,
    };
    info.*.private = if (_priv) |p| p else null;
    return TorrentInfo { .multi = info.*, };
}

// Chew up the bytes of the next encoded item without parsing
fn skip(text: []u8, pos: *u64) !void {
    switch (text[pos.*]) {
        '0'...'9' => {
            try skipString(text, pos);
        },
        'i' => {
            // TODO: combine with bDecodeInteger
            pos.* += 1;
            var check = text[pos.*];
            while (check != 'e') : ({ pos.* += 1; check = text[pos.*]; }) {
                assert((check >= '0' and check <= '9') or check == 'e');
            }
            pos.* += 1;
        },
        'l' => {
            pos.* += 1;
            while (text[pos.*] != 'e') {
                try skip(text, pos);
            }
            pos.* += 1;
        },
        'd' => {
            pos.* += 1;
            while (text[pos.*] != 'e') {
                _ = try parseString(text, pos);
                try skip(text, pos);
            }
            pos.* += 1;
        },
        else => unreachable,
    }
}

// Chew up the bytes of the string without parsing
// TODO: combine with parseString
fn skipString(text: []u8, pos: *u64) !void {
    assert(text[pos.*] >= '0' and text[pos.*] <= '9');
    const length = try bDecodeInteger(text, pos, ':');
    pos.* += length;
}

