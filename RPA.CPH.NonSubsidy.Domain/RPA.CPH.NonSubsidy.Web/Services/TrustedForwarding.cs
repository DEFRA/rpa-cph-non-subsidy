using System.Net;
using Microsoft.AspNetCore.HttpOverrides;

namespace RPA.CPH.NonSubsidy.Web.Services;

public static class TrustedForwarding
{
    public static IServiceCollection AddCphForwarding(this IServiceCollection services, IConfiguration configuration)
    {
        var proxies = configuration.GetSection("ReverseProxy:KnownProxies").Get<string[]>() ?? [];
        var networks = configuration.GetSection("ReverseProxy:KnownIPNetworks").Get<string[]>() ?? [];
        var addresses = proxies.Select(proxy =>
        {
            if (!IPAddress.TryParse(proxy, out var address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any))
                throw new InvalidOperationException("ReverseProxy:KnownProxies must contain explicit proxy IP addresses, not wildcard trust.");
            return address;
        }).ToArray();
        var ranges = networks.Select(network =>
        {
            if (!System.Net.IPNetwork.TryParse(network, out var range) || range.PrefixLength == 0 ||
                range.BaseAddress.Equals(IPAddress.Any) || range.BaseAddress.Equals(IPAddress.IPv6Any) ||
                !network.Equals(range.ToString(), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("ReverseProxy:KnownIPNetworks must contain canonical explicit proxy CIDRs, not wildcard trust.");
            return range;
        }).ToArray();
        services.Configure<ForwardedHeadersOptions>(options =>
        {
            options.KnownProxies.Clear();
            options.KnownIPNetworks.Clear();
            foreach (var address in addresses) options.KnownProxies.Add(address);
            foreach (var range in ranges) options.KnownIPNetworks.Add(range);
            options.ForwardLimit = 1;
            // ACA overwrites Proto, but appends For. Only the rightmost For is consumed.
            options.RequireHeaderSymmetry = false;
            // Empty trust lists mean "trust all" to the middleware, so disable processing when unconfigured.
            options.ForwardedHeaders = addresses.Length + ranges.Length == 0 ? ForwardedHeaders.None :
                ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
        });
        return services;
    }

}
