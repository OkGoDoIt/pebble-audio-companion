import GRDB

extension VoiceIdentityStore {
    static func installSchema(_ d: Database) throws {
        try d.execute(sql: """
            CREATE TABLE voice_recognition_config (
                id INTEGER PRIMARY KEY CHECK(id = 1), mode TEXT NOT NULL DEFAULT 'off',
                generation INTEGER NOT NULL DEFAULT 0, corpusRevision INTEGER NOT NULL DEFAULT 0, enabledAtMs INTEGER
            );
            INSERT INTO voice_recognition_config(id) VALUES(1);
            CREATE TABLE voice_sources (
                segmentId TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL,
                generation INTEGER NOT NULL DEFAULT 1, state TEXT NOT NULL DEFAULT 'ready'
            );
            CREATE TABLE voice_source_revocations (
                segmentId TEXT NOT NULL REFERENCES voice_sources(segmentId) ON DELETE CASCADE,
                revision TEXT NOT NULL, PRIMARY KEY(segmentId, revision)
            );
            CREATE TABLE voice_examples (
                id TEXT PRIMARY KEY NOT NULL, personId TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                confirmationID TEXT NOT NULL, sessionID TEXT NOT NULL,
                segmentId TEXT NOT NULL REFERENCES voice_sources(segmentId) ON DELETE CASCADE,
                startMediaMs INTEGER NOT NULL CHECK(startMediaMs >= 0),
                endMediaMs INTEGER NOT NULL CHECK(endMediaMs > startMediaMs),
                sourceRevision TEXT NOT NULL, recipeID TEXT NOT NULL,
                recipeJSON BLOB NOT NULL, embeddingJSON BLOB NOT NULL, qualityJSON BLOB NOT NULL,
                createdAtMs INTEGER NOT NULL,
                UNIQUE(personId, segmentId, startMediaMs, endMediaMs, sourceRevision, recipeID)
            );
            CREATE INDEX voice_examples_person ON voice_examples(personId, recipeID);
            CREATE TABLE voice_runs(runID TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL DEFAULT 'active');
            CREATE TABLE voice_auto_attributions (
                id TEXT PRIMARY KEY NOT NULL, personId TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                segmentId TEXT NOT NULL REFERENCES voice_sources(segmentId) ON DELETE CASCADE,
                startMediaMs INTEGER NOT NULL CHECK(startMediaMs >= 0),
                endMediaMs INTEGER NOT NULL CHECK(endMediaMs > startMediaMs),
                sourceRevision TEXT NOT NULL, recipeID TEXT NOT NULL,
                score DOUBLE NOT NULL, margin DOUBLE, calibrationID TEXT NOT NULL,
                runID TEXT NOT NULL REFERENCES voice_runs(runID), disposition TEXT NOT NULL,
                createdAtMs INTEGER NOT NULL
            );
            CREATE INDEX voice_auto_range ON voice_auto_attributions(segmentId, startMediaMs, endMediaMs);
            CREATE INDEX voice_auto_person ON voice_auto_attributions(personId);
            CREATE INDEX voice_auto_run ON voice_auto_attributions(runID);
            CREATE TABLE voice_suppressions (
                id INTEGER PRIMARY KEY, segmentId TEXT NOT NULL REFERENCES voice_sources(segmentId) ON DELETE CASCADE,
                startMediaMs INTEGER NOT NULL, endMediaMs INTEGER NOT NULL
            );
            CREATE INDEX voice_suppression_range ON voice_suppressions(segmentId, startMediaMs, endMediaMs);
            CREATE TABLE voice_jobs (
                id TEXT PRIMARY KEY NOT NULL, runID TEXT NOT NULL REFERENCES voice_runs(runID),
                segmentId TEXT NOT NULL REFERENCES voice_sources(segmentId) ON DELETE CASCADE,
                startMediaMs INTEGER NOT NULL, endMediaMs INTEGER NOT NULL, cursorMediaMs INTEGER NOT NULL,
                recipeID TEXT NOT NULL, sourceRevision TEXT NOT NULL,
                configGeneration INTEGER NOT NULL, corpusRevision INTEGER NOT NULL, sourceGeneration INTEGER NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
                updatedAtMs INTEGER NOT NULL, lastError TEXT,
                UNIQUE(runID, segmentId, startMediaMs, endMediaMs)
            );
            CREATE INDEX voice_jobs_pending ON voice_jobs(state, updatedAtMs);
            """)
        // Partial historical schema fixtures intentionally omit people and the identity state.
        guard try d.tableExists("people"), try d.tableExists("speaker_identity_state") else { return }
        for event in ["INSERT", "DELETE"] {
            try d.execute(sql: """
                CREATE TRIGGER voice_example_\(event.lowercased()) AFTER \(event) ON voice_examples BEGIN
                    UPDATE voice_recognition_config SET corpusRevision = corpusRevision + 1 WHERE id = 1;
                END;
                """)
            let row = event == "INSERT" ? "NEW" : "OLD"
            try SpeakerCorrectionStore.trigger(d, name: "identity_voice_auto_\(event.lowercased())",
                event: event, table: "voice_auto_attributions", statements:
                    ["UPDATE speaker_identity_state SET revision = revision + 1 WHERE id = 1;"]
                    + SpeakerCorrectionStore.markRange(row))
        }
        // Existing name/self triggers did not know about acoustic attributions. Keep their
        // normal work and add the account-local acoustic rows to affected archive payloads.
        for (name, event, table, condition, personIDs) in [
            ("rename", "UPDATE OF name", "people", "OLD.name IS NOT NEW.name", ["NEW.id"]),
            ("self", "UPDATE OF currentUserPersonId", "speaker_identity_state",
             "OLD.currentUserPersonId IS NOT NEW.currentUserPersonId", ["OLD.currentUserPersonId", "NEW.currentUserPersonId"]),
        ] {
            let marks = personIDs.flatMap { person in
                ["conversation", "transcript"].map { kind in
                    ArchiveOutbox.enqueueSQL(kind: "'\(kind)'", id: "cs.conversationId", op: "'upsert'",
                        from: "conversation_segments cs JOIN voice_auto_attributions va ON va.segmentId = cs.segmentId",
                        condition: "va.personId = \(person) AND COALESCE(cs.startMediaMs,0) < va.endMediaMs AND (cs.endMediaMs IS NULL OR cs.endMediaMs > va.startMediaMs)")
                }
            }
            try SpeakerCorrectionStore.trigger(d, name: "identity_voice_\(name)", event: event,
                table: table, when: condition, statements: marks)
        }
    }
}
