defmodule Factory.Embedder.FakeTest do
  @moduledoc """
  Locks the two properties that make memory testable without a model: determinism and
  distinctness.
  """

  use ExUnit.Case, async: true

  alias Factory.Embedder
  alias Factory.Embedder.Fake

  describe "determinism" do
    test "the same text always yields the same vector" do
      assert Fake.vector("binary allowlist") == Fake.vector("binary allowlist")
    end

    test "batch and single calls agree" do
      {:ok, [batched]} = Fake.embed(["the database is the truth"])
      assert batched == Fake.vector("the database is the truth")
    end

    test "the same batch embedded twice gives exactly the same vectors" do
      texts = ["one", "two", "three"]

      {:ok, first} = Fake.embed(texts)
      {:ok, second} = Fake.embed(texts)

      assert first == second
    end
  end

  describe "distinctness" do
    test "different texts yield different vectors" do
      refute Fake.vector("a text") == Fake.vector("another text")
    end

    test "similar texts still yield different vectors" do
      refute Fake.vector("task done") == Fake.vector("tasks done")
    end

    test "a hundred distinct texts give a hundred distinct vectors" do
      texts = Enum.map(1..100, &"chunk number #{&1}")

      {:ok, vectors} = Fake.embed(texts)

      assert length(Enum.uniq(vectors)) == 100
    end

    test "positions vary within a vector" do
      # A constant vector would be deterministic and useless for ranking.
      vector = Fake.vector("anything")
      assert length(Enum.uniq(vector)) > 100
    end
  end

  describe "shape" do
    test "without configuration, dimensions returns the default 384" do
      assert Fake.dimensions() == 384
    end

    test "without configuration, every vector has exactly 384 positions" do
      {:ok, vectors} = Fake.embed(["a", "", String.duplicate("long ", 500)])

      assert length(vectors) == 3
      assert Enum.all?(vectors, &(length(&1) == 384))
    end

    test "every position is a float" do
      assert Enum.all?(Fake.vector("x"), &is_float/1)
    end

    test "the vector is normalized to norm 1" do
      vector = Fake.vector("a chunk of the project history")
      norm = :math.sqrt(Enum.reduce(vector, 0.0, fn v, s -> s + v * v end))

      assert_in_delta norm, 1.0, 1.0e-9
    end

    test "an empty text has a valid vector" do
      {:ok, [vector]} = Fake.embed([""])

      assert length(vector) == 384
      assert Enum.all?(vector, &is_float/1)
    end
  end

  describe "batch" do
    test "output order follows input order" do
      texts = ["first", "second", "third"]
      {:ok, vectors} = Fake.embed(texts)

      expected = Enum.map(texts, &Fake.vector/1)
      assert vectors == expected
    end

    test "an empty batch returns an empty list" do
      assert {:ok, []} = Fake.embed([])
    end

    test "a batch with a non-string returns a named error" do
      assert {:error, :text_not_a_string} = Fake.embed(["ok", 42])
    end

    test "a non-list argument returns a named error" do
      assert {:error, :expected_list} = Fake.embed("not a list")
    end
  end

  describe "the contract" do
    test "Fake implements the Factory.Embedder behaviour" do
      behaviours =
        Fake.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Factory.Embedder in behaviours
    end

    test "the behaviour declares batch embed/1 and dimensions/0" do
      callbacks = Factory.Embedder.behaviour_info(:callbacks)

      assert {:embed, 1} in callbacks
      assert {:dimensions, 0} in callbacks
    end

    test "the embedder configured for the suite is Fake" do
      assert Embedder.configured() == Fake
      assert Embedder.dimensions() == 384
    end
  end

  describe "no model and no network" do
    test "Fake's code loads no model and touches no network" do
      source = File.read!("lib/factory/embedder/fake.ex")

      for forbidden <- ~w[Bumblebee Nx EXLA Axon Req Finch HTTPoison System.get_env] do
        pattern = ~r/(?<![A-Za-z0-9_.])#{Regex.escape(forbidden)}(?![A-Za-z0-9_])/

        refute Regex.match?(pattern, source),
               "Embedder.Fake references #{forbidden}; the fake must not load a model " <>
                 "(the target profile is 8 GB of RAM)."
      end
    end
  end
end

defmodule Factory.Embedder.FakeConfigurableTest do
  @moduledoc """
  The configured dimension changes global application env, hence `async: false`.
  """

  use ExUnit.Case, async: false

  alias Factory.Embedder
  alias Factory.Embedder.Fake

  setup do
    on_exit(fn -> Application.delete_env(:factory, Fake) end)
  end

  test "with configured dimensions, dimensions/0 returns the configured value" do
    Application.put_env(:factory, Fake, dimensions: 768)

    assert Fake.dimensions() == 768
  end

  test "with configured dimensions, every vector from embed/1 has that many positions" do
    Application.put_env(:factory, Fake, dimensions: 768)

    {:ok, vectors} = Fake.embed(["a chunk", "another chunk"])

    assert Enum.all?(vectors, &(length(&1) == 768))
  end

  test "with configured dimensions, the vector stays deterministic" do
    Application.put_env(:factory, Fake, dimensions: 768)

    assert Fake.vector("binary allowlist") == Fake.vector("binary allowlist")
  end

  test "with configured dimensions, the vector stays normalized" do
    Application.put_env(:factory, Fake, dimensions: 768)

    vector = Fake.vector("any chunk")
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn v, s -> s + v * v end))

    assert_in_delta norm, 1.0, 1.0e-9
  end

  test "the Factory.Embedder.dimensions/0 facade follows the adapter's configuration" do
    Application.put_env(:factory, Fake, dimensions: 768)

    assert Embedder.dimensions() == 768
  end

  test "without configuration, the default 384 applies again" do
    Application.delete_env(:factory, Fake)

    assert Fake.dimensions() == 384
  end
end
