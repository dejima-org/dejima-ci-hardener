# Documentation

The [README](../README.md) is the whole of the setup. Everything here is
background, deeper explanation, or the reasoning behind a decision that looks
arbitrary from outside.

| | |
| --- | --- |
| [reference.md](reference.md) | The two settings named `docker.sock`, `CONFIG_FILE` and why an edit can appear to do nothing, the `/data` volume, compose networks against job networks, whether several runners should share a job network, why the privileged runner is separate, why public egress is not restricted on the node, why the resolver is set per-runner, the cache server |
| [../proxmox/README.md](../proxmox/README.md) | Building the sacrificial VM: node firewall rules and the order they go in, bootstrap, snapshotting clean, and the scheduled rollback |
| [../proxmox/firewall.fw.template](../proxmox/firewall.fw.template) | The same node firewall as one annotated file, easier to review in one piece than as a table. Reference, not something to install |
| [../examples/](../examples/) | The annotated templates `dejima-ci-runners` renders into `~/runners`. Every setting carries the reasoning for its value, which the generated copies do not - read them here rather than reading what lands on the host |

One document lives outside this repository: dejima's `docs/ci.md`, which
covers why a CI run needs any of this over a sandbox, and why no approval gate
is offered. You do not need it to follow the README.
