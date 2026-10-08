# Dialyzer warnings ignored per file, each with its reason. Only false positives with a known
# cause go here; a project-wide flag would also hide real violations elsewhere.
#
# `call_without_opaque` where an `Ecto.Multi` is built: `Ecto.Multi.t()` holds an opaque
# `MapSet.t()`, and Dialyzer complains when the literal returned by `Multi.new()` is passed
# along. This is a known Dialyzer + Ecto.Multi limitation; extracting the body into a function
# with a `Multi.t()` spec only moves the warning.
[
  {"lib/factory/tools/report_result.ex", :call_without_opaque}
]
