using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace RPA.CPH.NonSubsidy.Web.Pages.Account;

[AllowAnonymous]
public sealed class AuthenticationFailedModel : PageModel
{
    public IActionResult OnGet() => new ContentResult
    {
        StatusCode = StatusCodes.Status401Unauthorized,
        Content = "Sign-in failed. Contact the application identity owner.",
        ContentType = "text/plain; charset=utf-8"
    };
}
