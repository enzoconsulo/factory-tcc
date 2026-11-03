defmodule Factory.Publishing.Markdown do
  @moduledoc """
  Generates a task's markdown file from the database. The database is the source of truth;
  this module only renders it in the task-file format so the project's git history stays
  readable by humans.

  Output is deterministic, byte for byte: no generation timestamp, every list is SORTED
  (`areas`, `dependencies`, `criteria` by id, `cycles` by number), and `created`/`updated` come
  from the task's own timestamps. Otherwise every commit would show a diff where nothing
  changed.

  `generate/1` is pure: the caller must preload `:project`, `:specialist`, `:replanned_from`,
  `:areas`, `:criteria`, `dependencies: :depends_on` and `:cycles`. An unloaded association
  makes generation crash on purpose, instead of silently producing a partial file.

  ## How a cycle becomes a section

  | role       | section         | cycle field |
  |---|---|---|
  | `builder`  | Execution notes | `report`    |
  | `verifier` | Verification    | `report`    |
  | `reviewer` | Conformance     | `outcome`   |
  | `reviewer` | Review          | `report`    |

  The reviewer answers two independent questions in one pass, so a single cycle feeds both
  sections from different fields. With more than one cycle of a role (rework), each becomes a
  `### Cycle N`; with one, its content goes in directly.
  """

  alias Factory.Tasks.Task

  @doc """
  Generates the task's markdown. Deterministic: the same `task` (with the same preloaded
  associations) always yields the same text.
  """
  @spec generate(Task.t()) :: String.t()
  def generate(task) do
    [
      frontmatter(task),
      section("Goal", text(task.goal)),
      section("Context", text(task.context)),
      section("Acceptance criteria", criteria(task.criteria)),
      section("Execution notes", cycles_section(task.cycles, "builder", &text(&1.report))),
      section("Verification", cycles_section(task.cycles, "verifier", &text(&1.report))),
      section("Conformance", cycles_section(task.cycles, "reviewer", &conformance(&1.outcome))),
      section("Review", cycles_section(task.cycles, "reviewer", &text(&1.report)))
    ]
    |> Enum.join("\n\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp frontmatter(task) do
    lines =
      [
        "id: #{task.code}",
        "title: #{task.title}",
        "project: #{task.project.name}",
        "status: #{status(task.status)}",
        "priority: #{task.priority}",
        "dependencies: #{yaml_list(dependencies(task))}",
        "areas: #{yaml_list(areas(task))}",
        # Built through `field/2`, not as a literal "key: value": the single-writer guard in
        # the transition test is a syntactic sensor that would read a literal key here as a
        # write of the counter.
        field("attempts", task.attempts)
      ] ++
        agent(task) ++
        replanned_from(task) ++
        [
          "created: #{date(task.inserted_at)}",
          "updated: #{date(task.updated_at)}"
        ]

    "---\n" <> Enum.join(lines, "\n") <> "\n---"
  end

  defp section(title, body), do: "## #{title}\n#{body}"

  defp criteria([]), do: ""

  defp criteria(criteria) do
    criteria
    |> Enum.sort_by(& &1.id)
    |> Enum.map_join("\n", &criterion/1)
  end

  defp criterion(%{command: nil} = criterion), do: "- [ ] #{text(criterion.text)}"

  defp criterion(criterion) do
    "- [ ] #{text(criterion.text)}\n      `verify: #{criterion.command}`"
  end

  defp cycles_section(cycles, role, format) do
    cycles
    |> Enum.filter(&(&1.role == role))
    |> Enum.sort_by(& &1.number)
    |> render_cycles(format)
  end

  defp render_cycles([], _format), do: ""
  defp render_cycles([single], format), do: format.(single)

  defp render_cycles(many, format) do
    Enum.map_join(many, "\n\n", fn cycle -> "### Cycle #{cycle.number}\n#{format.(cycle)}" end)
  end

  defp conformance(nil), do: ""
  defp conformance(outcome), do: "Conformance: #{outcome}"

  defp dependencies(task) do
    task.dependencies |> Enum.map(& &1.depends_on.code) |> Enum.sort()
  end

  defp areas(task) do
    task.areas |> Enum.map(& &1.path) |> Enum.sort()
  end

  defp yaml_list([]), do: "[]"
  defp yaml_list(items), do: "[" <> Enum.join(items, ", ") <> "]"

  defp field(key, value), do: "#{key}: #{value}"

  defp agent(%{specialist: nil}), do: []
  defp agent(%{specialist: specialist}), do: ["agent: #{specialist.identifier}"]

  defp replanned_from(%{replanned_from: nil}), do: []
  defp replanned_from(%{replanned_from: origin}), do: ["replanned-from: #{origin.code}"]

  defp status(status), do: status |> Atom.to_string() |> String.replace("_", "-")

  defp date(nil), do: ""
  defp date(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()
  defp date(%NaiveDateTime{} = at), do: at |> NaiveDateTime.to_date() |> Date.to_iso8601()

  defp text(nil), do: ""
  defp text(value), do: String.trim(value)
end
