defmodule Mix.Tasks.Factory.Map do
  @shortdoc "Generates _management/MAP.md, the dense project index"

  @moduledoc """
  Generates the dense project index at `_management/MAP.md`.

      mix factory.map

  Deterministic and model-free: two runs over the same tree produce identical bytes, which
  the prompt-prefix cache depends on (see `Factory.Index.CodeMap`).
  """

  use Mix.Task

  alias Factory.Index.CodeMap

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [root: :string, dest: :string])

    {:ok, dest, bytes} = CodeMap.write(opts)
    source = source_size(Keyword.get(opts, :root, "."))

    Mix.shell().info("map written: #{dest} (#{bytes} bytes)")

    if source > 0 do
      Mix.shell().info(
        "source: #{source} bytes — the map is #{Float.round(bytes / source * 100, 1)}%"
      )
    end
  end

  defp source_size(root) do
    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reduce(0, fn file, total -> total + File.stat!(file).size end)
  end
end
