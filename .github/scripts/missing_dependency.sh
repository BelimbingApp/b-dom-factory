#!/usr/bin/env bash
# Proves a missing Factory dependency fails composition.
#
# Run from a Bilimbi root with Factory mounted at apps/domains/factory and the
# workspace already compiled. The script mounts a throwaway Extension whose one
# module depends on factory/inventory, moves Factory out of apps/, and requires
# discovery to refuse the graph with the missing-dependency error. It then
# remounts Factory and requires the same graph to compile. The fixture is
# written here and removed on exit; it is never a real Extension.
set -euo pipefail

root=$(pwd -P)
factory="$root/apps/domains/factory"
parked="$root/.scratchpad/factory-parked"
fixture="$root/apps/extensions/factory_probe"
expected="module factory_probe/probe declares missing dependency factory/inventory"

[ -f "$root/apps/domains/AGENTS.md" ] || { echo "run from a Bilimbi root" >&2; exit 2; }
[ -d "$factory" ] || { echo "Factory is not mounted at $factory" >&2; exit 2; }
[ ! -e "$fixture" ] || { echo "$fixture already exists" >&2; exit 2; }
[ ! -e "$parked" ] || { echo "$parked already exists" >&2; exit 2; }

build="$root/_build/${MIX_ENV:-dev}/lib"

restore() {
  if [ -d "$parked" ] && [ ! -e "$factory" ]; then mv "$parked" "$factory"; fi
  rm -rf "$fixture" "$build/factory_probe" "$build/bilimbi_factory_probe_probe"
}
trap restore EXIT

mkdir -p "$fixture/probe/lib"

cat > "$fixture/bilimbi.container.exs" <<'EOF'
[id: "factory_probe", kind: :container, layer: :extension]
EOF

cat > "$fixture/mix.exs" <<'EOF'
Code.require_file(Path.expand("../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.FactoryProbe.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../..", __DIR__)

  def project do
    [
      app: :factory_probe,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      deps: Bilimbi.Base.ModuleRegistry.MixDiscovery.container_dependencies(__DIR__)
    ]
  end
end
EOF

cat > "$fixture/probe/bilimbi.module.exs" <<'EOF'
[
  id: "factory_probe/probe",
  kind: :module,
  layer: :extension,
  required: false,
  otp_app: :bilimbi_factory_probe_probe,
  namespace: Bilimbi.FactoryProbe.Probe,
  dependencies: ["factory/inventory"],
  migrations: nil,
  web: nil,
  schema_contract: nil,
  contribution_provider: nil,
  dev_seed: nil
]
EOF

cat > "$fixture/probe/mix.exs" <<'EOF'
Code.require_file(Path.expand("../../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.FactoryProbe.Probe.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../../..", __DIR__)

  def project do
    [
      app: :bilimbi_factory_probe_probe,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      deps: Bilimbi.Base.ModuleRegistry.MixDiscovery.module_dependencies(__DIR__)
    ]
  end

  def application do
    [env: Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__)]
  end
end
EOF

cat > "$fixture/probe/lib/probe.ex" <<'EOF'
defmodule Bilimbi.FactoryProbe.Probe do
  @moduledoc false

  def inventory, do: Bilimbi.Factory.Inventory
end
EOF

# Factory absent while a mounted dependent requires it: composition refuses.
mv "$factory" "$parked"
set +e
output=$(mix compile 2>&1)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "$output"
  echo "composition accepted factory_probe/probe without Factory mounted" >&2
  exit 1
fi

if ! grep -qF "$expected" <<<"$output"; then
  echo "$output"
  echo "composition failed without the expected error: $expected" >&2
  exit 1
fi

echo "without Factory: $expected"

# Factory mounted again: the same graph composes and compiles.
mv "$parked" "$factory"
mix compile

if [ ! -f "$build/bilimbi_factory_probe_probe/ebin/Elixir.Bilimbi.FactoryProbe.Probe.beam" ]; then
  echo "factory_probe/probe did not compile with Factory mounted" >&2
  exit 1
fi

echo "with Factory: factory_probe/probe composes and compiles"
