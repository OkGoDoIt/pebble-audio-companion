namespace PebbleAudio.Server.Data;

/// <summary>A permanent revocation of older automatic names from one local identity store.</summary>
public sealed class VoiceRevocation : SyncedRecord
{
	public string Id { get; set; } = "";
	public string OriginID { get; set; } = "";
	public long Generation { get; set; }
	public string Scope { get; set; } = "";
	public string? TargetID { get; set; }
}

/// <summary>Attribution provenance only. No voice vector or audio is synced.</summary>
public sealed class VoiceEvidence
{
	public string OriginID { get; set; } = "";
	public long Generation { get; set; }
	public string RunID { get; set; } = "";
}
