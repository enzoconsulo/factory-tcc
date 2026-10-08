defmodule Factory.Criteria.Suite do
  @moduledoc """
  The project's test suite runs on EVERY verification, without being written in any task.

  Writing "the suite still passes" as a criterion only creates a second chance to get the
  command wrong — and a wrong criterion command is the one thing the builder cannot fix, since
  it may not change criteria.

  The command is resolved in this order (declaration beats guessing):

  1. `_management/ci.json`, stage `tests` — a declaration by someone who knows the project;
  2. marker-file detection (`Factory.Ecosystems`) — a guess, useful when nothing is declared;
  3. nothing — the project runs without an implicit criterion, which is not an error.

  The criterion is appended with `implicit: true` so reports distinguish "the factory ran this"
  from "someone asked for this". If the task already declares the same command, the command key
  in `Factory.Criteria` turns the second into a mirror, so it never costs an extra run.
  """

  alias Factory.Ecosystems

  @typedoc "Where the suite command came from."
  @type origin :: :declared | {:detected, atom()}

  @ci_file "_management/ci.json"
  @tests_stage "tests"

  @doc """
  This project's suite command and where it came from.

  ## Examples

      iex> Factory.Criteria.Suite.command("path/that/does/not/exist")
      {:error, :no_ecosystem}
  """
  @spec command(Path.t()) :: {:ok, String.t(), origin()} | {:error, :no_ecosystem}
  def command(root) do
    case declared(root) do
      nil -> detected(root)
      command -> {:ok, command, :declared}
    end
  end

  defp detected(root) do
    case Ecosystems.detect(root) do
      nil -> {:error, :no_ecosystem}
      ecosystem -> {:ok, ecosystem.test_command, {:detected, ecosystem.id}}
    end
  end

  # Tolerant end to end: a missing file, broken JSON or a stage without a command returns `nil`
  # and falls back to detection. A malformed ci.json must not stop the suite from running.
  defp declared(root) do
    with {:ok, text} <- File.read(Path.join(root, @ci_file)),
         {:ok, %{"stages" => stages}} when is_list(stages) <- Jason.decode(text),
         %{"command" => command} when is_binary(command) <- tests_stage(stages) do
      empty_to_nil(String.trim(command))
    else
      _not_declared -> nil
    end
  end

  defp tests_stage(stages) do
    Enum.find(stages, fn
      %{"name" => name} -> name == @tests_stage
      _other -> false
    end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(command), do: command

  @doc """
  The implicit suite criterion, or `nil` when the project has no recognised ecosystem. Its text
  says where the command came from (declared file or guess).
  """
  @spec criterion(Path.t()) :: map() | nil
  def criterion(root) do
    case command(root) do
      {:error, :no_ecosystem} ->
        nil

      {:ok, command, origin} ->
        %{
          text: "The project suite passes (#{explain_origin(origin)}).",
          command: command,
          checked: false,
          implicit: true
        }
    end
  end

  defp explain_origin(:declared), do: "declared in #{@ci_file}"

  defp explain_origin({:detected, id}) do
    label = Ecosystems.by_id(id).label
    "detected: #{label}"
  end

  @doc """
  Appends the implicit criterion to the end of the task's criteria, so the written criteria
  come first in the report. Without a recognised ecosystem the list is returned unchanged.
  """
  @spec append([map()], Path.t()) :: [map()]
  def append(criteria, root) do
    case criterion(root) do
      nil -> criteria
      implicit -> criteria ++ [implicit]
    end
  end
end
