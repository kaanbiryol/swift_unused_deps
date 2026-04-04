"""Bazel aspect for detecting unused Swift dependencies.

Propagates through deps and private_deps of swift_library targets, collects
module traces, and runs the analyzer - all as Bazel actions. Produces a
per-target report file.

Usage:
    bazel build //App/... --config=unused-deps

    Or explicitly:
    bazel build //App/... \
        --aspects=//tools/swift_unused_deps/aspect:deps_info.bzl%swift_deps_aspect \
        --output_groups=swift_deps_report \
        --@build_bazel_rules_swift//swift:copt=-emit-loaded-module-trace \
        --spawn_strategy=local
"""

load("@build_bazel_rules_swift//swift:providers.bzl", "SwiftInfo")
load(":providers.bzl", "SwiftDepsInfo")

def _empty_trace(name):
    return '{"version":2,"name":"' + name + '","arch":"unknown","swiftmodules":[],"swiftmodulesDetailedInfo":[]}'

def _get_module_name(target):
    """Get the Swift module name from SwiftInfo."""
    for module in target[SwiftInfo].direct_modules:
        if module.swift:
            return module.name
    return None

def _get_swiftmodule_file(target):
    """Get the .swiftmodule File from SwiftInfo."""
    for module in target[SwiftInfo].direct_modules:
        if module.swift:
            return module.swift.swiftmodule
    return None

def _has_mixed_sources(ctx):
    has_swift = False
    has_other = False
    if hasattr(ctx.rule.attr, "srcs"):
        for src in ctx.rule.attr.srcs:
            for f in src.files.to_list():
                if f.extension == "swift":
                    has_swift = True
                elif f.extension in ["m", "mm", "c", "cc", "cpp"]:
                    has_other = True
    return has_swift and has_other

def _get_dep_module_name(dep):
    if SwiftInfo not in dep:
        return None
    for module in dep[SwiftInfo].direct_modules:
        if module.swift:
            return module.name
    return None

def _collect_dep_info(dep, kind):
    module_name = _get_dep_module_name(dep)
    if module_name == None:
        return None
    return {
        "label": str(dep.label),
        "module_name": module_name,
        "kind": kind,
    }

def _collect_transitive_modules(deps, private_deps):
    modules = {}
    for dep in list(deps) + list(private_deps):
        dep_module_name = _get_dep_module_name(dep)
        if dep_module_name:
            modules[dep_module_name] = str(dep.label)
        if SwiftDepsInfo in dep:
            for module_tuple in dep[SwiftDepsInfo].transitive_modules.to_list():
                mod_name, mod_label = module_tuple.split("=", 1)
                if mod_name not in modules:
                    modules[mod_name] = mod_label
    return modules

def _create_trace_action(ctx, module_name, swiftmodule_file):
    """Copy the loaded module trace to a declared output."""
    trace_output = ctx.actions.declare_file(
        "{}.trace.json".format(module_name),
    )

    empty_trace = _empty_trace(module_name)
    trace_beside_module = swiftmodule_file.path[:swiftmodule_file.path.rfind(".swiftmodule")] + ".trace.json"
    trace_at_root = module_name + ".trace.json"

    ctx.actions.run_shell(
        inputs = [swiftmodule_file],
        outputs = [trace_output],
        command = "if [ -f '{root}' ]; then cp '{root}' '{dst}'; elif [ -f '{beside}' ]; then cp '{beside}' '{dst}'; else echo '{fallback}' > '{dst}'; fi".format(
            root = trace_at_root,
            beside = trace_beside_module,
            dst = trace_output.path,
            fallback = empty_trace,
        ),
        mnemonic = "SwiftDepsTrace",
        progress_message = "Collecting module trace for %s" % module_name,
        execution_requirements = {"no-sandbox": "1"},
    )

    return trace_output

def _create_analysis_action(ctx, analyzer, metadata_file, trace_file, module_name):
    """Run the analyzer on a single target's metadata + trace."""
    report_file = ctx.actions.declare_file(
        "{}.swift_deps_report.json".format(module_name),
    )

    args = ctx.actions.args()
    args.add("--metadata-file", metadata_file)
    args.add("--trace-file", trace_file)
    args.add("--output", report_file)
    args.add("--json")

    ctx.actions.run(
        executable = analyzer,
        arguments = [args],
        inputs = [metadata_file, trace_file],
        outputs = [report_file],
        mnemonic = "SwiftDepsAnalyze",
        progress_message = "Analyzing unused deps for %s" % module_name,
    )

    return report_file

def _swift_deps_aspect_impl(target, ctx):
    if SwiftInfo not in target:
        return []

    module_name = _get_module_name(target)
    if module_name == None:
        return []

    swiftmodule_file = _get_swiftmodule_file(target)

    # Action 1: Copy trace file.
    trace_file = None
    if swiftmodule_file:
        trace_file = _create_trace_action(ctx, module_name, swiftmodule_file)

    # Build transitive module tuples.
    self_module_tuple = "{}={}".format(module_name, str(ctx.label))
    transitive_sets = [depset([self_module_tuple])]
    for attr_name in ["deps", "private_deps"]:
        if hasattr(ctx.rule.attr, attr_name):
            for dep in getattr(ctx.rule.attr, attr_name):
                if SwiftDepsInfo in dep:
                    transitive_sets.append(dep[SwiftDepsInfo].transitive_modules)
    transitive_modules = depset(transitive = transitive_sets)

    # Collect declared deps.
    declared_deps = []
    if hasattr(ctx.rule.attr, "deps"):
        for dep in ctx.rule.attr.deps:
            info = _collect_dep_info(dep, "dep")
            if info:
                declared_deps.append(info)

    declared_private_deps = []
    if hasattr(ctx.rule.attr, "private_deps"):
        for dep in ctx.rule.attr.private_deps:
            info = _collect_dep_info(dep, "private_dep")
            if info:
                declared_private_deps.append(info)

    # Build transitive module map.
    transitive_map = _collect_transitive_modules(
        ctx.rule.attr.deps if hasattr(ctx.rule.attr, "deps") else [],
        ctx.rule.attr.private_deps if hasattr(ctx.rule.attr, "private_deps") else [],
    )

    # Collect source file names.
    srcs = []
    if hasattr(ctx.rule.attr, "srcs"):
        for src in ctx.rule.attr.srcs:
            for f in src.files.to_list():
                srcs.append(f.basename)

    # Action 2: Write metadata JSON.
    metadata = {
        "schema_version": 1,
        "target": {
            "label": str(ctx.label),
            "module_name": module_name,
            "srcs": srcs,
            "is_mixed_source": _has_mixed_sources(ctx),
            "rule_kind": ctx.rule.kind,
        },
        "declared_deps": declared_deps + declared_private_deps,
        "transitive_module_map": transitive_map,
        "trace_file": trace_file.short_path if trace_file else "",
    }

    metadata_file = ctx.actions.declare_file(
        "{}.swift_deps_info.json".format(ctx.label.name),
    )
    ctx.actions.write(
        output = metadata_file,
        content = json.encode(metadata),
    )

    # Action 3: Run analyzer.
    report_file = None
    if trace_file:
        report_file = _create_analysis_action(
            ctx,
            ctx.executable._analyzer,
            metadata_file,
            trace_file,
            module_name,
        )

    # Output groups.
    info_outputs = [metadata_file]
    if trace_file:
        info_outputs.append(trace_file)

    report_outputs = []
    if report_file:
        report_outputs.append(report_file)

    return [
        SwiftDepsInfo(
            target_label = ctx.label,
            module_name = module_name,
            metadata_file = metadata_file,
            transitive_modules = transitive_modules,
        ),
        OutputGroupInfo(
            swift_deps_info = depset(info_outputs),
            swift_deps_report = depset(report_outputs),
        ),
    ]

swift_deps_aspect = aspect(
    implementation = _swift_deps_aspect_impl,
    doc = """Detects unused Swift dependencies.

    Produces per-target report files as Bazel outputs.

    Usage:
        bazel build //targets/... --config=unused-deps
    """,
    attr_aspects = ["deps", "private_deps"],
    attrs = {
        "_analyzer": attr.label(
            default = Label("//tools/swift_unused_deps/analyzer:cli"),
            executable = True,
            cfg = "exec",
        ),
    },
)
