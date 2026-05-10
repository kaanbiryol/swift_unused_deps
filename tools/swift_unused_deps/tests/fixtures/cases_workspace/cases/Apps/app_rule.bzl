"""Fixture-only app-like rule with deps but no SwiftInfo."""

def _fixture_app_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".fixture_app")
    ctx.actions.write(out, "fixture app\n")
    return [DefaultInfo(files = depset([out]))]

fixture_app = rule(
    implementation = _fixture_app_impl,
    attrs = {
        "deps": attr.label_list(),
    },
)
