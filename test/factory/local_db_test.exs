defmodule Factory.LocalDbTest do
  use ExUnit.Case, async: true

  alias Factory.LocalDb

  # Records every call and answers by program name, so no real server is touched.
  defp fake(answers) do
    me = self()

    fn program, args, _opts ->
      name = program |> Path.basename() |> Path.rootname()
      send(me, {:ran, name, args})
      Map.fetch!(answers, name)
    end
  end

  defp opts(answers, dir?), do: [cmd: fake(answers), dir?: fn _ -> dir? end, data: "D:/pg"]

  test "status is :up only when pg_isready exits 0" do
    assert LocalDb.status(opts(%{"pg_isready" => {"", 0}}, true)) == :up
    assert LocalDb.status(opts(%{"pg_isready" => {"", 2}}, true)) == :down
  end

  test "start does nothing when the server is already up" do
    assert {:ok, :already_up} = LocalDb.start(opts(%{"pg_isready" => {"", 0}}, true))
    refute_received {:ran, "pg_ctl", _}
  end

  test "start runs pg_ctl with wait and a log file inside the data directory" do
    o = opts(%{"pg_isready" => {"", 2}, "pg_ctl" => {"server started", 0}}, true)

    assert {:ok, :started} = LocalDb.start(o)
    assert_received {:ran, "pg_ctl", ["-D", "D:/pg", "-l", "D:/pg/server.log", "-w", "start"]}
  end

  test "start without a cluster points to init instead of calling pg_ctl" do
    o = opts(%{"pg_isready" => {"", 2}}, false)

    assert {:error, {:no_cluster, "D:/pg"}} = LocalDb.start(o)
    refute_received {:ran, "pg_ctl", _}
  end

  test "a failing pg_ctl is reported with its output" do
    o = opts(%{"pg_isready" => {"", 2}, "pg_ctl" => {"port in use", 1}}, true)
    assert {:error, {:start_failed, 1, "port in use"}} = LocalDb.start(o)
  end

  test "init creates the cluster only when the directory does not exist" do
    assert {:ok, :exists} = LocalDb.init(opts(%{}, true))
    refute_received {:ran, "initdb", _}

    assert {:ok, :created} = LocalDb.init(opts(%{"initdb" => {"", 0}}, false))

    assert_received {:ran, "initdb",
                     ["-D", "D:/pg", "-U", "postgres", "-A", "trust", "-E", "UTF8"]}
  end

  test "stop is idempotent" do
    assert {:ok, :already_down} = LocalDb.stop(opts(%{"pg_isready" => {"", 2}}, true))

    o = opts(%{"pg_isready" => {"", 0}, "pg_ctl" => {"", 0}}, true)
    assert {:ok, :stopped} = LocalDb.stop(o)
    assert_received {:ran, "pg_ctl", ["-D", "D:/pg", "-m", "fast", "-w", "stop"]}
  end

  test "a missing executable means the server is down, not a crash" do
    missing = fn _, _, _ -> raise ErlangError, original: :enoent end
    assert LocalDb.status(cmd: missing, dir?: fn _ -> true end, data: "D:/pg") == :down
  end
end
