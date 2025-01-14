"Public API"

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@bazel_skylib//lib:sets.bzl", "sets")
load("//:rules.bzl", "MyPyStubsInfo")

MyPyAspectInfo = provider(
    "TODO: documentation",
    fields = {
        "exe": "Used to pass the rule implementation built exe back to calling aspect.",
        "out": "Used to pass the dummy output file back to calling aspect.",
    },
)

# Switch to True only during debugging and development.
# All releases should have this as False.
DEBUG = False

VALID_EXTENSIONS = ["py", "pyi"]

DEFAULT_ATTRS = {
    "_template": attr.label(
        default = Label("//templates:mypy.sh.tpl"),
        allow_single_file = True,
    ),
    "_mypy_cli": attr.label(
        default = Label("//mypy"),
        executable = True,
        cfg = "host",
    ),
    "_mypy_config": attr.label(
        default = Label("@mypy_integration_config//:mypy.ini"),
        allow_single_file = True,
    ),
}

def _sources_to_cache_map_triples(srcs, is_aspect):
    triples_as_flat_list = []
    for f in srcs:
        if is_aspect:
            f_path = f.path
        else:
            # "The path of this file relative to its root. This excludes the aforementioned root, i.e. configuration-specific fragments of the path.
            # This is also the path under which the file is mapped if it's in the runfiles of a binary."
            # - https://docs.bazel.build/versions/master/skylark/lib/File.html
            f_path = f.short_path
        triples_as_flat_list.extend([
            shell.quote(f_path),
            shell.quote("{}.meta.json".format(f_path)),
            shell.quote("{}.data.json".format(f_path)),
        ])
    return triples_as_flat_list

def _is_external_dep(dep):
    return dep.label.workspace_root.startswith("external/")

def _is_external_src(src_file):
    return src_file.path.startswith("external/")

def _extract_srcs(srcs):
    direct_src_files = []
    for src in srcs:
        for f in src.files.to_list():
            if f.extension in VALID_EXTENSIONS:
                direct_src_files.append(f)
    return direct_src_files

def _extract_transitive_deps(deps, include_imports):
    transitive_deps = []
    transitive_imports = []
    seen_imports = {}  # No sets in Starlark, so use a dict.
    for dep in deps:
        if MyPyStubsInfo not in dep and PyInfo in dep:
            if include_imports:
                transitive_deps.append(dep[PyInfo].transitive_sources)
                for imp in dep[PyInfo].imports.to_list():
                    if imp not in seen_imports:
                        seen_imports[imp] = None
                        transitive_imports.append(imp)
            elif not _is_external_dep(dep):
                transitive_deps.append(dep[PyInfo].transitive_sources)
    return transitive_deps, transitive_imports

def _extract_stub_deps(deps):
    # Need to add the .py files AND the .pyi files that are
    # deps of the rule
    stub_files = []
    for dep in deps:
        if MyPyStubsInfo in dep:
            for stub_srcs_target in dep[MyPyStubsInfo].srcs:
                for src_f in stub_srcs_target.files.to_list():
                    if src_f.extension == "pyi":
                        stub_files.append(src_f)
    print("STUB FILES AND DEPS")
    print(stub_files)
    print(deps)
    return stub_files

def _extract_imports(imports, label):
    # NOTE: Bazel's implementation of this for py_binary, py_test is at
    # src/main/java/com/google/devtools/build/lib/bazel/rules/python/BazelPythonSemantics.java
    mypypath_parts = []
    for import_ in imports:
        if import_.startswith("/"):
            # buildifier: disable=print
            print("ignoring invalid absolute path '{}'".format(import_))
        elif import_ in ["", "."]:
            mypypath_parts.append(label.package)
        else:
            mypypath_parts.append("{}/{}".format(label.package, import_))
    return mypypath_parts

def _mypy_rule_impl(ctx, is_aspect = False):
    base_rule = ctx
    if is_aspect:
        base_rule = ctx.rule

    mypy_config_file = ctx.file._mypy_config

    mypypath_parts = []
    direct_src_files = []
    transitive_srcs_depsets = []
    stub_files = []

    include_imports = hasattr(base_rule.attr, "include_imports") and base_rule.attr.include_imports

    if hasattr(base_rule.attr, "srcs"):
        direct_src_files = _extract_srcs(base_rule.attr.srcs)

    if hasattr(base_rule.attr, "deps"):
        transitive_srcs_depsets, transitive_imports = _extract_transitive_deps(base_rule.attr.deps, include_imports)
        stub_files = _extract_stub_deps(base_rule.attr.deps)
        print("THESE ARE THE TRANSITIVE IMPORTS")
        print(transitive_imports)
        print(base_rule)
        print(base_rule.attr)
        print(base_rule.attr.deps)
        for dep in base_rule.attr.deps:
            print(dep.label.workspace_root) 
        if transitive_imports:
            rel_workspace_root = ''
            # If in a package, imports need to be made relative to the
            # workspace root.
            print("ctx.label.package")
            print(ctx.label.package)
            print(transitive_imports)
            if ctx.label.package:
                rel_workspace_root = '../' * (ctx.label.package.count('/') + 1)
            mypypath_parts += [rel_workspace_root + x for x in transitive_imports]
            print("mypypath_parts")
            print(mypypath_parts)

    if hasattr(base_rule.attr, "imports"):
        mypypath_parts += _extract_imports(base_rule.attr.imports, ctx.label)

    final_srcs_depset = depset(transitive = transitive_srcs_depsets +
                                            [depset(direct = direct_src_files)])
    input_src_files = final_srcs_depset.to_list()
    target_src_files = [f for f in input_src_files if not _is_external_src(f)]
    if not target_src_files:
        return None

    # If imports aren't being included, the input src files are restricted to
    # only the direct targets.
    if not include_imports:
        input_src_files = target_src_files

    mypypath_parts += [src_f.dirname for src_f in stub_files]
    mypypath = ":".join(mypypath_parts)
    print("MYPYPATHS")
    print(mypypath)

    # Ideally, a file should be passed into this rule. If this is an executable
    # rule, then we default to the implicit executable file, otherwise we create
    # a stub.
    if not is_aspect:
        if hasattr(ctx, "outputs"):
            exe = ctx.outputs.executable
        else:
            exe = ctx.actions.declare_file(
                "%s_mypy_exe" % base_rule.attr.name,
            )
        out = None
    else:
        out = ctx.actions.declare_file("%s_dummy_out" % ctx.rule.attr.name)
        exe = ctx.actions.declare_file(
            "%s_mypy_exe" % ctx.rule.attr.name,
        )

    # Compose a list of the files needed for use. Note that aspect rules can use
    # the project version of mypy however, other rules should fall back on their
    # relative runfiles.
    runfiles = ctx.runfiles(files = input_src_files + stub_files + [mypy_config_file])
    if not is_aspect:
        runfiles = runfiles.merge(ctx.attr._mypy_cli.default_runfiles)

    src_root_paths = sets.to_list(
        sets.make([f.root.path for f in input_src_files]),
    )

    follow_imports = ""
    if include_imports:
        pass
        # --follow-imports=silent is passed in order to suppress errors on
        # non-target (imported) libraries.
        # 0.810 has a --exclude flag which may work better:
        # https://github.com/python/mypy/pull/9992
        # follow_imports = "--follow-imports=silent"

    ctx.actions.expand_template(
        template = ctx.file._template,
        output = exe,
        substitutions = {
            "{MYPY_EXE}": ctx.executable._mypy_cli.path,
            "{MYPY_ROOT}": ctx.executable._mypy_cli.root.path,
            "{CACHE_MAP_TRIPLES}": " ".join(_sources_to_cache_map_triples(input_src_files, is_aspect)),
            "{PACKAGE_ROOTS}": " ".join([
                "--package-root " + shell.quote(path or ".")
                for path in src_root_paths
            ]),
            "{SRCS}": " ".join([
                shell.quote(f.path) if is_aspect else shell.quote(f.short_path)
                for f in target_src_files
            ]),
            "{VERBOSE_OPT}": "--verbose" if DEBUG else "",
            "{VERBOSE_BASH}": "set -x" if DEBUG else "",
            "{OUTPUT}": out.path if out else "",
            "{MYPYPATH_PATH}": mypypath if mypypath else "",
            "{MYPY_INI_PATH}": mypy_config_file.path,
            "{FOLLOW_IMPORTS}": follow_imports,
        },
        is_executable = True,
    )

    if is_aspect:
        return [
            DefaultInfo(executable = exe, runfiles = runfiles),
            MyPyAspectInfo(exe = exe, out = out),
        ]
    return DefaultInfo(executable = exe, runfiles = runfiles)

def _mypy_aspect_impl(_, ctx):
    if (ctx.rule.kind not in ["py_binary", "py_library", "py_test", "mypy_test"] or
        ctx.label.workspace_root.startswith("external")):
        return []

    providers = _mypy_rule_impl(
        ctx,
        is_aspect = True,
    )
    if not providers:
        return []

    info = providers[0]
    aspect_info = providers[1]

    ctx.actions.run(
        outputs = [aspect_info.out],
        inputs = info.default_runfiles.files,
        tools = [ctx.executable._mypy_cli],
        executable = aspect_info.exe,
        mnemonic = "MyPy",
        progress_message = "Type-checking %s" % ctx.label,
        use_default_shell_env = True,
    )
    return [
        OutputGroupInfo(
            mypy = depset([aspect_info.out]),
        ),
    ]

def _mypy_test_impl(ctx):
    info = _mypy_rule_impl(ctx, is_aspect = False)
    if not info:
        fail("A list of python deps are required for mypy_test")
    return info

mypy_aspect = aspect(
    implementation = _mypy_aspect_impl,
    attr_aspects = ["deps"],
    attrs = DEFAULT_ATTRS,
)

mypy_test = rule(
    implementation = _mypy_test_impl,
    test = True,
    attrs = dict(DEFAULT_ATTRS.items() +
                 [("deps", attr.label_list(aspects = [mypy_aspect])),
                  ("include_imports",
                   attr.bool(doc = "Set to true to include imported Python files for mypy. This is required for use with pip `requirement()` rules.")),
                 ]
    ),
)
