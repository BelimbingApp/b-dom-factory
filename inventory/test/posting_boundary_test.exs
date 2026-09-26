defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Base.ModuleRegistry.MixDiscovery
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.PostingAuthority

  # The BEAM cannot tell Inventory which module calls, so the boundary is held
  # over the compiled graph: only a declared posting authority may call a
  # production posting, and nothing outside Inventory may call a module
  # Inventory keeps internal (`@moduledoc false`).
  @production [
    :record_output,
    :record_transform,
    :record_production_consumption,
    :record_production_correction
  ]

  @tag :compiled_graph
  test "only a declared authority posts production, and Inventory's internals stay internal" do
    applications =
      File.cwd!()
      |> MixDiscovery.workspace_root!()
      |> MixDiscovery.discover_workspace!()
      |> Enum.map(&compiled!(&1.otp_app))

    authorities =
      for {app, env, modules} <- applications,
          Keyword.has_key?(env, :posting_authority),
          do: PostingAuthority.declared!(app, env, modules)

    beams =
      for {app, _env, modules} <- applications,
          app != :bilimbi_factory_inventory,
          module <- modules,
          do: beam!(app, module)

    assert violations(beams, authorities, internal()) == []
  end

  test "catches a production posting from an undeclared module and any internal reference" do
    [{poster, poster_beam}] =
      Code.compile_string("""
      defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest.Poster do
        def post(scope, request, authority),
          do: Bilimbi.Factory.Inventory.record_production_consumption(scope, 73, request, authority)
      end
      """)

    [{bypass, bypass_beam}] =
      Code.compile_string("""
      defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest.Bypass do
        def post(request), do: Bilimbi.Factory.Inventory.Ledger.post(73, :transform, request, [])
      end
      """)

    beams = [poster_beam, bypass_beam]

    assert violations(beams, [], internal()) == [poster, bypass]
    assert violations(beams, [poster, bypass], internal()) == [bypass]
  end

  # An application of the discovered graph, as its compiled resource lists it,
  # so a stale beam of a removed module is never read.
  defp compiled!(app) do
    app_file = Path.join(ebin(app), "#{app}.app")

    unless File.regular?(app_file) do
      flunk("#{app} is not compiled; compile the whole mounted graph before this test")
    end

    {:ok, [{:application, ^app, properties}]} = :file.consult(app_file)
    {app, Keyword.get(properties, :env, []), Keyword.fetch!(properties, :modules)}
  end

  defp beam!(app, module) do
    path = Path.join(ebin(app), "#{module}.beam")
    unless File.regular?(path), do: flunk("#{inspect(module)} of #{app} is not compiled")
    String.to_charlist(path)
  end

  defp ebin(app), do: Path.join([Mix.Project.build_path(), "lib", "#{app}", "ebin"])

  defp internal do
    Enum.filter(
      Application.spec(:bilimbi_factory_inventory, :modules),
      &match?({:docs_v1, _anno, _language, _format, :hidden, _meta, _docs}, Code.fetch_docs(&1))
    )
  end

  defp violations(beams, authorities, internal) do
    for beam <- beams,
        {:ok, {module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports]),
        {callee, function, _arity} <- imports,
        callee in internal or
          (callee == Inventory and function in @production and module not in authorities),
        uniq: true,
        do: module
  end
end
