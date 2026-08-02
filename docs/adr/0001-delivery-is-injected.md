# Delivery is injected, not built in

The plugin renders a batch into a payload and stops there: where that payload goes is a
function the **host** supplies. Building in a transport would have tied the plugin to one
agent runner, and the agent tooling this was written against changes faster than the review
workflow does.

## Consequences

The plugin cannot be used without a host wiring up delivery, and no test in this repo
exercises a real agent handoff — every adapter is a stub. That is the cost of the seam, and
it is accepted deliberately: the alternative is a plugin that is wrong for everyone whose
setup differs by one process boundary.
