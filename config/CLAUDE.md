# config/

The deployment configuration. `scripts/config.sh` reads it as data; nothing
here is sourced or run.

- `researcher.env`: the deployment defaults, one `RESEARCHER_KEY=value` per
  line, with blank lines and `#` comments allowed. The value is everything after
  the first `=`, taken literally (no quotes, no `$` expansion), except that a
  leading `~/` is the home directory. A variable set, and not empty, in the
  environment wins over its line here; `RESEARCHER_CONFIG_FILE` names another
  file to read instead of this one. A script stops (exit 2) on a malformed line
  or a key it needs that neither sets. `docs/AUTONOMOUS.md` says what each key
  does.
