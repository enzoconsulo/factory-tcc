defmodule Factory.Index.CodeMapTest do
  @moduledoc """
  Locks the dense index, above all the property the factory's cost depends on: two
  generations over the same tree produce identical bytes, so the prompt prefix stays cached.
  """

  use ExUnit.Case, async: true

  alias Factory.Index.CodeMap

  setup do
    root = Path.join(System.tmp_dir!(), "code-map-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp source(root, name, content) do
    path = Path.join([root, "lib", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  describe "determinism — the property the cache relies on" do
    test "two consecutive generations produce IDENTICAL bytes", %{root: root} do
      source(root, "example.ex", """
      defmodule Example do
        @moduledoc "An example."
        @doc "Adds two numbers."
        def add(a, b), do: a + b
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      first = File.read!(dest)

      {:ok, ^dest, _} = CodeMap.write(root: root)
      second = File.read!(dest)

      assert first == second
    end

    test "the map contains no date, hash or counter", %{root: root} do
      source(root, "example.ex", "defmodule Example do\n  @moduledoc \"x\"\nend\n")

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      today = Date.utc_today() |> Date.to_iso8601()

      refute content =~ today, "a date in the map invalidates the cache of every next dispatch"
      refute content =~ ~r/\b[0-9a-f]{7,40}\b/, "a commit hash has the same effect"
      refute content =~ "generated at"
    end

    test "the order does NOT depend on the file system order", %{root: root} do
      source(root, "zeta.ex", "defmodule Zeta do\n  @moduledoc \"z\"\nend\n")
      source(root, "alpha.ex", "defmodule Alpha do\n  @moduledoc \"a\"\nend\n")

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      assert :binary.match(content, "`Alpha`") < :binary.match(content, "`Zeta`")
    end

    test "a module's symbols come out in a stable order", %{root: root} do
      source(root, "order.ex", """
      defmodule Order do
        @moduledoc "o"
        def zebra, do: :ok
        def apple, do: :ok
        def middle(a), do: a
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      assert :binary.match(content, "apple/0") < :binary.match(content, "middle/1")
      assert :binary.match(content, "middle/1") < :binary.match(content, "zebra/0")
    end
  end

  describe "what goes in and what stays out" do
    test "a module with @moduledoc false does NOT appear", %{root: root} do
      source(root, "internal.ex", """
      defmodule Internal do
        @moduledoc false
        def hidden, do: :ok
      end
      """)

      source(root, "public.ex", """
      defmodule Public do
        @moduledoc "This one appears."
        def visible, do: :ok
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      refute content =~ "Internal"
      refute content =~ "hidden"
      assert content =~ "`Public`"
      assert content =~ "visible/0"
    end

    test "a private function does not appear", %{root: root} do
      source(root, "mix.ex", """
      defmodule Mixed do
        @moduledoc "m"
        def exposed, do: secret()
        defp secret, do: :ok
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      assert content =~ "exposed/0"
      refute content =~ "secret"
    end

    test "@doc false hides the function even though it is a def", %{root: root} do
      source(root, "docfalse.ex", """
      defmodule WithDocFalse do
        @moduledoc "d"
        @doc false
        def inner, do: :ok
        @doc "This one appears."
        def outer, do: :ok
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      refute content =~ "inner/0"
      assert content =~ "outer/0"
    end
  end

  describe "arity — where a regex would get it wrong" do
    test "arity is correct for several forms", %{root: root} do
      source(root, "arities.ex", """
      defmodule Arities do
        @moduledoc "a"
        def zero, do: :ok
        def one(a), do: a
        def three(a, b, c), do: {a, b, c}
      end
      """)

      module = CodeMap.extract(root: root) |> hd()
      signatures = Enum.map(module.symbols, &"#{&1.name}/#{&1.arity}")

      assert "zero/0" in signatures
      assert "one/1" in signatures
      assert "three/3" in signatures
    end

    test "a function WITH A GUARD does not become arity 2", %{root: root} do
      source(root, "guard.ex", """
      defmodule WithGuard do
        @moduledoc "g"
        def valid(number) when is_integer(number) and number > 0, do: :ok
        def pair(a, b) when is_atom(a), do: {a, b}
      end
      """)

      module = CodeMap.extract(root: root) |> hd()
      signatures = Enum.map(module.symbols, &"#{&1.name}/#{&1.arity}")

      assert "valid/1" in signatures
      assert "pair/2" in signatures
    end

    test "a def inside a string does not become a symbol", %{root: root} do
      source(root, "string.ex", """
      defmodule WithString do
        @moduledoc "s"
        def real, do: "def ghost(x), do: x"
      end
      """)

      module = CodeMap.extract(root: root) |> hd()
      signatures = Enum.map(module.symbols, &to_string(&1.name))

      assert "real" in signatures
      refute "ghost" in signatures
    end

    test "multiple clauses count as ONE symbol", %{root: root} do
      source(root, "clauses.ex", """
      defmodule Clauses do
        @moduledoc "c"
        def handle(:a), do: 1
        def handle(:b), do: 2
        def handle(_), do: 0
      end
      """)

      module = CodeMap.extract(root: root) |> hd()
      assert Enum.count(module.symbols, &(&1.name == :handle)) == 1
    end

    test "defmacro is marked as a macro", %{root: root} do
      source(root, "macro.ex", """
      defmodule WithMacro do
        @moduledoc "m"
        defmacro make(x), do: x
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      assert File.read!(dest) =~ "make/1` (macro)"
    end
  end

  describe "purpose" do
    test "only the FIRST line of @moduledoc and @doc goes in", %{root: root} do
      source(root, "doc.ex", """
      defmodule WithDoc do
        @moduledoc \"\"\"
        The first line of the module.

        This second line must not go into the map.
        \"\"\"
        @doc \"\"\"
        Adds two numbers.

        And neither does this paragraph.
        \"\"\"
        def add(a, b), do: a + b
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      assert content =~ "The first line of the module."
      assert content =~ "Adds two numbers."
      refute content =~ "must not go into"
      refute content =~ "neither does this paragraph"
    end

    test "a module without public symbols says so instead of being empty", %{root: root} do
      source(root, "empty.ex", "defmodule Empty do\n  @moduledoc \"v\"\nend\n")

      {:ok, dest, _} = CodeMap.write(root: root)
      assert File.read!(dest) =~ "no public symbols"
    end
  end

  describe "robustness" do
    test "a file that does not parse is skipped without breaking generation", %{root: root} do
      source(root, "broken.ex", "defmodule Broken do\n  def no_end(")
      source(root, "good.ex", "defmodule Good do\n  @moduledoc \"b\"\n  def ok, do: :ok\nend\n")

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      assert content =~ "`Good`"
      refute content =~ "Broken"
    end

    test "a tree with no source produces a valid map, not an error", %{root: root} do
      {:ok, dest, bytes} = CodeMap.write(root: root)

      assert bytes > 0
      assert File.read!(dest) =~ "# MAP"
    end

    test "nested modules appear", %{root: root} do
      source(root, "nested.ex", """
      defmodule Outer do
        @moduledoc "f"
        defmodule Inner do
          @moduledoc "d"
          def util, do: :ok
        end
      end
      """)

      {:ok, dest, _} = CodeMap.write(root: root)
      content = File.read!(dest)

      assert content =~ "`Outer`"
      assert content =~ "`Inner`"
    end
  end

  describe "size" do
    test "the map is a small fraction of the source", %{root: root} do
      # Proves the order of magnitude: a map close to the source size is a copy, not an index.
      body =
        Enum.map_join(1..40, "\n", fn n ->
          "  def function_#{n}(a, b) do\n    result = a + b\n    result * #{n}\n  end"
        end)

      source(root, "big.ex", "defmodule Big do\n  @moduledoc \"g\"\n#{body}\nend\n")

      source_size = File.stat!(Path.join([root, "lib", "big.ex"])).size
      {:ok, _, bytes} = CodeMap.write(root: root)

      assert bytes < source_size / 2,
             "a map of #{bytes} bytes for a source of #{source_size} is not a dense index"
    end
  end
end
