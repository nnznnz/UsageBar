# Credits & provenance

UsageBar is an **independent, from-scratch reimplementation** written for a single
person to run on their own Mac. It is not derived from any other project's source
code.

The *idea* — a menu-bar app that consolidates AI-subscription usage — and the
*research* into each vendor's (undocumented) usage endpoints come from
**OpenUsage** by Robin Ebers (MIT-licensed), https://github.com/robinebers/openusage.
That project's provider documentation was used as a reference for the functional
facts a client needs to talk to each API: endpoint URLs, required HTTP headers,
where each CLI stores its credentials locally, and the shape of the JSON
responses. Those are functional interface details, not creative content.

Everything in this repository — the architecture, the Swift code, the security
model (host allowlist, read-only-by-default credentials, no local server, no
telemetry) — was written fresh for this project. No code was copied.

"OpenUsage" is the upstream project's name/trademark; this project is deliberately
named differently and ships none of their assets.

Thanks to the OpenUsage maintainers and contributors for doing the reverse-
engineering legwork in the open.
