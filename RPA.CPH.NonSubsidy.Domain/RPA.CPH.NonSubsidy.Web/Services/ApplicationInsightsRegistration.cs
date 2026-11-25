using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using OpenTelemetry.Instrumentation.AspNetCore;
using OpenTelemetry.Resources;

namespace RPA.CPH.NonSubsidy.Web.Services;

public static class ApplicationInsightsRegistration
{
    /// <summary>
    /// Registers the Azure Monitor OpenTelemetry distro when configured, optionally
    /// authenticating ingestion with a user-assigned managed identity.
    /// </summary>
    public static IServiceCollection AddCphApplicationInsights(this IServiceCollection services, IConfiguration configuration)
    {
        // Prefer the Azure environment-variable key; fall back only when it is absent, not blank.
        var connection = configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"] ??
                         configuration["ApplicationInsights:ConnectionString"];
        var identity = configuration["Telemetry:ManagedIdentityClientId"];

        // An explicitly empty identity setting is a configuration error, not an opt-out.
        // Check the section too because configuration providers can expose a key with a null value.
        var hasIdentity = identity != null || configuration.GetSection("Telemetry").GetChildren()
            .Any(child => child.Key.Equals("ManagedIdentityClientId", StringComparison.OrdinalIgnoreCase));

        var clientId = Guid.Empty;

        if (hasIdentity)
        {
            if (!Guid.TryParse(identity, out clientId) || clientId == Guid.Empty)
                throw new InvalidOperationException("Telemetry:ManagedIdentityClientId must identify the user-assigned managed identity.");
            
            if (string.IsNullOrWhiteSpace(connection))
                throw new InvalidOperationException("Telemetry:ManagedIdentityClientId requires an Application Insights connection string.");
        }

        // No connection string means no telemetry registration. An identity without a connection
        // string has already failed above so a deployment mistake cannot silently disable telemetry.
        if (string.IsNullOrWhiteSpace(connection)) return services;

        var credential = hasIdentity
            ? new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(clientId.ToString()))
            : null;

        services.Configure<AspNetCoreTraceInstrumentationOptions>(options =>
            options.Filter = context => context.Request.Path != "/health/live" &&
                                        context.Request.Path != "/health/ready");
        // Keep distro collection and sampling defaults; no application-specific redaction is applied.
        services.AddOpenTelemetry()
            .UseAzureMonitor(options =>
            {
                options.ConnectionString = connection;
                if (credential != null)
                    options.Credential = credential;
            })
            .ConfigureResource(resource => resource.AddService("RPA.CPH.NonSubsidy.Web"));
        
        return services;
    }
}
