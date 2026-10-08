defmodule Factory.Index.CodeMap do
  @moduledoc """
  The dense project index: file tree, public symbols and the purpose of each one.

  Agents read it first and only open in full the files they are going to change, which keeps
  the context per dispatch small at zero model cost.

  Extraction uses the AST (`Code.string_to_quoted/2`), never regexes: a regex gets wrong `def`
  inside strings, guards, multi-line heads and `defdelegate`, and an index that lies about what
  exists is worse than none.

  The output has NO volatile header — no date, hash or counter. Two generations over the same
  tree produce identical bytes, so the map can sit in a cached prompt prefix.
  """

  @typedoc "A public symbol of a module."
  @type symbol :: %{
          name: atom(),
          arity: non_neg_integer(),
          type: :function | :macro,
          doc: String.t() | nil
        }

  @typedoc "A module found in the tree."
  @type module_entry :: %{
          name: String.t(),
          file: Path.t(),
          doc: String.t() | nil,
          symbols: [symbol()]
        }

  @doc """
  Walks the sources and returns the public modules, sorted by module name.

  `Path.wildcard/1` does not promise a stable order across machines, so the result is sorted.
  """
  @spec extract(keyword()) :: [module_entry()]
  def extract(opts \\ []) do
    root = root(opts)
    patterns = Keyword.get(opts, :patterns, ["lib/**/*.ex"])

    patterns
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.uniq()
    |> Enum.flat_map(&file_modules(&1, root))
    |> Enum.sort_by(& &1.name)
  end

  # On Windows `Path.wildcard/1` returns `[]` for a pattern containing `\`, even when the
  # files exist, which silently produced an empty map for absolute roots.
  defp root(opts) do
    opts
    |> Keyword.get(:root, ".")
    |> String.replace("\\", "/")
  end

  defp file_modules(path, root) do
    relative = path |> Path.relative_to(root) |> String.replace("\\", "/")

    case path |> File.read!() |> Code.string_to_quoted() do
      {:ok, ast} -> ast |> defmodules() |> Enum.map(&describe(&1, relative))
      {:error, _} -> []
    end
  end

  # Nested modules are included: they are as public as any other.
  defp defmodules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [alias_, [do: body]]} = node, acc ->
          {node, [{module_name(alias_), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp module_name({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &to_string/1)
  defp module_name(other), do: Macro.to_string(other)

  defp describe({name, body}, file) do
    %{
      name: name,
      file: file,
      doc: moduledoc(body),
      symbols: symbols(body)
    }
  end

  # `@moduledoc false` marks the module as internal, and it is left out of the map.
  defp moduledoc(body) do
    body
    |> attributes(:moduledoc)
    |> List.first()
    |> first_line()
  end

  @doc false
  def public?(%{doc: :private}), do: false
  def public?(_), do: true

  defp symbols(body) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {:@, _, [{:doc, _, [value]}]} = node, acc ->
          {node, [{:doc, value} | acc]}

        {definer, _, [head | _]} = node, acc when definer in [:def, :defmacro] ->
          {node, [{:symbol, definer, head} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
    |> Enum.reverse()
    |> build_symbols()
    |> Enum.uniq_by(&{&1.name, &1.arity})
    |> Enum.sort_by(&{to_string(&1.name), &1.arity})
  end

  # A function's `@doc` comes BEFORE it in the AST: keep the last `@doc` seen and spend it on
  # the next `def`. `@doc false` marks an internal function, which is dropped.
  defp build_symbols(nodes) do
    {symbols, _} =
      Enum.reduce(nodes, {[], nil}, fn
        {:doc, value}, {acc, _} ->
          {acc, value}

        {:symbol, definer, head}, {acc, doc} ->
          case signature(head) do
            nil -> {acc, nil}
            {name, arity} when doc == false -> {discard(acc, name, arity), nil}
            {name, arity} -> {[new_symbol(name, arity, definer, doc) | acc], nil}
          end
      end)

    Enum.reverse(symbols)
  end

  defp discard(acc, _name, _arity), do: acc

  defp new_symbol(name, arity, definer, doc) do
    %{
      name: name,
      arity: arity,
      type: if(definer == :defmacro, do: :macro, else: :function),
      doc: first_line(doc)
    }
  end

  # `when` wraps the head in its own tuple; without unwrapping, a guarded function would
  # always get arity 2.
  defp signature({:when, _, [head | _]}), do: signature(head)

  defp signature({name, _, args}) when is_atom(name) and is_list(args) do
    {name, length(args)}
  end

  defp signature({name, _, nil}) when is_atom(name), do: {name, 0}
  defp signature(_), do: nil

  defp attributes(body, key) do
    {_, values} =
      Macro.prewalk(body, [], fn
        {:@, _, [{^key, _, [value]}]} = node, acc -> {node, [value | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(values)
  end

  defp first_line(nil), do: nil
  defp first_line(false), do: :private

  defp first_line(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end

  defp first_line({:__block__, _, [text]}), do: first_line(text)
  defp first_line(_), do: nil

  @doc """
  Renders the map as markdown, with no date, hash or counter: if the tree did not change,
  the bytes do not change.
  """
  @spec render([module_entry()]) :: String.t()
  def render(modules) do
    public = Enum.reject(modules, &(&1.doc == :private))

    [
      "# MAP — dense project index\n",
      "\nGENERATED by `mix factory.map`. Do not edit by hand.\n",
      "\nWhat EXISTS and where. The `GUIDE.md` next to it says HOW IT IS DONE.\n",
      "\n## Tree\n\n",
      tree(public),
      "\n## Modules\n",
      Enum.map(public, &render_module/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp tree(modules) do
    modules
    |> Enum.map(& &1.file)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join("", &"- `#{&1}`\n")
  end

  defp render_module(module) do
    purpose = if module.doc, do: " — #{module.doc}", else: ""

    head = "\n### `#{module.name}`#{purpose}\n\n`#{module.file}`\n"

    body =
      case module.symbols do
        [] -> "\n_no public symbols._\n"
        symbols -> "\n" <> Enum.map_join(symbols, "", &render_symbol/1)
      end

    head <> body
  end

  defp render_symbol(symbol) do
    mark = if symbol.type == :macro, do: " (macro)", else: ""
    purpose = if symbol.doc, do: " — #{symbol.doc}", else: ""

    "- `#{symbol.name}/#{symbol.arity}`#{mark}#{purpose}\n"
  end

  @doc "Generates the map and writes it to `_management/MAP.md`. Returns the path and size."
  @spec write(keyword()) :: {:ok, Path.t(), non_neg_integer()}
  def write(opts \\ []) do
    dest = Keyword.get(opts, :dest, Path.join(root(opts), "_management/MAP.md"))

    content = opts |> extract() |> render()

    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, content)

    {:ok, dest, byte_size(content)}
  end
end
