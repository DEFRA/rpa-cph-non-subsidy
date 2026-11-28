-- Grants the App Service runtime identity least-privilege access to the CPH database.
-- Run by the DBA as the Entra SQL administrator, connected to the application database
-- (not master), through the private endpoint. Replace <runtime-identity-name> with the
-- user-assigned identity name from the foundation output (managedIdentityResourceId).
-- No schema is created here: apply the approved schema separately.
-- Confirm the exact CRUD needs with the application owner before production use.

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'<runtime-identity-name>')
    CREATE USER [<runtime-identity-name>] FROM EXTERNAL PROVIDER;
GO

-- Business data: read and maintain customers, addresses, land, parcels and cases.
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[CPH] TO [<runtime-identity-name>];
-- Audit trail: the app updates the shared-key Audit row (last user/time) on every customer save, so UPDATE is
-- required alongside SELECT and INSERT. DELETE is deliberately not granted.
GRANT SELECT, INSERT, UPDATE ON SCHEMA::[Audit] TO [<runtime-identity-name>];
GO
