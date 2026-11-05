pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var template_files: std.ArrayList([]const u8) = .empty;
    var output_path: ?[]const u8 = null;
    var config: Config = .{};
    var log_error_comments = false;

    {
        var args = try init.minimal.args.iterateAllocator(arena);
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                output_path = args.next() orelse fatal("-o requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "--zig-exe")) {
                config.zig_exe = args.next() orelse fatal("--zig-exe requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "--cache-dir")) {
                config.cache_dir = args.next() orelse fatal("--cache-dir requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "-target")) {
                config.target_triple = args.next() orelse fatal("-target requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "-mcpu")) {
                config.mcpu = args.next() orelse fatal("-mcpu requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "-version")) {
                config.version = args.next() orelse fatal("-version requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "-infile")) {
                config.infile = args.next() orelse fatal("-infile requires an argument", .{});
            } else if (std.mem.eql(u8, arg, "-log_err")) {
                log_error_comments = true;
            } else if (std.mem.startsWith(u8, arg, "-I")) {
                config.include_dirs.append(arena, arg) catch |e| oom(e);
            } else {
                template_files.append(arena, arg) catch |e| oom(e);
            }
        }
    }

    if (template_files.items.len == 0) {
        const usage =
            \\Usage: configquery [options] [template-files]
            \\
            \\Processes template files line by line. Lines starting with # are
            \\comments. Each line is NAME VALUE where VALUE is either a literal
            \\or a query starting with ?.
            \\
            \\Options:
            \\  -o <path>                 Write output to file (default: stdout)
            \\  --zig-exe [exe]           Path to zig executable (for compile queries)
            \\  -target [name]            <arch><sub>-<os>-<abi> see the targets command
            \\  -mcpu [cpu]               Specify target CPU and feature set
            \\  -version [version]        Specify Python version
            \\  -infile [python.h.in]     Path to python.h.in file
            \\  -I[dir]                   Add directory to include search path
            \\  -log_err                  Log to stderr the failed query output
            \\  --cache-dir [path]        The local cache directory
            \\
            \\Literal Values
            \\  SIZEOF_INT 4
            \\  RETSIGTYPE .void
            \\  PY_HASH "md5,sha1"
            \\  HAVE_FEATURE defined
            \\  MISSING_FEATURE undef
            \\
            \\Query syntax: NAME ? PASS|FAIL [define=DEF,...] [include=HDR,...] [COMPILE_BODY]
            \\
            \\  HAVE_ALLOCA_H ? 1|undef include=alloca.h
            \\  HAVE_FORK ? 1|undef include=unistd.h int main(){fork();}
            \\  HAVE_PRLIMIT ? 1|undef include=sys/time.h,sys/resource.h int main(){prlimit(0,0,0,0);}
            \\  HAVE_CLOSE_RANGE ? 1|undef define=_GNU_SOURCE include=unistd.h int main(){close_range(0,0,0);}
            \\
            \\configquery is purposely limited to compile-only (no link). Its up to the caller to ensure
            \\header/symbol availability matches library symbol availability.
            \\
        ;
        var stderr = std.Io.File.stderr().writer(io, &.{});
        stderr.interface.writeAll(usage) catch return stderr.err.?;
        stderr.interface.flush() catch return stderr.err.?;
        std.process.exit(1);
    }

    const config_h_in = std.Io.Dir.cwd().readFileAlloc(io, config.infile.?, arena, .unlimited) catch |err| fatal(
        "failed to read '{s}' with {t}",
        .{ config.infile.?, err },
    );

    var config_header: std.array_hash_map.String(ConfigHeader.Value) = .empty;
    try initialize_config(io, arena, config, &config_header);

    var out_buf: [4096]u8 = undefined;
    var out_file = if (output_path) |path| std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| fatal(
        "failed to create '{s}' with {t}",
        .{ path, err },
    ) else std.Io.File.stdout();
    defer if (output_path != null) out_file.close(io);
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;

    var queries: std.ArrayList(Query) = .empty;
    var name_set: std.StringHashMapUnmanaged(u32) = .empty;
    var error_count: u32 = 0;

    for (template_files.items) |template_path| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, template_path, arena, .unlimited) catch |err| fatal(
            "failed to read '{s}' with {t}",
            .{ template_path, err },
        );
        var line_it = std.mem.splitScalar(u8, content, '\n');
        var line_num: u32 = 0;
        while (line_it.next()) |line_untrimmed| {
            line_num += 1;
            switch (parseLine(line_untrimmed)) {
                .skip => continue,
                .err => |msg| {
                    reportError(io, template_path, line_num, "{s}", .{msg});
                    error_count += 1;
                },
                .literal => |lit| {
                    checkUnique(arena, &name_set, io, template_path, line_num, lit.config_name, &error_count);
                    if (parseValue(lit.value_str)) |entry| {
                        config_header.put(arena, lit.config_name, entry) catch @panic("OOM");
                    } else {
                        error_count += 1;
                        reportError(io, template_path, line_num, "{s} '{s}'", .{ lit.config_name, line_untrimmed });
                    }
                },
                .query => |input| {
                    checkUnique(arena, &name_set, io, template_path, line_num, input.config_name, &error_count);
                    if (input.includes.len > 0 or input.compile_body.len > 0) {
                        queries.append(arena, .{
                            .input = input,
                            .file_path = template_path,
                            .line_num = line_num,
                        }) catch |e| oom(e);
                    } else {
                        config_header.put(arena, input.config_name, .{ .string = input.pass_text }) catch @panic("OOM");
                    }
                },
            }
        }
    }

    if (error_count > 0) fatal("{} errors in config templates", .{error_count});

    if (queries.items.len > 0) {
        const zig_exe = config.zig_exe orelse fatal("compile query requires zig-exe", .{});
        const cache_dir = config.cache_dir orelse fatal("compile query requires --cache-dir", .{});
        const argv_template = buildArgvTemplate(arena, zig_exe, &config);

        var group: std.Io.Group = .init;
        for (queries.items, 0..) |*q, i| {
            group.async(io, runCompileCheck, .{ arena, io, q, argv_template, cache_dir, i });
        }
        group.await(io) catch |err| switch (err) {
            error.Canceled => fatal("canceled", .{}),
        };

        for (queries.items) |*q| {
            const result = q.result orelse fatal("compile query for '{s}' has no result", .{q.input.config_name});
            if (result.fatal_msg) |msg| {
                error_count += 1;
                reportError(io, q.file_path, q.line_num, "{s}", .{msg});
            } else {
                const value_text = if (result.success) q.input.pass_text else q.input.fail_text;

                if (parseValue(value_text)) |entry| {
                    config_header.put(arena, q.input.config_name, entry) catch @panic("OOM");
                } else {
                    error_count += 1;
                    reportError(io, q.file_path, q.line_num, "{s} '{s}'", .{ q.input.config_name, value_text });
                }
                if (result.error_comments.len > 0 and log_error_comments) {
                    std.log.debug("{s}{s} {s} : {s}\n", .{ result.error_comments, q.input.config_name, q.input.pass_text, q.input.fail_text });
                }
            }
        }
    }

    const all_keys = config_header.keys();

    var value_map: ValueMap = .empty;
    try value_map.ensureTotalCapacity(arena, all_keys.len);
    for (all_keys) |key| value_map.putAssumeCapacityNoClobber(key, false);

    try renderAutoConfUndef(config_h_in, out, &config_header, &value_map, config.infile.?);

    out.flush() catch return out_writer.err.?;
    if (error_count > 0) fatal("{} errors", .{error_count});
}

pub const Config = struct {
    zig_exe: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    target_triple: ?[]const u8 = null,
    mcpu: ?[]const u8 = null,
    version: ?[]const u8 = null,
    infile: ?[]const u8 = null,
    include_dirs: std.ArrayList([]const u8) = .empty,
};

const Line = union(enum) {
    skip,
    err: []const u8,
    literal: struct {
        config_name: []const u8,
        value_str: []const u8,
    },
    query: QueryInput,
};

const QueryInput = struct {
    config_name: []const u8,
    pass_text: []const u8,
    fail_text: []const u8,
    defines: []const u8,
    includes: []const u8,
    compile_body: []const u8,
};

const Query = struct {
    input: QueryInput,
    file_path: []const u8,
    line_num: u32,
    result: ?Result = null,
    pub const Result = struct {
        success: bool,
        error_comments: []const u8,
        fatal_msg: ?[]const u8,
    };
};

fn have(x: bool) ?u1 {
    return if (x) 1 else null;
}

fn initialize_config(io: std.Io, alloc: std.mem.Allocator, config: Config, config_header: *std.array_hash_map.String(ConfigHeader.Value)) !void {
    const query = try std.Target.Query.parse(.{ .arch_os_abi = config.target_triple.? });
    const t = try std.zig.system.resolveTargetQuery(io, query);

    addValues(alloc, config_header, .{
        .ALIGNOF_LONG = 8,
        .ALIGNOF_SIZE_T = 8,
        .DOUBLE_IS_LITTLE_ENDIAN_IEEE754 = 1,
        .ENABLE_IPV6 = 1,
        .MAJOR_IN_SYSMACROS = have(t.os.tag == .linux),
        .PTHREAD_KEY_T_IS_COMPATIBLE_WITH_INT = 1,
        .PTHREAD_SYSTEM_SCHED_SUPPORTED = 1,
        .PY_BUILTIN_HASHLIB_HASHES = "md5,sha1,sha256,sha512,sha3,blake2",
        .PY_COERCE_C_LOCALE = 1,
        .PY_SSL_DEFAULT_CIPHERS = 1,
        .PY_SUPPORT_TIER = 2,
        .RETSIGTYPE = .void,
        .SIZEOF_DOUBLE = 8,
        .SIZEOF_FLOAT = 4,
        .SIZEOF_FPOS_T = 16,
        .SIZEOF_INT = 4,
        .SIZEOF_LONG = 8,
        .SIZEOF_LONG_DOUBLE = 16,
        .SIZEOF_LONG_LONG = 8,
        .SIZEOF_OFF_T = 8,
        .SIZEOF_PID_T = 4,
        .SIZEOF_PTHREAD_KEY_T = 4,
        .SIZEOF_PTHREAD_T = 8,
        .SIZEOF_SHORT = 2,
        .SIZEOF_SIZE_T = 8,
        .SIZEOF_TIME_T = 8,
        .SIZEOF_UINTPTR_T = 8,
        .SIZEOF_VOID_P = 8,
        .SIZEOF_WCHAR_T = 4,
        .SIZEOF__BOOL = 1,
        .STDC_HEADERS = 1,
        .SYS_SELECT_WITH_SYS_TIME = 1,
        .WITH_DECIMAL_CONTEXTVAR = 1,
        .WITH_DOC_STRINGS = 1,
        .WITH_FREELISTS = 1,
        .WITH_PYMALLOC = 1,
        ._DARWIN_C_SOURCE = 1,
        ._FILE_OFFSET_BITS = 64,
        ._LARGEFILE_SOURCE = 1,
        ._NETBSD_SOURCE = 1,
        ._POSIX_C_SOURCE = .@"200809L",
        ._PYTHONFRAMEWORK = "",
        ._REENTRANT = 1,
        ._XOPEN_SOURCE = 700,
        ._XOPEN_SOURCE_EXTENDED = 1,
        .__BSD_VISIBLE = 1,
        ._ALL_SOURCE = 1,
        ._GNU_SOURCE = 1,
        ._POSIX_PTHREAD_SEMANTICS = 1,
        ._TANDEM_SOURCE = 1,
        .__EXTENSIONS__ = 1,

        .AC_APPLE_UNIVERSAL_BUILD = null,
        .AIX_BUILDDATE = null,
        .AIX_GENUINE_CPLUSPLUS = null,
        .ALT_SOABI = null,
        .ANDROID_API_LEVEL = null,
        .DOUBLE_IS_ARM_MIXED_ENDIAN_IEEE754 = null,
        .DOUBLE_IS_BIG_ENDIAN_IEEE754 = null,
        .GETPGRP_HAVE_ARG = null,
        .MAJOR_IN_MKDEV = null,
        .MVWDELCH_IS_EXPRESSION = null,
        .PACKAGE_BUGREPORT = null,
        .PACKAGE_NAME = null,
        .PACKAGE_STRING = null,
        .PACKAGE_TARNAME = null,
        .PACKAGE_URL = null,
        .PACKAGE_VERSION = null,
        .POSIX_SEMAPHORES_NOT_ENABLED = null,
        .PYLONG_BITS_IN_DIGIT = null,
        .PY_SQLITE_ENABLE_LOAD_EXTENSION = null,
        .PY_SQLITE_HAVE_SERIALIZE = null,
        .PY_SSL_DEFAULT_CIPHER_STRING = null,
        .Py_DEBUG = null,
        .Py_ENABLE_SHARED = null,
        .Py_HASH_ALGORITHM = null,
        .Py_STATS = null,
        .Py_SUNOS_VERSION = null,
        .Py_TRACE_REFS = null,
        .SETPGRP_HAVE_ARG = null,
        .SIGNED_RIGHT_SHIFT_ZERO_FILLS = null,
        .THREAD_STACK_SIZE = null,
        .TIMEMODULE_LIB = null,
        .TM_IN_SYS_TIME = null,
        .USE_COMPUTED_GOTOS = null,
        .WINDOW_HAS_FLAGS = null,
        .WITH_DTRACE = null,
        .WITH_DYLD = null,
        .WITH_EDITLINE = null,
        .WITH_LIBINTL = null,
        .WITH_NEXT_FRAMEWORK = null,
        .WITH_VALGRIND = null,
        .X87_DOUBLE_ROUNDING = null,
        ._BSD_SOURCE = null,
        ._INCLUDE__STDC_A1_SOURCE = null,
        ._LARGE_FILES = null,
        ._MINIX = null,
        ._POSIX_1_SOURCE = null,
        ._POSIX_SOURCE = null,
        ._POSIX_THREADS = null,
        ._WASI_EMULATED_GETPID = null,
        ._WASI_EMULATED_PROCESS_CLOCKS = null,
        ._WASI_EMULATED_SIGNAL = null,
        .clock_t = null,
        .@"const" = null,
        .gid_t = null,
        .mode_t = null,
        .off_t = null,
        .pid_t = null,
        .signed = null,
        .size_t = null,
        .socklen_t = null,
        .uid_t = null,
        .WORDS_BIGENDIAN = null,

        .HAVE_BROKEN_MBSTOWCS = null,
        .HAVE_BROKEN_NICE = null,
        .HAVE_BROKEN_PIPE_BUF = null,
        .HAVE_BROKEN_POLL = null,
        .HAVE_BROKEN_POSIX_SEMAPHORES = null,
        .HAVE_BROKEN_PTHREAD_SIGMASK = null,
        .HAVE_BROKEN_SEM_GETVALUE = null,
        .HAVE_BROKEN_UNSETENV = null,

        .HAVE_PTHREAD_STUBS = null,
        .HAVE_USABLE_WCHAR_T = null,
        .HAVE_NON_UNICODE_WCHAR_T_REPRESENTATION = null,
        .HAVE_CHROOT = have(t.os.tag == .linux),
        .HAVE_GCC_ASM_FOR_MC68881 = have(t.cpu.arch == .m68k),
        .HAVE_GCC_ASM_FOR_X64 = have(t.cpu.arch == .x86_64),
        .HAVE_GCC_ASM_FOR_X87 = have(t.cpu.arch == .x86_64 or t.cpu.arch == .x86),
        // Readline type (static configuration, not function test)
        .HAVE_RL_COMPDISP_FUNC_T = null,
    });
    if (std.mem.eql(u8, config.version.?, "3.11.13")) addValues(alloc, config_header, .{
        .PY_FORMAT_SIZE_T = "z",
        .TIME_WITH_SYS_TIME = 1,
        .FLOAT_WORDS_BIGENDIAN = null,
    });
    if (std.mem.eql(u8, config.version.?, "3.12.11"))
        addValues(alloc, config_header, .{
            .ALIGNOF_MAX_ALIGN_T = @as(u32, switch (t.cpu.arch) {
                .x86_64, .aarch64 => 16,
                .x86, .arm => 8,
                else => 8,
            }),

            // ncurses library (static configuration, not function test)
            .HAVE_NCURSESW = null,

            // Performance trampoline feature
            .PY_HAVE_PERF_TRAMPOLINE = null,

            ._HPUX_ALT_XOPEN_SOCKET_API = null,
            ._OPENBSD_SOURCE = null,

            // C standard feature test macros (all set to null as they're optional)
            .__STDC_WANT_IEC_60559_ATTRIBS_EXT__ = null,
            .__STDC_WANT_IEC_60559_BFP_EXT__ = null,
            .__STDC_WANT_IEC_60559_DFP_EXT__ = null,
            .__STDC_WANT_IEC_60559_FUNCS_EXT__ = null,
            .__STDC_WANT_IEC_60559_TYPES_EXT__ = null,
            .__STDC_WANT_LIB_EXT2__ = null,
            .__STDC_WANT_MATH_SPEC_FUNCS__ = null,
        });
}
pub fn addValue(arena: std.mem.Allocator, config_header: *std.array_hash_map.String(ConfigHeader.Value), name: []const u8, comptime T: type, value: T) void {
    return addValueInner(arena, config_header, name, T, value) catch @panic("OOM");
}

fn addValueInner(arena: std.mem.Allocator, config_header: *std.array_hash_map.String(ConfigHeader.Value), name: []const u8, comptime T: type, value: T) !void {
    switch (@typeInfo(T)) {
        .null => {
            try config_header.put(arena, name, .undef);
        },
        .void => {
            try config_header.put(arena, name, .defined);
        },
        .bool => {
            try config_header.put(arena, name, .{ .boolean = value });
        },
        .int => {
            try config_header.put(arena, name, .{ .int = value });
        },
        .comptime_int => {
            try config_header.put(arena, name, .{ .int = value });
        },
        .@"enum", .enum_literal => {
            try config_header.put(arena, name, .{ .ident = @tagName(value) });
        },
        .optional => {
            if (value) |x| {
                return addValueInner(arena, config_header, name, @TypeOf(x), x);
            } else {
                try config_header.put(arena, name, .undef);
            }
        },
        .pointer => |ptr| {
            switch (@typeInfo(ptr.child)) {
                .array => |array| {
                    if (ptr.size == .one and array.child == u8) {
                        try config_header.put(arena, name, .{ .string = value });
                        return;
                    }
                },
                .int => {
                    if (ptr.size == .slice and ptr.child == u8) {
                        try config_header.put(arena, name, .{ .string = value });
                        return;
                    }
                },
                else => {},
            }

            @compileError("unsupported ConfigHeader value type: " ++ @typeName(T));
        },
        else => @compileError("unsupported ConfigHeader value type: " ++ @typeName(T)),
    }
}

pub fn addValues(arena: std.mem.Allocator, config_header: *std.array_hash_map.String(ConfigHeader.Value), values: anytype) void {
    const info = @typeInfo(@TypeOf(values)).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        addValue(arena, config_header, field_name, field_type, @field(values, field_name));
    }
}

fn parseValue(ostr: ?[]const u8) ?ConfigHeader.Value {
    if (ostr == null) return .undef;
    const str = ostr.?;
    if (std.mem.eql(u8, str, "undef")) return .undef;
    if (std.mem.eql(u8, str, "defined")) return .defined;
    if (std.mem.eql(u8, str, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, str, "true")) return .{ .boolean = true };
    if (std.fmt.parseInt(i64, str, 10)) |int| return .{ .int = int } else |_| {}
    if (std.mem.startsWith(u8, str, ":")) return .{ .ident = str[1..] };
    if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"') return .{ .string = str[1 .. str.len - 1] };
    return null;
}

fn parseLine(line_untrimmed: []const u8) Line {
    const line = std.mem.trim(u8, line_untrimmed, &std.ascii.whitespace);
    if (line.len == 0 or line[0] == '#') return .skip;

    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .err = "expected 'NAME VALUE'" };
    const config_name = line[0..first_space];
    const value_str = std.mem.trimStart(u8, line[first_space + 1 ..], " ");

    if (!std.mem.startsWith(u8, value_str, "?")) {
        _ = parseValue(value_str) orelse
            return .{ .err = "invalid config value" };
        return .{ .literal = .{ .config_name = config_name, .value_str = value_str } };
    }

    const pass_str, const after_pass = scanConfigValue(value_str, 1);
    _ = parseValue(pass_str) orelse return .{ .err = "expected PASS_VALUE after ?" };
    const pipe_index = skipWhitespace(value_str, after_pass);
    if (pipe_index >= value_str.len or value_str[pipe_index] != '|')
        return .{ .err = "expected '|' after PASS_VALUE" };
    const fail_str, const after_fail = scanConfigValue(value_str, pipe_index + 1);
    _ = parseValue(fail_str) orelse return .{ .err = "expected FAIL_VALUE after '|'" };
    var rest = std.mem.trimStart(u8, value_str[after_fail..], " ");
    const defines = parseExprClause(&rest, "define=");
    const includes = parseExprClause(&rest, "include=");
    if (includes.len == 0 and rest.len == 0) return .{ .err = "query has no include nor code to check" };
    return .{ .query = .{
        .config_name = config_name,
        .pass_text = pass_str,
        .fail_text = fail_str,
        .defines = defines,
        .includes = includes,
        .compile_body = rest,
    } };
}

fn skipWhitespace(str: []const u8, start: usize) usize {
    var i = start;
    while (true) : (i += 1) {
        if (i >= str.len) return i;
        if (!std.ascii.isWhitespace(str[i])) return i;
    }
}

fn scanConfigValue(str: []const u8, start: usize) struct { []const u8, usize } {
    const i = skipWhitespace(str, start);
    if (i >= str.len) return .{ "", str.len };
    switch (str[i]) {
        'a'...'z', 'A'...'Z', '_' => return scanAlphanum(str, i),
        '-', '0'...'9' => return scanInt(str, i),
        // TODO: handle :IDENTICAL and "QUOTED_STRING"
        else => |ch| std.debug.panic("todo '{c}'", .{ch}),
    }
}
fn scanAlphanum(str: []const u8, start: usize) struct { []const u8, usize } {
    switch (str[start]) {
        'a'...'z', 'A'...'Z', '_' => {},
        else => unreachable,
    }
    var i = start + 1;
    while (true) : (i += 1) {
        if (i >= str.len) return .{ str[start..], i };
        switch (str[i]) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
            else => return .{ str[start..i], i },
        }
    }
}
fn scanInt(str: []const u8, start: usize) struct { []const u8, usize } {
    switch (str[start]) {
        '-', '0'...'9' => {},
        else => unreachable,
    }
    var i = start + 1;
    while (true) : (i += 1) {
        if (i >= str.len) return .{ str[start..], i };
        switch (str[i]) {
            '0'...'9' => {},
            else => return .{ str[start..i], i },
        }
    }
}

fn parseExprClause(rest: *[]const u8, prefix: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, rest.*, prefix)) return "";
    const after_prefix = rest.*[prefix.len..];
    const end = std.mem.indexOfScalar(u8, after_prefix, ' ') orelse after_prefix.len;
    rest.* = std.mem.trimStart(u8, after_prefix[end..], " ");
    return after_prefix[0..end];
}

fn buildArgvTemplate(
    arena: std.mem.Allocator,
    zig_exe: []const u8,
    config: *const Config,
) []const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(arena, zig_exe) catch |e| oom(e);
    argv.append(arena, "build-obj") catch |e| oom(e);
    if (config.target_triple) |t| {
        argv.append(arena, "-target") catch |e| oom(e);
        argv.append(arena, t) catch |e| oom(e);
    }
    if (config.mcpu) |m| {
        argv.append(arena, "-mcpu") catch |e| oom(e);
        argv.append(arena, m) catch |e| oom(e);
    }
    argv.append(arena, "-lc") catch |e| oom(e);
    argv.append(arena, "-fno-emit-bin") catch |e| oom(e);
    for (config.include_dirs.items) |dir| argv.append(arena, dir) catch |e| oom(e);
    return argv.toOwnedSlice(arena) catch |e| oom(e);
}

fn runCompileCheck(
    arena: std.mem.Allocator,
    io: std.Io,
    query: *Query,
    argv_template: []const []const u8,
    cache_dir: []const u8,
    index: usize,
) void {
    query.result = doCompileCheck(arena, io, query, argv_template, cache_dir, index);
}

fn doCompileCheck(
    arena: std.mem.Allocator,
    io: std.Io,
    query: *const Query,
    argv_template: []const []const u8,
    cache_dir: []const u8,
    index: usize,
) Query.Result {
    const sep = std.fs.path.sep_str;

    const pid = switch (@import("builtin").os.tag) {
        .linux => std.os.linux.getpid(),
        .macos, .ios => std.c.getpid(),
        else => @compileError("unsupported OS"),
    };
    var task_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const task_dir = std.fmt.bufPrint(&task_dir_buf, "{s}" ++ sep ++ "tmp" ++ sep ++ "cq-{}-{}", .{ cache_dir, pid, index }) catch
        fatal("cache-dir path too long", .{});
    std.Io.Dir.cwd().createDirPath(io, task_dir) catch |err|
        fatal("failed to create '{s}': {t}", .{ task_dir, err });

    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = std.fmt.bufPrint(&source_buf, "{s}" ++ sep ++ "check.c", .{task_dir}) catch
        fatal("source path too long", .{});

    {
        var file = std.Io.Dir.cwd().createFile(io, source_path, .{}) catch |err|
            fatal("failed to create '{s}' with {t}", .{ source_path, err });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        writeSource(&w.interface, &query.input) catch fatal("failed to write source: {t}", .{w.err.?});
        std.debug.assert(w.interface.end == 0);
    }

    const argv = blk: {
        var a = std.ArrayList([]const u8).initCapacity(arena, argv_template.len + 3) catch |e| oom(e);
        a.appendSliceAssumeCapacity(argv_template);
        a.appendAssumeCapacity(source_path);
        break :blk a.items;
    };

    const result = std.process.run(arena, io, .{
        .argv = argv,
    }) catch |err| fatal("zig build-obj failed with {t}", .{err});

    var delete_task_dir = true;
    defer if (delete_task_dir) std.Io.Dir.cwd().deleteTree(io, task_dir) catch {};

    switch (result.term) {
        .exited => |code| if (code == 0) return .{
            .success = true,
            .error_comments = "",
            .fatal_msg = null,
        },
        inline else => |sig, kind| {
            return .{
                .success = false,
                .error_comments = "",
                .fatal_msg = std.fmt.allocPrint(arena, "zig build-obj terminated ({t}) with {}", .{ kind, sig }) catch |e| oom(e),
            };
        },
    }

    var comments: std.ArrayList(u8) = .empty;
    comments.appendSlice(arena, std.fmt.allocPrint(arena, "# compilation for '{s}' failed with the following:\n", .{query.input.config_name}) catch |e| oom(e)) catch |e| oom(e);
    var stderr_it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (stderr_it.next()) |stderr_line| {
        if (stderr_line.len > 0) comments.appendSlice(arena, std.fmt.allocPrint(arena, "# {s}\n", .{stderr_line}) catch |e| oom(e)) catch |e| oom(e);
    }

    var has_expected_error = false;
    var has_unexpected_error = false;
    var err_it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (err_it.next()) |err_line_raw| {
        const err_line = std.mem.trimEnd(u8, err_line_raw, "\r");
        if (err_line.len == 0) continue;
        const error_prefix = "error: ";
        const error_start = std.mem.indexOf(u8, err_line, error_prefix) orelse continue;
        const err_msg = err_line[error_start + error_prefix.len ..];
        if (std.mem.endsWith(u8, err_msg, "file not found") or
            std.mem.startsWith(u8, err_msg, "call to undeclared function ") or
            std.mem.startsWith(u8, err_msg, "call to undeclared library function ") or
            std.mem.startsWith(u8, err_msg, "use of undeclared identifier") or
            std.mem.startsWith(u8, err_msg, "invalid instruction mnemonic") or
            std.mem.startsWith(u8, err_msg, "function definition is not allowed") or
            std.mem.startsWith(u8, err_msg, "unknown type name") or
            std.mem.startsWith(u8, err_msg, "no member named") or
            std.mem.startsWith(u8, err_msg, "incomplete definition of type") or
            std.mem.startsWith(u8, err_msg, "implicit declaration of function") or
            std.mem.startsWith(u8, err_msg, "redefinition of"))
        {
            has_expected_error = true;
        } else {
            has_unexpected_error = true;
        }
    }

    var fatal_msg: ?[]const u8 = null;
    if (has_unexpected_error and !has_expected_error) {
        delete_task_dir = false;
        fatal_msg = std.fmt.allocPrint(
            arena,
            "compile check failed with unexpected error(s):\n{s}",
            .{result.stderr},
        ) catch |e| oom(e);
    }

    return .{
        .success = false,
        .error_comments = comments.toOwnedSlice(arena) catch |e| oom(e),
        .fatal_msg = fatal_msg,
    };
}

fn checkUnique(
    arena: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(u32),
    io: std.Io,
    file: []const u8,
    line: u32,
    name: []const u8,
    error_count: *u32,
) void {
    const result = seen.getOrPut(arena, name) catch |e| oom(e);
    if (result.found_existing) {
        reportError(io, file, line, "duplicate config name '{s}' (first seen on line {})", .{ name, result.value_ptr.* });
        error_count.* += 1;
    } else {
        result.value_ptr.* = line;
    }
}

fn writeSource(w: *std.Io.Writer, q: *const QueryInput) error{WriteFailed}!void {
    if (q.defines.len > 0) {
        var it = std.mem.splitScalar(u8, q.defines, ',');
        while (it.next()) |d| try w.print("#define {s}\n", .{d});
    }
    if (q.includes.len > 0) {
        var it = std.mem.splitScalar(u8, q.includes, ',');
        while (it.next()) |h| try w.print("#include <{s}>\n", .{h});
    }
    if (q.compile_body.len != 0) {
        try w.writeAll(q.compile_body);
        try w.writeByte('\n');
    }
    try w.flush();
}

test parseLine {
    {
        const q = parseLine("HAVE_ALLOCA_H ? 1|undef include=alloca.h").query;
        try std.testing.expectEqualStrings("HAVE_ALLOCA_H", q.config_name);
        try std.testing.expectEqualStrings("1", q.pass_text);
        try std.testing.expectEqualStrings("undef", q.fail_text);
        try std.testing.expectEqualStrings("", q.defines);
        try std.testing.expectEqualStrings("alloca.h", q.includes);
        try std.testing.expectEqualStrings("", q.compile_body);
    }
    {
        const q = parseLine("HAVE_CLOSE_RANGE ? 1|undef define=_GNU_SOURCE include=unistd.h int main(){close_range(0,0,0);}").query;
        try std.testing.expectEqualStrings("_GNU_SOURCE", q.defines);
        try std.testing.expectEqualStrings("unistd.h", q.includes);
        try std.testing.expectEqualStrings("int main(){close_range(0,0,0);}", q.compile_body);
    }
    {
        const q = parseLine("HAVE_PRLIMIT ? 1|undef include=sys/time.h,sys/resource.h int main(){prlimit(0,0,0,0);}").query;
        try std.testing.expectEqualStrings("sys/time.h,sys/resource.h", q.includes);
        try std.testing.expectEqualStrings("int main(){prlimit(0,0,0,0);}", q.compile_body);
    }
    {
        const q = parseLine("HAVE_BUILTIN_ATOMIC ? 1|undef int main(){return 0;}").query;
        try std.testing.expectEqualStrings("", q.defines);
        try std.testing.expectEqualStrings("", q.includes);
        try std.testing.expectEqualStrings("int main(){return 0;}", q.compile_body);
    }
    {
        const lit = parseLine("SIZEOF_INT 4").literal;
        try std.testing.expectEqualStrings("SIZEOF_INT", lit.config_name);
        try std.testing.expectEqualStrings("4", lit.value_str);
    }
    try std.testing.expect(parseLine("") == .skip);
    try std.testing.expect(parseLine("# comment") == .skip);
    try std.testing.expect(parseLine("NOVALUE") == .err);
}

fn ensureAllValuesUsed(
    value_map: *ValueMap,
    src_path: []const u8,
) !void {
    var any_errors = false;
    for (value_map.keys(), value_map.values()) |name, used| {
        if (used) continue;
        std.log.err("{s}: config header value unused: {s}", .{ src_path, name });
        any_errors = true;
    }
    if (any_errors) unreachable;
}

const os_newline = if (@import("builtin").os.tag == .windows) "\r\n" else "\n";

fn detectNewline(contents: []const u8) []const u8 {
    const lf_index = std.mem.findScalar(u8, contents, '\n') orelse return os_newline;
    return if (lf_index > 0 and contents[lf_index - 1] == '\r') "\r\n" else "\n";
}

const header_text = "This file was generated by ConfigHeader using the Zig Build System.";
const c_generated_line = "/* " ++ header_text ++ " */";
const asm_generated_line = "; " ++ header_text;

fn renderAutoConfUndef(
    contents: []const u8,
    w: *Writer,
    config_header: *const std.array_hash_map.String(ConfigHeader.Value),
    value_map: *ValueMap,
    src_path: []const u8,
) !void {
    const newline = detectNewline(contents);

    try w.writeAll(c_generated_line);
    try w.writeAll(newline);

    var any_errors = false;
    var line_index: u32 = 0;
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |raw_line| : (line_index += 1) {
        const last_line = line_it.index == line_it.buffer.len;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (!std.mem.startsWith(u8, line, "#")) {
            try w.writeAll(line);
            if (!last_line) try w.writeAll(newline);
            continue;
        }
        var it = std.mem.tokenizeAny(u8, line[1..], " \t\r");
        const undef = it.next().?;
        if (!std.mem.eql(u8, undef, "undef")) {
            try w.writeAll(line);
            if (!last_line) try w.writeAll(newline);
            continue;
        }
        const name = it.next().?;
        const index = value_map.getIndex(name) orelse {
            std.log.err("{s}:{d}: unspecified config header value: {s}", .{
                src_path, line_index + 1, name,
            });
            any_errors = true;
            continue;
        };
        value_map.values()[index] = true; // Set to used.
        try renderValueC(w, newline, name, config_header.get(name).?);
    }

    try ensureAllValuesUsed(value_map, src_path);
    if (any_errors) return error.MakeFailed;
}

fn renderValueC(w: *Writer, newline: []const u8, name: []const u8, value: ConfigHeader.Value) !void {
    switch (value) {
        .undef => try w.print("/* #undef {s} */{s}", .{ name, newline }),
        .defined => try w.print("#define {s}{s}", .{ name, newline }),
        .boolean => |b| return renderValueCBool(w, newline, name, b),
        .int => |i| try w.print("#define {s} {d}{s}", .{ name, i, newline }),
        .ident => |ident| return renderValueCIdent(w, newline, name, ident),
        .string => |string| try w.print("#define {s} \"{f}\"{s}", .{ name, std.zig.fmtString(string), newline }),
    }
}

fn renderValueCBool(w: *Writer, newline: []const u8, name: []const u8, b: bool) Writer.Error!void {
    return w.print("#define {s} {c}{s}", .{ name, @as(u8, '0') + @intFromBool(b), newline });
}

fn renderValueCIdent(w: *Writer, newline: []const u8, name: []const u8, ident: []const u8) Writer.Error!void {
    try w.print("#define {s}", .{name});
    if (ident.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(ident);
    }
    return w.writeAll(newline);
}

fn reportError(io: std.Io, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
    var stderr = std.Io.File.stderr().writer(io, &.{});
    stderr.interface.print("{s}:{}: " ++ fmt ++ "\n", .{ file, line } ++ args) catch
        fatal("failed to write to stderr: {t}", .{stderr.err.?});
}

fn oom(err: error{OutOfMemory}) noreturn {
    fatal("{s}", .{@errorName(err)});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const std = @import("std");
const ConfigHeader = std.Build.Step.ConfigHeader;
const LazyPath = std.Build.LazyPath;
const Writer = std.Io.Writer;
const ValueMap = std.array_hash_map.String(bool);
