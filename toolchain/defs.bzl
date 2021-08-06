load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":zig_toolchain.bzl", "zig_cc_toolchain_config")

DEFAULT_TOOL_PATHS = {
    "ar": "ar",
    "gcc": "c++",  # https://github.com/bazelbuild/bazel/issues/4644
    "cpp": "/usr/bin/false",
    "gcov": "/usr/bin/false",
    "nm": "/usr/bin/false",
    "objdump": "/usr/bin/false",
    "strip": "/usr/bin/false",
}.items()

DEFAULT_INCLUDE_DIRECTORIES = [
    "include",
    "libcxx/include",
    "libcxxabi/include",
]

# -Os, -O2 or -O3 must be set, because some dependencies use C's undefined
# behavior. See https://github.com/ziglang/zig/issues/4830
DEFAULT_COPTS = ["-O3"]

_fcntl_map = """
GLIBC_2.2.5 {
   fcntl;
};
"""
_fcntl_h = """
#ifdef __ASSEMBLER__
.symver fcntl64, fcntl@GLIBC_2.2.5
#else
__asm__(".symver fcntl64, fcntl@GLIBC_2.2.5");
#endif
"""

# Zig supports even older glibcs than defined below, but we have tested only
# down to 2.17.
# $ zig targets | jq -r '.glibc[]' | sort -V
_GLIBCS = [
    "2.17",
    "2.18",
    "2.19",
    "2.22",
    "2.23",
    "2.24",
    "2.25",
    "2.26",
    "2.27",
    "2.28",
    "2.29",
    "2.30",
    "2.31",
    "2.32",
    "2.33",
]

DEFAULT_TOOLCHAINS = [
    "linux_arm64_gnu.2.28",  # Cannot apply fcntl64 hack for older versions.
    "linux_amd64_gnu.2.19",  # Debian Jessie
    "darwin_amd64",
    "darwin_arm64",
]

def _target_darwin(gocpu, zigcpu):
    return struct(
        gotarget = "darwin_{}".format(gocpu),
        zigtarget = "{}-macos-gnu".format(zigcpu),
        includes = [
            "libunwind/include",
            "libc/include/any-macos-any",
            "libc/include/{}-macos-any".format(zigcpu),
            "libc/include/{}-macos-gnu".format(zigcpu),
        ],
        linkopts = [],
        copts = DEFAULT_COPTS,
        bazel_target_cpu = "darwin",
        constraint_values = [
            "@platforms//os:macos",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld64.lld"},
    )

def _target_linux_gnu(gocpu, zigcpu, glibc_version = ""):
    glibc_suffix = "gnu"
    if glibc_version != "":
        glibc_suffix = "gnu.{}".format(glibc_version)

    # https://github.com/ziglang/zig/issues/5882#issuecomment-888250676
    # fcntl_hack is only required for glibc 2.27 or less. We assume that
    # glibc_version == "" (autodetect) is running a recent glibc version, thus
    # adding this hack only when glibc is explicitly 2.27 or lower.
    # __asm__ directive does not work on aarch64 (for some reasons unknown to
    # me), so the hack applies to x86_64 only.
    fcntl_hack = False
    if zigcpu == "x86_64":
        if glibc_version == "":
            # zig doesn't reliably detect the glibc version, so
            # often falls back to 2.17; the hack should be included.
            # https://github.com/ziglang/zig/issues/6469
            fcntl_hack = True
        else:
            # we know the version; hack is required for 2.27 or less.
            fcntl_hack = glibc_version < "2.28"

    return struct(
        gotarget = "linux_{}_{}".format(gocpu, glibc_suffix),
        zigtarget = "{}-linux-{}".format(zigcpu, glibc_suffix),
        includes = [
            "libunwind/include",
            "libc/include/generic-glibc",
            "libc/include/any-linux-any",
            "libc/include/{}-linux-gnu".format(zigcpu),
            "libc/include/{}-linux-any".format(zigcpu),
        ],
        toplevel_include = ["glibc-hacks"] if fcntl_hack else [],
        compiler_extra_includes = ["glibc-hacks/glibchack-fcntl.h"] if fcntl_hack else [],
        linker_version_scripts = ["glibc-hacks/fcntl.map"] if fcntl_hack else [],
        linkopts = ["-lc++", "-lc++abi"],
        copts = DEFAULT_COPTS,
        bazel_target_cpu = "k8",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld.lld"},
    )

def _target_linux_musl(gocpu, zigcpu):
    return struct(
        gotarget = "linux_{}_musl".format(gocpu),
        zigtarget = "{}-linux-musl".format(zigcpu),
        includes = [
            "libc/include/generic-musl",
            "libc/include/any-linux-any",
            "libc/include/{}-linux-musl".format(zigcpu),
            "libc/include/{}-linux-any".format(zigcpu),
        ],
        linkopts = ["-s", "-w"],
        copts = DEFAULT_COPTS + ["-D_LIBCPP_HAS_MUSL_LIBC", "-D_LIBCPP_HAS_THREAD_API_PTHREAD"],
        bazel_target_cpu = "k8",
        constraint_values = [
            "@platforms//os:linux",
            "@platforms//cpu:{}".format(zigcpu),
        ],
        tool_paths = {"ld": "ld.lld"},
    )

def register_toolchains(
        register = DEFAULT_TOOLCHAINS,
        speed_first_safety_later = "auto"):
    zig_repository(
        name = "zig_sdk",
        # Pre-release:
        version = "0.9.0-dev.727+aad459836",
        url_format = "https://ziglang.org/builds/zig-{host_platform}-{version}.tar.xz",
        # Release:
        # version = "0.8.0",
        # url_format = "https://ziglang.org/download/{version}/zig-{host_platform}-{version}.tar.xz",
        host_platform_sha256 = {
            "linux-x86_64": "1a0f45e77e2323d4afb3405868c0d96a88170a922eb60fc06f233ac8395fbfd5",
            "macos-x86_64": "cdc76afd3e361c8e217e4d56f2027ec6482d7f612462c27794149b7ad31b9244",
        },
        host_platform_include_root = {
            "macos-x86_64": "lib/zig/",
            "linux-x86_64": "lib/",
        },
        speed_first_safety_later = speed_first_safety_later,
    )

    toolchains = ["@zig_sdk//:%s_toolchain" % t for t in register]
    native.register_toolchains(*toolchains)

ZIG_TOOL_PATH = "tools/{zig_tool}"
ZIG_TOOL_WRAPPER = """#!/bin/bash
set -eu
readonly _zig="{zig}"

if [[ -n "$TMPDIR" ]]; then
  _cache_prefix=$TMPDIR
else
  _cache_prefix="$HOME/.cache"
  if [[ "$(uname)" = Darwin ]]; then
    _cache_prefix="$HOME/Library/Caches"
  fi
fi
export ZIG_LOCAL_CACHE_DIR="$_cache_prefix/bazel-zig-cc"
export ZIG_GLOBAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR

# https://github.com/ziglang/zig/issues/9431
exec {maybe_flock} "$_zig" "{zig_tool}" "$@"
"""

_ZIG_TOOLS = [
    "c++",
    "cc",
    "ar",
    "ld.lld",  # ELF
    "ld64.lld",  # Mach-O
    "lld-link",  # COFF
    "wasm-ld",  # WebAssembly
]

def _zig_repository_impl(repository_ctx):
    if repository_ctx.os.name.lower().startswith("mac os"):
        host_platform = "macos-x86_64"
    else:
        host_platform = "linux-x86_64"

    zig_include_root = repository_ctx.attr.host_platform_include_root[host_platform]
    zig_sha256 = repository_ctx.attr.host_platform_sha256[host_platform]
    format_vars = {
        "version": repository_ctx.attr.version,
        "host_platform": host_platform,
    }
    zig_url = repository_ctx.attr.url_format.format(**format_vars)

    repository_ctx.download_and_extract(
        url = zig_url,
        stripPrefix = "zig-{host_platform}-{version}/".format(**format_vars),
        sha256 = zig_sha256,
    )

    if repository_ctx.attr.speed_first_safety_later == "auto":
        do_flock = repository_ctx.os.name.lower().startswith("mac os")
    elif repository_ctx.attr.speed_first_safety_later == "yes":
        do_flock = True
    else:
        do_flock = False

    maybe_flock = 'flock "${_zig}"' if do_flock else ""
    for zig_tool in _ZIG_TOOLS:
        repository_ctx.file(
            ZIG_TOOL_PATH.format(zig_tool = zig_tool),
            ZIG_TOOL_WRAPPER.format(
                zig = str(repository_ctx.path("zig")),
                zig_tool = zig_tool,
                maybe_flock = maybe_flock,
            ),
        )

    repository_ctx.file(
        "glibc-hacks/fcntl.map",
        content = _fcntl_map,
    )
    repository_ctx.file(
        "glibc-hacks/glibchack-fcntl.h",
        content = _fcntl_h,
    )

    repository_ctx.template(
        "BUILD.bazel",
        Label("//toolchain:BUILD.sdk.bazel"),
        executable = False,
        substitutions = {
            "{absolute_path}": shell.quote(str(repository_ctx.path(""))),
            "{zig_include_root}": shell.quote(zig_include_root),
        },
    )

zig_repository = repository_rule(
    attrs = {
        "version": attr.string(),
        "host_platform_sha256": attr.string_dict(),
        "url_format": attr.string(),
        "host_platform_include_root": attr.string_dict(),
        "speed_first_safety_later": attr.string(
            values = ["yes", "no", "auto"],
            default = "auto",
            doc = "Workaround for github.com/ziglang/zig/issues/9431; " +
                  "dramatically decreases compilation time on multi-core " +
                  "hosts, but may fail compilation. Then re-run it. So far, " +
                  "the author has reproduced this only on OSX.",
        ),
    },
    implementation = _zig_repository_impl,
)

def _target_structs():
    ret = []
    for zigcpu, gocpu in (("x86_64", "amd64"), ("aarch64", "arm64")):
        ret.append(_target_darwin(gocpu, zigcpu))
        ret.append(_target_linux_musl(gocpu, zigcpu))
        for glibc in [""] + _GLIBCS:
            ret.append(_target_linux_gnu(gocpu, zigcpu, glibc))
    return ret

def filegroup(name, **kwargs):
    native.filegroup(name = name, **kwargs)
    return ":" + name

def zig_build_macro(absolute_path, zig_include_root):
    filegroup(name = "empty")
    native.exports_files(["zig"], visibility = ["//visibility:public"])
    filegroup(name = "lib/std", srcs = native.glob(["lib/std/**"]))

    lazy_filegroups = {}

    for target_config in _target_structs():
        gotarget = target_config.gotarget
        zigtarget = target_config.zigtarget
        native.platform(
            name = gotarget,
            constraint_values = target_config.constraint_values,
        )

        cxx_builtin_include_directories = []
        for d in DEFAULT_INCLUDE_DIRECTORIES + target_config.includes:
            d = zig_include_root + d
            if d not in lazy_filegroups:
                lazy_filegroups[d] = filegroup(name = d, srcs = native.glob([d + "/**"]))
            cxx_builtin_include_directories.append(absolute_path + "/" + d)
        for d in getattr(target_config, "toplevel_include", []):
            cxx_builtin_include_directories.append(absolute_path + "/" + d)

        absolute_tool_paths = {}
        for name, path in target_config.tool_paths.items() + DEFAULT_TOOL_PATHS:
            if path[0] == "/":
                absolute_tool_paths[name] = path
                continue
            tool_path = ZIG_TOOL_PATH.format(zig_tool = path)
            absolute_tool_paths[name] = "%s/%s" % (absolute_path, tool_path)

        linkopts = target_config.linkopts
        copts = target_config.copts
        for s in getattr(target_config, "linker_version_scripts", []):
            linkopts = linkopts + ["-Wl,--version-script,%s/%s" % (absolute_path, s)]
        for incl in getattr(target_config, "compiler_extra_includes", []):
            copts = copts + ["-include", absolute_path + "/" + incl]

        zig_cc_toolchain_config(
            name = zigtarget + "_cc_toolchain_config",
            target = zigtarget,
            tool_paths = absolute_tool_paths,
            cxx_builtin_include_directories = cxx_builtin_include_directories,
            copts = copts,
            linkopts = linkopts,
            target_cpu = target_config.bazel_target_cpu,
            target_system_name = "unknown",
            target_libc = "unknown",
            compiler = "clang",
            abi_version = "unknown",
            abi_libc_version = "unknown",
        )

        native.cc_toolchain(
            name = zigtarget + "_cc_toolchain",
            toolchain_identifier = zigtarget + "-toolchain",
            toolchain_config = ":%s_cc_toolchain_config" % zigtarget,
            all_files = ":zig",
            ar_files = ":zig",
            compiler_files = ":zig",
            linker_files = ":zig",
            dwp_files = ":empty",
            objcopy_files = ":empty",
            strip_files = ":empty",
            supports_param_files = 0,
        )

        # register two kinds of toolchain targets: Go and Zig conventions.
        # Go convention: amd64/arm64, linux/darwin
        native.toolchain(
            name = gotarget + "_toolchain",
            exec_compatible_with = None,
            target_compatible_with = target_config.constraint_values,
            toolchain = ":%s_cc_toolchain" % zigtarget,
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )

        # Zig convention: x86_64/aarch64, linux/macos
        native.toolchain(
            name = zigtarget + "_toolchain",
            exec_compatible_with = None,
            target_compatible_with = target_config.constraint_values,
            toolchain = ":%s_cc_toolchain" % zigtarget,
            toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        )
