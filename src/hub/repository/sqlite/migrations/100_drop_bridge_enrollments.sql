-- bridge_enrollments (002) was never read or written by any hub code: enrollment
-- state lives on bridges (088) and in the vault device directory (092+). Drop it and
-- its owner trigger. No backward compatibility.
DROP TRIGGER IF EXISTS bridge_enrollments_owner_immutable;
DROP TABLE IF EXISTS bridge_enrollments;
