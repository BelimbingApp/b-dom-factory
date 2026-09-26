defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.PostingAuthority

  # The BEAM cannot tell Inventory which module calls, so the boundary is held
  # over the compiled workspace: only a declared posting authority may call a
  # function that always posts production.
  @production [:record_output, :record_transform]

  test "only a declared posting authority calls a production posting function" do
    lib = Path.join(Mix.Project.build_path(), "lib")

    authorities =
      lib
      |> Path.join("*/ebin/*.app")
      |> Path.wildcard()
      |> Enum.flat_map(&declared/1)

    beams =
      lib |> Path.join("*/ebin/*.beam") |> Path.wildcard() |> Enum.map(&String.to_charlist/1)

    assert violations(beams, authorities) == []
  end

  test "catches a module that calls one without being declared" do
    [{intruder, beam}] =
      Code.compile_string("""
      defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest.Intruder do
        def post(scope, request), do: Bilimbi.Factory.Inventory.record_transform(scope, 73, request)
      end
      """)

    assert violations([beam], []) == [intruder]
    assert violations([beam], [intruder]) == []
  end

  defp declared(app_file) do
    {:ok, [{:application, app, properties}]} = :file.consult(app_file)
    env = Keyword.get(properties, :env, [])

    if Keyword.has_key?(env, :posting_authority),
      do: [PostingAuthority.declared!(app, env, Keyword.get(properties, :modules, []))],
      else: []
  end

  defp violations(beams, authorities) do
    for beam <- beams,
        {:ok, {module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports]),
        module not in authorities,
        Enum.any?(imports, fn {callee, function, _arity} ->
          callee == Inventory and function in @production
        end),
        do: module
  end
end
