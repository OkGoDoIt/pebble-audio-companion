import SegmentStore

// `SegmentProvenance` exists in BOTH SegmentStore (the durable firmware/protocol provenance the
// receiver writes) and AppDB (the per-member provenance row the conversation Details screen
// renders). Files that import both cannot name either unqualified, and the module name
// `SegmentStore` collides with the actor of the same name, so `SegmentStore.SegmentProvenance`
// does not resolve. This file imports only SegmentStore and hands the module a usable alias.

/// `SegmentStore.SegmentProvenance` — firmware version + protocol version, attached at segment open.
typealias DurableSegmentProvenance = SegmentProvenance
