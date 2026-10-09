defmodule Factory.Source do
  @moduledoc """
  Reads a source file keeping only the code, without docstrings or comments.

  Several tests assert "exactly one module does X" (reads credentials, writes `attempts`,
  speaks HTTP) by scanning the source for a pattern. Documentation that states the rule
  contains the same words as code that breaks it, so these scans must ignore prose. This is
  the single place that strips it.

  Docstrings (`@doc`, `@moduledoc`, `@typedoc`) and comments are removed; everything else,
  including `@type` and `@spec`, stays.
  """

  @docstring ~r/@(module|type)?doc\s+(""".*?"""|"[^"]*")/s
  @comment ~r/^\s*#.*$/m

  @doc """
  Removes docstrings and comments from a piece of code.

  ## Examples

      iex> Factory.Source.strip(~s|@moduledoc "uses API_KEY"\\nx = 1|)
      "\\nx = 1"

      iex> Factory.Source.strip("# API_KEY here\\nx = 1")
      "\\nx = 1"
  """
  @spec strip(String.t()) :: String.t()
  def strip(text) do
    text
    |> String.replace(@docstring, "")
    |> String.replace(@comment, "")
  end

  @doc "Reads the file and returns only its code."
  @spec code_only(Path.t()) :: String.t()
  def code_only(file), do: file |> File.read!() |> strip()

  @doc """
  The production source files whose CODE matches the pattern; the canonical form of the
  "exactly one module does X" assertions.
  """
  @spec matching_production_files(Regex.t(), String.t()) :: [String.t()]
  def matching_production_files(pattern, glob \\ "lib/**/*.ex") do
    glob
    |> Path.wildcard()
    |> Enum.filter(&(code_only(&1) =~ pattern))
  end
end
