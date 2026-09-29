defmodule Bilimbi.Factory.ProductionExecution.Web.LabourRolesLive do
  @moduledoc "Company labour role administration through the Production Execution facade."
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
      id: "labour-roles",
      nav: "admin.factory.labour-roles",
      title: "Labour roles",
      subtitle: "The roles people work in on a run, as they clock in on the shop floor.",
      noun: "Labour role",
      plural: "labour roles",
      empty: "Add the roles people may clock in as.",
      list: &ProductionExecution.list_labour_roles/3,
      create: &ProductionExecution.create_labour_role/3,
      update: &ProductionExecution.update_labour_role/4
    }
  end
end
