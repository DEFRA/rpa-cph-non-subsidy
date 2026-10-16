using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using System.Data.SqlClient;
using Microsoft.Extensions.Caching.Memory;

namespace RPA.CPH.NonSubsidy.Web.Services
{
    // Replacement for IDT.Web.Security.RoleProvider: loads the user's roles from the IDT security
    // database (standard ASP.NET SqlRoleProvider schema) and exposes them as role claims.
    public class IdtRoleClaimsTransformation : IClaimsTransformation
    {
        private const string ApplicationName = "/";
        private const string RolesLoadedClaimType = "urn:rpa:cph:idt-roles-loaded";
        private static readonly TimeSpan CacheDuration = TimeSpan.FromMinutes(5);

        private readonly string connectionString;
        private readonly IMemoryCache cache;
        private readonly ILogger<IdtRoleClaimsTransformation> logger;

        public IdtRoleClaimsTransformation(IConfiguration configuration, IMemoryCache cache, ILogger<IdtRoleClaimsTransformation> logger)
        {
            this.connectionString = configuration.GetConnectionString("IDTSecurityConnection");
            this.cache = cache;
            this.logger = logger;
        }

        public async Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
        {
            if (principal.Identity is not ClaimsIdentity identity || !identity.IsAuthenticated || string.IsNullOrEmpty(identity.Name))
            {
                return principal;
            }

            if (identity.HasClaim(c => c.Type == RolesLoadedClaimType))
            {
                return principal;
            }

            var roles = await cache.GetOrCreateAsync("idt-roles:" + identity.Name.ToLowerInvariant(), async entry =>
            {
                entry.AbsoluteExpirationRelativeToNow = CacheDuration;
                return await GetRolesForUserAsync(identity.Name);
            });

            // A WindowsPrincipal only evaluates Windows groups in IsInRole, so build a plain principal
            // that carries the original claims plus the IDT role claims.
            var transformed = new ClaimsIdentity(identity.Claims, identity.AuthenticationType, ClaimTypes.Name, ClaimTypes.Role);
            transformed.AddClaim(new Claim(RolesLoadedClaimType, "true"));

            foreach (var role in roles)
            {
                transformed.AddClaim(new Claim(ClaimTypes.Role, role));
            }

            return new ClaimsPrincipal(transformed);
        }

        private async Task<IReadOnlyList<string>> GetRolesForUserAsync(string userName)
        {
            var roles = new List<string>();

            if (string.IsNullOrEmpty(connectionString))
            {
                logger.LogWarning("Connection string 'IDTSecurityConnection' is not configured; no roles will be assigned.");
                return roles;
            }

            await using var connection = new SqlConnection(connectionString);
            await using var command = new SqlCommand("dbo.aspnet_UsersInRoles_GetRolesForUser", connection)
            {
                CommandType = System.Data.CommandType.StoredProcedure
            };

            command.Parameters.AddWithValue("@ApplicationName", ApplicationName);
            command.Parameters.AddWithValue("@UserName", userName);

            await connection.OpenAsync();

            await using var reader = await command.ExecuteReaderAsync();

            while (await reader.ReadAsync())
            {
                roles.Add(reader.GetString(0));
            }

            return roles;
        }
    }
}


