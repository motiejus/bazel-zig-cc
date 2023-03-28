load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "read_user_netrc", "use_netrc")
load("@bazel-zig-cc//toolchain/private:defs.bzl", "target_structs", "zig_tool_path")

# Directories that `zig c++` includes behind the scenes.
_DEFAULT_INCLUDE_DIRECTORIES = [
    "libcxx/include",
    "libcxxabi/include",
    "libunwind/include",
]

# Official recommended version. Should use this when we have a usable release.
URL_FORMAT_RELEASE = "https://ziglang.org/download/{version}/zig-{host_platform}-{version}.{_ext}"

# Caution: nightly releases are purged from ziglang.org after ~90 days. A real
# solution would be to allow the downstream project specify their own mirrors.
# This is explained in
# https://sr.ht/~motiejus/bazel-zig-cc/#alternative-download-urls and is
# awaiting my attention or your contribution.
URL_FORMAT_NIGHTLY = "https://ziglang.org/builds/zig-{host_platform}-{version}.{_ext}"

# Official Bazel's mirror with selected Zig SDK versions. Bazel community is
# generous enough to host the artifacts, which we use.
URL_FORMAT_BAZELMIRROR = "https://mirror.bazel.build/" + URL_FORMAT_NIGHTLY.lstrip("https://")

_VERSION = "0.11.0-dev.2312+dd66e0add"

_HOST_PLATFORM_SHA256 = {
    "linux-aarch64": "adb62d5616e803d4174a818c6180ba34995f55f8d1d7e9282dc3e71cae3a3ee7",
    "linux-x86_64": "e3c05b0a820a137c199bbd06b705b578d9a91b6ce64caadb87b15a0d97f7c9aa",
    "macos-aarch64": "327e851c44efe870aefeddd94be181d5a942658e6e1ae74672ffa6fb5c06f96d",
    "macos-x86_64": "e21a3e5fa7368f5bafdd469702d0b12e3d7da09ee6338b3eb6688cbf91884c7a",
    "windows-x86_64": "371e3567b757061b4bbc27de09de98e631f15cf312b45d9e81398f68ed8c89ea",
}

_HOST_PLATFORM_EXT = {
    "linux-aarch64": "tar.xz",
    "linux-x86_64": "tar.xz",
    "macos-aarch64": "tar.xz",
    "macos-x86_64": "tar.xz",
    "windows-x86_64": "zip",
}

_compile_failed = """
Compilation of launcher.zig failed:
command={compile_cmd}
return_code={return_code}
stderr={stderr}
stdout={stdout}

You most likely hit a rare but known race in Zig SDK. Congratulations?

We are working on fixing it with Zig Software Foundation. If you are curious,
feel free to follow along in https://github.com/ziglang/zig/issues/14815

There isn't much to do now but wait. Now apply the following workaround:
$ rm -fr {cache_prefix}
$ <... re-run your command ...>

... and proceed with your life.
"""

_want_format = """
Unexpected MacOS SDK definition. Expected format:

zig_toolchain(
    macos_sdks = [
      struct(
        version = "13.1",
        urls = [ "https://<...>", ... ],
        sha256 = "<...>",
      ),
      ...
    ],
)

"""

def toolchains(
        version = _VERSION,
        url_formats = [URL_FORMAT_BAZELMIRROR, URL_FORMAT_NIGHTLY],
        host_platform_sha256 = _HOST_PLATFORM_SHA256,
        host_platform_ext = _HOST_PLATFORM_EXT,
        macos_sdks = []):
    """
        Download zig toolchain and declare bazel toolchains.
        The platforms are not registered automatically, that should be done by
        the user with register_toolchains() in the WORKSPACE file. See README
        for possible choices.
    """

    macos_sdk_versions = []
    for sdk in macos_sdks:
        if not(bool(sdk.version) and bool(sdk.urls) and bool(sdk.sha256)):
            fail(_want_format)

        macos_sdk_versions.append(sdk.version)

        if not (len(sdk.version) == 4 and
                sdk.version[2] == "." and
                sdk.version[0:2].isdigit() and
                sdk.version[3].isdigit()):
            fail("unexpected macos SDK version {}, want DD.D".format(version))

        macos_sdk_repository(
            name = "macos_sdk_{}".format(sdk.version),
            urls = sdk.urls,
            sha256 = sdk.sha256,
        )

    zig_repository(
        name = "zig_sdk",
        version = version,
        url_formats = url_formats,
        host_platform_sha256 = host_platform_sha256,
        host_platform_ext = host_platform_ext,
        macos_sdk_versions = macos_sdk_versions,
    )

def macos_sdk(version, urls, sha256):
    return struct(
        version = version,
        urls = urls,
        sha256 = sha256,
    )

_ZIG_TOOLS = [
    "c++",
    "ar",
]

_template_mapfile = """
%s {
    %s;
};
"""

_template_linker = """
#ifdef __ASSEMBLER__
.symver {from_function}, {to_function_abi}
#else
__asm__(".symver {from_function}, {to_function_abi}");
#endif
"""

def _glibc_hack(from_function, to_function_abi):
    # Cannot use .format(...) here, because starlark thinks
    # that the byte 3 (the opening brace on the first line)
    # is a nested { ... }, returning an error:
    # Error in format: Nested replacement fields are not supported
    to_function, to_abi = to_function_abi.split("@")
    mapfile = _template_mapfile % (to_abi, to_function)
    header = _template_linker.format(
        from_function = from_function,
        to_function_abi = to_function_abi,
    )
    return struct(
        mapfile = mapfile,
        header = header,
    )

def _quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def _zig_repository_impl(repository_ctx):
    arch = repository_ctx.os.arch
    if arch == "amd64":
        arch = "x86_64"

    os = repository_ctx.os.name.lower()
    if os.startswith("mac os"):
        os = "macos"

    if os.startswith("windows"):
        os = "windows"

    host_platform = "{}-{}".format(os, arch)

    zig_sha256 = repository_ctx.attr.host_platform_sha256[host_platform]
    zig_ext = repository_ctx.attr.host_platform_ext[host_platform]
    format_vars = {
        "_ext": zig_ext,
        "version": repository_ctx.attr.version,
        "host_platform": host_platform,
    }

    # Fetch Label dependencies before doing download/extract.
    # The Bazel docs are not very clear about this behavior but see:
    # https://bazel.build/extending/repo#when_is_the_implementation_function_executed
    # and a related rules_go PR:
    # https://github.com/bazelbuild/bazel-gazelle/pull/1206
    macos_sdk_versions_str = _macos_versions(repository_ctx.attr.macos_sdk_versions)
    repository_ctx.symlink(Label("//toolchain/platform:BUILD"), "platform/BUILD")
    repository_ctx.template(
        "BUILD",
        Label("//toolchain:BUILD.sdk.bazel"),
        executable = False,
        substitutions = {
            "{zig_sdk_path}": _quote("external/zig_sdk"),
            "{os}": _quote(os),
            "{macos_sdk_versions}": macos_sdk_versions_str,
        },
    )

    for dest, src in {
        "toolchain/BUILD": "//toolchain/toolchain:BUILD",
        "libc/BUILD": "//toolchain/libc:BUILD.sdk.bazel",
        "libc_aware/platform/BUILD": "//toolchain/libc_aware/platform:BUILD.sdk.bazel",
        "libc_aware/toolchain/BUILD": "//toolchain/libc_aware/toolchain:BUILD.sdk.bazel",
    }.items():
        repository_ctx.template(
            dest,
            Label(src),
            executable = False,
            substitutions = {
                "{macos_sdk_versions}": macos_sdk_versions_str,
            },
        )

    urls = [uf.format(**format_vars) for uf in repository_ctx.attr.url_formats]
    repository_ctx.download_and_extract(
        auth = use_netrc(read_user_netrc(repository_ctx), urls, {}),
        url = urls,
        stripPrefix = "zig-{host_platform}-{version}/".format(**format_vars),
        sha256 = zig_sha256,
    )

    cache_prefix = repository_ctx.os.environ.get("BAZEL_ZIG_CC_CACHE_PREFIX", "")
    if cache_prefix == "":
        if os == "windows":
            cache_prefix = "C:\\\\Temp\\\\bazel-zig-cc"
        else:
            cache_prefix = "/tmp/bazel-zig-cc"

    repository_ctx.template(
        "tools/launcher.zig",
        Label("//toolchain:launcher.zig"),
        executable = False,
        substitutions = {
            "{BAZEL_ZIG_CC_CACHE_PREFIX}": cache_prefix,
        },
    )

    compile_env = {
        "ZIG_LOCAL_CACHE_DIR": cache_prefix,
        "ZIG_GLOBAL_CACHE_DIR": cache_prefix,
    }
    compile_cmd = [
        paths.join("..", "zig"),
        "build-exe",
        "-OReleaseSafe",
        "launcher.zig",
    ] + (["-static"] if os == "linux" else [])

    ret = repository_ctx.execute(
        compile_cmd,
        working_directory = "tools",
        environment = compile_env,
    )
    if ret.return_code != 0:
        full_cmd = [k + "=" + v for k, v in compile_env.items()] + compile_cmd
        fail(_compile_failed.format(
            compile_cmd = " ".join(full_cmd),
            return_code = ret.return_code,
            stdout = ret.stdout,
            stderr = ret.stderr,
            cache_prefix = cache_prefix,
        ))

    exe = ".exe" if os == "windows" else ""
    for target_config in target_structs(repository_ctx.attr.macos_sdk_versions):
        for zig_tool in _ZIG_TOOLS + target_config.tool_paths.values():
            tool_path = zig_tool_path(os).format(
                zig_tool = zig_tool,
                zigtarget = target_config.zigtarget,
            )
            repository_ctx.symlink("tools/launcher{}".format(exe), tool_path)

    fcntl_hack = _glibc_hack("fcntl64", "fcntl@GLIBC_2.2.5")
    repository_ctx.file("glibc-hacks/fcntl.map", content = fcntl_hack.mapfile)
    repository_ctx.file("glibc-hacks/fcntl.h", content = fcntl_hack.header)
    res_search_amd64 = _glibc_hack("res_search", "__res_search@GLIBC_2.2.5")
    repository_ctx.file("glibc-hacks/res_search-amd64.map", content = res_search_amd64.mapfile)
    repository_ctx.file("glibc-hacks/res_search-amd64.h", content = res_search_amd64.header)
    res_search_arm64 = _glibc_hack("res_search", "__res_search@GLIBC_2.17")
    repository_ctx.file("glibc-hacks/res_search-arm64.map", content = res_search_arm64.mapfile)
    repository_ctx.file("glibc-hacks/res_search-arm64.h", content = res_search_arm64.header)

zig_repository = repository_rule(
    attrs = {
        "version": attr.string(),
        "host_platform_sha256": attr.string_dict(),
        "url_formats": attr.string_list(allow_empty = False),
        "host_platform_ext": attr.string_dict(),
        "macos_sdk_versions": attr.string_list(),
    },
    environ = ["BAZEL_ZIG_CC_CACHE_PREFIX"],
    implementation = _zig_repository_impl,
)

def _macos_sdk_repository_impl(repository_ctx):
    urls = repository_ctx.attr.urls
    sha256 = repository_ctx.attr.sha256

    repository_ctx.symlink(Label("//toolchain:BUILD.macos.bazel"), "BUILD.bazel")
    repository_ctx.download_and_extract(
        auth = use_netrc(read_user_netrc(repository_ctx), urls, {}),
        url = urls,
        sha256 = sha256,
    )

macos_sdk_repository = repository_rule(
    attrs = {
        "urls": attr.string_list(allow_empty = False, mandatory = True),
        "sha256": attr.string(mandatory = True),
    },
    implementation = _macos_sdk_repository_impl,
)

def filegroup(name, **kwargs):
    native.filegroup(name = name, **kwargs)
    return ":" + name

def declare_macos_sdk_files():
    filegroup(name = "usr_include", srcs = native.glob(["usr/include/**"]))
    filegroup(name = "usr_lib", srcs = native.glob(["usr/lib/**"]))

def declare_files(os, macos_sdk_versions):
    filegroup(name = "all", srcs = native.glob(["**"]))
    filegroup(name = "empty")
    if os == "windows":
        native.exports_files(["zig.exe"], visibility = ["//visibility:public"])
        native.alias(name = "zig", actual = ":zig.exe")
    else:
        native.exports_files(["zig"], visibility = ["//visibility:public"])
    filegroup(name = "lib/std", srcs = native.glob(["lib/std/**"]))
    lazy_filegroups = {}

    for target_config in target_structs(macos_sdk_versions):
        cxx_tool_label = ":" + zig_tool_path(os).format(
            zig_tool = "c++",
            zigtarget = target_config.zigtarget,
        )

        all_includes = [native.glob(["lib/{}/**".format(i)]) for i in target_config.includes]
        all_includes.append(getattr(target_config, "compiler_extra_includes", []))

        filegroup(
            name = "{}_includes".format(target_config.zigtarget),
            srcs = _flatten(all_includes)
        )

        filegroup(
            name = "{}_compiler_files".format(target_config.zigtarget),
            srcs = [
                ":zig",
                ":lib/std",
                ":{}_includes".format(target_config.zigtarget),
                cxx_tool_label,
            ] + getattr(target_config, "sdk_include_files", [])
        )

        filegroup(
            name = "{}_linker_files".format(target_config.zigtarget),
            srcs = [
                ":zig",
                ":{}_includes".format(target_config.zigtarget),
                cxx_tool_label,
            ] + native.glob([
                "lib/libc/{}/**".format(target_config.libc),
                "lib/libcxx/**",
                "lib/libcxxabi/**",
                "lib/libunwind/**",
                "lib/compiler_rt/**",
                "lib/std/**",
                "lib/*.zig",
                "lib/*.h",
            ]) + getattr(target_config, "sdk_lib_files", []),
        )

        filegroup(
            name = "{}_ar_files".format(target_config.zigtarget),
            srcs = [
                ":zig",
                ":" + zig_tool_path(os).format(
                    zig_tool = "ar",
                    zigtarget = target_config.zigtarget,
                ),
            ],
        )

        filegroup(
            name = "{}_all_files".format(target_config.zigtarget),
            srcs = [
                ":{}_linker_files".format(target_config.zigtarget),
                ":{}_compiler_files".format(target_config.zigtarget),
                ":{}_ar_files".format(target_config.zigtarget),
            ],
        )

        for d in _DEFAULT_INCLUDE_DIRECTORIES + getattr(target_config, "includes", []):
            d = "lib/" + d
            if d not in lazy_filegroups:
                lazy_filegroups[d] = filegroup(name = d, srcs = native.glob([d + "/**"]))


def _flatten(iterable):
    result = []
    for element in iterable:
        result += element
    return result


def _macos_versions(versions):
    return "[{}]".format(", ".join([_quote(v) for v in versions]))
