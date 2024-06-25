const std = @import("std");
const Torrent_File = @import("Torrent_File.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len != 2) {
        std.debug.print("Expected something like `deluzig <filename.torrent>`\nYou had {d} arg(s).\n", .{args.len});
        std.process.exit(1);
    }

    const file = try Torrent_File.readFile(allocator, args[1]);

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = bw.writer();

    try file.printSummary(stdout);

    try bw.flush(); // don't forget to flush!
}
