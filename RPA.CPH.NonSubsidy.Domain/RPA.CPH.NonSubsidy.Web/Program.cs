using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Server.IIS;
using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.Migrations;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;
using RPA.CPH.NonSubsidy.Web.Models;
using RPA.CPH.NonSubsidy.Web.Services;
using System.Data.Entity.Migrations;

var builder = WebApplication.CreateBuilder(args);

var cphConnectionString = builder.Configuration.GetConnectionString("CPHContext")
    ?? throw new InvalidOperationException("Connection string 'CPHContext' is not configured.");

// IIS in-process hosting authenticates the user itself; Kestrel needs the Negotiate handler.
var hostedInIis = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("APP_POOL_ID"));
if (hostedInIis)
{
    builder.Services.AddAuthentication(IISServerDefaults.AuthenticationScheme);
}
else
{
    builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme).AddNegotiate();
}

builder.Services.AddAuthorization(options =>
{
    options.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
});

builder.Services.AddMemoryCache();
builder.Services.AddSingleton<IClaimsTransformation, IdtRoleClaimsTransformation>();

builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<IUser, User>();
builder.Services.AddScoped<IUnitOfWork>(_ => new UnitOfWork(new CPHContext(cphConnectionString)));

builder.Services.AddControllersWithViews();

var app = builder.Build();

// Schema changes are normally applied by the deployment pipeline; this switch keeps the previous
// "migrate on start-up" behaviour available for environments that still need it.
if (builder.Configuration.GetValue<bool>("ApplyMigrationsOnStartup"))
{
    new DbMigrator(new Configuration(cphConnectionString)).Update();
}

if (app.Environment.IsDevelopment())
{
    app.UseDeveloperExceptionPage();
}
else
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseRequestLocalization(new RequestLocalizationOptions()
    .SetDefaultCulture("en-GB")
    .AddSupportedCultures("en-GB")
    .AddSupportedUICultures("en-GB"));

app.UseStaticFiles();
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();

app.MapControllerRoute(
    name: "Default",
    pattern: "{controller=Home}/{action=Index}/{id?}");

app.Run();

public partial class Program { }
