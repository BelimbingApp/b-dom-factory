defmodule Bilimbi.Factory.ProductionExecution.Web.WastageReasonsLive do
  @moduledoc "Company wastage reason administration through the Production Execution facade."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Factory.ProductionExecution
  alias Bilimbi.Factory.ProductionExecution.Web.CodeList

  @impl true
  def mount(_params, _session, socket), do: {:ok, CodeList.mount(socket, config())}

  # CodeList refuses every write event without the manage capability.
  @impl true
  def handle_event(event, params, socket), do: CodeList.handle_event(event, params, socket)

  @impl true
  def render(assigns), do: CodeList.render(assigns)

  defp config do
    %{
      id: "wastage-reasons",
      nav: "admin.factory.wastage-reasons",
      title: "Wastage reasons",
      subtitle: "Why material is scrapped on a run, as operators choose it on the shop floor.",
      noun: "Wastage reason",
      plural: "wastage reasons",
      empty: "Add the reasons operators may give for scrapped material.",
      list: &ProductionExecution.list_wastage_reasons/3,
      create: &ProductionExecution.create_wastage_reason/3,
      update: &ProductionExecution.update_wastage_reason/4
    }
  end
end
