defmodule Mix.Tasks.Factory.Plan do
  @shortdoc "Turns a request into dispatchable tasks (the only human step)"

  @moduledoc """
  Creates (or reuses) a project and calls `Factory.Planner.plan/3` to turn a natural-language
  request into a task graph.

      mix factory.plan "<request>" --project <name>

  This is the only human entry point.

  An existing project (same `name`) is reused as is, keeping its `path`. A new project is
  created next to this one, at `../<name>` relative to the current directory, and the
  directory is created if missing.

  After planning, every new task without pending dependencies becomes `ready`, and the task
  prints how many tasks were created and how many are dispatchable.

  Running against the real `claude` CLI consumes subscription quota. Tests use
  `Factory.Provider.Fake`.
  """

  use Mix.Task

  alias Factory.Planner
  alias Factory.Projects.Project
  alias Factory.Repo
  alias Factory.Tasks.Scheduler
  alias Factory.Tasks.Transition

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest} = OptionParser.parse!(args, strict: [project: :string])

    request = List.first(rest) || usage!()
    name = Keyword.get(opts, :project) || usage!()

    case plan(request, name) do
      {:ok, report} -> print(report)
      {:error, reason} -> Mix.raise("planning failed: #{inspect(reason)}")
    end
  end

  @spec usage!() :: no_return()
  defp usage!, do: Mix.raise("usage: mix factory.plan \"<request>\" --project <name>")

  @doc """
  Creates or reuses project `name` and plans `request`. Public so tests can call it without
  argument parsing.

  `opts` accepts `:path` (project root, only used when the project does not exist yet) and
  passes the rest (`:needle`, `:model`, `:max_turns`, `:root`) to `Factory.Planner.plan/3`.

  Returns `{:ok, %{project: project, tasks: task_count, ready: ready_count}}` or
  `{:error, reason}`; nothing is promoted when planning fails.
  """
  @spec plan(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(request, name, opts \\ []) do
    {path, planner_opts} = Keyword.pop(opts, :path)
    project = get_or_create_project(name, path)

    case Planner.plan(request, project, planner_opts) do
      {:ok, %{tasks: tasks}} ->
        ready = promote(tasks)
        {:ok, %{project: project, tasks: length(tasks), ready: ready}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_or_create_project(name, path) do
    case Repo.get_by(Project, name: name) do
      nil ->
        path = path || default_path(name)
        File.mkdir_p!(path)
        Repo.insert!(Project.changeset(%Project{}, %{"name" => name, "path" => path}))

      project ->
        project
    end
  end

  defp default_path(name), do: Path.expand(Path.join([File.cwd!(), "..", name]))

  # The planner returns tasks with `:areas`, `:criteria` and `:dependencies` preloaded, and
  # every dependency points inside the same batch (the planner rejects outside references
  # and cycles), so promotion only needs this batch.
  defp promote(tasks) do
    case Scheduler.promote(tasks) do
      {:ok, %{promote: promotable}} ->
        Enum.each(promotable, &Transition.apply(&1, :ready))
        length(promotable)

      {:error, _reason} ->
        0
    end
  end

  defp print(report) do
    Mix.shell().info(
      "project #{report.project.name}: #{report.tasks} task(s) created, " <>
        "#{report.ready} ready for dispatch"
    )
  end
end
