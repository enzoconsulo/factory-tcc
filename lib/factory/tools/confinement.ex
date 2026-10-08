defmodule Factory.Tools.Confinement do
  @moduledoc """
  Confinement as a property of the code, not a sentence in the prompt.

  Every file tool goes through `resolve/2` before touching the disk, and it refuses:

  | form | why it escapes a naive check |
  |---|---|
  | absolute (`C:/Windows/...`) | the obvious one |
  | traversal (`../../..`) | only visible after normalizing |
  | symbolic link | the path is inside, the target is not; the real path must be resolved |
  | UNC (`\\\\server\\share`) | has no local root to compare against |
  | device (`CON`, `NUL`, `COM1`) | not a file: writing to it talks to hardware |

  A backslash is a separator on every platform: it is an input contract for the agent, so
  `lib\\foo.ex` means `lib/foo.ex` everywhere. Comparison is case-insensitive on Windows
  (where the file system is) and case-sensitive elsewhere (where `/x/PROJECT` and `/x/project`
  are different directories).

  Known limitation: Windows 8.3 short names (`C:\\Users\\ABCDEF~1`) are treated as different
  from their long form, so a legitimate link into a root given in short form is refused. The
  failure is on the safe side: it denies legitimate access, never grants improper access.
  """

  # DOS reserved names: opening one talks to a device, not a file.
  @devices ~w[con prn aux nul com1 com2 com3 com4 com5 com6 com7 com8 com9
              lpt1 lpt2 lpt3 lpt4 lpt5 lpt6 lpt7 lpt8 lpt9]

  @typedoc "Why a path was refused."
  @type reason :: :outside_confinement | :device | :unc_path | :invalid_path

  @doc """
  Resolves a path relative to the root, or refuses saying why.

  Always returns an ABSOLUTE, normalized path, so callers never normalize again.
  """
  @spec resolve(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, reason()}
  def resolve(root, path) when is_binary(root) and is_binary(path) do
    with :ok <- refuse_unc(path),
         :ok <- refuse_device(path),
         {:ok, absolute} <- join(root, path),
         :ok <- inside?(root, absolute) do
      {:ok, absolute}
    end
  end

  def resolve(_root, _path), do: {:error, :invalid_path}

  @doc """
  Tells whether an already resolved path is under the root, following links.

  A link cycle (`a -> b -> a`) has no real path and is refused as outside the confinement.
  """
  @spec inside?(Path.t(), Path.t()) :: :ok | {:error, reason()}
  def inside?(root, absolute) do
    real_root = real(normalize(Path.expand(root)))
    real_target = real(absolute)

    if under?(real_root, real_target) do
      :ok
    else
      {:error, :outside_confinement}
    end
  catch
    :link_cycle -> {:error, :outside_confinement}
  end

  @doc """
  Normalizes for comparison: forward slashes, no trailing slash, lowercase on Windows.

  The Unix root is the exception to "no trailing slash": `/` stays `/`, otherwise it would
  become `""` and every path joined to it would turn relative.
  """
  @spec normalize(Path.t()) :: String.t()
  def normalize(path) do
    normalized =
      path
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")
      |> keep_root(path)

    if windows?(), do: String.downcase(normalized), else: normalized
  end

  # Non-empty text that becomes empty after trimming slashes was only slashes: the root.
  defp keep_root("", original) when original != "", do: "/"
  defp keep_root(normalized, _original), do: normalized

  @doc "The reserved Windows device names."
  @spec devices() :: [String.t()]
  def devices, do: @devices

  # Backslash becomes slash BEFORE expanding, on every platform, so the path that is judged
  # is the same path that is returned.
  defp join(root, path) do
    path = String.replace(path, "\\", "/")

    absolute =
      if absolute?(path) do
        Path.expand(path)
      else
        root |> Path.expand() |> Path.join(path) |> Path.expand()
      end

    {:ok, absolute}
  end

  # `Path.type/1` does not recognize `C:/x` as absolute on every platform; this covers the
  # Unix root, drive letters and UNC.
  defp absolute?(path) do
    Path.type(path) != :relative or
      String.match?(path, ~r{^[a-zA-Z]:[\\/]}) or
      String.starts_with?(path, ["/", "\\"])
  end

  # Refused before ANY disk access: on Windows, resolving links would contact the server
  # (SMB, offering NTLM credentials). Mixed forms (`\/server`, `/\server`) are the same `//`.
  defp refuse_unc(path) do
    if path |> String.replace("\\", "/") |> String.starts_with?("//") do
      {:error, :unc_path}
    else
      :ok
    end
  end

  # A device name is reserved in any directory and with any extension (`dir/nul.txt`).
  defp refuse_device(path) do
    reserved? =
      path
      |> String.replace("\\", "/")
      |> String.split("/")
      |> Enum.any?(fn segment ->
        segment
        |> String.split(".")
        |> List.first()
        |> Kernel.||("")
        |> String.downcase()
        |> Kernel.in(@devices)
      end)

    if reserved?, do: {:error, :device}, else: :ok
  end

  # The REAL path, following symbolic links, walked component by component from the file
  # system root like the kernel does; `prefix` is always real. Rules:
  #
  # - A relative link target starts from the directory where the link really is (the real
  #   prefix), not from the textual dirname.
  # - `..` is resolved only AFTER the links before it: the parent of a link is the parent of
  #   its target.
  # - A missing component is not a link and is just appended; the walk does not stop there,
  #   because `write` creates files and directories through it.
  #
  # `hops` counts links followed across the WHOLE resolution, like the kernel. The cap is
  # Linux's `MAXSYMLINKS`; exceeding it is a `:link_cycle`.
  @max_hops 40

  defp real(path) do
    [fs_root | components] = Path.split(path)
    fs_root |> walk(components, 0) |> normalize()
  end

  defp walk(prefix, [], _hops), do: prefix
  defp walk(prefix, ["." | rest], hops), do: walk(prefix, rest, hops)
  defp walk(prefix, [".." | rest], hops), do: walk(Path.dirname(prefix), rest, hops)

  defp walk(prefix, [component | rest], hops) do
    candidate = Path.join(prefix, component)

    case :file.read_link_all(String.to_charlist(candidate)) do
      {:ok, _target} when hops >= @max_hops ->
        throw(:link_cycle)

      {:ok, target} ->
        {start, target_components} = split_target(prefix, List.to_string(target))
        walk(start, target_components ++ rest, hops + 1)

      {:error, :emlink} ->
        # Windows resolves a junction cycle itself and returns EMLINK directly, never an
        # `{:ok, _}` the hop counter could catch. Treating it as "not a link" would walk over
        # the cycle as a literal directory.
        throw(:link_cycle)

      {:error, _} ->
        walk(candidate, rest, hops)
    end
  end

  # Relative: continue from the real prefix with the raw target components (`..` included).
  # Absolute: restart from its root. `Path.absname/2` (not `expand`) keeps `..` and lets a
  # volume-relative Windows target (`\x`) inherit the prefix's drive.
  defp split_target(prefix, target) do
    if Path.type(target) == :relative do
      {prefix, Path.split(target)}
    else
      [fs_root | components] = target |> Path.absname(prefix) |> Path.split()
      {fs_root, components}
    end
  end

  # The prefix always includes the slash, otherwise `/project-other` would be under `/project`.
  defp under?(root, target), do: target == root or String.starts_with?(target, with_slash(root))

  defp with_slash(root), do: if(String.ends_with?(root, "/"), do: root, else: root <> "/")

  defp windows?, do: match?({:win32, _}, :os.type())
end
