defmodule Mix.Tasks.Factory.Plan do
  @shortdoc "Turns a request into dispatchable tasks (the only human step)"

  @moduledoc """
  Creates (or reuses) a project and calls `Factory.Planner.plan/3` to turn a natural-language
  request into a task graph.

      mix factory.plan "<request>" --project <name>
      mix factory.plan "<request>" --project <name> --domain <domain>

  This is the only human entry point.

  An existing project (same `name`) is reused as is, keeping its `path`. A new project is
  created inside this repository, at `generated-projects/<name>` relative to the current
  directory (`default_path/2`); the directory is created if missing and initialised as its own
  git repository, so the work of each task is committed there. `generated-projects/` is
  git-ignored.

  ## `--domain`

  A new project is created with the requested `domain`, which `Factory.Tracks.for_domain/1`
  reads to choose the project's track. Without the option the domain stays `"software"`. An
  existing project never has its domain changed: if `--domain` differs from the stored one, the
  task refuses to plan
  (`{:error, {:domain_mismatch, stored, requested}}`).

  After planning, every new task without pending dependencies becomes `ready`, and the task
  prints how many tasks were created and how many are dispatchable.

  Running against the real `claude` CLI consumes subscription quota. Tests use
  `Factory.Provider.Fake`.
  """

  use Mix.Task

  require Logger

  alias Factory.Planner
  alias Factory.Projects.Project
  alias Factory.Repo
  alias Factory.Tasks.Scheduler
  alias Factory.Tasks.Transition
  alias Factory.Tools.Command

  @default_gitignore """
  .DS_Store
  Thumbs.db
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest} = OptionParser.parse!(args, strict: [project: :string, domain: :string])

    request = List.first(rest) || usage!()
    name = Keyword.get(opts, :project) || usage!()
    domain = Keyword.get(opts, :domain)

    case plan(request, name, domain: domain) do
      {:ok, report} -> print(report)
      {:error, reason} -> Mix.raise("planning failed: #{inspect(reason)}")
    end
  end

  @spec usage!() :: no_return()
  defp usage!, do: Mix.raise("usage: mix factory.plan \"<request>\" --project <name>")

  @doc """
  Creates or reuses project `name` and plans `request`. Public so tests can call it without
  argument parsing.

  `opts` accepts `:path` (project root) and `:domain`, both only used when the project does not
  exist yet, and passes the rest (`:needle`, `:model`, `:max_turns`, `:root`) to
  `Factory.Planner.plan/3`.

  Returns `{:ok, %{project: project, tasks: task_count, ready: ready_count}}`,
  `{:error, {:domain_mismatch, stored, requested}}` when `:domain` differs from the one of an
  existing project, or `{:error, reason}` from planning. Nothing is promoted when planning fails.
  """
  @spec plan(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(request, name, opts \\ []) do
    {path, opts} = Keyword.pop(opts, :path)
    {domain, planner_opts} = Keyword.pop(opts, :domain)

    with {:ok, project} <- get_or_create_project(name, path, domain),
         {:ok, %{tasks: tasks}} <- Planner.plan(request, project, planner_opts) do
      ready = promote(tasks)
      {:ok, %{project: project, tasks: length(tasks), ready: ready}}
    end
  end

  defp get_or_create_project(name, path, domain) do
    case Repo.get_by(Project, name: name) do
      nil ->
        path = path || default_path(name)
        File.mkdir_p!(path)
        init_repository(path, name)
        attrs = put_domain(%{"name" => name, "path" => path}, domain)
        {:ok, Repo.insert!(Project.changeset(%Project{}, attrs))}

      %Project{domain: stored} when domain != nil and domain != stored ->
        {:error, {:domain_mismatch, stored, domain}}

      project ->
        {:ok, project}
    end
  end

  defp put_domain(attrs, nil), do: attrs
  defp put_domain(attrs, domain), do: Map.put(attrs, "domain", domain)

  @doc """
  Where a NEW project is created when the caller gives no `:path`:
  `<base>/generated-projects/<name>`, with `base` defaulting to the current working directory.

  ## Examples

      iex> Mix.Tasks.Factory.Plan.default_path("shortener", "/factory")
      Path.expand("/factory/generated-projects/shortener")
  """
  @spec default_path(String.t(), Path.t()) :: Path.t()
  def default_path(name, base \\ File.cwd!()),
    do: Path.expand(Path.join([base, "generated-projects", name]))

  # Without its own repository, the commit made at the end of each task would land in this one.
  # A directory that already has `.git` is left alone.
  defp init_repository(path, name) do
    if File.dir?(Path.join(path, ".git")) do
      :ok
    else
      result =
        with {:ok, %{code: 0}} <- Command.run(path, "git", ["init"]),
             :ok <- File.write(Path.join(path, ".gitignore"), @default_gitignore),
             {:ok, %{code: 0}} <- Command.run(path, "git", ["add", "--", ".gitignore"]),
             {:ok, %{code: 0}} <-
               Command.run(path, "git", ["commit", "-m", "chore: project #{name} created"]) do
          :ok
        end

      if result != :ok do
        Logger.warning("could not initialise git in #{path}: #{inspect(result)}")
      end

      :ok
    end
  end

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
