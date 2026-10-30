using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace RPA.CPH.NonSubsidy.Web.Pages.Account;

[Authorize]
public sealed class SignOutModel : PageModel
{
    public void OnGet() { }

    public IActionResult OnPost() =>
        SignOut(new AuthenticationProperties { RedirectUri = Url.Page("/Account/SignedOut") },
            CookieAuthenticationDefaults.AuthenticationScheme, OpenIdConnectDefaults.AuthenticationScheme);
}
