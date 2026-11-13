-- Shared server registry. Main.server.luau fills it before calling init(S) on each service.
-- Access other services ONLY through this table (no cross-requires between services).
return {} :: { [string]: any }
