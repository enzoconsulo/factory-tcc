defmodule Factory.Planner do
  @moduledoc """
  Turns a natural-language request into a graph of 8 to 12 tasks, written to the database in a
  single transaction — or nothing is written.

  The plan comes back as a ```` ```json ```` code block in the agent's LAST message (format
  defined in `priv/doctrine/planner.md`), not through `report_result`, whose fields describe a
  build report. This module extracts and validates that block after the provider answers.

  It calls `Factory.Provider.chat/2` directly rather than `Factory.Agents.Loop`: for the
  `:full_agent` family the loop does not keep the final text where the plan lives, and planning
  needs no factory tool loop (exploration runs inside a single adapter session).

  Every task, area, criterion and dependency enters one `Ecto.Multi`. A response without valid
  JSON, a task count outside 8..12, an area ending in `/` (a directory) or a dependency cycle is
  refused BEFORE touching the database, and a changeset failure inside the `Multi` rolls back
  everything. There is never a partial plan.

  The JSON `id` is a local integer (1..N) used only to express `dependencies`; the real code
  (`T-NNN`) is assigned here, continuing the project's numbering — like `status` and
  `attempts`, it is a system field.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Factory.Index.CodeMap
  alias Factory.Projects.Project
  alias Factory.Prompt.Prefix
  alias Factory.Provider
  alias Factory.Provider.Request
  alias Factory.Repo
  alias Factory.Tasks.Area
  alias Factory.Tasks.Criterion
  alias Factory.Tasks.Dependency
  alias Factory.Tasks.Task
  alias Factory.Team.Resolution
  alias Factory.Tools.Catalog

  @role "planner"
  @default_model "sonnet-5"
  @default_max_turns 30
  @min_tasks 8
  @max_tasks 12
  @valid_levels ~w[executed inspected judged]

  @doc """
  Plans `request` for `project` (new or existing) by dispatching the `"planner"` role.

  Options: `:model` (default `#{inspect(@default_model)}`), `:max_turns` (default
  #{@default_max_turns}), `:needle` (the `Factory.Provider.Fake` needle, required in tests) and
  `:root` (default `project.path`, passed to the `Factory.Provider.ClaudeCLI` confinement audit).

  Returns `{:ok, %{project: project, tasks: [task, ...]}}` with the tasks persisted and
  preloaded (`:areas`, `:criteria`, `:dependencies`), or `{:error, reason}` having written
  nothing.
  """
  @spec plan(String.t(), Project.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(request, %Project{} = project, opts \\ []) when is_binary(request) do
    with {:ok, response} <- ask(request, project, opts),
         {:ok, raw} <- extract_json(response.blocks),
         {:ok, tasks} <- validate_plan(raw) do
      write(project, tasks)
    end
  end

  # --- the provider exchange -------------------------------------------------------------

  defp ask(request, project, opts) do
    model = Keyword.get(opts, :model, @default_model)

    provider_request = %Request{
      model: model,
      role: @role,
      prefix: prefix(project, model),
      messages: [%{role: :user, content: request}],
      tools: role_tools(),
      max_turns: Keyword.get(opts, :max_turns, @default_max_turns)
    }

    provider_opts =
      opts
      |> Keyword.take([:needle, :root])
      |> Keyword.put_new(:root, project.path)

    case Provider.chat(provider_request, provider_opts) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:provider, reason}}
    end
  end

  defp role_tools do
    case Catalog.for_role(@role) do
      {:ok, tools} -> Map.keys(tools)
      {:error, _reason} -> []
    end
  end

  # The planner works on no existing task, so the doctrine is built here: generic role, no
  # specialist, index of the TARGET project. The request itself goes as a message, not in the
  # prefix, since it changes on every call.
  defp prefix(project, model) do
    doctrine =
      :planner
      |> Resolution.resolve(nil, [])
      |> Resolution.doctrine(doctrine_text())

    index = [root: project.path] |> CodeMap.extract() |> CodeMap.render()

    model
    |> Prefix.build(tools: role_tools(), doctrine: doctrine, index: index)
    |> Map.fetch!(:blocks)
    |> Enum.map(&provider_block/1)
  end

  defp provider_block(%Factory.Prompt.Block{text: text, cache_breakpoint: cache_breakpoint}) do
    %Factory.Provider.Block{text: text, cache_breakpoint: cache_breakpoint}
  end

  defp doctrine_text do
    :factory
    |> Application.app_dir("priv")
    |> Path.join("doctrine/planner.md")
    |> File.read!()
  end

  # --- extract the JSON from the last message ---------------------------------------------

  defp extract_json(blocks) do
    text =
      blocks
      |> Enum.filter(&(&1[:type] == :text))
      |> Enum.map_join("\n", &(&1[:text] || ""))

    case last_json_block(text) do
      nil ->
        {:error, {:response_without_json, text}}

      body ->
        case Jason.decode(body) do
          {:ok, map} -> {:ok, map}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end
    end
  end

  # The LAST fenced block: the end of the conversation decides, never an earlier excerpt.
  defp last_json_block(text) do
    ~r/```(?:json)?\s*\n(.*?)\n```/s
    |> Regex.scan(text)
    |> List.last()
    |> case do
      [_, body] -> body
      _ -> nil
    end
  end

  # --- validate the plan before touching the database --------------------------------------

  defp validate_plan(%{"tasks" => tasks}) when is_list(tasks) do
    cond do
      length(tasks) not in @min_tasks..@max_tasks ->
        {:error, {:task_count_out_of_range, length(tasks)}}

      (reason = validate_tasks(tasks)) != :ok ->
        reason

      (reason = validate_dependencies(tasks)) != :ok ->
        reason

      true ->
        {:ok, normalize(tasks)}
    end
  end

  defp validate_plan(_other), do: {:error, {:invalid_plan, :tasks_field_missing}}

  defp validate_tasks(tasks) do
    ids = Enum.map(tasks, & &1["id"])

    cond do
      Enum.any?(tasks, &invalid_task?/1) -> {:error, :incomplete_task}
      Enum.uniq(ids) != ids -> {:error, :duplicate_id}
      true -> :ok
    end
  end

  defp invalid_task?(task) do
    blank?(task["id"]) or blank?(task["title"]) or blank?(task["goal"]) or
      not valid_areas?(task["areas"]) or not valid_criteria?(task["criteria"])
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp valid_areas?(areas) when is_list(areas) and areas != [],
    do: Enum.all?(areas, &valid_area?/1)

  defp valid_areas?(_areas), do: false

  # Never a directory: refuse anything ending in a path separator.
  defp valid_area?(area) do
    is_binary(area) and String.trim(area) != "" and not String.ends_with?(area, "/") and
      not String.ends_with?(area, "\\")
  end

  defp valid_criteria?(criteria) when is_list(criteria) and criteria != [],
    do: Enum.all?(criteria, &valid_criterion?/1)

  defp valid_criteria?(_criteria), do: false

  defp valid_criterion?(%{"text" => text} = criterion) do
    not blank?(text) and valid_level?(criterion["level"])
  end

  defp valid_criterion?(_criterion), do: false

  defp valid_level?(nil), do: true
  defp valid_level?(level), do: level in @valid_levels

  defp validate_dependencies(tasks) do
    ids = MapSet.new(tasks, & &1["id"])
    graph = Map.new(tasks, &{&1["id"], List.wrap(&1["dependencies"])})

    cond do
      Enum.any?(graph, fn {_id, deps} -> Enum.any?(deps, &(&1 not in ids)) end) ->
        {:error, :unknown_dependency}

      cyclic?(graph) ->
        {:error, :dependency_cycle}

      true ->
        :ok
    end
  end

  # Three-colour DFS: :white (unvisited), :grey (on the current path — meeting one again IS the
  # cycle), :black (finished, no cycle reachable from it).
  defp cyclic?(graph) do
    initial = Map.new(graph, fn {node, _} -> {node, :white} end)

    {_state, cycle?} =
      Enum.reduce(Map.keys(graph), {initial, false}, &visit(graph, &1, &2))

    cycle?
  end

  defp visit(_graph, _node, {_state, true} = acc), do: acc

  defp visit(graph, node, {state, false}) do
    case Map.fetch!(state, node) do
      :black ->
        {state, false}

      :grey ->
        {state, true}

      :white ->
        state = Map.put(state, node, :grey)

        {state, cycle?} =
          Enum.reduce(Map.fetch!(graph, node), {state, false}, &visit(graph, &1, &2))

        {Map.put(state, node, :black), cycle?}
    end
  end

  defp normalize(tasks), do: Enum.map(tasks, &normalize_task/1)

  defp normalize_task(task) do
    %{
      id: task["id"],
      title: String.trim(task["title"]),
      goal: String.trim(task["goal"]),
      context: task["context"] |> text_or_empty() |> String.trim(),
      areas: Enum.map(task["areas"], &String.trim/1),
      criteria: Enum.map(task["criteria"], &normalize_criterion/1),
      dependencies: List.wrap(task["dependencies"])
    }
  end

  defp text_or_empty(nil), do: ""
  defp text_or_empty(text), do: text

  defp normalize_criterion(criterion) do
    command = command_or_nil(criterion["command"])

    level =
      cond do
        command != nil -> :executed
        criterion["level"] in @valid_levels -> String.to_existing_atom(criterion["level"])
        true -> :inspected
      end

    %{text: String.trim(criterion["text"]), command: command, level: level}
  end

  defp command_or_nil(nil), do: nil

  defp command_or_nil(command) do
    case String.trim(command) do
      "" -> nil
      command -> command
    end
  end

  # --- write everything in one transaction ------------------------------------------------

  defp write(project, tasks) do
    next = next_number(project)

    project
    |> build_multi(tasks, next)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, %{project: project, tasks: written_tasks(changes, tasks)}}
      {:error, step, reason, _changes} -> {:error, {:write_failed, step, reason}}
    end
  end

  defp next_number(project) do
    Task
    |> from(where: [project_id: ^project.id], select: [:code])
    |> Repo.all()
    |> Enum.map(&number_from_code(&1.code))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp number_from_code(code) do
    case Regex.run(~r/^T-(\d+)/i, code) do
      [_, number] -> String.to_integer(number)
      _other -> 0
    end
  end

  defp code(number), do: "T-#{number |> Integer.to_string() |> String.pad_leading(3, "0")}"

  defp build_multi(project, tasks, next_number) do
    tasks
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {task, index}, multi ->
      multi
      |> insert_task(project, task, code(next_number + index))
      |> insert_areas(task)
      |> insert_criteria(task)
    end)
    |> insert_dependencies(tasks)
  end

  defp insert_task(multi, project, task, code) do
    attrs = %{
      project_id: project.id,
      code: code,
      title: task.title,
      goal: task.goal,
      context: task.context
    }

    Multi.insert(multi, {:task, task.id}, Task.changeset(%Task{}, attrs))
  end

  defp insert_areas(multi, task) do
    task.areas
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {path, index}, multi ->
      Multi.insert(multi, {:area, task.id, index}, fn changes ->
        Area.changeset(%Area{}, %{
          task_id: Map.fetch!(changes, {:task, task.id}).id,
          path: path
        })
      end)
    end)
  end

  defp insert_criteria(multi, task) do
    task.criteria
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {criterion, index}, multi ->
      Multi.insert(multi, {:criterion, task.id, index}, fn changes ->
        Criterion.changeset(%Criterion{}, %{
          task_id: Map.fetch!(changes, {:task, task.id}).id,
          text: criterion.text,
          command: criterion.command,
          level: criterion.level
        })
      end)
    end)
  end

  defp insert_dependencies(multi, tasks) do
    Enum.reduce(tasks, multi, &insert_task_dependencies/2)
  end

  defp insert_task_dependencies(task, multi) do
    task.dependencies
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {depends_on, index}, multi ->
      Multi.insert(multi, {:dependency, task.id, index}, fn changes ->
        Dependency.changeset(%Dependency{}, %{
          task_id: Map.fetch!(changes, {:task, task.id}).id,
          depends_on_id: Map.fetch!(changes, {:task, depends_on}).id
        })
      end)
    end)
  end

  defp written_tasks(changes, tasks) do
    tasks
    |> Enum.map(&Map.fetch!(changes, {:task, &1.id}))
    |> Enum.map(&Repo.preload(&1, [:areas, :criteria, :dependencies]))
  end
end
