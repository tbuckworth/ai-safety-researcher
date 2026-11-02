Paid cloud GPUs on Lambda, on Titus's personal Lambda account (cloud-watch
account lambda:personal), with a budget of {{budget_usd}} US dollars for this
whole run. Never use Arrow's or ward9's Lambda accounts. Before launching
anything, estimate its cost against what is left of the budget; if an experiment
does not fit, do not launch it: record a FAIL-on-affordability with the exact ask
(GPU type, hours and dollars). Register every instance with cloud-watch straight
after it starts: cloud-watch register lambda:personal:<instance-name> --expect
<hours>h --reason "researcher <run_id>". Terminate it and run cloud-watch close
lambda:personal:<instance-name> before the step ends. Record each launch with its
estimated and actual cost in state.md. Prefer lightweight experiments (small
open-weight models).
