using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace RPA.CPH.NonSubsidy.Web.Pages.Account;

[AllowAnonymous]
public sealed class AccessDeniedModel : PageModel
{
    public IActionResult OnGet() => new ContentResult
    {
        StatusCode = StatusCodes.Status403Forbidden,
        Content = "Access denied. The required application role has not been assigned.",
        ContentType = "text/plain; charset=utf-8"
    };
}
