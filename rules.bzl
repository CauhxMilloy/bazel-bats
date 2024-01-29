load("@bazel_skylib//lib:collections.bzl", "collections")

# From:
# https://stackoverflow.com/questions/47192668/idiomatic-retrieval-of-the-bazel-execution-path#

def _dirname(path):
    prefix, _, _ = path.rpartition("/")
    return prefix.rstrip("/")

def _test_files(bats, srcs, attr):
    return '"{bats_bin}" {bats_args} {test_paths}'.format(
        bats_bin = bats.short_path,
        bats_args = " ".join(attr.bats_args),
        test_paths = " ".join(['"{}"'.format(s.short_path) for s in srcs]),
    )

# Finds shortest path.
# Used to find commonpath for bats-assert or bats-support.
# This would not always necessarily return the correct path (in other contexts),
# but works for the filegroups used.
# A more robust method of finding the base directory is made more difficult by skylark's
# divergence from python. Bringing in skylab as a dependency was deemed overkill.
# So long as a file in the base dir exists (e.g. load.bash), this is fine.
def _base_dir(files):
    result = files[0].dirname
    min_len = len(files[0].dirname)
    for file in files:
        if len(file.dirname) < min_len:
            min_len = len(file.dirname)
            result = file.dirname
    return result

def _bats_test_impl(ctx):
    path = ["$PWD/" + _dirname(b.short_path) for b in ctx.files.deps]
    sep = ctx.configuration.host_path_separator

    content = "\n".join(
        ["#!/usr/bin/env bash"] +
        ["set -e"] +
        ["export TMPDIR=\"$TEST_TMPDIR\""] +
        ["export PATH=\"{bats_bins_path}\":$PATH".format(bats_bins_path = sep.join(path))] +
        [_test_files(ctx.executable._bats, ctx.files.srcs, ctx.attr)],
    )
    ctx.actions.write(
        output = ctx.outputs.executable,
        content = content,
    )

    dep_transitive_files = []
    for dep in ctx.attr.deps:
        dep_transitive_files.extend(dep.default_runfiles.files.to_list())
    runfiles = ctx.runfiles(
        files = ctx.files.srcs,
        transitive_files = depset(ctx.files.data + dep_transitive_files),
    ).merge(ctx.attr._bats.default_runfiles)
    return [DefaultInfo(runfiles = runfiles)]

def _bats_with_bats_assert_test_impl(ctx):
    base_info = _bats_test_impl(ctx)[0]

    bats_assert_base_dir = _base_dir(ctx.attr._bats_assert.files.to_list())
    bats_support_base_dir = _base_dir(ctx.attr._bats_support.files.to_list())
    test_helper_outputs = []
    for src_file in ctx.files.srcs:
        test_helper_dir = ctx.actions.declare_directory(
            "test_helper",
            sibling = src_file,
        )
        test_helper_outputs.append(test_helper_dir)
        ctx.actions.run_shell(
            outputs = [test_helper_dir],
            inputs = depset(ctx.attr._bats_assert.files.to_list() + ctx.attr._bats_support.files.to_list()),
            arguments = [test_helper_dir.path, bats_assert_base_dir, bats_support_base_dir],
            command = """
            mkdir -p $1/bats-support $1/bats-assert \\
                && cp -r $2/* $1/bats-assert \\
                && cp -r $3/* $1/bats-support
            """,
        )

    runfiles = ctx.runfiles(
        files = test_helper_outputs,
    ).merge(base_info.default_runfiles)
    return [DefaultInfo(runfiles = runfiles)]

_bats_test_attrs = {
    "data": attr.label_list(allow_files = True),
    "deps": attr.label_list(),
    "bats_args": attr.string_list(
        doc = "List of arguments passed to `bats`",
    ),
    "srcs": attr.label_list(
        allow_files = [".bats"],
        doc = "Source files to run a BATS test on",
    ),
    "_bats": attr.label(
        default = Label("@bats_core//:bats"),
        executable = True,
        cfg = "exec",
    ),
}

_bats_with_bats_assert_test_attrs = _bats_test_attrs | {
    "_bats_support": attr.label(
        default = Label("@bats_support//:load_files"),
    ),
    "_bats_assert": attr.label(
        default = Label("@bats_assert//:load_files"),
    ),
}

_bats_test = rule(
    _bats_test_impl,
    attrs = _bats_test_attrs,
    test = True,
    doc = "Runs a BATS test on the supplied source files.",
)

_bats_with_bats_assert_test = rule(
    _bats_with_bats_assert_test_impl,
    attrs = _bats_with_bats_assert_test_attrs,
    test = True,
    doc = "Runs a BATS test on the supplied source files, allowing for usage of bats-support and bats-assert.",
)

def bats_test(uses_bats_assert = False, **kwargs):
    """
    A rule for creating a test target for running one or more `*.bats` test files.

    The rule is implemented as a macro to handle creating the correct rule(s) for running bats
    tests with the necessary dependencies and environment configuration.
    Two targets are created internally.
    An `sh_test` is used for the actual target, this ensures that environment variables will be
    expanded properly.
    A custom rule is used to generated the entrypoint and context for the test to run. This
    target's name is suffixed with `_entrypoint` and is marked as `manual` to not run out of
    context (ignore wildcards like `*` and `...`).

    Args:
        uses_bats_assert (str): Whether this test makes use of `bats_assert` (and `bats_support`).
        **kwargs (dict): Additional keyword arguments that are passed to the underyling targets.
            These attributes may include:
            name:       (Required) The name for the underlying `sh_test` target and the custom
                            internal (suffixed) entrypoint target.
            srcs:       (Required) The `*.bats` files to be run by this test.
            data:       (Optional) Files necessary for the test during runtime.
            deps:       (Optional) Dependency targets for the test.
            bats_args:  (Optional) Arguments to be passed to the `bats` (bats-core) binary when
                        running the tests.
            env:        (Optional) Dictionary of enviroment variables to their set values. Values
                        are subject to $(location) and "Make variable" substitution. This includes
                        logic provided via `toolchains`.
            toolchains: (Optional) Additional providers for extra logic (e.g. `env` substitution).
            tags:       (Optional) Tags to be set onto underlying rules.
            *:          (Optional) Any other attributes that apply for `*_test` targets.
    """
    name = kwargs.pop("name")
    srcs = kwargs.pop("srcs")
    data = kwargs.pop("data", [])
    deps = kwargs.pop("deps", [])
    env = kwargs.pop("env", {})
    bats_args = kwargs.pop("bats_args", [])
    tags = kwargs.pop("tags", [])

    if not uses_bats_assert:
        _bats_test(
            name = name + "_entrypoint",
            srcs = srcs,
            data = data,
            deps = deps,
            bats_args = bats_args,
            tags = collections.uniq(tags + ["manual"]),
            **kwargs
        )
    else:
        _bats_with_bats_assert_test(
            name = name + "_entrypoint",
            srcs = srcs,
            data = data,
            deps = deps,
            bats_args = bats_args,
            tags = collections.uniq(tags + ["manual"]),
            **kwargs
        )

    native.sh_test(
        name = name,
        srcs = [
            ":" + name + "_entrypoint",
        ],
        data = data + deps,
        env = env,
        tags = tags,
        **kwargs
    )

# Inspired from `rules_rust`
def bats_test_suite(name, srcs, **kwargs):
    """
    A rule for creating a test suite for a set of `bats_test` targets.

    The rule can be used to generate `bats_test` targets for each source file and a `test_suite`
    which encapsulates all tests.

    Args:
        name (str): The name of the `test_suite`.
        srcs (list): All test sources, typically `glob(["*.bats"])`.
        **kwargs (dict): Additional keyword arguments for the underyling `bats_test` targets. The
            `tags` argument is also passed to the generated `test_suite` target.
    """
    tests = []

    for src in srcs:
        # Prefixed with `name` to allow parameterization with macros
        # The test name should not end with `.bats`
        test_name = name + "_" + src[:-5]
        bats_test(
            name = test_name,
            srcs = [src],
            **kwargs
        )
        tests.append(test_name)

    native.test_suite(
        name = name,
        tests = tests,
        tags = kwargs.get("tags", None),
    )
