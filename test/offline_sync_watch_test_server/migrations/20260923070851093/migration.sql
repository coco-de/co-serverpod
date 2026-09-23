BEGIN;

--
-- Function: gen_random_uuid_v7()
-- Source: https://gist.github.com/kjmph/5bd772b2c2df145aa645b837da7eca74
-- License: MIT (copyright notice included on the generator source code).
--
create or replace function gen_random_uuid_v7()
returns uuid
as $$
begin
  -- use random v4 uuid as starting point (which has the same variant we need)
  -- then overlay timestamp
  -- then set version 7 by flipping the 2 and 1 bit in the version 4 string
  return encode(
    set_bit(
      set_bit(
        overlay(uuid_send(gen_random_uuid())
                placing substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3)
                from 1 for 6
        ),
        52, 1
      ),
      53, 1
    ),
    'hex')::uuid;
end
$$
language plpgsql
volatile;

--
-- ACTION CREATE TABLE
--
CREATE TABLE "folder" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7(),
    "spaceId" bigint,
    "name" text NOT NULL
);

--
-- ACTION CREATE TABLE
--
CREATE TABLE "note" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7(),
    "spaceId" bigint,
    "title" text NOT NULL,
    "archived" boolean NOT NULL DEFAULT false,
    "folderId" uuid
);

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_cloud_storage" (
    "id" bigserial PRIMARY KEY,
    "storageId" text NOT NULL,
    "path" text NOT NULL,
    "addedTime" timestamp without time zone NOT NULL,
    "expiration" timestamp without time zone,
    "byteData" bytea NOT NULL,
    "verified" boolean NOT NULL,
    "contentType" text,
    "cacheControl" text,
    "contentDisposition" text,
    "contentEncoding" text,
    "customMetadata" text
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_cloud_storage_path_idx" ON "serverpod_cloud_storage" USING btree ("storageId", "path");
CREATE INDEX "serverpod_cloud_storage_expiration" ON "serverpod_cloud_storage" USING btree ("expiration");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_cloud_storage_direct_download" (
    "id" bigserial PRIMARY KEY,
    "storageId" text NOT NULL,
    "path" text NOT NULL,
    "expiration" timestamp without time zone NOT NULL,
    "authKey" text NOT NULL,
    "downloadFileName" text,
    "contentType" text
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_cloud_storage_direct_download_auth_key" ON "serverpod_cloud_storage_direct_download" USING btree ("authKey");
CREATE INDEX "serverpod_cloud_storage_direct_download_expiration" ON "serverpod_cloud_storage_direct_download" USING btree ("expiration");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_cloud_storage_direct_upload" (
    "id" bigserial PRIMARY KEY,
    "storageId" text NOT NULL,
    "path" text NOT NULL,
    "expiration" timestamp without time zone NOT NULL,
    "authKey" text NOT NULL,
    "maxFileSize" bigint NOT NULL DEFAULT 10485760,
    "contentLength" bigint,
    "preventOverwrite" boolean NOT NULL DEFAULT false,
    "contentType" text,
    "cacheControl" text,
    "contentDisposition" text,
    "contentEncoding" text,
    "customMetadata" text
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_cloud_storage_direct_upload_storage_path" ON "serverpod_cloud_storage_direct_upload" USING btree ("storageId", "path");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_future_call" (
    "id" bigserial PRIMARY KEY,
    "name" text NOT NULL,
    "time" timestamp without time zone NOT NULL,
    "serializedObject" text,
    "serverId" text NOT NULL,
    "identifier" text,
    "scheduling" json
);

-- Indexes
CREATE INDEX "serverpod_future_call_time_idx" ON "serverpod_future_call" USING btree ("time");
CREATE INDEX "serverpod_future_call_serverId_idx" ON "serverpod_future_call" USING btree ("serverId");
CREATE INDEX "serverpod_future_call_identifier_idx" ON "serverpod_future_call" USING btree ("identifier");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_future_call_claim" (
    "id" bigserial PRIMARY KEY,
    "futureCallId" bigint,
    "lastHeartbeatTime" timestamp without time zone NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "future_call_unique_idx" ON "serverpod_future_call_claim" USING btree ("futureCallId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_health_connection_info" (
    "id" bigserial PRIMARY KEY,
    "serverId" text NOT NULL,
    "timestamp" timestamp without time zone NOT NULL,
    "active" bigint NOT NULL,
    "closing" bigint NOT NULL,
    "idle" bigint NOT NULL,
    "granularity" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_health_connection_info_timestamp_idx" ON "serverpod_health_connection_info" USING btree ("timestamp", "serverId", "granularity");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_health_metric" (
    "id" bigserial PRIMARY KEY,
    "name" text NOT NULL,
    "serverId" text NOT NULL,
    "timestamp" timestamp without time zone NOT NULL,
    "isHealthy" boolean NOT NULL,
    "value" double precision NOT NULL,
    "granularity" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_health_metric_timestamp_idx" ON "serverpod_health_metric" USING btree ("timestamp", "serverId", "name", "granularity");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_log" (
    "id" bigserial PRIMARY KEY,
    "sessionLogId" bigint NOT NULL,
    "messageId" bigint,
    "reference" text,
    "serverId" text NOT NULL,
    "time" timestamp without time zone NOT NULL,
    "logLevel" bigint NOT NULL,
    "message" text NOT NULL,
    "error" text,
    "stackTrace" text,
    "order" bigint NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_log_sessionLogId_idx" ON "serverpod_log" USING btree ("sessionLogId", "order");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_message_log" (
    "id" bigserial PRIMARY KEY,
    "sessionLogId" bigint NOT NULL,
    "serverId" text NOT NULL,
    "messageId" bigint NOT NULL,
    "endpoint" text NOT NULL,
    "messageName" text NOT NULL,
    "duration" double precision NOT NULL,
    "error" text,
    "stackTrace" text,
    "slow" boolean NOT NULL,
    "order" bigint NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_message_log_sessionLogId_idx" ON "serverpod_message_log" USING btree ("sessionLogId", "order");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_method" (
    "id" bigserial PRIMARY KEY,
    "endpoint" text NOT NULL,
    "method" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_method_endpoint_method_idx" ON "serverpod_method" USING btree ("endpoint", "method");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_migrations" (
    "id" bigserial PRIMARY KEY,
    "module" text NOT NULL,
    "version" text NOT NULL,
    "timestamp" timestamp without time zone
);

-- Indexes
CREATE UNIQUE INDEX "serverpod_migrations_ids" ON "serverpod_migrations" USING btree ("module");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_query_log" (
    "id" bigserial PRIMARY KEY,
    "serverId" text NOT NULL,
    "sessionLogId" bigint NOT NULL,
    "messageId" bigint,
    "query" text NOT NULL,
    "duration" double precision NOT NULL,
    "numRows" bigint,
    "error" text,
    "stackTrace" text,
    "slow" boolean NOT NULL,
    "order" bigint NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_query_log_sessionLogId_idx" ON "serverpod_query_log" USING btree ("sessionLogId", "order");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_readwrite_test" (
    "id" bigserial PRIMARY KEY,
    "number" bigint NOT NULL
);

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_runtime_settings" (
    "id" bigserial PRIMARY KEY,
    "logSettings" json NOT NULL,
    "logSettingsOverrides" json NOT NULL,
    "logServiceCalls" boolean NOT NULL,
    "logMalformedCalls" boolean NOT NULL
);

--
-- ACTION CREATE TABLE
--
CREATE TABLE "serverpod_session_log" (
    "id" bigserial PRIMARY KEY,
    "serverId" text NOT NULL,
    "time" timestamp without time zone NOT NULL,
    "module" text,
    "endpoint" text,
    "method" text,
    "duration" double precision,
    "numQueries" bigint,
    "slow" boolean,
    "error" text,
    "stackTrace" text,
    "authenticatedUserId" bigint,
    "userId" text,
    "isOpen" boolean,
    "touched" timestamp without time zone NOT NULL
);

-- Indexes
CREATE INDEX "serverpod_session_log_serverid_idx" ON "serverpod_session_log" USING btree ("serverId");
CREATE INDEX "serverpod_session_log_time_idx" ON "serverpod_session_log" USING btree ("time");
CREATE INDEX "serverpod_session_log_touched_idx" ON "serverpod_session_log" USING btree ("touched");
CREATE INDEX "serverpod_session_log_isopen_idx" ON "serverpod_session_log" USING btree ("isOpen");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "crdt_data_attempted_value" (
    "id" bigserial PRIMARY KEY,
    "fieldId" bigint NOT NULL,
    "value" jsonb NOT NULL,
    "projectionReason" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "crdt_data_attempted_value__fieldId__unique_idx" ON "crdt_data_attempted_value" USING btree ("fieldId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "crdt_data_fields" (
    "id" bigserial PRIMARY KEY,
    "hlcDatetime" timestamp without time zone NOT NULL,
    "hlcCounter" bigint NOT NULL,
    "rowId" bigint NOT NULL,
    "columnId" bigint NOT NULL,
    "nodeId" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "crdt_data_fields_row_column_idx" ON "crdt_data_fields" USING btree ("rowId", "columnId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "crdt_data_rows" (
    "id" bigserial PRIMARY KEY,
    "hlcDatetime" timestamp without time zone NOT NULL,
    "hlcCounter" bigint NOT NULL,
    "spaceId" bigint NOT NULL,
    "tblId" bigint NOT NULL,
    "uuidRowId" uuid NOT NULL,
    "nodeId" bigint NOT NULL,
    "visibility" bigint NOT NULL DEFAULT 0
);

-- Indexes
CREATE UNIQUE INDEX "crdt_data_rows_space_tbl_row_idx" ON "crdt_data_rows" USING btree ("spaceId", "tblId", "uuidRowId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "crdt_data_tombstone" (
    "id" bigserial PRIMARY KEY,
    "hlcDatetime" timestamp without time zone NOT NULL,
    "hlcCounter" bigint NOT NULL,
    "rowId" bigint NOT NULL,
    "nodeId" bigint NOT NULL,
    "clFlag" bigint NOT NULL,
    "reason" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "crdt_data_tombstone_row_idx" ON "crdt_data_tombstone" USING btree ("rowId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "crdt_nodes" (
    "id" bigserial PRIMARY KEY,
    "uuidNodeId" uuid NOT NULL DEFAULT gen_random_uuid_v7(),
    "lastHlc" jsonb
);

-- Indexes
CREATE UNIQUE INDEX "crdt_nodes__uuidNodeId__unique_idx" ON "crdt_nodes" USING btree ("uuidNodeId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "crdt_schema_columns" (
    "id" bigserial PRIMARY KEY,
    "tblId" bigint NOT NULL,
    "name" text NOT NULL,
    "columnType" text NOT NULL,
    "dartType" text NOT NULL,
    "isNullable" boolean NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "crdt_schema_columns_table_column_idx" ON "crdt_schema_columns" USING btree ("tblId", "name");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "crdt_schema_tables" (
    "id" bigserial PRIMARY KEY,
    "name" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "crdt_schema_tables__name__unique_idx" ON "crdt_schema_tables" USING btree ("name");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "offline_sync_integrity_violations" (
    "id" bigserial PRIMARY KEY,
    "type" text NOT NULL,
    "domainTableName" text NOT NULL,
    "uuidRowId" uuid NOT NULL,
    "ownerSpaceUuid" uuid,
    "incomingSpaceUuid" uuid NOT NULL,
    "operation" text NOT NULL,
    "uuidNodeId" uuid,
    "crdtDataRowId" bigint,
    "hlcDatetime" timestamp without time zone,
    "hlcCounter" bigint,
    "firstSeenAt" timestamp without time zone NOT NULL,
    "lastSeenAt" timestamp without time zone NOT NULL,
    "occurrences" bigint NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "offline_sync_integrity_violations_key_idx" ON "offline_sync_integrity_violations" USING btree ("type", "operation", "domainTableName", "uuidRowId", "ownerSpaceUuid", "incomingSpaceUuid");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "offline_sync_space_members" (
    "id" bigserial PRIMARY KEY,
    "spaceId" bigint NOT NULL,
    "userUuid" uuid NOT NULL,
    "role" text NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "offline_sync_space_member_unique_idx" ON "offline_sync_space_members" USING btree ("userUuid", "spaceId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "offline_sync_space_nodes" (
    "id" bigserial PRIMARY KEY,
    "spaceId" bigint NOT NULL,
    "nodeId" bigint NOT NULL,
    "lastReceivedHlc" jsonb
);

-- Indexes
CREATE UNIQUE INDEX "offline_sync_space_node_unique_idx" ON "offline_sync_space_nodes" USING btree ("spaceId", "nodeId");

--
-- ACTION CREATE TABLE
--
CREATE TABLE "offline_sync_spaces" (
    "id" bigserial PRIMARY KEY,
    "uuidSpaceId" uuid NOT NULL DEFAULT gen_random_uuid_v7(),
    "currentNodeId" bigint
);

-- Indexes
CREATE UNIQUE INDEX "offline_sync_spaces__uuidSpaceId__unique_idx" ON "offline_sync_spaces" USING btree ("uuidSpaceId");

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "folder"
    ADD CONSTRAINT "folder_fk_0"
    FOREIGN KEY("spaceId")
    REFERENCES "offline_sync_spaces"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "note"
    ADD CONSTRAINT "note_fk_0"
    FOREIGN KEY("spaceId")
    REFERENCES "offline_sync_spaces"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "note"
    ADD CONSTRAINT "note_fk_1"
    FOREIGN KEY("folderId")
    REFERENCES "folder"("id")
    ON DELETE SET NULL
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "serverpod_future_call_claim"
    ADD CONSTRAINT "serverpod_future_call_claim_fk_0"
    FOREIGN KEY("futureCallId")
    REFERENCES "serverpod_future_call"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "serverpod_log"
    ADD CONSTRAINT "serverpod_log_fk_0"
    FOREIGN KEY("sessionLogId")
    REFERENCES "serverpod_session_log"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "serverpod_message_log"
    ADD CONSTRAINT "serverpod_message_log_fk_0"
    FOREIGN KEY("sessionLogId")
    REFERENCES "serverpod_session_log"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "serverpod_query_log"
    ADD CONSTRAINT "serverpod_query_log_fk_0"
    FOREIGN KEY("sessionLogId")
    REFERENCES "serverpod_session_log"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "crdt_data_attempted_value"
    ADD CONSTRAINT "crdt_data_attempted_value_fk_0"
    FOREIGN KEY("fieldId")
    REFERENCES "crdt_data_fields"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "crdt_data_fields"
    ADD CONSTRAINT "crdt_data_fields_fk_0"
    FOREIGN KEY("rowId")
    REFERENCES "crdt_data_rows"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "crdt_data_fields"
    ADD CONSTRAINT "crdt_data_fields_fk_1"
    FOREIGN KEY("columnId")
    REFERENCES "crdt_schema_columns"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "crdt_data_fields"
    ADD CONSTRAINT "crdt_data_fields_fk_2"
    FOREIGN KEY("nodeId")
    REFERENCES "crdt_nodes"("id")
    ON DELETE NO ACTION
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "crdt_data_rows"
    ADD CONSTRAINT "crdt_data_rows_fk_0"
    FOREIGN KEY("spaceId")
    REFERENCES "offline_sync_spaces"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "crdt_data_rows"
    ADD CONSTRAINT "crdt_data_rows_fk_1"
    FOREIGN KEY("tblId")
    REFERENCES "crdt_schema_tables"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "crdt_data_rows"
    ADD CONSTRAINT "crdt_data_rows_fk_2"
    FOREIGN KEY("nodeId")
    REFERENCES "crdt_nodes"("id")
    ON DELETE NO ACTION
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "crdt_data_tombstone"
    ADD CONSTRAINT "crdt_data_tombstone_fk_0"
    FOREIGN KEY("rowId")
    REFERENCES "crdt_data_rows"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "crdt_data_tombstone"
    ADD CONSTRAINT "crdt_data_tombstone_fk_1"
    FOREIGN KEY("nodeId")
    REFERENCES "crdt_nodes"("id")
    ON DELETE NO ACTION
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "crdt_schema_columns"
    ADD CONSTRAINT "crdt_schema_columns_fk_0"
    FOREIGN KEY("tblId")
    REFERENCES "crdt_schema_tables"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "offline_sync_space_members"
    ADD CONSTRAINT "offline_sync_space_members_fk_0"
    FOREIGN KEY("spaceId")
    REFERENCES "offline_sync_spaces"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "offline_sync_space_nodes"
    ADD CONSTRAINT "offline_sync_space_nodes_fk_0"
    FOREIGN KEY("spaceId")
    REFERENCES "offline_sync_spaces"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "offline_sync_space_nodes"
    ADD CONSTRAINT "offline_sync_space_nodes_fk_1"
    FOREIGN KEY("nodeId")
    REFERENCES "crdt_nodes"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "offline_sync_spaces"
    ADD CONSTRAINT "offline_sync_spaces_fk_0"
    FOREIGN KEY("currentNodeId")
    REFERENCES "crdt_nodes"("id")
    ON DELETE NO ACTION
    ON UPDATE NO ACTION;


--
-- MIGRATION VERSION FOR offline_sync_watch_test
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('offline_sync_watch_test', '20260923070851093', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260923070851093', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod', '20260824182259319', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260824182259319', "timestamp" = now();

--
-- MIGRATION VERSION FOR serverpod_offline_sync
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('serverpod_offline_sync', '20260914143806119', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260914143806119', "timestamp" = now();


COMMIT;
