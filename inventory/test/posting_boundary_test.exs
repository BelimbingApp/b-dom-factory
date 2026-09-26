defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Base.ModuleRegistry.MixDiscovery
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.PostingAuthority

  # The BEAM cannot tell Inventory which module calls, so the boundary is held
  # over the compiled graph: only a declared posting authority may call a
  # production posting, and nothing outside Inventory may call a module
  # Inventory keeps internal (`@moduledoc false`), by call or capture.
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
    {poster, poster_beam} =
      compile!("""
      defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest.Poster do
        def post(scope, request, authority),
          do: Bilimbi.Factory.Inventory.record_production_consumption(scope, 73, request, authority)
      end
      """)

    {bypass, bypass_beam} =
      compile!("""
      defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest.Bypass do
        def post(request), do: Bilimbi.Factory.Inventory.Ledger.post(73, :transform, request, [])
      end
      """)

    {captor, captor_beam} =
      compile!("""
      defmodule Bilimbi.Factory.Inventory.PostingBoundaryTest.Captor do
        def output, do: &Bilimbi.Factory.Inventory.record_output/4
        def ledger, do: &Bilimbi.Factory.Inventory.Ledger.post/4
      end
      """)

    beams = [poster_beam, bypass_beam, captor_beam]

    assert violations(beams, [], internal()) == [poster, bypass, captor]
    assert violations(beams, [poster, bypass, captor], internal()) == [bypass, captor]
  end

  # `mix test` compiles without debug info, which a graph module carries.
  defp compile!(source) do
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      [compiled] = Code.compile_string(source)
      compiled
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end
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
        {module, references} = references!(beam),
        {callee, function} <- references,
        callee in internal or
          (callee == Inventory and function in @production and module not in authorities),
        uniq: true,
        do: module
  end

  # Every remote call and remote capture in a module's abstract code; the
  # imports chunk lists calls but not captures such as `&Inventory.record_output/4`.
  defp references!(beam) do
    case :beam_lib.chunks(beam, [:abstract_code]) do
      {:ok, {module, [abstract_code: {:raw_abstract_v1, forms}]}} -> {module, remote(forms, [])}
      _no_debug_info -> flunk("a compiled module carries no debug info to check")
    end
  end

  defp remote({:remote, _anno, {:atom, _, module}, {:atom, _, function}}, acc),
    do: [{module, function} | acc]

  defp remote({:function, {:atom, _, module}, {:atom, _, function}, _arity}, acc),
    do: [{module, function} | acc]

  defp remote(term, acc) when is_tuple(term), do: remote(Tuple.to_list(term), acc)
  defp remote(terms, acc) when is_list(terms), do: Enum.reduce(terms, acc, &remote/2)
  defp remote(_term, acc), do: acc
end
