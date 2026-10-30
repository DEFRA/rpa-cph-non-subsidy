using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Identity.Web;
using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;
using RPA.CPH.NonSubsidy.Web.Models;

namespace RPA.CPH.NonSubsidy.Web.Services;

public static class ApplicationServices
{
    public const string BasicAccessPolicy = "CPH Non Subsidy: Basic Access";

    public static IServiceCollection AddCphApplication(this IServiceCollection services, IConfiguration configuration,
        IHostEnvironment environment = null)
    {
        var settings = ValidateConfiguration(configuration, environment);

        services.Configure<AuditIdentityOptions>(options => options.AuditNameClaimType = settings.AuditClaim);
        services.AddCphDataProtection(configuration);

        AddIdentity(services, configuration, settings.TenantId, settings.Role, settings.AuditClaim);
        
        services.AddCphForwarding(configuration);
        services.AddHttpsRedirection(options => options.HttpsPort = settings.HttpsPort);
        services.AddHttpContextAccessor();
        services.AddScoped<IUser, User>();
        
        AddDatabase(services, settings.ConnectionString);

        services.AddRazorPages(options =>
        {
            options.Conventions.AddPageRoute("/Index", "");
            options.Conventions.AddPageRoute("/Index", "Home");
            options.Conventions.AddPageRoute("/Error", "Error/Index/{id?}");
        });

        services.AddCphApplicationInsights(configuration);
        
        return services;
    }

    private static (Guid TenantId, string Role, string AuditClaim, string ConnectionString, int HttpsPort) 
        ValidateConfiguration(IConfiguration configuration, IHostEnvironment environment)
    {
        var tenant = Required(configuration, "AzureAd:TenantId");
        
        if (!Guid.TryParse(tenant, out var tenantId) || tenantId == Guid.Empty)
            throw new InvalidOperationException("AzureAd:TenantId must identify the configured tenant, not a shared or wildcard authority.");
        
        if (!Guid.TryParse(Required(configuration, "AzureAd:ClientId"), out var clientId) || clientId == Guid.Empty)
            throw new InvalidOperationException("AzureAd:ClientId must be an application registration ID.");
        
        if (!Uri.TryCreate(Required(configuration, "AzureAd:Instance"), UriKind.Absolute, out var instance) ||
            instance.Scheme != Uri.UriSchemeHttps || !string.IsNullOrEmpty(instance.UserInfo) ||
            !string.IsNullOrEmpty(instance.Query) || !string.IsNullOrEmpty(instance.Fragment))
            throw new InvalidOperationException("AzureAd:Instance must be the externally approved HTTPS identity authority.");
        
        // Supplied by ACA's Key Vault reference in production or the local launcher in development.
        Required(configuration, "AzureAd:ClientSecret");

        var role = Required(configuration, "Authorization:BasicAccessRole");
        
        if (role.Length > 120 || role.Any(c => !IsAppRoleCharacter(c)) || role[0] == '.')
            throw new InvalidOperationException("Authorization:BasicAccessRole must be an Entra app-role token value, not its display name.");
        
        var auditClaim = Required(configuration, "Identity:AuditNameClaimType");
        
        if (auditClaim.Any(char.IsWhiteSpace))
            throw new InvalidOperationException("Identity:AuditNameClaimType must be an explicit claim type without whitespace.");

        var connectionString = Required(configuration, "ConnectionStrings:CPHContext");
        ValidateSqlConnection(connectionString, environment);
        
        var allowedHosts = Required(configuration, "AllowedHosts").Split(';');
        if (allowedHosts.Any(host => host.Contains('*') || Uri.CheckHostName(host) == UriHostNameType.Unknown))
            throw new InvalidOperationException("AllowedHosts must contain explicit hostnames separated by semicolons, without wildcards, schemes, paths, ports or empty entries.");
        
        if (!int.TryParse(configuration["HttpsRedirection:HttpsPort"] ?? "443", out var httpsPort) ||
            httpsPort is < 1 or > 65535)
            throw new InvalidOperationException("HttpsRedirection:HttpsPort must be a valid HTTPS port.");

        return (tenantId, role, auditClaim, connectionString, httpsPort);
    }

    private static void AddIdentity(IServiceCollection services, IConfiguration configuration,
        Guid tenantId, string role, string auditClaim)
    {
        services.AddAuthentication(options =>
        {
            options.DefaultAuthenticateScheme = CookieAuthenticationDefaults.AuthenticationScheme;
            options.DefaultSignInScheme = CookieAuthenticationDefaults.AuthenticationScheme;
            options.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;
            options.DefaultForbidScheme = CookieAuthenticationDefaults.AuthenticationScheme;
        })
        .AddMicrosoftIdentityWebApp(configuration.GetSection("AzureAd"));

        services.Configure<OpenIdConnectOptions>(OpenIdConnectDefaults.AuthenticationScheme, options =>
        {
            // Sign-in-only SDK registration defaults to id_token; keep authorization code flow.
            options.ResponseType = Microsoft.IdentityModel.Protocols.OpenIdConnect.OpenIdConnectResponseType.Code;
            options.MapInboundClaims = false;
            // MIW replaces the handler independently of the OIDC claim-mapping setter.
            if (options.TokenHandler is Microsoft.IdentityModel.JsonWebTokens.JsonWebTokenHandler tokenHandler)
                tokenHandler.MapInboundClaims = false;
            options.TokenValidationParameters.RoleClaimType = "roles";
            options.TokenValidationParameters.NameClaimType = auditClaim;
            
            var previous = options.Events.OnTokenValidated;
            options.Events.OnTokenValidated = async context =>
            {
                if (previous != null) await previous(context);
                if (context.Result?.Failure != null) return;
                var tenants = context.Principal?.FindAll("tid").ToArray() ?? [];
                if (tenants.Length != 1 || !Guid.TryParse(tenants[0].Value, out var actualTenant) || actualTenant != tenantId)
                {
                    LogAuthenticationFailure(context.HttpContext, "TENANT_CONTRACT_REJECTED");
                    context.Fail("The identity does not belong to the configured tenant.");
                    return;
                }

                try
                {
                    AuditIdentity.GetName(context.Principal, auditClaim);
                }
                catch (InvalidOperationException)
                {
                    LogAuthenticationFailure(context.HttpContext, "AUDIT_CONTRACT_REJECTED");
                    context.Fail("The identity is missing its required audit-name contract.");
                }
            };
            
            var previousRemoteFailure = options.Events.OnRemoteFailure;
            options.Events.OnRemoteFailure = async context =>
            {
                LogAuthenticationFailure(context.HttpContext, "OIDC_REMOTE_FAILURE");
                if (previousRemoteFailure != null) await previousRemoteFailure(context);
                if (context.Result?.Handled == true || context.Result?.Skipped == true) return;
                context.HandleResponse();
                context.Response.Redirect("/Account/AuthenticationFailed");
            };
        });
        
        services.Configure<CookieAuthenticationOptions>(CookieAuthenticationDefaults.AuthenticationScheme, options =>
        {
            options.Cookie.Name = "__Host-Cph.Auth";
            options.Cookie.HttpOnly = true;
            options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
            options.Cookie.SameSite = SameSiteMode.Lax;
            options.Cookie.Path = "/";
            options.AccessDeniedPath = "/Account/AccessDenied";
            options.ExpireTimeSpan = TimeSpan.FromMinutes(30);
            options.SlidingExpiration = true;
        });
        
        services.AddAuthorization(options =>
        {
            options.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
            options.AddPolicy(BasicAccessPolicy, policy => policy.RequireAuthenticatedUser().RequireRole(role));
        });
    }

    private static void AddDatabase(IServiceCollection services, string connectionString)
    {
        services.AddDbContext<CPHContext>(options => options.UseSqlServer(connectionString));
        services.AddScoped<IUnitOfWork, UnitOfWork>();
        services.AddHealthChecks().AddCheck<SqlReadinessHealthCheck>("sql", tags: ["ready"]);
    }

    private static void LogAuthenticationFailure(HttpContext context, string failureCode) =>
        context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("RPA.CPH.NonSubsidy.Web.Authentication")
            .LogWarning(new EventId(1001, "AuthenticationRejected"),
                "Authentication rejected. FailureCode: {FailureCode}", failureCode);

    private static string Required(IConfiguration configuration, string key) =>
        !string.IsNullOrWhiteSpace(configuration[key]) ? configuration[key] :
            throw new InvalidOperationException($"Required external configuration '{key}' is missing.");

    private static bool IsAppRoleCharacter(char c) =>
        char.IsAsciiLetterOrDigit(c) || ".-_!#$%&'()*+,/:;<=>?@[]^`{|}~".Contains(c);

    private static void ValidateSqlConnection(string connectionString, IHostEnvironment environment)
    {
        SqlConnectionStringBuilder sql;
        
        try 
        { 
            sql = new SqlConnectionStringBuilder(connectionString); 
        }
        catch (ArgumentException)
        {
            throw new InvalidOperationException("ConnectionStrings:CPHContext is not a valid Microsoft.Data.SqlClient connection string.");
        }
    }
}
