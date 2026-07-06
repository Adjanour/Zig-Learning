const std = @import("std");
const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const content = try std.Io.Dir.cwd().readFileAlloc(io, "index.html", allocator, .unlimited);

    var code = false;
    var builder = std.ArrayList(u8).empty;
    var result = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    errdefer result.deinit(allocator);

    var i: usize = 0;

    while (i < content.len) {
        const rest = content[i..];
        if (!code) {
            const CODE_START = "<?";
            if (std.mem.startsWith(u8, rest, CODE_START)) {
                const html = try builder.toOwnedSlice(allocator);
                try result.appendSlice(allocator, try std.fmt.allocPrint(allocator, "writer.WriteAll(\"{s}\");\n", .{html}));
                code = true;
                i += CODE_START.len;
            } else {
                switch (content[i]) {
                    '\n' => try builder.appendSlice(allocator, "\\n"),
                    '\r' => try builder.appendSlice(allocator, "\\r"),
                    '\t' => try builder.appendSlice(allocator, "\\t"),
                    '\\' => try builder.appendSlice(allocator, "\\\\"),
                    '\"' => try builder.appendSlice(allocator, "\\\""),
                    else => try builder.append(allocator, content[i]),
                }
                i += 1;
            }
        } else {
            const CODE_END = "?>";
            if (std.mem.startsWith(u8, rest, CODE_END)) {
                const code_src = try builder.toOwnedSlice(allocator);
                try result.appendSlice(allocator, code_src);
                try result.appendSlice(allocator, "\n");
                code = false;
                i += CODE_END.len;
            } else {
                try builder.append(allocator, content[i]);
                i += 1;
            }
        }
    }

    if (!code) {
        const html = try builder.toOwnedSlice(allocator);
        if (html.len > 0) {
            try result.appendSlice(allocator, try std.fmt.allocPrint(allocator, "writer.WriteAll(\"{s}\");\n", .{html}));
        }
    }

    const output = try result.toOwnedSlice(allocator);
    print("{s}\n", .{output});
}
