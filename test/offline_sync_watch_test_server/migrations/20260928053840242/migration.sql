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
CREATE TABLE "stroke" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7(),
    "spaceId" bigint,
    "seq" text NOT NULL,
    "legacyId" text,
    "payload" bytea NOT NULL,
    "noteId" uuid NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX "stroke_note_seq_idx" ON "stroke" USING btree ("spaceId", "noteId", "seq");

--
-- ACTION CREATE FOREIGN KEY
--
ALTER TABLE ONLY "stroke"
    ADD CONSTRAINT "stroke_fk_0"
    FOREIGN KEY("spaceId")
    REFERENCES "offline_sync_spaces"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION;
ALTER TABLE ONLY "stroke"
    ADD CONSTRAINT "stroke_fk_1"
    FOREIGN KEY("noteId")
    REFERENCES "note"("id")
    ON DELETE CASCADE
    ON UPDATE NO ACTION
    DEFERRABLE INITIALLY DEFERRED;


--
-- MIGRATION VERSION FOR offline_sync_watch_test
--
INSERT INTO "serverpod_migrations" ("module", "version", "timestamp")
    VALUES ('offline_sync_watch_test', '20260928053840242', now())
    ON CONFLICT ("module")
    DO UPDATE SET "version" = '20260928053840242', "timestamp" = now();

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
