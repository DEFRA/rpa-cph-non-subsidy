using System.Security.Claims;

namespace RPA.CPH.NonSubsidy.Web.Services;

/// <summary>
/// Configures which claim supplies the audit username after the move to Entra ID.
/// </summary>
public sealed class AuditIdentityOptions
{
    /// <summary>
    /// The required claim type on the authenticated principal. Choose a claim whose value
    /// matches the application's audit identity contract; Identity.Name is not used as a fallback.
    /// </summary>
    public string AuditNameClaimType { get; set; }
}

/// <summary>
/// Converts an authenticated user's configured claim into the username stored in audit records.
/// Authentication and role authorization are handled elsewhere; this class does not validate tokens
/// or grant access.
/// </summary>
public static class AuditIdentity
{
    /// <summary>
    /// Requires exactly one nonempty claim of the configured type and applies the legacy
    /// username formatting: lowercase, remove "earth\", and replace "m0" with "m".
    /// These transformations preserve existing audit behavior; they do not map Entra identities
    /// to legacy directory accounts.
    /// </summary>
    /// <param name="principal">The current request's principal, populated by authentication.</param>
    /// <param name="claimType">The explicitly configured audit-name claim type.</param>
    /// <returns>The normalized audit username.</returns>
    /// <exception cref="InvalidOperationException">
    /// The claim type is missing, the principal is unauthenticated, the claim is missing,
    /// duplicated or blank, or normalization produces a blank name. No fallback identity is recorded.
    /// </exception>
    public static string GetName(ClaimsPrincipal principal, string claimType)
    {
        if (string.IsNullOrWhiteSpace(claimType))
            throw new InvalidOperationException("An explicit audit-name claim type is required.");
        
        var claims = principal?.FindAll(claimType).ToArray() ?? [];
        
        if (principal?.Identity?.IsAuthenticated != true || claims.Length != 1 ||
            string.IsNullOrWhiteSpace(claims[0].Value))
        {
            throw new InvalidOperationException("The authenticated user must have exactly one nonempty configured audit-name claim.");
        }

        var name = claims[0].Value.ToLower().Replace("earth\\", "").Replace("m0", "m");
        
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new InvalidOperationException("The configured audit-name claim does not produce a valid audit name.");
        }

        return name;
    }
}
