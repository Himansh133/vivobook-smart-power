# vivobook-smart-power

A small background service for Linux laptops that switches the system power profile based on what the machine is actually doing. It is a rough stand-in for the "Dynamic" mode you get on Windows.

**Status: experimental (v0.1.0).** It has been tested on one laptop only. Read the limitations section before relying on it.

## What it does

It samples CPU and NVIDIA GPU load every 10 seconds and talks to `power-profiles-daemon` through `powerprofilesctl`.

| Situation | Profile |
|---|---|
| On AC, light load | `balanced` |
| On AC, sustained heavy load (about 30 s) | `performance` |
| On AC, load gone for about 2 min | back to `balanced` |
| On battery | `balanced` (configurable) |
| CPU package too hot | `balanced` until it cools down |

Fan speed is never touched. The laptop firmware keeps full control of fans and its own thermal protection.

"Heavy load" means one of these:

- The sum of all cores' usage reaches `CPU_BUSY_SUM` (100 means one core fully busy). A single-threaded job that hops between cores still adds up to about 100, so it counts.
- NVIDIA GPU utilization reaches `GPU_HIGH` percent.

## Tested on

- ASUS Vivobook 14X (K3405ZF), Intel Core i7 12th gen H, NVIDIA RTX 2050
- Ubuntu, GNOME on Wayland, `power-profiles-daemon` with `intel_pstate` and `platform_profile`

It should work on other laptops that have `power-profiles-daemon` and a CPU package thermal zone, but that is untested. Compatibility reports are welcome (see below).

## Requirements

- `power-profiles-daemon` (`powerprofilesctl` must work for your user)
- systemd user services
- Optional: `nvidia-smi` for GPU load

## Install

```bash
git clone https://github.com/YOUR_USERNAME/vivobook-smart-power.git
cd vivobook-smart-power
./install.sh
```

No sudo needed. It copies the script to `~/.local/bin`, installs a user service, creates `~/.config/smart-power/config` if you do not have one, and starts the service. It starts again at every login.

```bash
systemctl --user status smart-power
journalctl --user -u smart-power -f
```

## Try it without changing anything

```bash
./smart-power.sh --once       # one reading and the decision it would make
./smart-power.sh --dry-run    # keeps running, logs decisions, never switches
```

A log line looks like this:

```
src=ac cpu=6% busy=100 gpu=0% temp=90C mode=load hot=0 have=balanced want=performance
```

- `cpu` is overall CPU use, `busy` is the sum over all cores
- `mode` is the load state (`idle` or `load`), `hot` is the temperature guard
- `have` is the current profile, `want` is the one the script picked

## Configuration

Edit `~/.config/smart-power/config`, then `systemctl --user restart smart-power`. See `config.example` for every option and its default.

| Option | Default | Meaning |
|---|---|---|
| `INTERVAL` | 10 | Seconds between samples |
| `CPU_BUSY_SUM` | 80 | Sum of core usage that counts as heavy load |
| `GPU_HIGH` | 40 | GPU % that counts as heavy load |
| `UP_SAMPLES` | 3 | Heavy samples in a row before switching up |
| `DOWN_SAMPLES` | 12 | Light samples in a row before switching down |
| `MIN_HOLD` | 30 | Minimum seconds between profile changes |
| `AC_IDLE_PROFILE` | balanced | Profile on AC when idle |
| `AC_LOAD_PROFILE` | performance | Profile on AC under load |
| `BATTERY_PROFILE` | balanced | Profile on battery (`power-saver` saves more) |
| `TEMP_ZONE_TYPE` | x86_pkg_temp | Thermal zone name to watch |
| `TEMP_LIMIT_C` | 85 | At or above this, drop to the idle profile |
| `TEMP_RESUME_C` | 75 | Must cool below this before performance is allowed again |
| `USE_GPU` | 1 | Set to 0 to skip `nvidia-smi` |

### Temperature tuning

The thermal zone is found by name, not by number. To see what your laptop has:

```bash
for z in /sys/class/thermal/thermal_zone*; do echo "$(basename $z) $(cat $z/type) $(cat $z/temp)"; done
```

On the Vivobook, a single busy thread pushes `x86_pkg_temp` to about 90C even in `balanced`, so the default 85C limit kept the script from ever switching up. The author runs `TEMP_LIMIT_C=95` and `TEMP_RESUME_C=85`. If your log shows `hot=1` and `mode` never reaches `load`, check this first.

## Uninstall

```bash
./uninstall.sh            # keeps your config
./uninstall.sh --purge    # removes the config too
```

It sets the profile back to `balanced`.

## Limitations

- Tested on a single laptop model.
- Load is a rough signal. An AI agent that mostly waits on a cloud API uses little CPU, so it will not trigger `performance`. Local model inference usually will.
- The temperature check is one sensor and one threshold. It is not a replacement for firmware thermal protection, which stays on.
- If the NVIDIA GPU is runtime-suspended, the script reads 0% instead of waking it. If your GPU never sleeps, it reads normally.
- Behavior after suspend and resume, and when the charger is plugged or unplugged, has only been lightly tested.
- If `power-profiles-daemon` is missing or refuses the change, the script logs the failure and keeps trying.

## Roadmap

- Safer thermal logic (trip only after several hot readings in a row)
- Test suite and CI
- Notes on which laptops work
- An explicit "AI inference" mode instead of guessing from CPU and GPU load
- A wider name than "vivobook" if other laptops join in

## Contributing

Issues and pull requests are welcome. The most useful thing right now is a compatibility report: your laptop model, distro, the output of `./smart-power.sh --once`, and whether profiles switched as expected.

## License

MIT, see `LICENSE`.
