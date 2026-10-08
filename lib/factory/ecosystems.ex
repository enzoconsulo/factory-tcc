defmodule Factory.Ecosystems do
  @moduledoc """
  Detects a project's language and the command that runs its test suite.

  Detection by marker file is a heuristic: a repository may contain several markers (an
  Elixir project with npm assets, a Python API with a Node frontend). The first catalog entry
  that matches wins, and an explicit declaration in `_management/ci.json` always beats the
  guess (see `Factory.Criteria.Suite`). Elixir comes first because this very system is an
  Elixir project with a Phoenix `package.json`.

  Not recognizing a project is not an error: `detect/1` returns `nil` and the mechanical pass
  runs without an implicit criterion.
  """

  @typedoc """
  A recognized ecosystem. `markers` starting with a dot are extensions (`.csproj` matches
  `Api.csproj`); the others are exact file names at the root.
  """
  @type t :: %{
          id: atom(),
          label: String.t(),
          markers: [String.t()],
          test_command: String.t()
        }

  @catalog [
    %{id: :elixir, label: "Elixir / Mix", markers: ["mix.exs"], test_command: "mix test"},
    %{id: :node, label: "Node.js / npm", markers: ["package.json"], test_command: "npm test"},
    %{
      id: :python,
      label: "Python",
      markers: ["pyproject.toml", "requirements.txt", "setup.py"],
      test_command: "pytest"
    },
    %{id: :rust, label: "Rust / Cargo", markers: ["Cargo.toml"], test_command: "cargo test"},
    %{id: :go, label: "Go", markers: ["go.mod"], test_command: "go test ./..."},
    %{
      id: :dotnet,
      label: ".NET",
      markers: [".csproj", ".fsproj", ".vbproj", ".sln"],
      test_command: "dotnet test"
    }
  ]

  @doc "The whole catalog, in detection priority order."
  @spec catalog() :: [t()]
  def catalog, do: @catalog

  @doc "The ecosystem with this id, or `nil`."
  @spec by_id(atom()) :: t() | nil
  def by_id(id), do: Enum.find(@catalog, &(&1.id == id))

  @doc """
  Detects the ecosystem from the files at the root. Returns `nil` when nothing is recognized
  or the directory cannot be listed.
  """
  @spec detect(Path.t()) :: t() | nil
  def detect(root) do
    case File.ls(root) do
      {:ok, files} -> Enum.find(@catalog, &has_marker?(&1, files))
      {:error, _reason} -> nil
    end
  end

  defp has_marker?(ecosystem, files) do
    Enum.any?(ecosystem.markers, fn marker ->
      if String.starts_with?(marker, ".") do
        Enum.any?(files, &String.ends_with?(&1, marker))
      else
        marker in files
      end
    end)
  end
end
