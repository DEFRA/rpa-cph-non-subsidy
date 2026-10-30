using Microsoft.Extensions.Options;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Models
{
    public class User : IUser
    {
        private readonly IHttpContextAccessor httpContextAccessor;
        private readonly AuditIdentityOptions options;

        public User(IHttpContextAccessor httpContextAccessor, IOptions<AuditIdentityOptions> options)
        {
            this.httpContextAccessor = httpContextAccessor;
            this.options = options.Value;
        }

        // Use the configured Entra ID claim for audit attribution rather than assuming Identity.Name.
        // AuditIdentity validates the claim and preserves legacy username formatting; roles are handled elsewhere.
        public string Name
        {
            get
            {
                return AuditIdentity.GetName(httpContextAccessor.HttpContext?.User, options.AuditNameClaimType);
            }
        }
    }
}
