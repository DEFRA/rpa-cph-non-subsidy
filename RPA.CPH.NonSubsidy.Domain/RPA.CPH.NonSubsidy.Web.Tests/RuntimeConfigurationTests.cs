using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using RPA.CPH.NonSubsidy.Web.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Logging;
using Microsoft.EntityFrameworkCore;
using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
[TestCategory("Unit")]
public class RuntimeConfigurationTests
{
    internal static Dictionary<string, string> Settings() => new()
    {
        ["AzureAd:Instance"] = "https://login.microsoftonline.com/",
        ["AzureAd:TenantId"] = "11111111-1111-1111-1111-111111111111",
        ["AzureAd:ClientId"] = "22222222-2222-2222-2222-222222222222",
        ["AzureAd:ClientSecret"] = "offline-test-only-not-a-real-credential",
        ["Authorization:BasicAccessRole"] = "Test.BasicAccess",
        ["Identity:AuditNameClaimType"] = "test_audit_name",
        ["AllowedHosts"] = "localhost",
        ["ConnectionStrings:CPHContext"] = "Server=unused.invalid;Database=OfflineTests;Authentication=Active Directory Managed Identity;Encrypt=Mandatory;TrustServerCertificate=False"
    };

    internal static IConfiguration Configuration(Dictionary<string, string> settings = null) =>
        new ConfigurationBuilder().AddInMemoryCollection(settings ?? Settings()).Build();

    [TestMethod]
    public void DatabaseRegistration_IsScopedSqlServerAndDoesNotAccessSchemaOrOpenConnection()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCphApplication(Configuration());
        using var provider = services.BuildServiceProvider();
        using var first = provider.CreateScope();
        var context = first.ServiceProvider.GetRequiredService<CPHContext>();
        var work = first.ServiceProvider.GetRequiredService<IUnitOfWork>();
        Assert.AreSame(work, first.ServiceProvider.GetRequiredService<IUnitOfWork>());
        var customer = new Customer { SBI = 105000001, BusinessName = "Unsaved" };
        work.CustomerRepository.Create(customer);
        Assert.AreEqual(EntityState.Added, context.Entry(customer).State, "Repository and DI must share the same context.");
        Assert.AreEqual("Microsoft.EntityFrameworkCore.SqlServer", context.Database.ProviderName);
        Assert.AreEqual(System.Data.ConnectionState.Closed, context.Database.GetDbConnection().State);
        using var second = provider.CreateScope();
        Assert.AreNotSame(context, second.ServiceProvider.GetRequiredService<CPHContext>());
        Assert.AreEqual(0, second.ServiceProvider.GetRequiredService<CPHContext>().ChangeTracker.Entries().Count());
    }

    [TestMethod]
    [DataRow("AzureAd:TenantId")]
    [DataRow("AzureAd:ClientId")]
    [DataRow("Authorization:BasicAccessRole")]
    [DataRow("Identity:AuditNameClaimType")]
    [DataRow("ConnectionStrings:CPHContext")]
    [DataRow("AzureAd:ClientSecret")]
    [DataRow("AllowedHosts")]
    public void MissingRequiredConfiguration_FailsWithoutValues(string key)
    {
        var settings = Settings();
        settings.Remove(key);
        var exception = Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(Configuration(settings)));
        StringAssert.Contains(exception.Message, key);
        Assert.IsFalse(exception.ToString().Contains("unused.invalid"));
    }

    [TestMethod]
    [DataRow("common")]
    [DataRow("organizations")]
    [DataRow("consumers")]
    [DataRow("*")]
    public void NonSpecificTenant_IsRejected(string tenant)
    {
        var settings = Settings();
        settings["AzureAd:TenantId"] = tenant;
        Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(Configuration(settings)));
    }

    [TestMethod]
    [DataRow("")]
    [DataRow(" ")]
    [DataRow("*")]
    [DataRow("*.example.invalid")]
    [DataRow("localhost;*")]
    [DataRow("https://app.example.invalid")]
    [DataRow("app.example.invalid/path")]
    [DataRow("localhost:7143")]
    [DataRow("localhost,app.example.invalid")]
    [DataRow("localhost;")]
    [DataRow(";")]
    [DataRow("localhost; app.example.invalid")]
    public void InvalidAllowedHosts_FailsAtStartup(string hosts)
    {
        var settings = Settings();
        settings["AllowedHosts"] = hosts;
        var error = Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(Configuration(settings)));
        StringAssert.Contains(error.Message, "AllowedHosts");
    }

    [TestMethod]
    [DataRow("localhost")]
    [DataRow("app.example.invalid")]
    [DataRow("localhost;app.example.invalid")]
    [DataRow("127.0.0.1;localhost")]
    public void ExplicitAllowedHosts_AreAccepted(string hosts)
    {
        var settings = Settings();
        settings["AllowedHosts"] = hosts;
        new ServiceCollection().AddCphApplication(Configuration(settings));
    }

    [TestMethod]
    public void RoleDisplayName_IsNotAnAppRoleValue()
    {
        var settings = Settings();
        settings["Authorization:BasicAccessRole"] = "CPH Non Subsidy: Basic Access";
        Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(Configuration(settings)));
    }

    [TestMethod]
    [DataRow("")]
    [DataRow(" ")]
    [DataRow("\t")]
    public void BlankClientSecret_FailsWithConfigurationKeyOnly(string secret)
    {
        var settings = Settings();
        settings["AzureAd:ClientSecret"] = secret;
        var error = Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(Configuration(settings)));
        Assert.AreEqual("Required external configuration 'AzureAd:ClientSecret' is missing.", error.Message);
    }

    [TestMethod]
    public void AlternativeCredentials_DoNotReplaceRequiredClientSecret()
    {
        var settings = Settings();
        settings.Remove("AzureAd:ClientSecret");
        settings["AzureAd:ClientCredentials:0:SourceType"] = "SignedAssertionFromManagedIdentity";
        var error = Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(Configuration(settings)));
        StringAssert.Contains(error.Message, "AzureAd:ClientSecret");
    }

    [TestMethod]
    [DataRow("Test.BasicAccess", true)]
    [DataRow("test.basicaccess", false)]
    [DataRow("Other.Role", false)]
    [DataRow("CPH Non Subsidy: Basic Access", false)]
    [DataRow("", false)]
    public async Task Policy_RequiresExactConfiguredTokenRole(string role, bool allowed)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCphApplication(Configuration());
        using var provider = services.BuildServiceProvider();
        var principal = new ClaimsPrincipal(new ClaimsIdentity(
            string.IsNullOrEmpty(role) ? [] : [new Claim("roles", role)], "test", "name", "roles"));
        var result = await provider.GetRequiredService<IAuthorizationService>()
            .AuthorizeAsync(principal, null, ApplicationServices.BasicAccessPolicy);
        Assert.AreEqual(allowed, result.Succeeded);
    }

    [TestMethod]
    public void AuditName_UsesOnlyConfiguredClaimAndPreservesLegacyNormalization()
    {
        var principal = new ClaimsPrincipal(new ClaimsIdentity(
            [new Claim("test_audit_name", @"EARTH\M01234"), new Claim("name", "untrusted fallback")], "test"));
        Assert.AreEqual("m1234", AuditIdentity.GetName(principal, "test_audit_name"));
        Assert.ThrowsExactly<InvalidOperationException>(() => AuditIdentity.GetName(principal, "missing"));
        principal.Identities.First().AddClaim(new Claim("test_audit_name", "second"));
        Assert.ThrowsExactly<InvalidOperationException>(() => AuditIdentity.GetName(principal, "test_audit_name"));
    }

    [TestMethod]
    public void Options_UseSecureCookieAndRealRolesClaim()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        var configuration = Configuration();
        services.AddSingleton(configuration);
        services.AddCphApplication(configuration);
        using var provider = services.BuildServiceProvider();
        Assert.IsNull(provider.GetService<Microsoft.Identity.Web.ITokenAcquisition>(),
            "Sign-in and app-role authorization must not register downstream token acquisition.");
        var oidc = provider.GetRequiredService<IOptionsMonitor<OpenIdConnectOptions>>()
            .Get(OpenIdConnectDefaults.AuthenticationScheme);
        Assert.AreEqual(configuration["AzureAd:ClientSecret"], oidc.ClientSecret);
        Assert.AreEqual(Microsoft.IdentityModel.Protocols.OpenIdConnect.OpenIdConnectResponseType.Code, oidc.ResponseType);
        Assert.IsTrue(oidc.UsePkce);
        Assert.IsTrue(oidc.RequireHttpsMetadata);
        Assert.IsFalse(oidc.SaveTokens);
        Assert.IsFalse(oidc.GetClaimsFromUserInfoEndpoint);
        Assert.IsFalse(oidc.MapInboundClaims);
        Assert.IsInstanceOfType<Microsoft.IdentityModel.JsonWebTokens.JsonWebTokenHandler>(oidc.TokenHandler);
        Assert.IsFalse(((Microsoft.IdentityModel.JsonWebTokens.JsonWebTokenHandler)oidc.TokenHandler).MapInboundClaims);
        Assert.AreEqual("roles", oidc.TokenValidationParameters.RoleClaimType);
        Assert.AreEqual(configuration["Identity:AuditNameClaimType"], oidc.TokenValidationParameters.NameClaimType);
        Assert.IsTrue(oidc.TokenValidationParameters.ValidateIssuer);
        Assert.IsFalse(oidc.UseTokenLifetime);
        var cookie = provider.GetRequiredService<IOptionsMonitor<CookieAuthenticationOptions>>()
            .Get(CookieAuthenticationDefaults.AuthenticationScheme);
        Assert.AreEqual(Microsoft.AspNetCore.Http.CookieSecurePolicy.Always, cookie.Cookie.SecurePolicy);
        Assert.IsTrue(cookie.Cookie.HttpOnly);
        Assert.IsTrue(cookie.SlidingExpiration);
        Assert.AreEqual(TimeSpan.FromMinutes(30), cookie.ExpireTimeSpan);
    }

    private sealed record CapturedLog(LogLevel Level, EventId Event, string Message, Exception Exception,
        KeyValuePair<string, object>[] State);

    private sealed class CaptureLoggerProvider : ILoggerProvider
    {
        public List<CapturedLog> Entries { get; } = [];
        public ILogger CreateLogger(string categoryName) => new CaptureLogger(Entries);
        public void Dispose() { }

        private sealed class CaptureLogger(List<CapturedLog> entries) : ILogger
        {
            public IDisposable BeginScope<TState>(TState state) where TState : notnull => null;
            public bool IsEnabled(LogLevel logLevel) => true;
            public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception exception,
                Func<TState, Exception, string> formatter) =>
                entries.Add(new CapturedLog(logLevel, eventId, formatter(state, exception), exception,
                    (state as IEnumerable<KeyValuePair<string, object>>)?.ToArray() ?? []));
        }
    }

    [TestMethod]
    public async Task RemoteFailure_LogsStableStructuredCodeWithoutFailureDetailsOrTokens()
    {
        using var capture = new CaptureLoggerProvider();
        var services = new ServiceCollection();
        services.AddLogging(logging => logging.AddProvider(capture));
        var configuration = Configuration();
        services.AddSingleton(configuration);
        services.AddCphApplication(configuration);
        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptionsMonitor<OpenIdConnectOptions>>()
            .Get(OpenIdConnectDefaults.AuthenticationScheme);
        capture.Entries.Clear();
        var http = new DefaultHttpContext { RequestServices = provider };
        http.Request.QueryString = new QueryString("?error_description=private-description&id_token=private-token");
        http.User = new ClaimsPrincipal(new ClaimsIdentity([new Claim("name", "private-claim")], "test"));
        var context = new RemoteFailureContext(http,
            new AuthenticationScheme(OpenIdConnectDefaults.AuthenticationScheme, null, typeof(OpenIdConnectHandler)), options,
            new InvalidOperationException("private-failure", new Exception("private-inner")));
        await options.Events.OnRemoteFailure(context);
        Assert.AreEqual(StatusCodes.Status302Found, http.Response.StatusCode);
        Assert.AreEqual("/Account/AuthenticationFailed", http.Response.Headers.Location.ToString());
        Assert.IsTrue(context.Result.Handled);
        var warning = capture.Entries.Single(entry => entry.Event.Id == 1001);
        Assert.AreEqual(LogLevel.Warning, warning.Level);
        Assert.AreEqual("AuthenticationRejected", warning.Event.Name);
        Assert.AreEqual("OIDC_REMOTE_FAILURE", warning.State.Single(pair => pair.Key == "FailureCode").Value);
        foreach (var entry in capture.Entries)
        {
            Assert.IsNull(entry.Exception);
            Assert.IsFalse(entry.Message.Contains("private-", StringComparison.Ordinal));
            Assert.IsFalse(entry.State.Any(pair => pair.Value?.ToString()?.Contains("private-", StringComparison.Ordinal) == true));
        }
    }

    [TestMethod]
    [DataRow("11111111-1111-1111-1111-111111111111", "EARTH\\M01234", true)]
    [DataRow("44444444-4444-4444-4444-444444444444", "EARTH\\M01234", false)]
    [DataRow("", "EARTH\\M01234", false)]
    [DataRow("11111111-1111-1111-1111-111111111111", "", false)]
    public async Task ValidatedToken_RequiresConfiguredTenantAndAuditClaim(string tenant, string audit, bool expected)
    {
        using var capture = new CaptureLoggerProvider();
        var services = new ServiceCollection();
        services.AddLogging(logging => logging.AddProvider(capture));
        var configuration = Configuration();
        services.AddSingleton(configuration);
        services.AddCphApplication(configuration);
        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptionsMonitor<OpenIdConnectOptions>>()
            .Get(OpenIdConnectDefaults.AuthenticationScheme);
        var claims = new List<Claim>();
        if (!string.IsNullOrEmpty(tenant)) claims.Add(new Claim("tid", tenant));
        if (!string.IsNullOrEmpty(audit)) claims.Add(new Claim("test_audit_name", audit));
        var context = new TokenValidatedContext(
            new DefaultHttpContext { RequestServices = provider },
            new AuthenticationScheme(OpenIdConnectDefaults.AuthenticationScheme, null, typeof(OpenIdConnectHandler)), options,
            new ClaimsPrincipal(new ClaimsIdentity(claims, "validated-test-identity")), new AuthenticationProperties());
        await options.Events.OnTokenValidated(context);
        Assert.AreEqual(expected, context.Result?.Failure == null);
        var warnings = capture.Entries.Where(entry => entry.Event.Id == 1001).ToArray();
        Assert.AreEqual(expected ? 0 : 1, warnings.Length);
        if (!expected)
        {
            var code = string.IsNullOrEmpty(audit) ? "AUDIT_CONTRACT_REJECTED" : "TENANT_CONTRACT_REJECTED";
            Assert.AreEqual(code, warnings.Single().State.Single(pair => pair.Key == "FailureCode").Value);
            Assert.IsNull(warnings.Single().Exception);
            Assert.IsFalse(warnings.Single().Message.Contains("EARTH", StringComparison.Ordinal));
            Assert.IsFalse(warnings.Single().Message.Contains("11111111", StringComparison.Ordinal));
        }
    }

    [TestMethod]
    public void ForwardedHeaders_AreDisabledUntilExplicitProxyTrustIsConfigured()
    {
        var services = new ServiceCollection();
        services.AddCphApplication(Configuration());
        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<ForwardedHeadersOptions>>().Value;
        Assert.AreEqual(ForwardedHeaders.None, options.ForwardedHeaders);
        Assert.AreEqual(0, options.KnownIPNetworks.Count);
        Assert.AreEqual(0, options.KnownProxies.Count);
    }

    [TestMethod]
    public void ForwardedHeaders_TrustOnlyExplicitProxyAddress()
    {
        var settings = Settings();
        settings["ReverseProxy:KnownProxies:0"] = "192.0.2.1";
        var services = new ServiceCollection();
        services.AddCphApplication(Configuration(settings));
        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<ForwardedHeadersOptions>>().Value;
        Assert.AreEqual(1, options.KnownProxies.Count);
        Assert.AreEqual(System.Net.IPAddress.Parse("192.0.2.1"), options.KnownProxies.Single());
        Assert.AreEqual(0, options.KnownIPNetworks.Count);
        Assert.IsFalse(options.RequireHeaderSymmetry);
        Assert.AreEqual(1, options.ForwardLimit);
    }

}
