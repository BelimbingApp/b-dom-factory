defmodule Bilimbi.Factory.Inventory.Application do
  @moduledoc false

  use Application

  # A refused posting-authority declaration fails boot, not the postings.
  @impl true
  def start(_type, _args) do
    Bilimbi.Factory.Inventory.PostingAuthority.install!()
    Supervisor.start_link([], strategy: :one_for_one, name: Bilimbi.Factory.Inventory.Supervisor)
  end
end
