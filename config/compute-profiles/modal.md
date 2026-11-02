Paid cloud GPUs on Modal, in the Arrow workspace (the modal CLI's own login;
cloud-watch account modal:arrow), with a budget of {{budget_usd}} US dollars for
this whole run. Never use ward9's Modal workspace. Before launching anything,
estimate its cost against what is left of the budget; if an experiment does not
fit, do not launch it: record a FAIL-on-affordability with the exact ask (GPU
type, hours and dollars). Register every launch with cloud-watch straight after
it starts: cloud-watch register modal:arrow:<app-name> --expect <hours>h
--reason "researcher <run_id>". Stop it and run cloud-watch close
modal:arrow:<app-name> before the step ends. Record each launch with its
estimated and actual cost in state.md. Prefer lightweight experiments (small
open-weight models).
