using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Microsoft.IdentityModel.Validators;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
[TestCategory("Integration")]
public class SignedTokenAuthenticationTests
{
    [TestMethod]
    public async Task SignedToken_ConfiguredHandlerAndMiwEventsPreserveRawTenantRoleAndAuditClaims()
    {
        using var pipeline = new OfflinePipeline();
        var (validation, context) = await pipeline.ValidateAsync();

        Assert.IsTrue(validation.IsValid);
        Assert.IsNotNull(context);
        Assert.IsNull(context.Result?.Failure);
        Assert.AreEqual(pipeline.Tenant, context.Principal.FindAll("tid").Single().Value);
        Assert.IsFalse(context.Principal.HasClaim(c => c.Type == "http://schemas.microsoft.com/identity/claims/tenantid"));
        Assert.AreEqual("Test.BasicAccess", context.Principal.FindAll("roles").Single().Value);
        Assert.AreEqual("offline-user@example.invalid", AuditIdentity.GetName(context.Principal, "preferred_username"));
        Assert.IsTrue((await pipeline.AuthorizeAsync(context.Principal)).Succeeded);
        Assert.AreEqual(0, pipeline.Logs.Codes.Count);
    }

    [TestMethod]
    public async Task SignedToken_ValidIdentityWithoutRoleIsForbidden()
    {
        using var pipeline = new OfflinePipeline();
        var claims = pipeline.Claims().Where(c => c.Type != "roles").ToList();
        var (validation, context) = await pipeline.ValidateAsync(claims);

        Assert.IsTrue(validation.IsValid);
        Assert.IsNull(context.Result?.Failure);
        Assert.IsFalse((await pipeline.AuthorizeAsync(context.Principal)).Succeeded);
    }

    [TestMethod]
    [DataRow(false)]
    [DataRow(true)]
    public async Task SignedToken_MissingOrAmbiguousAuditClaimIsRejected(bool duplicate)
    {
        using var pipeline = new OfflinePipeline();
        var claims = pipeline.Claims().Where(c => c.Type != "preferred_username").ToList();
        if (duplicate)
        {
            claims.Add(new Claim("preferred_username", "first@example.invalid"));
            claims.Add(new Claim("preferred_username", "second@example.invalid"));
        }
        var (validation, context) = await pipeline.ValidateAsync(claims);

        Assert.IsTrue(validation.IsValid);
        Assert.IsNotNull(context.Result?.Failure);
        CollectionAssert.AreEqual(new[] { "AUDIT_CONTRACT_REJECTED" }, pipeline.Logs.Codes);
    }

    [TestMethod]
    [DataRow(false)]
    [DataRow(true)]
    public async Task SignedToken_ForeignTenantPassingMiwIssuerValidationStillFailsTenantContract(bool approvedAlias)
    {
        using var pipeline = new OfflinePipeline();
        const string foreignTenant = "44444444-4444-4444-4444-444444444444";
        var claims = pipeline.Claims().Where(c => c.Type != "tid").ToList();
        claims.Add(new Claim("tid", foreignTenant));
        if (approvedAlias)
            claims.Add(new Claim("http://schemas.microsoft.com/identity/claims/tenantid", pipeline.Tenant));
        var (validation, context) = await pipeline.ValidateAsync(claims,
            issuer: $"https://login.microsoftonline.com/{foreignTenant}/v2.0",
            validIssuer: "https://login.microsoftonline.com/{tenantid}/v2.0");

        Assert.IsTrue(validation.IsValid, "MIW validates the signed issuer/tenant pair against its supported issuer template.");
        Assert.IsNotNull(context.Result?.Failure, "The application must still enforce its one configured tenant.");
        CollectionAssert.AreEqual(new[] { "TENANT_CONTRACT_REJECTED" }, pipeline.Logs.Codes);
    }

    [TestMethod]
    [DataRow("foreign-tenant")]
    [DataRow("missing-tenant")]
    [DataRow("malformed-tenant")]
    [DataRow("duplicate-tenant")]
    [DataRow("issuer-tenant-mismatch")]
    [DataRow("wrong-audience")]
    [DataRow("wrong-signature")]
    [DataRow("expired")]
    [DataRow("foreign-tenant-with-approved-alias")]
    public async Task SignedToken_InvalidIdentityBoundariesCannotAuthenticate(string scenario)
    {
        using var pipeline = new OfflinePipeline();
        var claims = pipeline.Claims().ToList();
        const string foreignTenant = "44444444-4444-4444-4444-444444444444";
        var issuer = pipeline.Issuer;
        var audience = pipeline.Client;
        var expired = false;
        using var otherRsa = RSA.Create(2048);
        SecurityKey signingKey = null;
        switch (scenario)
        {
            case "foreign-tenant":
            case "foreign-tenant-with-approved-alias":
                claims.RemoveAll(c => c.Type == "tid");
                claims.Add(new Claim("tid", foreignTenant));
                issuer = $"https://login.microsoftonline.com/{foreignTenant}/v2.0";
                if (scenario == "foreign-tenant-with-approved-alias")
                    claims.Add(new Claim("http://schemas.microsoft.com/identity/claims/tenantid", pipeline.Tenant));
                break;
            case "missing-tenant":
                claims.RemoveAll(c => c.Type == "tid");
                break;
            case "malformed-tenant":
                claims.RemoveAll(c => c.Type == "tid");
                claims.Add(new Claim("tid", "not-a-tenant-id"));
                break;
            case "duplicate-tenant":
                claims.Add(new Claim("tid", foreignTenant));
                break;
            case "issuer-tenant-mismatch":
                issuer = $"https://login.microsoftonline.com/{foreignTenant}/v2.0";
                break;
            case "wrong-audience":
                audience = "55555555-5555-5555-5555-555555555555";
                break;
            case "wrong-signature":
                signingKey = new RsaSecurityKey(otherRsa) { KeyId = "offline-signing-key" };
                break;
            case "expired":
                expired = true;
                break;
        }

        var (validation, context) = await pipeline.ValidateAsync(claims, issuer, audience, signingKey, expired);

        Assert.IsTrue(!validation.IsValid || context?.Result?.Failure != null,
            $"The real token-validation and event pipeline must reject {scenario}.");
    }

    private sealed class OfflinePipeline : IDisposable
    {
        private readonly RSA rsa = RSA.Create(2048);
        private readonly RsaSecurityKey key;
        private readonly ServiceProvider provider;
        public OpenIdConnectOptions Options { get; }
        public FailureCodes Logs { get; } = new();
        public string Tenant { get; }
        public string Client { get; }
        public string Issuer { get; }

        public OfflinePipeline()
        {
            var settings = RuntimeConfigurationTests.Settings();
            settings["Identity:AuditNameClaimType"] = "preferred_username";
            Tenant = settings["AzureAd:TenantId"];
            Client = settings["AzureAd:ClientId"];
            Issuer = $"https://login.microsoftonline.com/{Tenant}/v2.0";
            var configuration = RuntimeConfigurationTests.Configuration(settings);
            var services = new ServiceCollection();
            services.AddLogging(logging => logging.AddProvider(Logs));
            services.AddSingleton(configuration);
            services.AddCphApplication(configuration);
            services.AddSingleton<IHttpClientFactory, OfflineHttpClientFactory>();
            provider = services.BuildServiceProvider();
            Options = provider.GetRequiredService<IOptionsMonitor<OpenIdConnectOptions>>()
                .Get(OpenIdConnectDefaults.AuthenticationScheme);
            Assert.IsFalse(Options.UseSecurityTokenValidator);
            Assert.IsInstanceOfType<JsonWebTokenHandler>(Options.TokenHandler);
            key = new RsaSecurityKey(rsa) { KeyId = "offline-signing-key" };
            var metadata = new OpenIdConnectConfiguration { Issuer = Issuer };
            metadata.SigningKeys.Add(key);
            Options.ConfigurationManager = new StaticConfigurationManager<OpenIdConnectConfiguration>(metadata);
            // No discovery or backchannel requests are allowed by these tests.
            Options.Backchannel = new HttpClient(new RejectNetwork());
            // Use the same MIW issuer-validation method with static metadata, avoiding its global authority cache.
            var issuerValidator = AadIssuerValidator.GetAadIssuerValidator(Options.Authority, Options.Backchannel,
                _ => (BaseConfigurationManager)Options.ConfigurationManager);
            IssuerValidator offlineIssuerValidation = issuerValidator.Validate;
            Assert.AreEqual(Options.TokenValidationParameters.IssuerValidator.Method, offlineIssuerValidation.Method);
            Options.TokenValidationParameters.IssuerValidator = offlineIssuerValidation;
        }

        public IEnumerable<Claim> Claims() =>
        [
            new("tid", Tenant),
            new("oid", "33333333-3333-3333-3333-333333333333"),
            new("sub", "offline-subject"),
            new("preferred_username", "offline-user@example.invalid"),
            new("roles", "Test.BasicAccess"),
            new("ver", "2.0")
        ];

        public async Task<(TokenValidationResult Validation, TokenValidatedContext Context)> ValidateAsync(
            IEnumerable<Claim> claims = null, string issuer = null, string audience = null,
            SecurityKey signingKey = null, bool expired = false, string validIssuer = null)
        {
            var token = new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
            {
                Issuer = issuer ?? Issuer,
                Audience = audience ?? Client,
                Subject = new ClaimsIdentity(claims ?? Claims()),
                SigningCredentials = new SigningCredentials(signingKey ?? key, SecurityAlgorithms.RsaSha256),
                IssuedAt = DateTime.UtcNow.AddMinutes(-20),
                NotBefore = DateTime.UtcNow.AddMinutes(-20),
                Expires = DateTime.UtcNow.AddMinutes(expired ? -10 : 5)
            });
            var parameters = Options.TokenValidationParameters.Clone();
            parameters.ConfigurationManager = (BaseConfigurationManager)Options.ConfigurationManager;
            parameters.ValidAudience = Client;
            parameters.ValidIssuer = validIssuer ?? Issuer;
            var validation = await Options.TokenHandler.ValidateTokenAsync(token, parameters);
            if (!validation.IsValid) return (validation, null);
            // OIDC converts its JsonWebToken result to JwtSecurityToken before firing the MIW event chain.
            var context = new TokenValidatedContext(new DefaultHttpContext { RequestServices = provider },
                new AuthenticationScheme(OpenIdConnectDefaults.AuthenticationScheme, null, typeof(OpenIdConnectHandler)),
                Options, new ClaimsPrincipal(validation.ClaimsIdentity), new AuthenticationProperties())
            {
                SecurityToken = new JwtSecurityToken(token)
            };
            await Options.Events.OnTokenValidated(context);
            return (validation, context);
        }

        public Task<AuthorizationResult> AuthorizeAsync(ClaimsPrincipal principal) =>
            provider.GetRequiredService<IAuthorizationService>().AuthorizeAsync(principal, null, ApplicationServices.BasicAccessPolicy);

        public void Dispose()
        {
            Options.Backchannel.Dispose();
            provider.Dispose();
            rsa.Dispose();
        }
    }

    private sealed class RejectNetwork : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Network access is forbidden in signed-token regression tests.");
    }

    private sealed class OfflineHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(new RejectNetwork());
    }

    private sealed class FailureCodes : ILoggerProvider
    {
        public List<string> Codes { get; } = [];
        public ILogger CreateLogger(string categoryName) => new Logger(Codes);
        public void Dispose() { }

        private sealed class Logger(List<string> codes) : ILogger
        {
            public IDisposable BeginScope<TState>(TState state) where TState : notnull => null;
            public bool IsEnabled(LogLevel level) => true;
            public void Log<TState>(LogLevel level, EventId eventId, TState state, Exception exception,
                Func<TState, Exception, string> formatter)
            {
                if (eventId.Id == 1001 && state is IEnumerable<KeyValuePair<string, object>> values)
                    codes.Add((string)values.Single(pair => pair.Key == "FailureCode").Value);
            }
        }
    }
}
