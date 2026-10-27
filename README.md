# kitchen-incus

A [Test Kitchen](https://kitchen.ci) driver and transport for [Incus](https://linuxcontainers.org/incus/) containers and virtual machines.

Everything goes through the `incus` CLI, so any remote your client can reach works: the local unix socket, or a remote HTTPS server or cluster. Instances don't need SSH or a network route from your workstation.

- **Driver** (`incus`): creates, starts, waits for, and deletes instances. It also reports live status for `kitchen list --live`.
- **Transport** (`incus`): runs commands with `incus exec`, uploads files as a tar stream (falling back to `incus file push`), downloads with `incus file pull`, and opens `kitchen login` with `incus exec … -- su -l`.
- **InSpec**: when the transport is `incus`, the `inspec` verifier runs through a bundled `incus` train backend.
- **Cinc by default**: this gem depends on `kitchen-cinc`. Use `cinc_infra`, `cinc_zero`, `cinc_solo`, or `cinc_apply`. The `chef_*` provisioner names also install Cinc unless `kitchen-chef-enterprise` is installed.

## Usage

```yaml
driver:
  name: incus

transport:
  name: incus

provisioner:
  name: cinc_infra

verifier:
  name: inspec

platforms:
  - name: debian-12          # image defaults to images:debian/12
  - name: rockylinux-9
  - name: ubuntu-24.04-vm
    driver:
      image: images:ubuntu/24.04
      vm: true
      config:
        limits.cpu: 2
        limits.memory: 2GiB

suites:
  - name: default
    run_list:
      - recipe[my_cookbook::default]
```

`kitchen create`, `converge`, `verify`, `test`, `login`, `exec`, `destroy`, and `list --live --probe` all work.

## Driver options

| Option | Default | Description |
| --- | --- | --- |
| `remote` | client default | Incus remote. The resolved name is saved in state, so `destroy` still targets the right server if you later switch remotes. |
| `project` | remote's current project | Incus project |
| `image` | `images:<distro>/<version>` | Derived from the platform name (`ubuntu-24.04` → `images:ubuntu/24.04`) |
| `vm` | `false` | Launch a VM instead of a container |
| `profiles` | `[]` | Profiles to apply. Empty means the server default. Setting this replaces `default`. |
| `config` | `{}` | Instance config keys, e.g. `security.nesting: true` |
| `devices` | `{}` | `{ name => { type: disk, source: /src, path: /dst } }` |
| `storage_pool` | `nil` | `--storage` |
| `network` | `nil` | `--network` |
| `instance_type` | `nil` | `--type`, e.g. `c2-m4` |
| `instance_name` | `kitchen-<instance>-<random>` | Explicit instance name |
| `ready_timeout` | `300` | Seconds to wait for the instance to accept commands |
| `wait_for_network` | `true` | Also wait for a global IP address |
| `install_prerequisites` | `true` | Install `curl`, `sudo`, `tar`, and `ca-certificates` if they're missing (apt, dnf, yum, zypper, apk, pacman) |
| `provision_commands` | `[]` | Shell commands to run after boot |
| `incus_binary` | `incus` | Path to the client |

## Transport options

| Option | Default | Description |
| --- | --- | --- |
| `user` | root | uid that commands run as |
| `env` | `{}` | Extra environment variables for every command |
| `login_command` | `["su", "-l"]` | Command that `kitchen login` runs |
| `ready_timeout` | `300` | Seconds `wait_until_ready` waits |

## Standalone InSpec / cinc-auditor

```
cinc-auditor exec profile -t incus://my-instance --remote myremote
```

## Development

```
bundle exec rspec
cd test/kitchen && RUBYLIB=../../lib kitchen test     # live run on your current Incus remote
```
