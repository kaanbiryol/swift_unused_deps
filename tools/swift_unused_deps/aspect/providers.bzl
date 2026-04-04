"""Provider definitions for swift_unused_deps aspect."""

SwiftDepsInfo = provider(
    doc = """Collected dependency metadata for a swift_library target.

    This provider carries the module-name-to-label mapping that SwiftInfo
    does not provide. Module names are read from SwiftInfo.direct_modules,
    but the Bazel label association is tracked here.
    """,
    fields = {
        "target_label": "Label of the analyzed target.",
        "module_name": "Swift module name (read from SwiftInfo).",
        "metadata_file": "File containing the full metadata JSON.",
        "transitive_modules": "Depset of 'module_name=label' strings for all transitive Swift deps.",
    },
)
