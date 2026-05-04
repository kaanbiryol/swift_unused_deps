"""Bazel aspect for detecting unused Swift dependencies.

Propagates through deps and private_deps of swift_library targets and emits
per-target metadata for batch analysis.

Usage:
    bazel build //App/... --config=unused-deps

    Or explicitly:
    bazel build //App/... \
        --features=swift.index_while_building \
        --features=swift.use_global_index_store \
        --aspects=//tools/swift_unused_deps/aspect:deps_info.bzl%swift_deps_aspect \
        --output_groups=swift_deps_info,swift_index_store \
        --spawn_strategy=local
"""

load("@build_bazel_rules_swift//swift:providers.bzl", "SwiftInfo")
load(":providers.bzl", "SwiftDepsInfo")

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

def _get_indexstore_directory(target):
    """Get the declared indexstore directory from SwiftInfo if available."""
    for module in target[SwiftInfo].direct_modules:
        if module.swift:
            return getattr(module.swift, "indexstore", None)
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
    """Collect declared dep info from a dependency.

    Returns a list of dep info dicts. For normal swift_library targets this
    is a single-element list. For aggregation targets like swift_library_group
    (which have SwiftInfo but no direct module), the direct child modules
    are used with the group's own label.
    """
    module_name = _get_dep_module_name(dep)
    if module_name:
        return [{"label": str(dep.label), "module_name": module_name, "kind": kind}]

    # Target has no direct Swift module (e.g. swift_library_group).
    # Use the group's direct child modules with the group's own label.
    if SwiftDepsInfo in dep and dep[SwiftDepsInfo].direct_dep_modules:
        result = []
        for mod_name in dep[SwiftDepsInfo].direct_dep_modules:
            result.append({"label": str(dep.label), "module_name": mod_name, "kind": kind})
        return result

    return []

def _collect_transitive_modules(deps, private_deps, plugins = []):
    modules = {}
    for dep in list(deps) + list(private_deps) + list(plugins):
        dep_module_name = _get_dep_module_name(dep)
        if dep_module_name:
            modules[dep_module_name] = str(dep.label)
        if SwiftDepsInfo in dep:
            for module_tuple in dep[SwiftDepsInfo].transitive_modules.to_list():
                mod_name, mod_label = module_tuple.split("=", 1)
                if mod_name not in modules:
                    modules[mod_name] = mod_label
    return modules

def _collect_passthrough_transitive_modules(ctx):
    """Collect transitive modules from deps of a non-Swift target.

    This ensures the transitive module map is not broken when a non-Swift
    target (e.g. objc_library, swift_library_group) sits between two Swift
    targets. Also records which modules are directly provided by this
    target's deps (vs deeply transitive ones).
    """
    transitive_sets = []
    direct_dep_modules = []
    for attr_name in ["deps", "private_deps", "plugins"]:
        if hasattr(ctx.rule.attr, attr_name):
            for dep in getattr(ctx.rule.attr, attr_name):
                if SwiftDepsInfo in dep:
                    transitive_sets.append(dep[SwiftDepsInfo].transitive_modules)

                # Record direct module names from deps that have SwiftInfo.
                if SwiftInfo in dep:
                    for module in dep[SwiftInfo].direct_modules:
                        if module.swift:
                            direct_dep_modules.append(module.name)
    if transitive_sets:
        return [
            SwiftDepsInfo(
                target_label = ctx.label,
                module_name = None,
                metadata_file = None,
                transitive_modules = depset(transitive = transitive_sets),
                direct_dep_modules = direct_dep_modules,
            ),
        ]
    return []

def _swift_deps_aspect_impl(target, ctx):
    if SwiftInfo not in target:
        return _collect_passthrough_transitive_modules(ctx)

    module_name = _get_module_name(target)
    if module_name == None:
        # Target has SwiftInfo but no direct Swift module (e.g. swift_library_group).
        # Still propagate transitive modules from deps.
        return _collect_passthrough_transitive_modules(ctx)

    swiftmodule_file = _get_swiftmodule_file(target)
    indexstore_directory = _get_indexstore_directory(target)

    # Build transitive module tuples.
    self_module_tuple = "{}={}".format(module_name, str(ctx.label))
    transitive_sets = [depset([self_module_tuple])]
    for attr_name in ["deps", "private_deps", "plugins"]:
        if hasattr(ctx.rule.attr, attr_name):
            for dep in getattr(ctx.rule.attr, attr_name):
                if SwiftDepsInfo in dep:
                    transitive_sets.append(dep[SwiftDepsInfo].transitive_modules)
    transitive_modules = depset(transitive = transitive_sets)

    # Collect declared deps, deduplicating by module name (a module can
    # appear through multiple swift_library_group expansions).
    seen_modules = {}
    declared_deps = []
    if hasattr(ctx.rule.attr, "deps"):
        for dep in ctx.rule.attr.deps:
            for info in _collect_dep_info(dep, "dep"):
                if info["module_name"] not in seen_modules:
                    seen_modules[info["module_name"]] = True
                    declared_deps.append(info)

    declared_private_deps = []
    if hasattr(ctx.rule.attr, "private_deps"):
        for dep in ctx.rule.attr.private_deps:
            for info in _collect_dep_info(dep, "private_dep"):
                if info["module_name"] not in seen_modules:
                    seen_modules[info["module_name"]] = True
                    declared_private_deps.append(info)

    # Build transitive module map.
    transitive_map = _collect_transitive_modules(
        ctx.rule.attr.deps if hasattr(ctx.rule.attr, "deps") else [],
        ctx.rule.attr.private_deps if hasattr(ctx.rule.attr, "private_deps") else [],
        ctx.rule.attr.plugins if hasattr(ctx.rule.attr, "plugins") else [],
    )

    # Collect source file names.
    srcs = []
    if hasattr(ctx.rule.attr, "srcs"):
        for src in ctx.rule.attr.srcs:
            for f in src.files.to_list():
                if f.extension == "swift":
                    srcs.append(f.basename)

    # Write metadata JSON.
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
        "indexstore_path": indexstore_directory.short_path if indexstore_directory else "",
    }

    metadata_file = ctx.actions.declare_file(
        "{}.swift_deps_info.json".format(ctx.label.name),
    )
    metadata_json = json.encode(metadata)

    # Use run_shell with swiftmodule as input to ensure compilation runs
    # (needed so the index store gets populated as a side effect).
    if swiftmodule_file:
        ctx.actions.run_shell(
            inputs = [swiftmodule_file],
            outputs = [metadata_file],
            command = "cat > '{}' << 'METADATA_EOF'\n{}\nMETADATA_EOF".format(
                metadata_file.path,
                metadata_json,
            ),
            mnemonic = "SwiftDepsMetadata",
            progress_message = "Collecting deps metadata for %s" % module_name,
        )
    else:
        ctx.actions.write(
            output = metadata_file,
            content = metadata_json,
        )

    return [
        SwiftDepsInfo(
            target_label = ctx.label,
            module_name = module_name,
            metadata_file = metadata_file,
            transitive_modules = transitive_modules,
            direct_dep_modules = [],
        ),
        OutputGroupInfo(swift_deps_info = depset([metadata_file])),
    ]

swift_deps_aspect = aspect(
    implementation = _swift_deps_aspect_impl,
    doc = """Detects unused Swift dependencies.

    Produces per-target metadata files as Bazel outputs.

    Usage:
        bazel build //targets/... --config=unused-deps
    """,
    attr_aspects = ["deps", "private_deps", "plugins"],
)
