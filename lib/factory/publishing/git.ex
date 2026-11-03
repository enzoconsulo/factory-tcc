defmodule Factory.Publishing.Git do
  @moduledoc """
  Commits a task's `areas` PLUS its markdown file — never the whole tree.

  Before adding anything it asks git what changed in the whole tree and REFUSES when anything
  lies outside the declared paths, returning the list so the caller can decide (add it to
  `areas`, discard, investigate). Nothing is committed silently; there is no `git add -A`.

  Runs git through `Factory.Tools.Command`, which confines the working directory, kills the
  process tree if git hangs, and measures duration.
  """

  alias Factory.Tools.Command

  @type path :: String.t()

  @doc "The canonical commit message of a task: `T-NNN: title`."
  @spec message(String.t(), String.t()) :: String.t()
  def message(code, title), do: "#{code}: #{title}"

  @doc """
  The changed paths in the tree at `root` that are NOT in `paths`.

  Reads `git status --porcelain`: modified, added, removed and untracked files.
  """
  @spec changes_outside(Path.t(), [path()]) :: {:ok, [path()]} | {:error, term()}
  def changes_outside(root, paths) do
    # `--untracked-files=all`: otherwise a brand-new directory collapses to "?? lib/", which
    # never matches a declared area.
    case Command.run(root, "git", ["status", "--porcelain", "--untracked-files=all"]) do
      {:ok, %{code: 0, stdout: output}} ->
        allowed = MapSet.new(paths, &normalize/1)

        outside =
          output
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.flat_map(&line_paths/1)
          |> Enum.map(&normalize/1)
          |> Enum.reject(&MapSet.member?(allowed, &1))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, outside}

      {:ok, result} ->
        {:error, {:git_failed, result}}

      error ->
        error
    end
  end

  @doc """
  Commits `paths` (the task's `areas` + its markdown) in `root` with `message`.

  **Refuses** when anything changed outside `paths`, returning
  `{:error, {:changes_outside_areas, list}}` without adding or committing anything.
  """
  @spec commit(Path.t(), [path()], String.t()) ::
          {:ok, %{output: String.t()}}
          | {:error, {:changes_outside_areas, [path()]}}
          | {:error, term()}
  def commit(root, paths, message) do
    with {:ok, outside} <- changes_outside(root, paths) do
      if outside == [] do
        add_and_commit(root, paths, message)
      else
        {:error, {:changes_outside_areas, outside}}
      end
    end
  end

  @doc "The short hash of the latest commit in `root`."
  @spec hash(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def hash(root) do
    case Command.run(root, "git", ["rev-parse", "--short", "HEAD"]) do
      {:ok, %{code: 0, stdout: output}} -> {:ok, String.trim(output)}
      {:ok, result} -> {:error, {:git_failed, result}}
      error -> error
    end
  end

  defp add_and_commit(root, paths, message) do
    with {:ok, %{code: 0}} <- Command.run(root, "git", ["add", "--"] ++ paths),
         {:ok, %{code: 0, stdout: output}} <-
           Command.run(root, "git", ["commit", "-m", message]) do
      {:ok, %{output: output}}
    else
      {:ok, result} -> {:error, {:git_failed, result}}
      error -> error
    end
  end

  # "XY path" or "XY source -> target" (rename/copy). Both sides of a rename count as changed.
  defp line_paths(line) do
    content = String.slice(line, 3..-1//1)

    case String.split(content, " -> ") do
      [source, target] -> [unquote_path(source), unquote_path(target)]
      [single] -> [unquote_path(single)]
    end
  end

  defp unquote_path(path), do: path |> String.trim() |> String.trim("\"")

  defp normalize(path), do: path |> String.trim() |> String.replace("\\", "/")
end
