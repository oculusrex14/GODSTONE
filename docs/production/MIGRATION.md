# Migration policy

The Archive-only initial application keeps one identity on each platform. No tier suffix is permitted. Future database changes require fixture-based migrations from every supported version, crash interruption at each step, identity/history preservation, corruption behavior, and rollback policy. The current legacy Mesh store is nonshipping and must not be migrated into production as-is.
