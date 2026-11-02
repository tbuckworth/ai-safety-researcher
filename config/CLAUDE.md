# config/

The deployment configuration. `scripts/config.sh` reads it as data; nothing
here is sourced or run. How the scripts use it (what each key does, the
environment winning over it, `RESEARCHER_CONFIG_FILE`, the errors) is in
`docs/AUTONOMOUS.md`, under Configuration and Compute Profile.

- `researcher.env`: the deployment defaults, one `RESEARCHER_KEY=value` per
  line, with blank lines and `#` comments allowed. The value is everything after
  the first `=`, taken literally (no quotes, no `$` expansion), except that a
  leading `~/` is the home directory.
- `compute-profiles/<name>.md`: the text of the compute-profile preset `<name>`,
  which is joined into one line. In it, `{{paid_compute}}` stands for
  `paid-compute.md` and `{{budget_usd}}` for the run's budget in US dollars.
- `paid-compute.md`: the rules every paid preset shares, included where the
  preset has `{{paid_compute}}`.
