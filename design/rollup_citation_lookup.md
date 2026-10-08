# Bounded citation lookup

The context reader can surface an existing exact `[id,...]` citation. It does
not establish that a citation is a correction, or that the summary writer can
create links between separately sealed siblings.

Per assembly, lookup probes at most 128 canonical sealed-block paths, newest
first in each tier, round-robin from tier 1 upwards. It does not enumerate
directories or grep the archive. Each present candidate contributes at most
32 KiB plus one overflow byte to the read; oversized and malformed candidates
are skipped. Summaries are held in an in-memory snapshot, reused for all
displayed windows; citations are not followed recursively. Ordering is stable.

This is deliberately incomplete retrieval, not an exhaustive correction index.
A notice says to search `rollups/t*/` for the exact window prefix to find
omitted citations. It is also emitted when history exceeds the probe cap,
a candidate cannot be read, or a matching summary cannot fit.

Optional text (including that notice) is limited to the smaller of 4096 bytes,
20% of the context budget at four bytes per token, and the budget remaining
after the base context. Whole citation summaries are retained or omitted,
not cut mid-sentence. Base staircase/tail output is never truncated. The
pre-existing base context can itself exceed the requested budget; this change
does not repair that independent behavior. If even the notice will not fit,
base output is unchanged and the notice goes to stderr.

No full-directory indexing or mutable correction files are introduced.
The limit applies to additional citation history reads, not the pre-existing
rendered trajectory/cache maintenance and base staircase assembly.
