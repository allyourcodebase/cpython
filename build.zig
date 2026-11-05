pub const Version = enum {
    @"3.11.13",
    @"3.12.11",
    pub fn libName(self: Version) []const u8 {
        return switch (self) {
            .@"3.11.13" => "3.11",
            .@"3.12.11" => "3.12",
        };
    }

    pub const latest: Version = .@"3.12.11";
};

/// There are 3 stages of the python exe, the first two are used compile and embed modules for
/// the next stage which is referred to as "freezing" modules.
const PythonExeStage = union(enum) {
    /// stage1: used to "freeze" the modules used by bootstrap
    freeze_module,
    /// stage2: used to freeze the remaining modules for the final exe
    bootstrap: Stage2FrozenMods,
    /// stage3: the final python exe
    final: struct {
        stage2: Stage2FrozenMods,
        deepfreeze_c: std.Build.LazyPath,
        frozen_headers: []const std.Build.LazyPath,
    },

    pub fn stage2FrozenMods(self: PythonExeStage) ?Stage2FrozenMods {
        return switch (self) {
            .freeze_module => null,
            .bootstrap => |mods| mods,
            .final => |final| final.stage2,
        };
    }
};
const Stage2FrozenMods = struct {
    getpath_h: std.Build.LazyPath,
    importlib_bootstrap_h: std.Build.LazyPath,
    importlib_bootstrap_external_h: std.Build.LazyPath,
    zipimport_h: std.Build.LazyPath,
};

pub fn build(b: *std.Build) !void {
    const version: Version = b.option(Version, "version", "Python Version") orelse .latest;

    const upstream: *std.Build.Dependency = switch (version) {
        .@"3.11.13" => if (b.lazyDependency("upstream_3.11.13", .{})) |d| d else noUpstream(b),
        .@"3.12.11" => if (b.lazyDependency("upstream_3.12.11", .{})) |d| d else noUpstream(b),
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ssl_enabled = b.option(bool, "ssl", "enable ssl") orelse switch (target.result.os.tag) {
        .macos => false, // there's an issue building openssl on macos
        else => true,
    };

    var hacl: ?*std.Build.Step.Compile = undefined;
    if (version == .@"3.12.11") {
        hacl = b.addLibrary(.{
            .name = "hacl",
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        hacl.?.root_module.addIncludePath(upstream.path("./Modules/_hacl/include"));
        hacl.?.root_module.addIncludePath(upstream.path("./Modules/_hacl/"));
        hacl.?.root_module.addCSourceFile(.{ .file = upstream.path("./Modules/_hacl/Hacl_Hash_SHA2.c"), .flags = &.{
            "-D_BSD_SOURCE", "-D_DEFAULT_SOURCE",   "-fwrapv",
            "-std=c11",      "-fvisibility=hidden", "-DVPATH=\"\"",
        } });
    } else hacl = null;

    const libs_host: Libs = .{ .zlib = null, .openssl = null, .hacl = null };
    const libs_target: Libs = .{
        .zlib = (b.dependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })).artifact("z"),
        .openssl = if (ssl_enabled) (if (b.lazyDependency("openssl", .{
            .target = target,
            .optimize = optimize,
        })) |dep| dep.artifact("openssl") else null) else null,
        .hacl = hacl,
    };

    if (b.graph.needed_lazy_dependencies.count() > 0) return;

    const configquery_exe = b.addExecutable(.{
        .name = "configquery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("configquery.zig"),
            .target = b.graph.host,
        }),
    });

    const makesetup_host = addMakesetup(b, version, upstream, libs_host, b.graph.host.result.os.tag);
    const makesetup_target = addMakesetup(b, version, upstream, libs_target, target.result.os.tag);

    const pyconfig_host = try addPyconfig(b, version, upstream, b.graph.host, libs_host, configquery_exe);

    const freeze_module_exe = addPythonExe(b, upstream, b.graph.host, .Debug, .{
        .name = "freeze_module",
        .setup = makesetup_host,
        .pyconfig = pyconfig_host,
        .stage = .freeze_module,
    });

    const stage2_frozen_mods: Stage2FrozenMods = .{
        .getpath_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("getpath");
            freeze.addFileArg(upstream.path("Modules/getpath.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/getpath.h");
        },
        .importlib_bootstrap_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap.h");
        },
        .importlib_bootstrap_external_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("importlib._bootstrap_external");
            freeze.addFileArg(upstream.path("Lib/importlib/_bootstrap_external.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/importlib._bootstrap_external.h");
        },
        .zipimport_h = blk: {
            const freeze = b.addRunArtifact(freeze_module_exe);
            freeze.addArg("zipimport");
            freeze.addFileArg(upstream.path("Lib/zipimport.py"));
            break :blk freeze.addOutputFileArg("Python/frozen_modules/zipimport.h");
        },
    };

    const frozen_headers, const deepfreeze_c = blk_deepfreeze_c: {
        const bootstrap_python_exe = addPythonExe(b, upstream, b.graph.host, .Debug, .{
            .name = "bootstrap_python",
            .setup = makesetup_host,
            .pyconfig = pyconfig_host,
            .stage = .{ .bootstrap = stage2_frozen_mods },
        });
        const bootstrap_packaged = packagePython(b, version, upstream, bootstrap_python_exe, &.{});

        const frozen_headers = b.allocator.alloc(std.Build.LazyPath, frozen_modules.len) catch @panic("OOM");
        // don't free

        const freeze_step = b.step("freeze", "");
        for (frozen_modules, frozenModuleNames(version), frozen_headers) |mod_path, mod_name, *header| {
            const freeze = std.Build.Step.Run.create(b, b.fmt("run _freeze_module.py for '{s}'", .{mod_path}));
            freeze.addFileArg(bootstrap_packaged.exe);
            freeze.addFileArg(upstream.path("Programs/_freeze_module.py"));
            freeze.addArg(mod_name);
            freeze.addFileArg(upstream.path(mod_path));
            header.* = freeze.addOutputFileArg(b.fmt("frozen_modules/{s}.h", .{mod_name}));
            freeze_step.dependOn(&freeze.step);
        }

        const run = std.Build.Step.Run.create(b, "run deepfreeze.py");
        run.addFileArg(bootstrap_packaged.exe);
        run.addFileArg(upstream.path(switch (version) {
            .@"3.11.13" => "Tools/scripts/deepfreeze.py",
            else => "Tools/build/deepfreeze.py",
        }));
        run.addArg("-o");
        const deepfreeze_c = run.addOutputFileArg("deepfreeze.c");
        for (frozenModuleNames(version), frozen_headers) |mod_name, header| {
            const mod_name_part = b.fmt(":{s}", .{mod_name});
            run.addFileArg2(header, .{ .suffix = mod_name_part });
        }
        b.step("deepfreeze", "").dependOn(&run.step);
        break :blk_deepfreeze_c .{ frozen_headers, deepfreeze_c };
    };

    const final_pyconfig = try addPyconfig(b, version, upstream, target, libs_target, configquery_exe);
    const final_exe = addPythonExe(b, upstream, target, optimize, .{
        .name = "python",
        .setup = makesetup_target,
        .pyconfig = final_pyconfig,
        .stage = .{
            .final = .{
                .stage2 = stage2_frozen_mods,
                .frozen_headers = frozen_headers,
                .deepfreeze_c = deepfreeze_c,
            },
        },
    });
    const final_packaged = packagePython(b, version, upstream, final_exe, &.{final_pyconfig.sysconfigdata.?});
    const install_final = b.addInstallDirectory(.{
        .source_dir = final_packaged.root,
        .install_dir = .prefix,
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&install_final.step);

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    try ci(b, version, ssl_enabled, upstream, ci_step, .{
        .stage2_frozen_mods = stage2_frozen_mods,
        .frozen_headers = frozen_headers,
        .deepfreeze_c = deepfreeze_c,
    }, configquery_exe);
}

fn noUpstream(b: *std.Build) *std.Build.Dependency {
    const dependency = b.allocator.create(std.Build.Dependency) catch @panic("OOM");
    dependency.* = .{ .builder = b };
    return dependency;
}

fn addMakesetup(
    b: *std.Build,
    version: Version,
    upstream: *std.Build.Dependency,
    libs: Libs,
    os_tag: std.Target.Os.Tag,
) makesetup.Setup {
    const is_posix = (os_tag != .windows);

    const stdlib_modules_common = .{
        ._ssl = (libs.openssl != null),
        .zlib = (libs.zlib != null),

        // Modules that should always be present (POSIX and Windows):
        ._asyncio = true,
        ._bisect = true,
        ._contextvars = true,
        ._csv = true,
        ._datetime = true,
        ._decimal = false, // depends on libmpdec, disabled until it's available
        ._heapq = true,
        ._json = true,
        ._lsprof = true,
        ._multiprocessing = true,
        ._opcode = true,
        ._pickle = true,
        ._queue = true,
        ._random = true,
        ._socket = (os_tag != .windows),
        ._statistics = true,
        ._struct = true,
        ._zoneinfo = true,
        .array = true,
        .audioop = true,
        .binascii = true,
        .cmath = true,
        .math = true,
        .mmap = true,
        .select = true,

        // text encodings and unicode
        ._codecs_cn = false,
        ._codecs_hk = false,
        ._codecs_iso2022 = false,
        ._codecs_jp = false,
        ._codecs_kr = false,
        ._codecs_tw = false,
        ._multibytecodec = true,
        .unicodedata = true,

        // Modules with some UNIX dependencies
        ._posixsubprocess = is_posix,
        .fcntl = is_posix,
        ._posixshmem = is_posix,
        .grp = is_posix,
        .ossaudiodev = (os_tag == .linux),
        .resource = (os_tag == .linux),
        .spwd = (os_tag == .linux),
        .syslog = is_posix,
        .termios = is_posix,

        ._md5 = true,
        ._sha1 = true,
        ._sha3 = true,
        ._blake2 = true,

        ._bz2 = false,
        ._lzma = false,

        ._dbm = false,
        ._gdbm = false,
        .readline = false,
        .pyexpat = false,
        ._elementtree = false,
        ._crypt = false,
        .nis = false,
        ._curses = false,
        ._curses_panel = false,
        ._sqlite3 = false,
        ._hashlib = false,
        ._uuid = false,
        ._tkinter = false,
        ._scproxy = false,
        ._xxtestfuzz = false,
        ._testbuffer = false,
        ._testinternalcapi = false,
        ._testcapi = false,
        ._testclinic = false,
        ._testimportmultiple = false,
        ._testmultiphase = false,
        ._ctypes_test = false,
        .xxlimited = false,
        .xxlimited_35 = false,
        ._xxsubinterpreters = false,
    };
    const @"stdlib_modules_3.11.13" = .{
        ._ctypes = true,
        ._typing = true,
        ._sha256 = true,
        ._sha512 = true,
    };
    const @"stdlib_modules_3.12.11" = .{
        ._ctypes = false,
        ._sha2 = (libs.hacl != null),
        .xxsubtype = false,
        ._xxinterpchannels = false,
    };

    const pwd_enabled = is_posix;
    const value_str = if (pwd_enabled) "" else "#";

    const dep_root_path = upstream.builder.root.root_dir.path orelse ".";
    const bootstrap_in_path = b.pathJoin(&.{ dep_root_path, "Modules/Setup.bootstrap.in" });
    b.dependOnFileContents(upstream.path("Modules/Setup.bootstrap.in"));

    // First replace call
    const setup_bootstrap = replace.replace(b, bootstrap_in_path, &.{
        b.fmt("MODULE_PWD_TRUE={s}", .{value_str}),
    });
    defer b.allocator.free(setup_bootstrap);

    var replacements: std.ArrayList([]const u8) = .empty;
    defer replacements.deinit(b.allocator);

    replacements.append(b.allocator, "MODULE_{NAME}_TRUE=MODULE_{NAME}_TRUE") catch @panic("OOM");
    replacements.append(b.allocator, "MODULE_BUILDTYPE=static") catch @panic("OOM");
    addReplacements(&replacements, b, @TypeOf(stdlib_modules_common), stdlib_modules_common);
    switch (version) {
        .@"3.11.13" => addReplacements(&replacements, b, @TypeOf(@"stdlib_modules_3.11.13"), @"stdlib_modules_3.11.13"),
        .@"3.12.11" => {
            replacements.append(b.allocator, "MODULE__CTYPES_MALLOC_CLOSURE=") catch @panic("OOM");
            addReplacements(&replacements, b, @TypeOf(@"stdlib_modules_3.12.11"), @"stdlib_modules_3.12.11");
        },
    }

    // Second replace call
    const stdlib_in_path = b.pathJoin(&.{ dep_root_path, "Modules/Setup.stdlib.in" });
    b.dependOnFileContents(upstream.path("Modules/Setup.stdlib.in"));
    const setup_stdlib = replace.replace(b, stdlib_in_path, replacements.items);
    defer b.allocator.free(setup_stdlib);

    const setup_in_path = b.pathJoin(&.{ dep_root_path, "Modules/Setup" });
    b.dependOnFileContents(upstream.path("Modules/Setup"));

    const setup_file = std.Io.Dir.cwd().readFileAlloc(b.graph.io, setup_in_path, b.allocator, .unlimited) catch |e|
        std.debug.panic("open '{s}' failed with {t}", .{ setup_in_path, e });
    var setup = makesetup.makesetup(b, &.{ setup_bootstrap, setup_stdlib, setup_file }, &.{ bootstrap_in_path, stdlib_in_path, setup_in_path });

    const config_c_in_path = b.pathJoin(&.{ dep_root_path, "Modules/config.c.in" });
    b.dependOnFileContents(upstream.path("Modules/config.c.in"));
    const config_c_in = std.Io.Dir.cwd().readFileAlloc(b.graph.io, config_c_in_path, b.allocator, .unlimited) catch |e|
        std.debug.panic("open file '{s}' failed with {t}", .{ config_c_in_path, e });

    const wf = b.addWriteFiles();
    const config_contents = makesetup.writeConfigC(b, setup, config_c_in_path, config_c_in);
    defer b.allocator.free(config_contents);
    const config_c = wf.add("Modules/config.c", config_contents);
    setup.outfile = config_c;

    return setup;
}

fn addReplacements(list: *std.ArrayList([]const u8), b: *std.Build, comptime Modules: type, modules: Modules) void {
    comptime switch (@typeInfo(Modules)) {
        .@"struct" => {},
        else => @compileError("Modules type must be a struct"),
    };
    inline for (@typeInfo(Modules).@"struct".field_names) |name| {
        const value = @field(modules, name);
        var upcase_buf: [100]u8 = undefined;
        for (name, 0..) |c, i| {
            upcase_buf[i] = std.ascii.toUpper(c);
        }
        const value_str = if (value) "" else "#";
        list.append(b.allocator, b.fmt("MODULE_{s}_TRUE={s}", .{ upcase_buf[0..name.len], value_str })) catch @panic("OOM");
    }
}

const other_libs = struct {
    path: std.Build.LazyPath,
    name: []const u8,
};

fn packagePython(b: *std.Build, version: Version, upstream: *std.Build.Dependency, exe: *std.Build.Step.Compile, libs: []const other_libs) struct {
    root: std.Build.LazyPath,
    exe: std.Build.LazyPath,
} {
    const write_files = b.addNamedWriteFiles(exe.name);
    _ = write_files.addCopyDirectory(upstream.path("Lib"), b.fmt("lib/python{s}", .{version.libName()}), .{});
    for (libs) |lib| {
        _ = write_files.addCopyFile(lib.path, b.fmt("lib/python{s}/{s}", .{ version.libName(), lib.name }));
    }
    const empty_dir = b.addWriteFiles().getDirectory();
    _ = write_files.addCopyDirectory(empty_dir, b.fmt("lib/python{s}/lib-dynload", .{version.libName()}), .{});
    if (exe.producesPdbFile()) {
        _ = write_files.addCopyFile(exe.getEmittedPdb(), b.fmt("bin/{s}.pdb", .{exe.name}));
    }
    b.getInstallStep().dependOn(&write_files.step);
    return .{
        .root = write_files.getDirectory(),
        .exe = write_files.addCopyFile(
            exe.getEmittedBin(),
            b.fmt("bin/{s}", .{exe.out_filename}),
        ),
    };
}

fn addPythonExe(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    args: struct {
        name: []const u8,
        setup: makesetup.Setup,
        pyconfig: Pyconfig,
        stage: PythonExeStage,
    },
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = args.name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addCMacro("Py_BUILD_CORE", "");
    exe.root_module.addCMacro("_GNU_SOURCE", "");
    switch (optimize) {
        .Debug => {},
        .ReleaseSafe, .ReleaseSmall, .ReleaseFast => {
            const release_date = switch (args.pyconfig.version) {
                .@"3.11.13" => "June 3, 2025",
                .@"3.12.11" => "June 3, 2025",
            };
            // need to redefine __DATE__ and __TIME__ for a reproducible build
            exe.root_module.addCMacro("__DATE__", b.fmt("\"{s}\"", .{release_date}));
            exe.root_module.addCMacro("__TIME__", "\"00:00:00\"");
        },
    }
    exe.root_module.addCMacro("PLATFORM", switch (target.result.os.tag) {
        .linux => "\"linux\"",
        .macos => "\"darwin\"",
        .windows => "\"win32\"",
        else => std.debug.panic("todo: populate PLATFORM for os '{s}'", .{@tagName(target.result.os.tag)}),
    });
    exe.root_module.addIncludePath(args.pyconfig.header.dirname());
    exe.root_module.addIncludePath(upstream.path("."));
    exe.root_module.addIncludePath(upstream.path("Include"));
    exe.root_module.addIncludePath(upstream.path("Include/internal"));
    if (args.stage.stage2FrozenMods()) |mods| {
        exe.root_module.addIncludePath(mods.getpath_h.dirname().dirname());
        exe.root_module.addIncludePath(mods.importlib_bootstrap_h.dirname().dirname().dirname());
        exe.root_module.addIncludePath(mods.importlib_bootstrap_external_h.dirname().dirname().dirname());
        exe.root_module.addIncludePath(mods.zipimport_h.dirname().dirname().dirname());
    }

    switch (args.stage) {
        .freeze_module, .bootstrap => {},
        .final => |final| switch (args.pyconfig.version) {
            .@"3.11.13" => {},
            else => for (final.frozen_headers) |h| {
                exe.root_module.addIncludePath(h.dirname().dirname());
            },
        },
    }

    const flags_common = [_][]const u8{
        "-fwrapv",
        "-std=c11",
        "-fvisibility=hidden",
        "-DVPATH=\"\"",
        "-DABIFLAGS=\"\"",
        "-fno-sanitize=function",
    };

    var it = args.setup.modules.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.enabled) {
            for (entry.value_ptr.compile_args) |compile_arg| switch (compile_arg) {
                .source => |src| exe.root_module.addCSourceFile(.{
                    .file = upstream.path(b.fmt("Modules/{s}", .{src})),
                }),
                .include => |inc| exe.root_module.addIncludePath(upstream.path(b.fmt("{s}", .{inc}))),
            };
        }
    }

    exe.root_module.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = switch (args.stage) {
            .freeze_module => concat(b.allocator, &.{
                &.{
                    "Programs/_freeze_module.c",
                    "Modules/getbuildinfo.c",
                    "Modules/getpath_noop.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
            .bootstrap => concat(b.allocator, &.{
                &.{
                    "Programs/_bootstrap_python.c",
                    "Modules/getbuildinfo.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
            .final => concat(b.allocator, &.{
                &.{
                    "Programs/python.c",
                    "Modules/getbuildinfo.c",
                    "Python/frozen.c",
                },
                switch (args.pyconfig.version) {
                    .@"3.11.13" => &library_src_omit_frozen.@"3.11.13",
                    .@"3.12.11" => &library_src_omit_frozen.@"3.12.11",
                },
            }),
        },
        .flags = concat(b.allocator, &.{
            &flags_common,
            switch (args.pyconfig.version) {
                // workaround dictobject.c memcpy alignment issue
                .@"3.11.13" => &.{"-fno-sanitize=alignment"},
                // tokenizer.c uses pointer overflow in restore_fstring_buffers
                .@"3.12.11" => &.{"-fno-sanitize=pointer-overflow"},
            },
        }),
    });

    exe.root_module.addCSourceFile(.{
        .file = args.setup.outfile orelse @panic("Missing config.c file"),
        .flags = &flags_common,
    });

    switch (args.stage) {
        .freeze_module => {},
        .bootstrap, .final => exe.root_module.addCSourceFile(.{
            .file = upstream.path("Modules/getpath.c"),
            .flags = &(flags_common ++ [_][]const u8{
                "-DPREFIX=\"\"",
                "-DEXEC_PREFIX=\"\"",
                b.fmt("-DVERSION=\"{s}\"", .{args.pyconfig.version.libName()}),
                "-DPLATLIBDIR=\"lib\"",
            }),
        }),
    }
    switch (args.stage) {
        .freeze_module, .bootstrap => {},
        .final => |final| {
            exe.root_module.addCSourceFile(.{ .file = final.deepfreeze_c, .flags = &flags_common });
        },
    }

    if (target.result.os.tag == .windows) {
        exe.root_module.addCSourceFile(.{
            .file = upstream.path("Python/dynload_win.c"),
            .flags = &flags_common,
        });
    } else {
        exe.root_module.addCSourceFile(.{
            .file = upstream.path("Python/dynload_shlib.c"),
            .flags = &(flags_common ++ .{
                "-DSOABI=\"cpython-311-x86_64-linux-gnu\"",
            }),
        });
    }

    if (args.pyconfig.libs.zlib) |zlib| exe.root_module.linkLibrary(zlib);
    if (args.pyconfig.libs.openssl) |openssl| exe.root_module.linkLibrary(openssl);
    if (args.pyconfig.libs.hacl) |hacl| exe.root_module.linkLibrary(hacl);

    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
        exe.root_module.linkSystemLibrary("api-ms-win-core-path-l1-1-0", .{});
    }

    // TODO: do we need this
    // exe.rdynamic = true;

    return exe;
}

const Pyconfig = struct {
    version: Version,
    libs: Libs,
    header: std.Build.LazyPath,
    sysconfigdata: ?other_libs,
};

const Libs = struct {
    zlib: ?*std.Build.Step.Compile,
    openssl: ?*std.Build.Step.Compile,
    hacl: ?*std.Build.Step.Compile,
};

fn addPyconfig(
    b: *std.Build,
    version: Version,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    libs: Libs,
    configquery_exe: *std.Build.Step.Compile,
) !Pyconfig {
    const t = target.result;
    if (t.os.tag == .windows) return .{
        .version = version,
        .libs = libs,
        .header = upstream.path("PC/pyconfig.h"),
        .sysconfigdata = null,
    };

    const vers_config_file = switch (version) {
        .@"3.11.13" => "config-3.11.13",
        .@"3.12.11" => "config-3.12.11",
    };
    const vers_config_file_path = b.path(vers_config_file);
    b.dependOnFileContents(vers_config_file_path);
    b.dependOnFileContents(b.path("config-common"));

    const pyconfig_h_in_path = upstream.path("pyconfig.h.in");
    b.dependOnFileContents(pyconfig_h_in_path);

    const run = b.addRunArtifact(configquery_exe);
    run.addArg("--zig-exe");
    run.addArg(b.graph.zig_exe);
    run.addArg("--cache-dir");
    run.addDirectoryArg(std.Build.LazyPath.cache_root);
    run.addArg("-target");
    run.addArg(try target.query.zigTriple(b.allocator));
    run.addArg("-mcpu");
    run.addArg(try target.query.serializeCpuAlloc(b.allocator));
    run.addArg("-version");
    run.addArg(switch (version) {
        .@"3.11.13" => "3.11.13",
        .@"3.12.11" => "3.12.11",
    });
    run.addArg("-infile");
    run.addFileArg(pyconfig_h_in_path);
    if (libs.zlib) |zlib| run.addPrefixedDirectoryArg("-I", zlib.getEmittedIncludeTree());
    if (libs.openssl) |openssl| run.addPrefixedDirectoryArg("-I", openssl.getEmittedIncludeTree());
    run.addFileArg(b.path("config-common"));
    run.addFileArg(vers_config_file_path);
    run.addArg("-o");
    const config_header = run.addOutputFileArg("pyconfig.h");

    const sysconfigdata_contents = makesetup.writeSysConfigData(b);
    defer b.allocator.free(sysconfigdata_contents);

    const sysconfigdata_filename = b.fmt("_sysconfigdata__{s}_.py", .{switch (t.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        else => std.debug.panic("todo: populate PLATFORM for os '{s}'", .{@tagName(t.os.tag)}),
    }});

    const wf = b.addWriteFiles();
    const sysconfigdata_file = wf.add(sysconfigdata_filename, sysconfigdata_contents);
    const install_step = b.addInstallFile(sysconfigdata_file, b.fmt("lib/python{s}/{s}", .{ version.libName(), sysconfigdata_filename }));
    b.getInstallStep().dependOn(&install_step.step);

    return .{
        .version = version,
        .libs = libs,
        .header = config_header,
        .sysconfigdata = .{ .path = sysconfigdata_file, .name = sysconfigdata_filename },
    };
}

const Config = struct { name: []const u8, string: []const u8 };
fn concatConfigs(comptime first: anytype, comptime second: anytype) [std.meta.fields(@TypeOf(first)).len + std.meta.fields(@TypeOf(second)).len]Config {
    const first_len = std.meta.fields(@TypeOf(first)).len;
    var result: [first_len + std.meta.fields(@TypeOf(second)).len]Config = undefined;
    inline for (std.meta.fields(@TypeOf(first)), result[0..first_len]) |field, *config| {
        config.* = .{ .name = @tagName(@field(first, field.name)[0]), .string = @field(first, field.name)[1] };
    }
    inline for (std.meta.fields(@TypeOf(second)), result[first_len..]) |field, *config| {
        config.* = .{ .name = @tagName(@field(second, field.name)[0]), .string = @field(second, field.name)[1] };
    }
    return result;
}

const python_src = struct {
    const common = [_][]const u8{
        "Python/_warnings.c",
        "Python/Python-ast.c",
        "Python/Python-tokenize.c",
        "Python/asdl.c",
        "Python/ast.c",
        "Python/ast_opt.c",
        "Python/ast_unparse.c",
        "Python/bltinmodule.c",
        "Python/ceval.c",
        "Python/codecs.c",
        "Python/compile.c",
        "Python/context.c",
        "Python/dynamic_annotations.c",
        "Python/errors.c",
        "Python/frame.c",
        "Python/frozenmain.c",
        "Python/future.c",
        "Python/getargs.c",
        "Python/getcompiler.c",
        "Python/getcopyright.c",
        "Python/getplatform.c",
        "Python/getversion.c",
        "Python/hamt.c",
        "Python/hashtable.c",
        "Python/import.c",
        "Python/importdl.c",
        "Python/initconfig.c",
        "Python/marshal.c",
        "Python/modsupport.c",
        "Python/mysnprintf.c",
        "Python/mystrtoul.c",
        "Python/pathconfig.c",
        "Python/preconfig.c",
        "Python/pyarena.c",
        "Python/pyctype.c",
        "Python/pyfpe.c",
        "Python/pyhash.c",
        "Python/pylifecycle.c",
        "Python/pymath.c",
        "Python/pystate.c",
        "Python/pythonrun.c",
        "Python/pytime.c",
        "Python/bootstrap_hash.c",
        "Python/specialize.c",
        "Python/structmember.c",
        "Python/symtable.c",
        "Python/sysmodule.c",
        "Python/thread.c",
        "Python/traceback.c",
        "Python/getopt.c",
        "Python/pystrcmp.c",
        "Python/pystrtod.c",
        "Python/pystrhex.c",
        "Python/dtoa.c",
        "Python/formatter_unicode.c",
        "Python/fileutils.c",
        "Python/suggestions.c",
    };
    pub const @"3.11.13" = common;
    pub const @"3.12.11" = common ++ .{
        "Python/assemble.c",
        "Python/flowgraph.c",
        "Python/ceval_gil.c",
        "Python/instrumentation.c",
        "Python/intrinsics.c",
        "Python/legacy_tracing.c",
        "Python/tracemalloc.c",
        "Python/perf_trampoline.c",
    };
};

const object_src = struct {
    const common = [_][]const u8{
        "Objects/abstract.c",
        "Objects/boolobject.c",
        "Objects/bytes_methods.c",
        "Objects/bytearrayobject.c",
        "Objects/bytesobject.c",
        "Objects/call.c",
        "Objects/capsule.c",
        "Objects/cellobject.c",
        "Objects/classobject.c",
        "Objects/codeobject.c",
        "Objects/complexobject.c",
        "Objects/descrobject.c",
        "Objects/enumobject.c",
        "Objects/exceptions.c",
        "Objects/genericaliasobject.c",
        "Objects/genobject.c",
        "Objects/fileobject.c",
        "Objects/floatobject.c",
        "Objects/frameobject.c",
        "Objects/funcobject.c",
        "Objects/interpreteridobject.c",
        "Objects/iterobject.c",
        "Objects/listobject.c",
        "Objects/longobject.c",
        "Objects/dictobject.c",
        "Objects/odictobject.c",
        "Objects/memoryobject.c",
        "Objects/methodobject.c",
        "Objects/moduleobject.c",
        "Objects/namespaceobject.c",
        "Objects/object.c",
        "Objects/obmalloc.c",
        "Objects/picklebufobject.c",
        "Objects/rangeobject.c",
        "Objects/setobject.c",
        "Objects/sliceobject.c",
        "Objects/structseq.c",
        "Objects/tupleobject.c",
        "Objects/typeobject.c",
        "Objects/unicodeobject.c",
        "Objects/unicodectype.c",
        "Objects/unionobject.c",
        "Objects/weakrefobject.c",
    };
    pub const @"3.11.13" = common ++ .{
        "Objects/accu.c",
    };
    pub const @"3.12.11" = common ++ .{
        "Objects/typevarobject.c",
    };
};

const parser_src = [_][]const u8{
    // PEGEN_OBJS
    "Parser/pegen.c",
    "Parser/pegen_errors.c",
    "Parser/action_helpers.c",
    "Parser/parser.c",
    "Parser/string_parser.c",
    "Parser/peg_api.c",

    // POBJS
    "Parser/token.c",

    //
    "Parser/myreadline.c",
    "Parser/tokenizer.c",
};

const module_src = [_][]const u8{
    "Modules/main.c",
    "Modules/gcmodule.c",
};

const library_src_omit_frozen = struct {
    pub const @"3.11.13" = parser_src ++ object_src.@"3.11.13" ++ python_src.@"3.11.13" ++ module_src;
    pub const @"3.12.11" = parser_src ++ object_src.@"3.12.11" ++ python_src.@"3.12.11" ++ module_src;
};

const frozen_modules = [_][]const u8{
    "Lib/importlib/_bootstrap.py",
    "Lib/importlib/_bootstrap_external.py",
    "Lib/zipimport.py",
    "Lib/abc.py",
    "Lib/codecs.py",
    "Lib/io.py",
    "Lib/_collections_abc.py",
    "Lib/_sitebuiltins.py",
    "Lib/genericpath.py",
    "Lib/ntpath.py",
    "Lib/posixpath.py",
    "Lib/os.py",
    "Lib/site.py",
    "Lib/stat.py",
    "Lib/importlib/util.py",
    "Lib/importlib/machinery.py",
    "Lib/runpy.py",
    "Lib/__hello__.py",
    "Lib/__phello__/__init__.py",
    "Lib/__phello__/ham/__init__.py",
    "Lib/__phello__/ham/eggs.py",
    "Lib/__phello__/spam.py",
    "Tools/freeze/flag.py",
};

fn frozenModuleNames(version: Version) *const [frozen_modules.len][]const u8 {
    return switch (version) {
        .@"3.11.13" => &frozen_module_name_sets.@"3.11",
        else => &frozen_module_name_sets.@"after_3.11",
    };
}
const frozen_module_name_sets = struct {
    pub const @"3.11" = makeNames(.@"3.11");
    pub const @"after_3.11" = makeNames(.@"after_3.11");
    fn makeNames(when: enum { @"3.11", @"after_3.11" }) [frozen_modules.len][]const u8 {
        var names: [frozen_modules.len][]const u8 = undefined;
        for (&names, frozen_modules) |*name_ref, path| {
            if (std.mem.eql(u8, "Tools/freeze/flag.py", path)) {
                name_ref.* = "frozen_only";
                continue;
            }

            const name = blk_name: {
                const path_prefix = "Lib/";
                const path_suffix = blk: {
                    const init_suffix = "/__init__.py";
                    if (std.mem.endsWith(u8, path, init_suffix)) break :blk init_suffix;
                    break :blk ".py";
                };
                var name_buf: [path.len - path_prefix.len - path_suffix.len]u8 = undefined;
                for (&name_buf, path[path_prefix.len..][0..name_buf.len]) |*name_char, path_char| {
                    name_char.* = switch (path_char) {
                        '/' => switch (when) {
                            .@"3.11" => '_',
                            .@"after_3.11" => '.',
                        },
                        else => |c| c,
                    };
                }
                break :blk_name name_buf;
            };
            name_ref.* = &name;
        }
        return names;
    }
};

fn ci(
    b: *std.Build,
    version: Version,
    ssl_enabled: bool,
    upstream: *std.Build.Dependency,
    ci_step: *std.Build.Step,
    args: struct {
        stage2_frozen_mods: Stage2FrozenMods,
        frozen_headers: []const std.Build.LazyPath,
        deepfreeze_c: std.Build.LazyPath,
    },
    configquery_exe: *std.Build.Step.Compile,
) !void {
    const CiTarget = struct { triple: []const u8, ssl: bool };
    const ci_targets = [_]CiTarget{
        // .{ .triple = "x86_64-windows", .ssl = false },
        // .{ .triple = "aarch64-windows", .ssl = true },
        // .{ .triple = "x86-windows", .ssl = true },

        .{ .triple = "x86_64-macos", .ssl = false },
        .{ .triple = "aarch64-macos", .ssl = false },

        .{ .triple = "x86_64-linux-musl", .ssl = true },
        .{ .triple = "x86_64-linux-gnu", .ssl = true },
        .{ .triple = "aarch64-linux-musl", .ssl = false },
        .{ .triple = "aarch64-linux-gnu", .ssl = false },
        // .{ .triple = "arm-linux-musl", .ssl = true }, // zlib doesn't build
        .{ .triple = "riscv64-linux-musl", .ssl = false },
        .{ .triple = "powerpc64le-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-musl", .ssl = false },
        // .{ .triple = "x86-linux-gnu", .ssl = false },
        .{ .triple = "s390x-linux-musl", .ssl = false },
    };

    for (ci_targets) |ci_target| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target.triple },
        ));
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;
        const target_dest_dir: std.Build.InstallDir = .{ .custom = ci_target.triple };
        const install = b.step(b.fmt("install-{s}", .{ci_target.triple}), "");
        ci_step.dependOn(install);

        var hacl: ?*std.Build.Step.Compile = undefined;
        if (version == .@"3.12.11") {
            hacl = b.addLibrary(.{
                .name = "hacl",
                .linkage = .static,
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            hacl.?.root_module.addIncludePath(upstream.path("./Modules/_hacl/include"));
            hacl.?.root_module.addIncludePath(upstream.path("./Modules/_hacl/"));
            hacl.?.root_module.addCSourceFile(.{ .file = upstream.path("./Modules/_hacl/Hacl_Hash_SHA2.c"), .flags = &.{
                "-D_BSD_SOURCE", "-D_DEFAULT_SOURCE",   "-fwrapv",
                "-std=c11",      "-fvisibility=hidden", "-DVPATH=\"\"",
            } });
        } else hacl = null;

        const libs: Libs = .{
            .zlib = (b.dependency("zlib", .{
                .target = target,
                .optimize = optimize,
            })).artifact("z"),
            .openssl = if (ssl_enabled and ci_target.ssl) (if (b.lazyDependency("openssl", .{
                .target = target,
                .optimize = optimize,
            })) |dep| dep.artifact("openssl") else null) else null,
            .hacl = hacl,
        };
        const makesetups = addMakesetup(b, version, upstream, libs, target.result.os.tag);
        const exe = addPythonExe(b, upstream, target, optimize, .{
            .name = "python",
            .setup = makesetups,
            .pyconfig = try addPyconfig(b, version, upstream, target, libs, configquery_exe),
            .stage = .{ .final = .{
                .stage2 = args.stage2_frozen_mods,
                .frozen_headers = args.frozen_headers,
                .deepfreeze_c = args.deepfreeze_c,
            } },
        });

        install.dependOn(
            &b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );
    }
}

fn concat(allocator: std.mem.Allocator, lists: []const []const []const u8) []const []const u8 {
    var total: usize = 0;
    for (lists) |list| {
        total += list.len;
    }
    const result = allocator.alloc([]const u8, total) catch @panic("OOM");
    var index: usize = 0;
    for (lists) |list| {
        for (list) |s| {
            result[index] = s;
            index += 1;
        }
    }
    std.debug.assert(index == total);
    return result;
}

const std = @import("std");
const replace = @import("replace.zig");
const makesetup = @import("makesetup.zig");
