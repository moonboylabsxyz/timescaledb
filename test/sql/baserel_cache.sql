-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Test that the baserel cache is not clobbered if there's an error
-- in a SQL function.
CREATE TABLE valid_ids
(
  id UUID PRIMARY KEY
);

CREATE FUNCTION DEFAULT_UUID(TEXT DEFAULT '') RETURNS UUID AS $$
  BEGIN
    RETURN COALESCE($1, '')::UUID;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN '00000000-0000-0000-0000-000000000000';
  END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE FUNCTION KNOWN_ID(UUID, TEXT) RETURNS UUID AS $$
  SELECT COALESCE(
    (SELECT id FROM valid_ids WHERE id = $1),
    DEFAULT_UUID()
  );
$$ LANGUAGE SQL;

SELECT KNOWN_ID(NULL, ''), KNOWN_ID(NULL, '');
