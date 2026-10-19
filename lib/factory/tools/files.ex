defmodule Factory.Tools.Files do
  @moduledoc """
  The agent's file tools: `read`, `write`, `edit`, `list` and `search`.

  All of them are confined to the project directory through `Factory.Tools.Confinement`;
  none has another way to reach the file system.

  `edit` is an EXACT replacement: it refuses when the target appears zero times (the agent was
  looking at another version of the file) or more than once (it does not know which one will
  change).
  """

  alias Factory.Tools.Confinement

  @max_size 2_000_000

  @typedoc "Named error."
  @type error ::
          Confinement.reason()
          | :file_missing
          | :file_too_large
          | :target_missing
          | :target_ambiguous
          | :not_a_file

  @doc "Reads a project file."
  @spec read(Path.t(), Path.t()) :: {:ok, String.t()} | {:error, error()}
  def read(root, path) do
    with {:ok, absolute} <- Confinement.resolve(root, path),
         {:ok, %{size: size, type: :regular}} <- stat(absolute),
         :ok <- fits?(size) do
      read_file(absolute)
    else
      {:ok, %{type: _other}} -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes a project file, creating missing directories."
  @spec write(Path.t(), Path.t(), String.t()) :: {:ok, Path.t()} | {:error, error()}
  def write(root, path, content) do
    with {:ok, absolute} <- Confinement.resolve(root, path) do
      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, content)
      {:ok, absolute}
    end
  end

  @doc """
  Replaces ONE exact occurrence of `target` with `new`.

  Refuses with `:target_missing` when not found and `:target_ambiguous` when found more
  than once.
  """
  @spec edit(Path.t(), Path.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, error()}
  def edit(root, path, target, new) do
    with {:ok, absolute} <- Confinement.resolve(root, path),
         {:ok, content} <- read(root, path),
         {:ok, replaced} <- replace(content, target, new) do
      File.write!(absolute, replaced)
      {:ok, absolute}
    end
  end

  @doc "Lists the project files matching the pattern, in deterministic order."
  @spec list(Path.t(), String.t()) :: {:ok, [Path.t()]} | {:error, error()}
  def list(root, pattern \\ "**/*") do
    with {:ok, absolute} <- Confinement.resolve(root, ".") do
      files =
        absolute
        |> Path.join(pattern)
        |> String.replace("\\", "/")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&relative(absolute, &1))
        |> Enum.sort()

      {:ok, files}
    end
  end

  @doc """
  Searches for text in the project files. Returns `{path, line, text}`.

  The search is literal, not a regex, so a malformed pattern from the agent yields an empty
  result instead of an error.
  """
  @spec search(Path.t(), String.t(), keyword()) ::
          {:ok, [{Path.t(), pos_integer(), String.t()}]} | {:error, error()}
  def search(root, text, opts \\ []) do
    pattern = Keyword.get(opts, :pattern, "**/*")
    limit = Keyword.get(opts, :limit, 200)

    with {:ok, files} <- list(root, pattern) do
      matches =
        files
        |> Enum.flat_map(&find_in_file(root, &1, text))
        |> Enum.take(limit)

      {:ok, matches}
    end
  end

  defp find_in_file(root, path, text) do
    case read(root, path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> String.contains?(line, text) end)
        |> Enum.map(fn {line, number} -> {path, number, String.trim(line)} end)

      _ ->
        []
    end
  end

  defp replace(content, target, new) do
    case occurrences(content, target) do
      0 -> {:error, :target_missing}
      1 -> {:ok, String.replace(content, target, new)}
      _ -> {:error, :target_ambiguous}
    end
  end

  defp occurrences(content, target) do
    content |> String.split(target) |> length() |> Kernel.-(1)
  end

  # Any file-system error (POSIX reason) is reported as `:file_missing`.
  defp stat(absolute) do
    case File.stat(absolute) do
      {:ok, stat} -> {:ok, stat}
      {:error, _posix} -> {:error, :file_missing}
    end
  end

  defp read_file(absolute) do
    case File.read(absolute) do
      {:ok, content} -> {:ok, content}
      {:error, _posix} -> {:error, :file_missing}
    end
  end

  # Size cap: a 50 MB file read into an agent's context overflows the window at full cost.
  defp fits?(size) when size > @max_size, do: {:error, :file_too_large}
  defp fits?(_size), do: :ok

  defp relative(root, absolute) do
    absolute
    |> String.replace("\\", "/")
    |> String.replace_prefix(String.replace(root, "\\", "/") <> "/", "")
  end
end
