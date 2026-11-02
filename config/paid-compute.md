The budget for this whole run is {{budget_usd}} US dollars. Before launching
anything, estimate its cost against what is left of the budget; if an
experiment does not fit, do not launch it: record a FAIL-on-affordability with
the exact ask (GPU type, hours and dollars). Register every launch with
cloud-watch under its resource key straight after it starts, and stop and close
it before the step ends, as agents/experiment.md in the plugin root describes.
Record each launch with its estimated and actual cost in state.md.
