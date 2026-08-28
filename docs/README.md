# Documentation

The [README](../README.md) is the map: what this is, which tier you want, and
how to operate one once it exists. The build itself is two pages, and this is
where the second one lives.

| | |
| --- | --- |
| [building-a-runner.md](building-a-runner.md) | The build, inside the VM: the Debian install, addressing, one bootstrap command, `install.sh`'s settings, and the runners. The same on any hypervisor and for both tiers. Start at your hypervisor's page and it sends you here |
| [reference.md](reference.md) | The two settings named `docker.sock`, `CONFIG_FILE` and why an edit can appear to do nothing, the `/data` volume, compose networks against job networks, whether several runners should share a job network, why the privileged runner is separate, why public egress is not restricted on the node, why the resolver is set per-runner, the cache server |
| [threat-model.md](threat-model.md) | The adversary, where each tier's boundary sits, blast radius by layer, and what was rejected |
| [upgrading.md](upgrading.md) | Moving a runner that already exists to a newer version, why the two halves are counted separately, and the seven steps a guest-side change takes when a rollback is going to rebuild the machine. Start at [Updating](../README.md#updating-an-existing-runner) |
| [../upgrades/](../upgrades/) | One note per version: what an operator does in the console and in the guest to reach it |
| [../proxmox/README.md](../proxmox/README.md) | The node-side half on Proxmox: the VM, the datacenter firewall, the security group and the order its rules go in, and all three snapshot moments including the scheduled rollback |
| [../proxmox/firewall.fw.template](../proxmox/firewall.fw.template) | The same node firewall as one annotated file, easier to review in one piece than as a table. Reference, not something to install |
| [../examples/](../examples/) | The annotated templates `dejima-ci-runners` renders into `~/runners`. Every setting carries the reasoning for its value, which the generated copies do not - read them here rather than reading what lands on the host |

One document lives outside this repository: [dejima's `docs/ci.md`](https://gitbox.branderson.io/dejima/dejima/src/branch/main/docs/ci.md), which
covers why a CI run needs any of this over a sandbox, and why no approval gate
is offered. You do not need it to follow the README.
