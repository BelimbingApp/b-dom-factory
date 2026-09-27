defmodule Bilimbi.Factory.ProductDefinition.Web.DefinitionsLive do
  @moduledoc "Company Formula/BOM and routing revision administration through Product Definition."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductDefinition, as: Definitions

  @view "factory.product-definition.configuration.view"
  @manage "factory.product-definition.configuration.manage"

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:page_title, "BOM formulas & routings")
      |> assign(:active_nav, "admin.factory.definitions")
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:selected, nil)
      |> assign(:formulas, [])
      |> assign(:routings, [])
      |> assign(:product_form, product_form(%{}))
      |> assign(:formula_form, formula_form(%{}))
      |> assign(:routing_form, routing_form(%{}))
      |> assign(:error, nil)

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    if can?(socket, @view) do
      case Integer.parse(id) do
        {product_id, ""} ->
          case Enum.find(socket.assigns.products, &(&1.id == product_id)) do
            nil -> {:noreply, assign(socket, :error, "Product definition not found.")}
            product -> {:noreply, select(socket, product)}
          end

        _ -> {:noreply, assign(socket, :error, "Product definition not found.")}
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to view definitions.")}
    end
  end

  def handle_event("create_product", _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, assign(socket, :error, "You do not have permission to manage definitions.")}

  def handle_event("create_product", %{"product" => params}, socket) do
    with_manage(socket, fn socket ->
      result =
        case Integer.parse(params["item_id"] || "") do
          {item_id, ""} -> Definitions.create_product(scope(socket), company_id(socket), item_id, params)
          _ -> {:error, :item_not_found}
        end

      case result do
        {:ok, product} ->
          {:noreply,
           socket
           |> load()
           |> select(product)
           |> assign(:product_form, product_form(%{}))
           |> put_flash(:success, "Product definition created.")}

        {:error, reason} ->
          {:noreply, socket |> assign(:product_form, product_form(params)) |> assign(:error, error_text(reason))}
      end
    end)
  end

  def handle_event("publish_formula", %{"formula" => params}, socket) do
    with_manage(socket, fn socket ->
      case socket.assigns.selected do
        %{id: product_id} = product ->
          attrs = %{"lines" => decode_json(params["lines"]), "process_config" => decode_json(params["process_config"])}

          case Definitions.publish_formula(scope(socket), company_id(socket), product_id, attrs) do
            {:ok, _revision} ->
              {:noreply,
               socket
               |> select(product)
               |> assign(:formula_form, formula_form(%{}))
               |> put_flash(:success, "Formula revision published.")}

            {:error, reason} ->
              {:noreply, socket |> assign(:formula_form, formula_form(params)) |> assign(:error, error_text(reason))}
          end

        _ -> {:noreply, assign(socket, :error, "Select a product definition.")}
      end
    end)
  end

  def handle_event("publish_routing", %{"routing" => params}, socket) do
    with_manage(socket, fn socket ->
      case socket.assigns.selected do
        %{id: product_id} = product ->
          attrs = %{"operations" => decode_json(params["operations"]), "process_config" => decode_json(params["process_config"])}

          case Definitions.publish_routing(scope(socket), company_id(socket), product_id, attrs) do
            {:ok, _revision} ->
              {:noreply,
               socket
               |> select(product)
               |> assign(:routing_form, routing_form(%{}))
               |> put_flash(:success, "Routing revision published.")}

            {:error, reason} ->
              {:noreply, socket |> assign(:routing_form, routing_form(params)) |> assign(:error, error_text(reason))}
          end

        _ -> {:noreply, assign(socket, :error, "Select a product definition.")}
      end
    end)
  end

  defp load(socket) do
    if can?(socket, @view) do
      with {:ok, products} <- Definitions.list_products(scope(socket), company_id(socket)),
           {:ok, items} <- Inventory.list_items(scope(socket), company_id(socket), limit: 500) do
        socket |> assign(:products, products) |> assign(:items, items)
      else
        {:error, reason} ->
          socket |> assign(:products, []) |> assign(:items, []) |> assign(:error, error_text(reason))
      end
    else
      socket |> assign(:products, []) |> assign(:items, []) |> assign(:error, "You do not have permission to view definitions.")
    end
  end

  defp select(socket, product) do
    with {:ok, formulas} <- Definitions.list_formula_revisions(scope(socket), company_id(socket), product.id),
         {:ok, routings} <- Definitions.list_routing_revisions(scope(socket), company_id(socket), product.id) do
      socket
      |> assign(:selected, product)
      |> assign(:formulas, formulas)
      |> assign(:routings, routings)
      |> assign(:error, nil)
    else
      {:error, reason} -> assign(socket, :error, error_text(reason))
    end
  end

  defp with_manage(socket, callback) do
    if can?(socket, @manage),
      do: callback.(socket),
      else: {:noreply, assign(socket, :error, "You do not have permission to manage definitions.")}
  end

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp product_form(params),
    do: to_form(Map.merge(%{"item_id" => "", "code" => "", "name" => ""}, params), as: :product)

  defp formula_form(params),
    do: to_form(Map.merge(%{"lines" => "[]", "process_config" => "{}"}, params), as: :formula)

  defp routing_form(params),
    do: to_form(Map.merge(%{"operations" => "[]", "process_config" => "{}"}, params), as: :routing)

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  defp decode_json(_), do: nil

  defp error_text(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, options}} ->
      message =
        Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
          options |> Keyword.get(String.to_existing_atom(key)) |> to_string()
        end)

      "#{Phoenix.Naming.humanize(field)} #{message}"
    end)
    |> Enum.join("; ")
  end

  defp error_text(reason), do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>
          BOM formulas & routings
          <:subtitle>Published revisions are immutable. New versions use the current company items, units, and resources.</:subtitle>
        </.header>

        <p :if={@error} id="definition-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card :if={@can_manage?} id="new-product" title="New product definition" class="mt-5">
          <.form for={@product_form} id="product-form" phx-submit="create_product" class="space-y-4 p-4">
            <.input field={@product_form[:item_id]} type="select" label="Output item" prompt="Choose an item" options={for item <- @items, do: {"#{item.sku} — #{item.title}", item.id}} />
            <.input field={@product_form[:code]} label="Code" />
            <.input field={@product_form[:name]} label="Name" />
            <.button type="submit" variant="primary">Create product definition</.button>
          </.form>
        </.card>

        <.card id="product-definitions" inner_class="p-0" class="mt-5">
          <.table id="product-definitions-table" rows={@products} caption="Product definitions" framed={false}>
            <:col :let={product} label="Code">{product.code}</:col>
            <:col :let={product} label="Name">{product.name}</:col>
            <:action :let={product}><.button type="button" phx-click="select" phx-value-id={product.id}>Revisions</.button></:action>
            <:empty :if={@products == []} title="No product definitions" reason="Create one for a company item." />
          </.table>
        </.card>

        <div :if={@selected} class="mt-5 space-y-5">
          <.card id="formula-revisions" title={"#{@selected.name} formulas"}>
            <.table id="formula-revisions-table" rows={@formulas} caption="Formula revisions" framed={false}>
              <:col :let={formula} label="Version">{formula.version}</:col>
              <:col :let={formula} label="Lines"><pre class="whitespace-pre-wrap text-xs">{Jason.encode!(formula.lines, pretty: true)}</pre></:col>
              <:col :let={formula} label="Process configuration"><pre class="whitespace-pre-wrap text-xs">{Jason.encode!(formula.process_config, pretty: true)}</pre></:col>
              <:empty :if={@formulas == []} title="No formulas" reason="Publish a formula revision to define inputs and outputs." />
            </.table>
            <.form :if={@can_manage?} for={@formula_form} id="formula-form" phx-submit="publish_formula" class="space-y-4 p-4">
              <.input field={@formula_form[:lines]} type="textarea" label="Lines (JSON)" hint="Each line names item_id, unit_id, role, and quantity." />
              <.input field={@formula_form[:process_config]} type="textarea" label="Process configuration (JSON)" />
              <.button type="submit" variant="primary">Publish formula version</.button>
            </.form>
          </.card>

          <.card id="routing-revisions" title={"#{@selected.name} routings"}>
            <.table id="routing-revisions-table" rows={@routings} caption="Routing revisions" framed={false}>
              <:col :let={routing} label="Version">{routing.version}</:col>
              <:col :let={routing} label="Operations"><pre class="whitespace-pre-wrap text-xs">{Jason.encode!(routing.operations, pretty: true)}</pre></:col>
              <:col :let={routing} label="Process configuration"><pre class="whitespace-pre-wrap text-xs">{Jason.encode!(routing.process_config, pretty: true)}</pre></:col>
              <:empty :if={@routings == []} title="No routings" reason="Publish a routing revision to define operations." />
            </.table>
            <.form :if={@can_manage?} for={@routing_form} id="routing-form" phx-submit="publish_routing" class="space-y-4 p-4">
              <.input field={@routing_form[:operations]} type="textarea" label="Operations (JSON)" hint="Each operation names code, sequence, inputs, outputs, and allowed_resource_ids." />
              <.input field={@routing_form[:process_config]} type="textarea" label="Process configuration (JSON)" />
              <.button type="submit" variant="primary">Publish routing version</.button>
            </.form>
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
